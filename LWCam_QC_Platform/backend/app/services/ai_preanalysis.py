"""Background scanner that runs the AI metadata check before a reviewer opens a folder.

QC Platform stage. Every few seconds (settings.ai_preanalysis_*) it looks for
folders that are PENDING, unclaimed and have images, and queues an AI review
job for each one the AI coordinator (app.services.ai_review) has not seen yet.
It only works when both switches are on: AI review (stage 1, plus an API key)
and pre-analysis (stage 2). On startup it also cancels jobs whose folder is no
longer reviewable. Started and stopped from app.main's lifespan hook.
"""
from __future__ import annotations

import logging
import threading
from collections.abc import Callable

from sqlalchemy import func, select

from app.core.config import settings
from app.db.session import SessionLocal
from app.models.capture import CaptureBox, CaptureFolder
from app.models.project import Project
from app.services.sweep import PeriodicSweep
from app.services.ai_review import (
    AiReviewCoordinator,
    AiReviewDisabledError,
    AiReviewError,
    AiReviewSnapshot,
    ai_review_available,
    ai_review_coordinator,
)


logger = logging.getLogger("uvicorn.error")
SnapshotLoader = Callable[[int], list[AiReviewSnapshot]]
PreanalysisContinuationCheck = Callable[[int], bool]
ManualContinuationCheck = Callable[[int, str], bool]


def _reviewable_conditions():
    return (
        func.lower(CaptureFolder.qc_status) == "pending",
        CaptureFolder.is_deleted.is_not(True),
        CaptureFolder.folder_path.is_not(None),
        CaptureFolder.box.has(CaptureBox.is_deleted.is_not(True)),
        CaptureFolder.box.has(CaptureBox.project.has(Project.is_deleted.is_not(True))),
        CaptureFolder.images.any(),
    )


def _scan_eligible_conditions():
    return (*_reviewable_conditions(), CaptureFolder.qc_locked_by.is_(None))


def _folder_is_scan_eligible(folder_id: int) -> bool:
    with SessionLocal() as db:
        return bool(db.scalar(
            select(func.count())
            .select_from(CaptureFolder)
            .where(CaptureFolder.id == folder_id, *_scan_eligible_conditions())
        ))


def _preanalysis_can_continue(folder_id: int) -> bool:
    with SessionLocal() as db:
        return bool(db.scalar(
            select(func.count())
            .select_from(CaptureFolder)
            .where(CaptureFolder.id == folder_id, *_reviewable_conditions())
        ))


def _manual_can_continue(folder_id: int, user_id: str) -> bool:
    with SessionLocal() as db:
        return bool(db.scalar(
            select(func.count())
            .select_from(CaptureFolder)
            .where(
                CaptureFolder.id == folder_id,
                *_reviewable_conditions(),
                CaptureFolder.qc_locked_by == user_id,
            )
        ))


def load_preanalysis_snapshots(limit: int) -> list[AiReviewSnapshot]:
    # Imported lazily to keep the router/service dependency acyclic at startup.
    from app.routers.qc import folder_options, official_ai_review_snapshot

    page_size = settings.ai_preanalysis_scan_batch_size
    max_candidates = max(limit, page_size) * 5
    snapshots: list[AiReviewSnapshot] = []
    offset = 0
    while len(snapshots) < max_candidates and offset < max_candidates:
        with SessionLocal() as db:
            folders = db.scalars(
                select(CaptureFolder)
                .options(*folder_options())
                .where(*_scan_eligible_conditions())
                .order_by(CaptureFolder.source_created_at.asc().nullslast(), CaptureFolder.id.asc())
                .offset(offset)
                .limit(page_size)
            ).unique().all()
            for folder in folders:
                if len(snapshots) >= max_candidates:
                    break
                image_count = len(folder.images)
                if image_count < 1 or image_count > settings.ai_review_max_images:
                    logger.info(
                        "AI preanalysis skipped; folder_id=%s reason=image_count images=%s",
                        folder.id,
                        image_count,
                    )
                    continue
                try:
                    snapshots.append(official_ai_review_snapshot(folder))
                except Exception as error:
                    logger.warning(
                        "AI preanalysis skipped; folder_id=%s reason=unreadable_input error_type=%s",
                        folder.id,
                        type(error).__name__,
                    )
        if len(folders) < page_size:
            break
        offset += len(folders)
    return snapshots


class AiPreanalysisScheduler(PeriodicSweep):
    """Periodic sweep that queues pre-analysis jobs and reconciles stale ones."""

    def __init__(
        self,
        coordinator: AiReviewCoordinator = ai_review_coordinator,
        snapshot_loader: SnapshotLoader = load_preanalysis_snapshots,
        eligibility_check: Callable[[int], bool] = _folder_is_scan_eligible,
        preanalysis_continuation_check: PreanalysisContinuationCheck = _preanalysis_can_continue,
        manual_continuation_check: ManualContinuationCheck = _manual_can_continue,
    ) -> None:
        self.coordinator = coordinator
        self.snapshot_loader = snapshot_loader
        self.eligibility_check = eligibility_check
        self.preanalysis_continuation_check = preanalysis_continuation_check
        self.manual_continuation_check = manual_continuation_check
        self._scan_lock = threading.RLock()
        super().__init__(
            "lwcam-ai-preanalysis-scan",
            tick=self.scan_once,
            interval=lambda: settings.ai_preanalysis_scan_interval_seconds,
            enabled=AiPreanalysisScheduler.enabled,
        )

    @staticmethod
    def enabled() -> bool:
        # Stage 2 of the switch, and it only means anything on top of stage 1.
        return bool(
            settings.ai_preanalysis_enabled and AiPreanalysisScheduler.available()
        )

    @staticmethod
    def available() -> bool:
        """Whether the scanner COULD run — stage 1 on, and a key to call with.

        Lets the console explain why the automatic switch is unavailable instead of
        silently accepting a setting that does nothing.
        """
        return ai_review_available()

    def apply_enabled(self) -> bool:
        """Start or stop the scanner thread to match the current switch."""
        if self.enabled():
            self.start()
            return True
        self.stop()
        return False

    def scan_once(self) -> int:
        if not self.enabled():
            return 0
        active = self.coordinator.active_preanalysis_count()
        available = max(0, settings.ai_preanalysis_queue_limit - active)
        limit = min(available, settings.ai_preanalysis_scan_batch_size)
        if limit <= 0:
            logger.info("AI preanalysis scan complete; active=%s enqueued=0 queue_full=true", active)
            return 0

        enqueued = 0
        cached = 0
        failed = 0
        for snapshot in self.snapshot_loader(limit):
            if self.coordinator.has_known_preanalysis(snapshot):
                cached += 1
                continue
            with self._scan_lock:
                if not self.eligibility_check(snapshot.folder_id):
                    logger.info(
                        "AI preanalysis skipped; folder_id=%s reason=no_longer_eligible",
                        snapshot.folder_id,
                    )
                    continue
                try:
                    job = self.coordinator.enqueue(snapshot, trigger="preanalysis", force=False)
                except (AiReviewDisabledError, AiReviewError) as error:
                    failed += 1
                    logger.warning(
                        "AI preanalysis enqueue failed; folder_id=%s error_type=%s",
                        snapshot.folder_id,
                        type(error).__name__,
                    )
                    continue
                if job["status"] in {"queued", "running"}:
                    enqueued += 1
                elif job["status"] == "succeeded":
                    cached += 1
                else:
                    failed += 1
            if enqueued >= limit:
                break
        logger.info(
            "AI preanalysis scan complete; active_before=%s enqueued=%s cached=%s skipped_or_failed=%s",
            active,
            enqueued,
            cached,
            failed,
        )
        return enqueued

    def cancel_for_finalization(self, folder_id: int, *, reason: str) -> int:
        # This lock closes the race between a final eligibility check and enqueue.
        with self._scan_lock:
            return self.coordinator.cancel_active_jobs(folder_id, reason=reason)

    def cancel_manual_for_release(self, folder_id: int) -> int:
        with self._scan_lock:
            return self.coordinator.cancel_active_jobs(
                folder_id,
                reason="task_released",
                triggers={"manual"},
            )

    def reconcile_active_jobs(self) -> int:
        cancelled = 0
        with self._scan_lock:
            for descriptor in self.coordinator.active_job_descriptors():
                folder_id = int(descriptor["folderId"])
                trigger = str(descriptor.get("trigger") or "manual")
                try:
                    if trigger == "preanalysis":
                        eligible = self.preanalysis_continuation_check(folder_id)
                    else:
                        user_id = descriptor.get("userId")
                        eligible = bool(
                            isinstance(user_id, str)
                            and user_id
                            and self.manual_continuation_check(folder_id, user_id)
                        )
                except Exception as error:
                    logger.warning(
                        "AI review startup reconciliation skipped; folder_id=%s job_id=%s "
                        "trigger=%s error_type=%s",
                        folder_id,
                        descriptor["jobId"],
                        trigger,
                        type(error).__name__,
                    )
                    continue
                if not eligible:
                    cancelled += self.coordinator.cancel_job(
                        str(descriptor["jobId"]),
                        reason="no_longer_reviewable_on_resume",
                    )
        if cancelled:
            logger.info("AI review startup reconciliation cancelled jobs=%s", cancelled)
        return cancelled

    def reconcile_ineligible_jobs(self) -> int:
        """Backward-compatible alias for the broader startup reconciliation."""
        return self.reconcile_active_jobs()



ai_preanalysis_scheduler = AiPreanalysisScheduler()


__all__ = [
    "AiPreanalysisScheduler",
    "ai_preanalysis_scheduler",
    "load_preanalysis_snapshots",
]

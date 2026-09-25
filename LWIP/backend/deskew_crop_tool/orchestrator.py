from __future__ import annotations

import hashlib
import json
import logging
from logging.handlers import RotatingFileHandler
import os
import shutil
import signal
import time
from concurrent.futures import (
    FIRST_COMPLETED,
    BrokenExecutor,
    CancelledError,
    Future,
    ProcessPoolExecutor,
    ThreadPoolExecutor,
    wait,
)
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Callable

from .config import ToolConfig
from .image_ops import deskew_crop_file, fs_path, initialise_worker


LOGGER = logging.getLogger("deskew_crop")
MANIFEST_NAME = ".deskew_crop_manifest.json"


def _thumb_rel(relative: str) -> str:
    # Thumbnails are always JPEG; name them with the source's stem + a .jpg
    # extension (page1.png -> page1.jpg) rather than appending (page1.png.jpg)
    # — shorter, so deep destinations stay well under Windows MAX_PATH.
    # Collision ceiling: two sources in one folder differing only by extension
    # would map to the same thumb — impossible in capture output (unique .jpg
    # device names); revisit only if that stops being true.
    return PurePosixPath(relative).with_suffix(".jpg").as_posix()


@dataclass(frozen=True)
class FileSnapshot:
    folder: Path
    files: tuple[tuple[str, int, int], ...]
    fingerprint: str
    newest_mtime_ns: int

    @property
    def image_count(self) -> int:
        return len(self.files)


@dataclass
class StabilityRecord:
    fingerprint: str
    unchanged_since: float


class StateStore:
    def __init__(self, path: Path):
        self.path = path
        self.data = self._load()
        # Drop completions whose source folder no longer exists so state.json
        # can't grow unbounded as old day folders are cleared. A folder that
        # still exists is never pruned (pruning it would trigger a reprocess).
        if self._prune_missing():
            self._save()

    def _prune_missing(self) -> bool:
        completed = self.data.get("completed")
        if not isinstance(completed, dict):
            return False
        removed = False
        for folder_str in list(completed.keys()):
            try:
                exists = fs_path(Path(folder_str)).exists()
            except OSError:
                exists = True  # unreadable ≠ gone; keep it
            if not exists:
                del completed[folder_str]
                removed = True
        return removed

    def completed_record(self, folder: Path) -> dict[str, object] | None:
        item = self.data["completed"].get(str(folder.resolve()))
        return item if isinstance(item, dict) else None

    def completed_fingerprint(self, folder: Path) -> str | None:
        item = self.completed_record(folder)
        if not item or item.get("retry_required"):
            return None
        return str(item.get("fingerprint"))

    def mark_completed(
        self,
        snapshot: FileSnapshot,
        output_folder: Path,
        manifest_checksum: str,
    ) -> None:
        now = time.time()
        self.data["completed"][str(snapshot.folder.resolve())] = {
            "fingerprint": snapshot.fingerprint,
            "image_count": snapshot.image_count,
            "output_folder": str(output_folder.resolve()),
            "manifest_checksum": manifest_checksum,
            "completed_at": datetime.now(timezone.utc).isoformat(),
            "last_presence_check_epoch": now,
            "last_checksum_check_epoch": now,
            "retry_required": False,
        }
        self._save()

    # NOTE: mark_integrity_checked() was removed with the periodic idle audit
    # (see _try_adopt / the release model in scan_once). The two
    # last_*_check_epoch fields are still written by mark_completed for
    # state-file compatibility with older builds, but nothing reads them.

    def mark_reported(self, folder: Path, reason: str | None = None) -> None:
        """Records that this completion has reached the database.

        Same shape as mark_for_retry: mutate the entry in place and persist. An
        extra per-entry key is inert to older builds - _load only checks
        version == 1 - and the two dead last_*_check_epoch fields are the
        standing precedent for that.

        `reason` is set only when the entry is being settled WITHOUT a write
        (no usable identity), so the journal distinguishes "sent" from "there
        was nothing to send".
        """
        item = self.completed_record(folder)
        if item is None:
            return
        item["reported_at"] = datetime.now(timezone.utc).isoformat()
        if reason:
            item["reported_skip_reason"] = reason
        self._save()

    def mark_for_retry(self, folder: Path, reason: str) -> None:
        item = self.completed_record(folder)
        if item is None:
            return
        item["retry_required"] = True
        item["integrity_error"] = reason
        item["integrity_failed_at"] = datetime.now(timezone.utc).isoformat()
        self._save()

    def _load(self) -> dict[str, object]:
        backup = self.path.with_suffix(f"{self.path.suffix}.bak")
        for candidate in (self.path, backup):
            if not candidate.exists():
                continue
            try:
                value = json.loads(candidate.read_text(encoding="utf-8"))
                if value.get("version") != 1 or not isinstance(
                    value.get("completed"), dict
                ):
                    raise ValueError("unsupported state file format")
                if candidate == backup:
                    LOGGER.error(
                        "Recovered integrity state from backup after the primary failed"
                    )
                return value
            except (OSError, ValueError, json.JSONDecodeError) as exc:
                LOGGER.error("Cannot read integrity state %s: %s", candidate, exc)
        if self.path.exists() or backup.exists():
            LOGGER.error(
                "No valid integrity state remains; all source folders will be reprocessed"
            )
        return {"version": 1, "completed": {}}

    def _save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix(f"{self.path.suffix}.tmp")
        with temporary.open("w", encoding="utf-8", newline="\n") as stream:
            json.dump(self.data, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, self.path)
        try:
            _copy_file_atomic(
                self.path,
                self.path.with_suffix(f"{self.path.suffix}.bak"),
            )
        except Exception as exc:
            LOGGER.warning("Could not update integrity state backup: %s", exc)


class FolderChangedError(RuntimeError):
    pass


class OutputIntegrityError(RuntimeError):
    pass


@dataclass
class ActiveFolder:
    """One folder's private staging state inside the shared image pool."""

    snapshot: FileSnapshot
    work_folder: Path
    staged_folder: Path
    stage: str = "crop"
    next_job: int = 0
    completed_jobs: int = 0
    in_flight: int = 0
    thumbnails_created: bool = False
    thumbnail_failed: bool = False
    failed: bool = False
    # Per-image angle/lossless/qc_ops from deskew_crop_file, keyed by the
    # source-relative path, so _publish can carry them into the matching
    # manifest files[] entry (the contract QC's replay reads).
    image_results: dict[str, dict[str, object]] = field(default_factory=dict)

    @property
    def job_count(self) -> int:
        return self.snapshot.image_count


class FolderOrchestrator:
    # How long a starting orchestrator waits for a live one to release the lock.
    # Station Setup's save asks the running LWIP to stop and starts this one
    # right away; the old one finishes the folder it is publishing first, which
    # at q100 can take minutes. Generous, because giving up leaves image
    # processing dead until the next logon.
    LOCK_WAIT_SECONDS = 15 * 60

    def __init__(self, config: ToolConfig):
        self._bind(config)

    def _bind(self, config: ToolConfig) -> None:
        self.config = config
        self.state = StateStore(config.state_file)
        self.stability: dict[Path, StabilityRecord] = {}
        # Seen but not admitted because it is not ready yet. With a completion
        # marker configured, _is_ready never records the folder in stability,
        # so without this set the console showed "0 waiting" while a folder sat
        # there for want of its marker - the one case an operator must see.
        self.not_ready: set[Path] = set()
        self.stop_requested = False
        # Resolved once. None means reporting is off for this run - either the
        # config says so, or the station has no credentials to offer - and the
        # sweep then costs nothing per poll.
        self._pg = None
        if config.cloud_report:
            from . import cloud_report

            self._pg = cloud_report.settings_from_config(config)
            if self._pg is None:
                # load_config already refuses a cloud_report=true file with no
                # db_host/db_user/db_password, so this only fires when a
                # caller builds ToolConfig directly (tests, benchmark_lwip).
                # There is no other writer to fall back on any more: finished
                # folders simply will not reach QC until this is fixed.
                LOGGER.info(
                    "Cloud reporting is on but no database settings were found "
                    "- finished folders will not reach QC"
                )

    # Written by whoever needs this process gone: Setup before it overwrites
    # the backend, and Station Setup's save before it starts a replacement.
    STOP_FILE_NAME = "stop.request"
    # Machine-wide alternative, for a writer that cannot resolve work_root
    # without parsing LWIP's own config.json - the installer's uninstall step
    # is one. %ProgramData% is a fixed path no elevation or profile switch can
    # move, unlike a per-user location, so it works the same for an elevated
    # installer and for LWIP itself running as SYSTEM.
    STOP_FILE_SHARED = "LWCAM/lwip.stop"

    def _stop_file_candidates(self) -> list[Path]:
        paths = [self.config.work_root / self.STOP_FILE_NAME]
        program_data = os.environ.get("ProgramData")
        if program_data:
            paths.append(Path(program_data) / self.STOP_FILE_SHARED)
        return paths

    def _stop_file_requested(self) -> bool:
        """True once, when an external stop file appears.

        The signal handlers below cannot be reached from outside on Windows.
        LWIP runs as `pythonw.exe`: no console, so no CTRL_BREAK, and no window,
        so `taskkill` without /F has nothing to post WM_CLOSE to. `/F` is
        TerminateProcess, which skips the handler entirely. A polled file is the
        one channel that works, and this loop already polls.

        The file is deleted as it is READ, not on exit: a stale one left by a
        crashed installer would otherwise make LWIP quit on every start, which
        is a worse failure than the one being fixed - image processing would
        stop suite-wide with nothing in the log to explain it.
        """
        requested = False
        for marker in self._stop_file_candidates():
            target = fs_path(marker)
            try:
                if not target.is_file():
                    continue
                target.unlink(missing_ok=True)
            except OSError as exc:
                # Unreadable is not a stop request; a transient AV lock must
                # not take image processing down.
                LOGGER.warning("Could not read the stop file %s: %s", marker, exc)
                continue
            requested = True
        return requested

    def run_forever(
        self,
        *,
        lock_wait: float = LOCK_WAIT_SECONDS,
        reload_config: Callable[[], ToolConfig] | None = None,
    ) -> None:
        self._prepare_directories()
        self._install_signal_handlers()
        with instance_lock(
            self.config.work_root / "orchestrator.lock", wait=lock_wait
        ):
            acquired_at = time.time()
            if reload_config is not None:
                # The wait above can last minutes, and Station Setup may have
                # saved again meanwhile - possibly starting yet another waiter.
                # Whichever one wins runs the settings on disk NOW; the losers
                # time out and exit. Without this a waiter started by an
                # earlier save would come up with that save's config.
                self._bind(reload_config())
                self._prepare_directories()
            # Only now, holding the lock: a stop request can only be meant for
            # a running orchestrator, and there is none. Newer than the
            # acquisition means it is addressed to THIS process, so it stays.
            self._clear_stale_stop_files(older_than=acquired_at)
            LOGGER.info(
                "Watching %s with %d image worker process(es)",
                self.config.input_root,
                self.config.workers,
            )
            self._run_scheduler(keep_running=True, wait_for_stability=True)
        LOGGER.info("Deskew/crop orchestrator stopped")

    def run_once(self, *, wait_for_stability: bool = False) -> int:
        self._prepare_directories()
        with instance_lock(self.config.work_root / "orchestrator.lock"):
            self._clear_stale_stop_files(older_than=time.time())
            return self._run_scheduler(
                keep_running=False, wait_for_stability=wait_for_stability
            )

    def scan_once(self) -> bool:
        """Process one ready folder for compatibility with the old API."""
        return bool(
            self._run_scheduler(
                keep_running=False,
                wait_for_stability=False,
                active_limit=1,
                stop_after=1,
            )
        )

    def _run_scheduler(
        self,
        *,
        keep_running: bool,
        wait_for_stability: bool,
        active_limit: int | None = None,
        stop_after: int | None = None,
    ) -> int:
        """Keep many folders moving through one shared image-worker pool.

        Images, rather than folders, are scheduled round-robin. A folder only
        publishes after all of its own work has completed, preserving the
        existing atomic hand-off to QC.
        """
        active_limit = active_limit or min(self.config.workers, 16)
        active: list[ActiveFolder] = []
        image_futures: dict[Future[object], ActiveFolder] = {}
        publish_future: Future[tuple[Path, str]] | None = None
        publishing: ActiveFolder | None = None
        completed = 0
        round_robin = 0
        attempted: set[Path] = set()

        with ProcessPoolExecutor(
            max_workers=self.config.workers,
            initializer=initialise_worker,
        ) as image_executor, ThreadPoolExecutor(max_workers=1) as publisher:
            try:
                while True:
                    if not self.stop_requested and self._stop_file_requested():
                        LOGGER.info(
                            "Stop file seen; finishing the folder already "
                            "publishing and exiting"
                        )
                        self.stop_requested = True
                    stopping = self.stop_requested or (
                        stop_after is not None and completed >= stop_after
                    )
                    if stopping:
                        self._cancel_unpublished(active, image_futures)
                    else:
                        self._admit_ready_folders(active, active_limit, attempted)
                        self._write_status_snapshot(active)
                        round_robin = self._submit_image_jobs(
                            image_executor, active, image_futures, round_robin
                        )
                        if publish_future is None:
                            ready = next(
                                (item for item in active if item.stage == "publish"),
                                None,
                            )
                            if ready is not None:
                                ready.stage = "publishing"
                                publishing = ready
                                publish_future = publisher.submit(
                                    self._publish_active_folder, ready
                                )

                    futures: set[Future[object]] = set(image_futures)
                    if publish_future is not None:
                        futures.add(publish_future)
                    if futures:
                        done, _pending = wait(futures, return_when=FIRST_COMPLETED)
                        for future in done:
                            if future is publish_future:
                                publish_future = None
                                item = publishing
                                publishing = None
                                if item is not None:
                                    completed += self._finish_publish(item, future, active)
                                continue
                            item = image_futures.pop(future)
                            item.in_flight -= 1
                            self._finish_image_job(item, future, image_futures)
                        continue

                    self._remove_finished_failures(active)
                    if stopping:
                        break
                    if active:
                        # Only folders waiting for the single publishing lane
                        # remain. The next loop starts it immediately.
                        continue
                    if not keep_running:
                        if not wait_for_stability or not self._has_uncompleted_folders():
                            return completed
                    # A daemon may retry a failed folder on its next poll; a
                    # one-shot run must not spin on the same failure.
                    attempted.clear()
                    # Quiescent: no image or publish work is in flight, so this
                    # is the one point per poll where a blocking database call
                    # cannot stall anything else. See _sweep_unreported.
                    self._sweep_unreported()
                    self._sleep_interruptibly(self.config.poll_interval_seconds)
            except BrokenExecutor:
                # A poisoned worker pool cannot safely accept more jobs. The
                # service supervisor restarts LWIP; unjournaled output is
                # adopted or regenerated on that next run.
                LOGGER.exception("Image worker pool failed; stopping for supervisor restart")
                raise
            finally:
                for item in active:
                    if item.stage != "completed":
                        shutil.rmtree(fs_path(item.work_folder), ignore_errors=True)
        return completed

    def _admit_ready_folders(
        self, active: list[ActiveFolder], active_limit: int, attempted: set[Path]
    ) -> None:
        candidates = self._candidate_folders()
        candidate_set = set(candidates)
        for old_path in set(self.stability) - candidate_set:
            self.stability.pop(old_path, None)
        self.not_ready &= candidate_set

        for folder in candidates:
            if len(active) >= active_limit:
                return
            if folder in attempted:
                continue
            if any(item.snapshot.folder == folder for item in active):
                continue
            attempted.add(folder)
            try:
                snapshot = build_snapshot(folder, self.config)
                if snapshot is None:
                    continue
                record = self.state.completed_record(folder)
                completed = (
                    record is not None
                    and record.get("fingerprint") == snapshot.fingerprint
                    and not record.get("retry_required")
                )
                if completed:
                    # RELEASED: journaled outputs are never re-examined. QC owns
                    # the output folder from here and edits it in place.
                    self.stability.pop(folder, None)
                    continue
                force_retry = bool(
                    record
                    and record.get("fingerprint") == snapshot.fingerprint
                    and record.get("retry_required")
                )
                # No journal entry (or a stale one) but the output already holds
                # a matching valid manifest — adopt it instead of regenerating.
                # Checked before the readiness gate so a QC-authored child
                # folder is adopted immediately, not after a marker wait.
                if not force_retry and self._try_adopt(snapshot):
                    self.stability.pop(folder, None)
                    continue
                if not force_retry and not self._is_ready(snapshot):
                    self.not_ready.add(folder)
                    continue
                self.not_ready.discard(folder)
                confirmed = build_snapshot(folder, self.config)
                if confirmed is None or confirmed.fingerprint != snapshot.fingerprint:
                    self._observe(confirmed)
                    continue
                active.append(self._start_folder(snapshot))
                self.stability.pop(folder, None)
            except FolderChangedError as exc:
                LOGGER.warning("%s", exc)
                self.stability.pop(folder, None)
            except Exception:
                LOGGER.exception("Folder admission failed: %s", folder)
                self.stability.pop(folder, None)

    def _write_status_snapshot(self, active: list[ActiveFolder]) -> None:
        """Cheapest possible progress snapshot for the console (service.py).

        Reuses folders already known from this scan pass - self.stability
        (seen but not yet ready/admitted) and the active list (work in
        flight) - rather than walking the filesystem again. Never allowed to
        break processing: a write failure here is logged and swallowed.
        """
        try:
            status_path = self.config.state_file.parent / "status.json"
            _write_json_atomic(
                status_path,
                {
                    "updated_at": datetime.now(timezone.utc).isoformat(),
                    "waiting": sorted(str(folder) for folder in set(self.stability) | self.not_ready),
                    "processing": [str(item.snapshot.folder) for item in active],
                },
            )
        except Exception:
            LOGGER.debug("Could not write status.json", exc_info=True)

    def _start_folder(self, snapshot: FileSnapshot) -> ActiveFolder:
        folder = snapshot.folder
        work_folder = self.config.work_root / _work_name(folder)
        staged_folder = work_folder / "output"
        shutil.rmtree(fs_path(work_folder), ignore_errors=True)
        fs_path(staged_folder).mkdir(parents=True, exist_ok=True)
        LOGGER.info("Starting folder %s (%d images)", folder, snapshot.image_count)
        LOGGER.info("deskew/crop started for %s (%d images)", folder, snapshot.image_count)
        return ActiveFolder(snapshot, work_folder, staged_folder)

    def _submit_image_jobs(
        self,
        executor: ProcessPoolExecutor,
        active: list[ActiveFolder],
        futures: dict[Future[object], ActiveFolder],
        round_robin: int,
    ) -> int:
        while len(futures) < self.config.workers:
            runnable = [item for item in active if self._can_submit(item)]
            if not runnable:
                return round_robin
            item = runnable[round_robin % len(runnable)]
            round_robin += 1
            future = executor.submit(*self._next_submission(item))
            item.in_flight += 1
            futures[future] = item
        return round_robin

    def _can_submit(self, item: ActiveFolder) -> bool:
        return (
            not item.failed
            and item.stage == "crop"
            and item.next_job < item.job_count
        )

    def _next_submission(self, item: ActiveFolder) -> tuple[object, ...]:
        relative = item.snapshot.files[item.next_job][0]
        item.next_job += 1
        thumbnail_destination: str | None = None
        if self.config.thumbnail_width > 0:
            thumbnail_destination = str(
                item.staged_folder
                / self.config.thumbnail_dirname
                / _thumb_rel(relative)
            )
        return (
            deskew_crop_file,
            str(item.snapshot.folder / relative),
            str(item.staged_folder / relative),
            self.config.crop_padding,
            self.config.jpeg_quality,
            thumbnail_destination,
            self.config.thumbnail_width,
            self.config.thumbnail_quality,
            self.config.deskew_min_degrees,
        )

    def _finish_image_job(
        self,
        item: ActiveFolder,
        future: Future[object],
        futures: dict[Future[object], ActiveFolder],
    ) -> None:
        try:
            result = future.result()
        except CancelledError:
            pass
        except BrokenExecutor:
            raise
        except Exception:
            LOGGER.exception("Folder processing failed: %s", item.snapshot.folder)
            item.failed = True
            item.next_job = item.job_count
            self._cancel_folder_jobs(item, futures)
        else:
            if not item.failed:
                item.completed_jobs += 1
                if isinstance(result, dict):
                    # relative_to succeeds because _next_submission builds the
                    # source path as exactly `item.snapshot.folder / relative`.
                    try:
                        relative = (
                            Path(str(result.get("source")))
                            .relative_to(item.snapshot.folder)
                            .as_posix()
                        )
                    except ValueError:
                        relative = None
                    if relative is not None:
                        item.image_results[relative] = result
                if self.config.thumbnail_width > 0 and not bool(
                    result.get("thumbnail_created") if isinstance(result, dict) else False
                ):
                    if not item.thumbnail_failed:
                        LOGGER.warning(
                            "Thumbnail stage failed for %s; completing without thumbnails",
                            item.snapshot.folder,
                        )
                    item.thumbnail_failed = True

        if item.failed:
            return
        if item.stage == "crop" and item.completed_jobs == item.job_count and item.in_flight == 0:
            LOGGER.info("deskew/crop completed for %s", item.snapshot.folder)
            if item.thumbnail_failed:
                shutil.rmtree(
                    fs_path(item.staged_folder / self.config.thumbnail_dirname),
                    ignore_errors=True,
                )
                item.thumbnails_created = False
            elif self.config.thumbnail_width > 0:
                item.thumbnails_created = True
                LOGGER.info("thumbnails completed for %s", item.snapshot.folder)
            item.stage = "publish"

    def _cancel_folder_jobs(
        self, item: ActiveFolder, futures: dict[Future[object], ActiveFolder]
    ) -> None:
        for future, owner in futures.items():
            if owner is item:
                future.cancel()

    def _cancel_unpublished(
        self, active: list[ActiveFolder], futures: dict[Future[object], ActiveFolder]
    ) -> None:
        for item in active:
            if item.stage != "publishing":
                item.failed = True
                item.next_job = item.job_count
                self._cancel_folder_jobs(item, futures)

    def _remove_finished_failures(self, active: list[ActiveFolder]) -> None:
        for item in list(active):
            if item.failed and item.in_flight == 0:
                shutil.rmtree(fs_path(item.work_folder), ignore_errors=True)
                active.remove(item)

    def _publish_active_folder(self, item: ActiveFolder) -> tuple[Path, str]:
        self._require_unchanged(item.snapshot)
        output_folder = self.config.output_root / item.snapshot.folder.relative_to(
            self.config.input_root
        )
        manifest_checksum = self._publish(
            item.staged_folder,
            output_folder,
            item.snapshot,
            thumbnails_created=item.thumbnails_created,
            source_identity=self._read_source_identity(item.snapshot.folder),
            image_results=item.image_results,
        )
        return output_folder, manifest_checksum

    def _finish_publish(
        self,
        item: ActiveFolder,
        future: Future[tuple[Path, str]],
        active: list[ActiveFolder],
    ) -> int:
        try:
            output_folder, manifest_checksum = future.result()
            self.state.mark_completed(item.snapshot, output_folder, manifest_checksum)
            item.stage = "completed"
            LOGGER.info("Completed folder %s -> %s", item.snapshot.folder, output_folder)
            return 1
        except Exception:
            item.failed = True
            LOGGER.exception("Folder publishing failed: %s", item.snapshot.folder)
            return 0
        finally:
            shutil.rmtree(fs_path(item.work_folder), ignore_errors=True)
            if item in active:
                active.remove(item)

    def _read_source_identity(self, folder: Path) -> dict[str, object] | None:
        # The completion marker doubles as the folder's DB-identity payload;
        # embed it in the manifest so the LWCAM reporting agent never has to
        # parse paths. Read tolerantly — a bad/absent marker just means no
        # identity travels through (the agent then skips reporting it).
        marker_name = self.config.completion_marker
        if not marker_name:
            return None
        marker_path = fs_path(folder / marker_name)
        try:
            if not marker_path.is_file():
                return None
            value = json.loads(marker_path.read_text(encoding="utf-8"))
            return value if isinstance(value, dict) else None
        except Exception as exc:
            LOGGER.warning("Could not read completion marker %s: %s", marker_path, exc)
            return None

    def _publish(
        self,
        staged_folder: Path,
        output_folder: Path,
        snapshot: FileSnapshot,
        *,
        thumbnails_created: bool = False,
        source_identity: dict[str, object] | None = None,
        image_results: dict[str, dict[str, object]] | None = None,
    ) -> str:
        suffix = hashlib.sha256(str(snapshot.folder).encode("utf-8")).hexdigest()[:12]
        publishing = output_folder.with_name(
            f".{output_folder.name}-{suffix}.publishing"
        )
        previous = output_folder.with_name(
            f".{output_folder.name}-{suffix}.previous"
        )
        shutil.rmtree(fs_path(publishing), ignore_errors=True)
        if fs_path(output_folder).exists():
            shutil.rmtree(fs_path(previous), ignore_errors=True)
        fs_path(publishing).mkdir(parents=True)

        try:
            manifest_files = []
            for relative, _size, _mtime in snapshot.files:
                source = staged_folder / relative
                destination = publishing / relative
                size_bytes, checksum = _copy_file_atomic(source, destination)
                # angle/lossless/qc_ops: the deferred-straightening contract
                # QC's preview/export replay reads. Defaults cover a relative
                # path that somehow never reported (should not happen — see
                # _finish_image_job) so the key is always present.
                result = (image_results or {}).get(relative, {})
                manifest_files.append(
                    {
                        "relative_path": relative,
                        "size_bytes": size_bytes,
                        "sha256": checksum,
                        "angle": result.get("angle", 0.0),
                        "lossless": bool(result.get("lossless", False)),
                        "qc_ops": result.get("qc_ops", []),
                    }
                )

            thumbnail_files = []
            if thumbnails_created:
                for relative, _size, _mtime in snapshot.files:
                    thumb_rel = f"{self.config.thumbnail_dirname}/{_thumb_rel(relative)}"
                    source = staged_folder / thumb_rel
                    destination = publishing / thumb_rel
                    size_bytes, checksum = _copy_file_atomic(source, destination)
                    thumbnail_files.append(
                        {
                            "relative_path": thumb_rel,
                            "size_bytes": size_bytes,
                            "sha256": checksum,
                        }
                    )

            manifest = {
                "version": 1,
                "source_folder": str(snapshot.folder.resolve()),
                "source_fingerprint": snapshot.fingerprint,
                "image_count": snapshot.image_count,
                "created_at": datetime.now(timezone.utc).isoformat(),
                "files": manifest_files,
                "thumbnails": {
                    "created": bool(thumbnails_created),
                    "dirname": self.config.thumbnail_dirname,
                    "files": thumbnail_files,
                },
            }
            if source_identity is not None:
                manifest["source_identity"] = source_identity
            manifest_path = publishing / MANIFEST_NAME
            _write_json_atomic(manifest_path, manifest)
            manifest_checksum = _sha256_file(manifest_path)
            verify_output(
                publishing,
                snapshot,
                manifest_checksum,
                extensions=self.config.extensions,
                deep=False,
                thumbnail_dirname=self.config.thumbnail_dirname,
            )
        except Exception:
            shutil.rmtree(fs_path(publishing), ignore_errors=True)
            raise

        moved_previous = False
        try:
            if fs_path(output_folder).exists():
                os.replace(fs_path(output_folder), fs_path(previous))
                moved_previous = True
            os.replace(fs_path(publishing), fs_path(output_folder))
            # DEEP (re-read every byte and compare sha256) because this is the
            # LAST time the tool ever looks at this output: once mark_completed
            # journals it, the folder is released to QC, which edits those files
            # in place. Catching a bad publish here is the whole failsafe — the
            # old periodic audit could not tell corruption from a QC edit and
            # "repaired" committed review work.
            verify_output(
                output_folder,
                snapshot,
                manifest_checksum,
                extensions=self.config.extensions,
                deep=True,
                thumbnail_dirname=self.config.thumbnail_dirname,
            )
        except Exception:
            if moved_previous and fs_path(previous).exists():
                if fs_path(output_folder).exists():
                    shutil.rmtree(fs_path(output_folder), ignore_errors=True)
                os.replace(fs_path(previous), fs_path(output_folder))
            raise
        finally:
            shutil.rmtree(fs_path(publishing), ignore_errors=True)
        shutil.rmtree(fs_path(previous), ignore_errors=True)
        return manifest_checksum

    def _try_adopt(self, snapshot: FileSnapshot) -> bool:
        """Journal an input folder whose output ALREADY holds a matching, valid
        manifest — without reprocessing it.

        Two producers rely on this:
          * QC separation, which splits a reviewed folder into children and
            writes each child's input dir, marker and manifest itself. Without
            adoption those brand-new input folders would look like fresh work
            and be regenerated from the originals, reverting the split.
          * recovery — a lost/corrupt state.json re-adopts every completed
            folder instead of reprocessing the entire history.

        Deliberately strict: the manifest's fingerprint must equal the input's
        current fingerprint AND a deep verify_output must pass, so a stale or
        tampered output is never adopted (it falls through to reprocessing).
        """
        folder = snapshot.folder
        try:
            output_folder = self.config.output_root / folder.relative_to(
                self.config.input_root
            )
        except ValueError:
            return False
        manifest_path = fs_path(output_folder / MANIFEST_NAME)
        if not manifest_path.is_file():
            return False
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            if not isinstance(manifest, dict):
                return False
            if str(manifest.get("source_fingerprint") or "") != snapshot.fingerprint:
                return False
            manifest_checksum = _sha256_file(manifest_path)
            verify_output(
                output_folder,
                snapshot,
                manifest_checksum,
                extensions=self.config.extensions,
                deep=True,
                thumbnail_dirname=self.config.thumbnail_dirname,
                should_continue=lambda: not self.stop_requested,
            )
        except InterruptedError:
            raise
        except Exception as exc:
            LOGGER.info(
                "Existing output not adoptable (will reprocess) for %s: %s",
                folder,
                exc,
            )
            return False
        self.state.mark_completed(snapshot, output_folder, manifest_checksum)
        LOGGER.info("Adopted existing output: %s -> %s", folder, output_folder)
        return True

    def _is_ready(self, snapshot: FileSnapshot) -> bool:
        if self.config.completion_marker:
            if not fs_path(snapshot.folder / self.config.completion_marker).is_file():
                return False
            return True
        record = self.stability.get(snapshot.folder)
        now = time.monotonic()
        if record is None or record.fingerprint != snapshot.fingerprint:
            self.stability[snapshot.folder] = StabilityRecord(
                fingerprint=snapshot.fingerprint,
                unchanged_since=now,
            )
            return self.config.stable_seconds == 0 and self._old_enough(snapshot)
        return (
            now - record.unchanged_since >= self.config.stable_seconds
            and self._old_enough(snapshot)
        )

    def _old_enough(self, snapshot: FileSnapshot) -> bool:
        newest_seconds = snapshot.newest_mtime_ns / 1_000_000_000
        return time.time() - newest_seconds >= self.config.minimum_file_age_seconds

    def _observe(self, snapshot: FileSnapshot | None) -> None:
        if snapshot is None:
            return
        self.stability[snapshot.folder] = StabilityRecord(
            fingerprint=snapshot.fingerprint,
            unchanged_since=time.monotonic(),
        )

    def _require_unchanged(self, expected: FileSnapshot) -> None:
        current = build_snapshot(expected.folder, self.config)
        if current is None or current.fingerprint != expected.fingerprint:
            raise FolderChangedError(
                f"Input changed while processing; discarded staged output for {expected.folder}"
            )

    def _candidate_folders(self) -> list[Path]:
        # iterdir runs on the SHORT parent (the input root, then a YYYYMMDD day),
        # so enumeration itself is never near MAX_PATH and the names it yields
        # stay logical — which is what has to be returned, since these paths
        # become state.json keys and cloud_report rows. Only the per-child
        # is_dir() probe touches the long path, so only that takes fs_path.
        try:
            top = [
                path
                for path in self.config.input_root.iterdir()
                if fs_path(path).is_dir()
            ]
        except FileNotFoundError:
            LOGGER.warning("Input root does not exist: %s", self.config.input_root)
            return []
        if self.config.folder_depth == 1:
            folders = top
        else:
            # Depth 2: each grandchild dir (e.g. YYYYMMDD/<folder>) is a job.
            # Day-root siblings (CSVs, logs/) are never image folders and
            # carry no marker, so they're skipped naturally downstream.
            folders = []
            for day in top:
                try:
                    folders.extend(
                        child for child in day.iterdir() if fs_path(child).is_dir()
                    )
                except OSError:
                    continue
        return sorted(folders, key=_folder_order)

    def _has_uncompleted_folders(self) -> bool:
        for folder in self._candidate_folders():
            snapshot = build_snapshot(folder, self.config)
            if snapshot and self.state.completed_fingerprint(folder) != snapshot.fingerprint:
                return True
        return False

    def _prepare_directories(self) -> None:
        self.config.input_root.mkdir(parents=True, exist_ok=True)
        self.config.output_root.mkdir(parents=True, exist_ok=True)
        self.config.work_root.mkdir(parents=True, exist_ok=True)

    def _clear_stale_stop_files(self, *, older_than: float) -> None:
        """Drops any stop request left over from BEFORE this process held the lock.

        A stop request can only ever be meant for a process that was already
        running, so one sitting there at startup is stale by definition.
        Clearing it here makes the mechanism immune to a writer that forgets to
        clean up after itself - which is not hypothetical: Station Setup's save
        stops LWIP and then starts a replacement, and the first version of that
        code left its own request behind, so the new process read it and exited
        two milliseconds after logging "Watching". Image processing stopped
        suite-wide and the only trace was one line in this log.

        Belt to the braces of the writers deleting their own files: this is a
        silent-stop failure, and the cost of being wrong is a folder waiting one
        extra poll interval.

        Called AFTER taking the instance lock, never before: a starting process
        may wait on that lock behind a live orchestrator that is still draining,
        and a request written for that one must survive until it reads it.
        [older_than] is the lock acquisition time; a marker newer than that was
        written for this process and is honoured on the first poll.
        """
        for marker in self._stop_file_candidates():
            target = fs_path(marker)
            try:
                if target.is_file() and target.stat().st_mtime < older_than:
                    target.unlink(missing_ok=True)
            except OSError as exc:
                LOGGER.warning("Could not clear a stale stop file %s: %s", marker, exc)

    def _install_signal_handlers(self) -> None:
        def request_stop(_signum, _frame) -> None:
            LOGGER.info("Stop requested; waiting for active image work to finish")
            self.stop_requested = True

        for signal_name in ("SIGINT", "SIGTERM"):
            value = getattr(signal, signal_name, None)
            if value is not None:
                signal.signal(value, request_stop)

    def _sweep_unreported(self) -> None:
        """Reports every completed folder that has not reached the database yet.

        A sweep rather than a hook on completion, because there are TWO ways a
        folder enters the journal: _finish_publish and _try_adopt (an existing
        valid output adopted without reprocessing - QC folder splits, state
        recovery). A hook on the first would silently miss the second.

        Sweeping also makes retry free: an entry stays unreported until it is
        written, the journal survives restarts, and so a folder finished before a
        week-long outage reports itself when the network comes back. Nothing is
        ever given up on, which is the whole point - the failure being removed
        here is a batch sitting invisible to QC until someone opens an app.

        One WRITE per poll, deliberately: a backlog drains at one row every
        poll_interval rather than holding the scheduler through a long serial
        run of database calls. An entry whose row has not synced yet is
        skipped, not returned on - otherwise the first such entry blocks every
        folder behind it for as long as it stays unresolved.
        """
        if self._pg is None:
            return
        from . import cloud_report

        completed = self.state.data.get("completed")
        if not isinstance(completed, dict):
            return
        self._settle_predating_entries(completed)

        for folder_str, item in list(completed.items()):
            if not isinstance(item, dict):
                continue
            if item.get("reported_at") or item.get("retry_required"):
                continue
            output_folder = item.get("output_folder")
            if not output_folder:
                continue
            manifest_path = fs_path(Path(output_folder) / MANIFEST_NAME)
            try:
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                # Output not readable yet, or gone. Leave it unreported and try
                # again next poll rather than settling it on a transient read.
                continue
            # Guard against reporting output that belongs to an older run of the
            # same folder, the same check LWCAM's agent makes.
            if manifest.get("source_fingerprint") != item.get("fingerprint"):
                continue

            result = cloud_report.report_folder(
                self._pg, manifest, Path(output_folder)
            )
            if result is cloud_report.ReportResult.REPORTED:
                self.state.mark_reported(Path(folder_str))
                LOGGER.info("Reported to database: %s", output_folder)
            elif result is cloud_report.ReportResult.NO_IDENTITY:
                # No marker, so no row can ever be resolved. Settle it or the
                # sweep retries it forever.
                self.state.mark_reported(Path(folder_str), reason="no_identity")
                LOGGER.info(
                    "No capture identity in manifest - not reporting: %s",
                    output_folder,
                )
            elif result is cloud_report.ReportResult.UNREACHABLE:
                # The database itself is the problem; the next entry would only
                # fail the same way. Try again next poll.
                return
            else:
                # NOT_YET: this folder's row has not synced. The next entry may
                # have one, so keep going; one short round trip per stuck entry.
                continue
            return

    def _settle_predating_entries(self, completed: dict) -> None:
        """Marks every entry completed before reporting was switched on as sent.

        Until then LWCAM's agent was the only writer, so those folders have
        already reached the database - and QC may since have moved them on to
        PASS or REWORK. Replaying them through the unconditional UPDATE would
        reset each one to PENDING. Runs once: the journal remembers the switch-on.
        """
        if self.state.data.get("cloud_report_since"):
            return
        for folder_str, item in completed.items():
            if isinstance(item, dict) and not item.get("reported_at"):
                item["reported_at"] = datetime.now(timezone.utc).isoformat()
                item["reported_skip_reason"] = "predates_reporting"
        self.state.data["cloud_report_since"] = datetime.now(timezone.utc).isoformat()
        self.state._save()

    def _sleep_interruptibly(self, seconds: float) -> None:
        deadline = time.monotonic() + seconds
        while not self.stop_requested and time.monotonic() < deadline:
            time.sleep(min(0.25, max(0, deadline - time.monotonic())))


def build_snapshot(folder: Path, config: ToolConfig) -> FileSnapshot | None:
    pattern = "**/*" if config.recursive else "*"
    values: list[tuple[str, int, int]] = []
    # Enumerated through fs_path, relative_to the SAME prefixed root: a long
    # folder name would otherwise glob to nothing and the folder would look
    # empty, which build_snapshot reports as "no work here" rather than as an
    # error. The stored values stay relative, so no prefix is journalled.
    fs_folder = fs_path(folder)
    for path in fs_folder.glob(pattern):
        if not path.is_file() or path.suffix.lower() not in config.extensions:
            continue
        stat = path.stat()
        values.append(
            (path.relative_to(fs_folder).as_posix(), stat.st_size, stat.st_mtime_ns)
        )
    if not values:
        return None
    values.sort(key=lambda item: item[0].lower())
    digest = hashlib.sha256()
    for relative, size, modified in values:
        digest.update(relative.encode("utf-8", errors="surrogatepass"))
        digest.update(b"\0")
        digest.update(str(size).encode("ascii"))
        digest.update(b"\0")
        digest.update(str(modified).encode("ascii"))
        digest.update(b"\n")
    return FileSnapshot(
        folder=folder,
        files=tuple(values),
        fingerprint=digest.hexdigest(),
        newest_mtime_ns=max(item[2] for item in values),
    )


def verify_output(
    output_folder: Path,
    snapshot: FileSnapshot,
    expected_manifest_checksum: str,
    *,
    extensions: tuple[str, ...],
    deep: bool,
    thumbnail_dirname: str | None = None,
    should_continue: Callable[[], bool] | None = None,
) -> None:
    if not fs_path(output_folder).is_dir():
        raise OutputIntegrityError(f"output folder is missing: {output_folder}")
    manifest_path = fs_path(output_folder / MANIFEST_NAME)
    if not manifest_path.is_file():
        raise OutputIntegrityError(f"integrity manifest is missing: {manifest_path}")
    manifest_bytes = manifest_path.read_bytes()
    manifest_checksum = hashlib.sha256(manifest_bytes).hexdigest()
    if not expected_manifest_checksum or manifest_checksum != expected_manifest_checksum:
        raise OutputIntegrityError("integrity manifest checksum does not match state")
    try:
        manifest = json.loads(manifest_bytes.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise OutputIntegrityError(f"integrity manifest is invalid: {exc}") from exc
    if (
        manifest.get("version") != 1
        or manifest.get("source_fingerprint") != snapshot.fingerprint
        or manifest.get("image_count") != snapshot.image_count
        or not isinstance(manifest.get("files"), list)
    ):
        raise OutputIntegrityError("integrity manifest does not match the source snapshot")

    expected_paths = {relative for relative, _size, _mtime in snapshot.files}
    entries: dict[str, dict[str, object]] = {}
    for item in manifest["files"]:
        if not isinstance(item, dict):
            raise OutputIntegrityError("integrity manifest contains an invalid file entry")
        relative = str(item.get("relative_path") or "")
        path = Path(relative)
        if not relative or path.is_absolute() or ".." in path.parts or relative in entries:
            raise OutputIntegrityError("integrity manifest contains an unsafe file path")
        entries[relative] = item
    if set(entries) != expected_paths:
        raise OutputIntegrityError("integrity manifest file list does not match input")

    thumb_prefix = f"{thumbnail_dirname}/" if thumbnail_dirname else None
    # fs_path both sides: an unprefixed glob on a long output path yields
    # nothing, and "nothing" here reads as "the publish lost every file" —
    # this audit is the last gate before the folder is released to QC.
    fs_output = fs_path(output_folder)
    actual_paths = {
        path.relative_to(fs_output).as_posix()
        for path in fs_output.glob("**/*")
        if path.is_file() and path.suffix.lower() in extensions
    }
    if thumb_prefix:
        # Thumbnails are also image-extension files but live under the thumbs
        # dir — they're verified separately below, not as source images.
        actual_paths = {rel for rel in actual_paths if not rel.startswith(thumb_prefix)}
    if actual_paths != expected_paths:
        raise OutputIntegrityError("output image list is missing files or contains extras")

    for relative in sorted(expected_paths, key=str.lower):
        if should_continue is not None and not should_continue():
            raise InterruptedError("Stop requested during output integrity audit")
        path = output_folder / relative
        item = entries[relative]
        try:
            expected_size = int(item["size_bytes"])
            expected_checksum = str(item["sha256"])
        except (KeyError, TypeError, ValueError) as exc:
            raise OutputIntegrityError(
                f"invalid integrity values for {relative}"
            ) from exc
        fs_item = fs_path(path)
        if not fs_item.is_file() or fs_item.stat().st_size != expected_size:
            raise OutputIntegrityError(f"output is missing or has the wrong size: {relative}")
        if deep and _sha256_file(path) != expected_checksum:
            raise OutputIntegrityError(f"output checksum mismatch: {relative}")

    _verify_thumbnails(
        output_folder, manifest, thumbnail_dirname, deep=deep, should_continue=should_continue
    )


def _verify_thumbnails(
    output_folder: Path,
    manifest: dict,
    thumbnail_dirname: str | None,
    *,
    deep: bool,
    should_continue: Callable[[], bool] | None,
) -> None:
    thumbs = manifest.get("thumbnails")
    if not isinstance(thumbs, dict):
        return  # pre-thumbnail manifest — nothing to check
    dir_name = str(thumbs.get("dirname") or thumbnail_dirname or "thumbs")
    thumb_dir = output_folder / dir_name
    if not thumbs.get("created"):
        # Stage was skipped/failed — the thumbs dir must not linger with files.
        if fs_path(thumb_dir).is_dir() and any(fs_path(thumb_dir).iterdir()):
            raise OutputIntegrityError(
                "thumbnails marked not-created but the thumbnail directory is non-empty"
            )
        return

    prefix = f"{dir_name}/"
    entries: dict[str, dict[str, object]] = {}
    for item in thumbs.get("files", []):
        if not isinstance(item, dict):
            raise OutputIntegrityError("integrity manifest contains an invalid thumbnail entry")
        relative = str(item.get("relative_path") or "")
        path = Path(relative)
        if (
            not relative
            or path.is_absolute()
            or ".." in path.parts
            or not relative.startswith(prefix)
            or relative in entries
        ):
            raise OutputIntegrityError("integrity manifest contains an unsafe thumbnail path")
        entries[relative] = item

    fs_output = fs_path(output_folder)
    fs_thumb = fs_path(thumb_dir)
    actual = {
        p.relative_to(fs_output).as_posix()
        for p in fs_thumb.glob("**/*")
        if p.is_file()
    } if fs_thumb.is_dir() else set()
    if actual != set(entries):
        raise OutputIntegrityError("output thumbnail list is missing files or contains extras")

    for relative in sorted(entries, key=str.lower):
        if should_continue is not None and not should_continue():
            raise InterruptedError("Stop requested during output integrity audit")
        path = output_folder / relative
        item = entries[relative]
        try:
            expected_size = int(item["size_bytes"])
            expected_checksum = str(item["sha256"])
        except (KeyError, TypeError, ValueError) as exc:
            raise OutputIntegrityError(
                f"invalid thumbnail integrity values for {relative}"
            ) from exc
        fs_item = fs_path(path)
        if not fs_item.is_file() or fs_item.stat().st_size != expected_size:
            raise OutputIntegrityError(
                f"thumbnail is missing or has the wrong size: {relative}"
            )
        if deep and _sha256_file(path) != expected_checksum:
            raise OutputIntegrityError(f"thumbnail checksum mismatch: {relative}")


def configure_logging(config: ToolConfig, *, verbose: bool = False) -> None:
    config.log_file.parent.mkdir(parents=True, exist_ok=True)
    level = logging.DEBUG if verbose else logging.INFO
    formatter = logging.Formatter(
        "%(asctime)s %(levelname)s %(processName)s %(message)s"
    )
    console = logging.StreamHandler()
    console.setFormatter(formatter)
    file_handler = RotatingFileHandler(
        config.log_file,
        maxBytes=10 * 1024 * 1024,
        backupCount=5,
        encoding="utf-8",
    )
    file_handler.setFormatter(formatter)
    root = logging.getLogger()
    root.handlers.clear()
    root.setLevel(level)
    root.addHandler(console)
    root.addHandler(file_handler)


@contextmanager
def instance_lock(path: Path, *, wait: float = 0.0):
    """Holds the single-instance lock; with [wait] > 0, retries for that long.

    Waiting is what lets Station Setup start a replacement while the previous
    LWIP is still finishing its last folder: the new process parks here, the
    old one exits, and the new one takes over. Before this the replacement
    died on the held lock and nothing processed images until the next logon.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    stream = path.open("a+b")
    acquired = False
    try:
        stream.seek(0)
        if stream.tell() == 0 and path.stat().st_size == 0:
            stream.write(b"0")
            stream.flush()
        stream.seek(0)
        deadline = time.monotonic() + wait
        announced = False
        while True:
            try:
                if os.name == "nt":
                    import msvcrt

                    msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl

                    fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
                break
            except OSError as exc:
                if time.monotonic() >= deadline:
                    raise RuntimeError(
                        "Another deskew/crop orchestrator is already running"
                    ) from exc
                if not announced:
                    LOGGER.info(
                        "Another orchestrator holds %s; waiting up to %ds for it to exit",
                        path,
                        wait,
                    )
                    announced = True
                time.sleep(1)
        yield
    finally:
        try:
            if acquired:
                stream.seek(0)
                if os.name == "nt":
                    import msvcrt

                    msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
                else:
                    import fcntl

                    fcntl.flock(stream.fileno(), fcntl.LOCK_UN)
        finally:
            stream.close()


def _folder_order(path: Path) -> tuple[int, str]:
    try:
        return fs_path(path).stat().st_mtime_ns, path.name.lower()
    except OSError:
        return 0, path.name.lower()


def _work_name(folder: Path) -> str:
    suffix = hashlib.sha256(str(folder.resolve()).encode("utf-8")).hexdigest()[:12]
    return f"{folder.name}-{suffix}"


def _copy_file_atomic(source: Path, destination: Path) -> tuple[int, str]:
    # fs_path on every call that touches the disk: the temp name below is the
    # LONGEST path this pipeline ever builds, so it is the first to hit
    # MAX_PATH. See image_ops.fs_path.
    fs_destination = fs_path(destination)
    fs_path(destination.parent).mkdir(parents=True, exist_ok=True)
    temporary = fs_path(destination.with_name(f".{destination.name}.{os.getpid()}.tmp"))
    checksum = hashlib.sha256()
    size_bytes = 0
    try:
        with fs_path(source).open("rb") as source_stream, temporary.open(
            "wb"
        ) as output_stream:
            while chunk := source_stream.read(4 * 1024 * 1024):
                output_stream.write(chunk)
                checksum.update(chunk)
                size_bytes += len(chunk)
            output_stream.flush()
            os.fsync(output_stream.fileno())
        os.replace(temporary, fs_destination)
    finally:
        temporary.unlink(missing_ok=True)
    if fs_destination.stat().st_size != size_bytes:
        raise OutputIntegrityError(f"published file size mismatch: {destination}")
    return size_bytes, checksum.hexdigest()


def _write_json_atomic(path: Path, value: dict[str, object]) -> None:
    temporary = fs_path(path.with_name(f".{path.name}.{os.getpid()}.tmp"))
    try:
        with temporary.open("w", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, fs_path(path))
    finally:
        temporary.unlink(missing_ok=True)


def _sha256_file(path: Path) -> str:
    checksum = hashlib.sha256()
    with fs_path(path).open("rb") as stream:
        while chunk := stream.read(4 * 1024 * 1024):
            checksum.update(chunk)
    return checksum.hexdigest()

"""Tells the rest of the suite this server is alive (service_heartbeat, migration 007).

Two rows per PC: `qc` (review backlog) and `qc-export` (export failure ledger).
Every 60 s. A failure is logged at most once per 10 minutes and never reaches
the server: a heartbeat is a report, not a duty.
"""

from __future__ import annotations

import json
import logging
import socket
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from sqlalchemy import func, select, text

from app.core.config import settings
from app.core.paths import to_local
from app.db.session import SessionLocal
from app.models.capture import CaptureFolder
from app.services.export import export_auto_scheduler, export_coordinator
from app.services.sweep import PeriodicSweep

logger = logging.getLogger(__name__)

INTERVAL_SECONDS = 60.0
LOG_EVERY_SECONDS = 600.0
STARTED_AT = datetime.now(timezone.utc)

# last_ok keeps its old value when this beat has no success to report;
# last_error is overwritten, so it clears once the problem is gone.
UPSERT_SQL = text(
    """
    INSERT INTO service_heartbeat
        (part, host, version, started_at, last_seen, last_ok, last_error, last_error_at, backlog)
    VALUES
        (:part, :host, :version, :started_at, now(), :last_ok, :last_error, :last_error_at,
         CAST(:backlog AS jsonb))
    ON CONFLICT (part, host) DO UPDATE SET
        version = EXCLUDED.version,
        started_at = EXCLUDED.started_at,
        last_seen = now(),
        last_ok = COALESCE(EXCLUDED.last_ok, service_heartbeat.last_ok),
        last_error = EXCLUDED.last_error,
        last_error_at = EXCLUDED.last_error_at,
        backlog = EXCLUDED.backlog
    """
)


def read_version() -> str:
    """`VERSION.txt` from the install root (the installer writes it), else `dev`."""
    roots = [Path(__file__).resolve().parents[i] for i in range(2, 5)]
    roots.append(Path(sys.executable).resolve().parent)
    for root in roots:
        try:
            value = (root / "VERSION.txt").read_text(encoding="utf-8-sig").strip()
        except OSError:
            continue
        if value:
            return value
    return "dev"


VERSION = read_version()


INPUT_CHECK_TIMEOUT = 5.0


def input_unreachable(folder_path: str | None) -> bool:
    """True when the input share cannot be reached (timeout or OS error).

    Resolves ONE sample PENDING folder like the QC engine does (qcInputRoot /
    to_local) and looks for it in a worker thread so a dead UNC share cannot
    stall the beat. A folder that is simply gone while its root answers is
    "not found", not "unreachable". ponytail: a hung probe thread is abandoned
    (daemon), not killed.
    """
    if not folder_path:
        return False
    result: list[bool] = []

    def probe() -> None:
        try:
            path = to_local(folder_path)
            if path.exists():
                result.append(False)
                return
            root = Path(settings.qc_images_root) if settings.qc_images_root.strip() else path.parent
            result.append(not root.exists())
        except OSError:
            result.append(True)

    worker = threading.Thread(target=probe, daemon=True)
    worker.start()
    worker.join(INPUT_CHECK_TIMEOUT)
    return bool(result[0]) if result else True


def _rows() -> list[dict[str, Any]]:
    """The two rows to write this beat (raises if the DB cannot be read)."""
    with SessionLocal() as db:
        pending = db.scalar(
            select(func.count()).select_from(CaptureFolder).where(
                CaptureFolder.is_deleted.is_not(True), func.lower(CaptureFolder.qc_status) == "pending"
            )
        )
        # Age is taken from the DB's own now() so PC clocks cannot skew it.
        # updated_at is the last change to the folder, i.e. its approval, as an
        # approved folder is not touched again until it is exported.
        approved, oldest_approved = db.execute(
            select(
                func.count(),
                func.extract("epoch", func.now() - func.min(CaptureFolder.updated_at)) / 60,
            ).where(
                CaptureFolder.is_deleted.is_not(True),
                func.lower(CaptureFolder.qc_status) == "pass",
                CaptureFolder.is_exported.is_not(True),
            )
        ).one()
        sample = db.scalar(
            select(CaptureFolder.folder_path).where(
                CaptureFolder.is_deleted.is_not(True),
                func.lower(CaptureFolder.qc_status) == "pending",
                CaptureFolder.folder_path.is_not(None),
            ).order_by(CaptureFolder.id.desc()).limit(1)
        )
    unreachable = input_unreachable(sample)
    run = export_coordinator.current() or {}
    blocked = export_auto_scheduler.blocked_reason
    now = datetime.now(timezone.utc)
    failures = export_coordinator.read_failures()  # newest first
    newest = failures[0] if failures else {}
    failed_at = None
    if newest.get("failedAt"):
        try:
            failed_at = datetime.fromisoformat(str(newest["failedAt"]))
            if failed_at.tzinfo is None:
                failed_at = failed_at.replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    base = {"host": socket.gethostname(), "version": VERSION, "started_at": STARTED_AT}
    return [
        {**base, "part": "qc", "last_ok": now, "last_error": None, "last_error_at": None,
         "backlog": {
             "pending_review": int(pending or 0),
             "approved_not_exported": int(approved or 0),
             "oldest_approved_minutes": int(oldest_approved or 0),
             "exports_busy": int(run.get("skipped") or 0),
             "input_unreachable": unreachable,
         },
         **({"last_error": "Input folder is unreachable", "last_error_at": now, "last_ok": None}
            if unreachable else {})},
        {**base, "part": "qc-export", "last_ok": None if failures or blocked else now,
         "last_error": blocked or (str(newest.get("error"))[:200] if failures else None),
         "last_error_at": now if blocked else (failed_at if failures else None),
         "backlog": {"failures": len(failures)}},
    ]


_last_logged = float("-inf")


def beat() -> None:
    """One heartbeat. Never raises."""
    global _last_logged
    try:
        rows = _rows()
        with SessionLocal() as db:
            for row in rows:
                db.execute(UPSERT_SQL, {**row, "backlog": json.dumps(row["backlog"])})
            db.commit()
    except Exception as error:
        if time.monotonic() - _last_logged > LOG_EVERY_SECONDS:
            _last_logged = time.monotonic()
            logger.warning("heartbeat failed: %s", error)


heartbeat_sweep = PeriodicSweep("heartbeat", tick=beat, interval=lambda: INTERVAL_SECONDS)

STALE_SECONDS = 300.0
UPLOAD_STALE_SECONDS = 900.0
BACKUP_MAX_AGE_SECONDS = 26 * 3600.0
HIDE_AFTER_DAYS = 7
EXPECTED_PARTS = ("qc", "qc-export", "lwip", "upload", "backup")


def _num(backlog: dict, key: str) -> float:
    try:
        return float(backlog.get(key) or 0)
    except (TypeError, ValueError):
        return 0.0


def heartbeat_state(part: str, seen_age, ok_age, err_age, backlog: dict | None = None) -> str:
    """`red`, `green` or `grey`. Ages are seconds (None = never), computed by the
    DB from its own now(), so PCs with different clocks agree.

    Capture PCs are informational: a PC that is simply off is grey, red only on
    a real problem (held images, an old unsent image, an error newer than the
    last success). Every other part is red when silent too long, on an error
    newer than its last success, or on its backlog problem. A daily backup is
    judged by its last success, not by how recently it reported."""
    backlog = backlog if isinstance(backlog, dict) else {}
    error_newer = err_age is not None and (ok_age is None or err_age < ok_age)
    if part == "capture":
        if (
            error_newer
            or _num(backlog, "held") > 0
            or _num(backlog, "oldest_unsent_minutes") > 60
            or _num(backlog, "oldest_transfer_wait_minutes") > 60
        ):
            return "red"
        return "grey" if seen_age is None or seen_age > STALE_SECONDS else "green"
    if part == "backup":
        if ok_age is None or ok_age > BACKUP_MAX_AGE_SECONDS:
            return "red"
    elif seen_age is None or seen_age > (UPLOAD_STALE_SECONDS if part == "upload" else STALE_SECONDS):
        return "red"
    if error_newer:
        return "red"
    if part == "qc-export" and _num(backlog, "failures") > 0:
        return "red"
    if part == "qc" and (
        backlog.get("input_unreachable") is True
        or (_num(backlog, "approved_not_exported") > 0 and _num(backlog, "oldest_approved_minutes") > 30)
    ):
        return "red"
    if part == "lwip" and (_num(backlog, "failed") > 0 or _num(backlog, "oldest_waiting_minutes") > 120):
        return "red"
    if part == "lwip" and _num(backlog, "oldest_unreported_minutes") > 120:
        return "red"
    if part == "upload" and (
        _num(backlog, "failed") > 0
        or (
            "last_scan_minutes_ago" in backlog
            and "scan_interval_minutes" in backlog
            and _num(backlog, "last_scan_minutes_ago") > max(15, 3 * _num(backlog, "scan_interval_minutes"))
        )  # both keys absent while the service is switched off: not red
    ):
        return "red"
    return "green"


_STATUS_SQL = """
    SELECT part, host, version, started_at, last_seen, last_ok, last_error, last_error_at, backlog,
           EXTRACT(EPOCH FROM (now() - last_seen)) AS seen_age,
           EXTRACT(EPOCH FROM (now() - last_ok)) AS ok_age,
           EXTRACT(EPOCH FROM (now() - last_error_at)) AS err_age
    FROM service_heartbeat
    {where}
    ORDER BY part, host
"""


def system_status(db, show_all: bool = False) -> dict[str, Any]:
    from app.services import schema_check  # late: schema_check imports the engine

    where = "" if show_all else f"WHERE last_seen > now() - interval '{HIDE_AFTER_DAYS} days'"
    rows = db.execute(text(_STATUS_SQL.format(where=where))).mappings().all()
    services = []
    backup_age_hours = None
    for row in rows:
        seen, ok, err = (None if row[k] is None else float(row[k]) for k in ("seen_age", "ok_age", "err_age"))
        state = heartbeat_state(row["part"], seen, ok, err, row["backlog"])
        if row["part"] == "backup" and ok is not None:
            age = ok / 3600
            backup_age_hours = age if backup_age_hours is None else min(backup_age_hours, age)
        data = {k: v for k, v in dict(row).items() if k not in ("seen_age", "ok_age", "err_age")}
        services.append({**data, "state": state, "silent_seconds": seen})
    reported = {s["part"] for s in services}
    for part in EXPECTED_PARTS:
        if part not in reported:
            services.append({
                "part": part, "host": None, "version": None, "started_at": None, "last_seen": None,
                "last_ok": None, "last_error": None, "last_error_at": None, "backlog": {},
                "state": "red", "silent_seconds": None, "neverReported": True,
            })
    upload_failed = int(db.scalar(
        select(func.count()).select_from(CaptureFolder).where(
            CaptureFolder.upload_error.is_not(None), CaptureFolder.is_deleted.is_not(True)
        )
    ) or 0)
    return {
        "services": services,
        "anyRed": upload_failed > 0 or any(s["state"] == "red" for s in services),
        "databaseSchemaLevel": schema_check.schema_level(),
        "requiredSchemaLevel": schema_check.REQUIRED_SCHEMA,
        "serverVersion": VERSION,
        "backupLastOkAgeHours": backup_age_hours,
        "uploadFailedFolders": upload_failed,
    }


def forget_host(db, part: str, host: str) -> bool:
    """Removes a PC's row (a retired capture PC). True if there was one."""
    result = db.execute(
        text("DELETE FROM service_heartbeat WHERE part = :part AND host = :host"),
        {"part": part, "host": host},
    )
    db.commit()
    return bool(result.rowcount)


__all__ = ["UPSERT_SQL", "VERSION", "beat", "forget_host", "heartbeat_sweep", "heartbeat_state", "system_status"]

"""Reports a finished folder to the shared PostgreSQL schema.

The only module in LWIP that knows a database exists. Everything else here is a
local filesystem process, and that is worth keeping true: this module is imported
lazily and every entry point returns a result rather than raising, so a station
with no database, no credentials or no network behaves exactly as LWIP did before
it was written.

WHY THIS EXISTS. A finished folder only reaches a QC operator once
`capture_folders.qc_status` is 'PENDING'. That write used to happen in exactly one
place: a 15s tick inside the LWCAM desktop app. So an operator who transferred a
box, closed LWCAM and went on leave left the batch fully processed on disk and
invisible to QC until someone next opened the app on that PC. LWIP already runs
headless and starts at logon, so it is the process that is actually present when
that happens.

BOTH WRITERS STAY. LWCAM's agent is unchanged and still reports the same folders
through its own outbox. The write is idempotent - identical columns, identical
values, both derived from the same manifest - so whichever arrives first wins and
the other is a no-op. They cover different failures: this path survives LWCAM
being closed, and LWCAM's outbox survives the station being offline, where this
path cannot reach the database at all.

The UPDATE below is a transcription of `folderProcessingUpdateSql` in LWCAM's
`lib/services/pg_statements.dart`. That statement remains the definition of what a
processing report writes; if it changes, change this with it.
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Any

LOGGER = logging.getLogger("deskew_crop_tool.cloud_report")

# Same variable, same file, same keys the QC backend reads (its
# app/core/node_config.py). Pointing both at one file is deliberate: the station's
# credentials live in exactly one place, written by LWCam Admin's Station Setup,
# and LWIP never gets a copy of its own to drift.
NODE_CONFIG_ENV = "LWCAM_NODE_CONFIG"

_REQUIRED_KEYS = ("pgHost", "pgDatabase", "pgUser", "pgPassword")


class ReportResult(Enum):
    """What the caller should do next."""

    REPORTED = "reported"
    """Written. Mark the journal entry and never look at it again."""

    NOT_YET = "not_yet"
    """The folder row has not synced from the capture PC yet. Retry later.

    Normal on a split-PC site: a processing-only station can finish a folder
    before the capture station has pushed the row it belongs to.
    """

    NO_IDENTITY = "no_identity"
    """The manifest carries no usable source identity, so no row can ever be
    resolved for it. Retrying is pointless - the caller should mark it settled.

    Happens when a folder was processed without LWCAM's completion marker, e.g. a
    manual START_DESKEW_CROP.bat run over a directory LWCAM never wrote.
    """

    UNREACHABLE = "unreachable"
    """No database right now. Retry indefinitely - the journal outlives any
    outage, so a folder finished before a week of downtime still reports when the
    network returns.
    """


@dataclass(frozen=True)
class PgSettings:
    host: str
    port: int
    dbname: str
    user: str
    password: str


def load_pg_settings() -> PgSettings | None:
    """The station's database settings, or None when reporting is not configured
    on this machine.

    None is a normal state, not an error: a developer running the tool by hand has
    no node config, and a station Station Setup has never touched has no
    credentials to offer.
    """
    path = os.environ.get(NODE_CONFIG_ENV, "").strip()
    if not path:
        return None
    try:
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        LOGGER.warning("Node config unreadable (%s): %s", path, exc)
        return None
    if not isinstance(raw, dict):
        LOGGER.warning("Node config is not a JSON object: %s", path)
        return None
    missing = [k for k in _REQUIRED_KEYS if not str(raw.get(k, "")).strip()]
    if missing:
        LOGGER.warning("Node config is missing %s - not reporting", ", ".join(missing))
        return None
    try:
        port = int(raw.get("pgPort", 5432) or 5432)
    except (TypeError, ValueError):
        port = 5432
    return PgSettings(
        host=str(raw["pgHost"]).strip(),
        port=port,
        dbname=str(raw["pgDatabase"]).strip(),
        user=str(raw["pgUser"]).strip(),
        password=str(raw["pgPassword"]),
    )


def identity_of(manifest: dict[str, Any]) -> dict[str, Any] | None:
    """The natural key from a manifest, or None when it cannot address a row.

    All three parts are required: the project resolves the box, the box resolves
    the folder. A partial identity is the same as none.
    """
    identity = manifest.get("source_identity")
    if not isinstance(identity, dict):
        return None
    project_key = str(identity.get("project_key", "")).strip()
    box_name = str(identity.get("box_name", "")).strip()
    folder_seq = identity.get("folder_seq")
    if not project_key or not box_name or folder_seq is None:
        return None
    try:
        folder_seq = int(folder_seq)
    except (TypeError, ValueError):
        return None
    return {
        "project_key": project_key,
        "box_name": box_name,
        "folder_seq": folder_seq,
    }


def report_folder(
    settings: PgSettings,
    manifest: dict[str, Any],
    output_folder: Path,
    *,
    timeout: int = 5,
    connect=None,
) -> ReportResult:
    """Resolves the folder by natural key and marks it ready for QC.

    A short-lived connection per call, like LWCAM's own direct writes: this runs
    from the scheduler's idle branch, at most once per poll, so a pooled
    connection would sit idle far longer than it is ever used.

    `connect` is the seam the tests use; production leaves it None and gets
    psycopg.
    """
    identity = identity_of(manifest)
    if identity is None:
        return ReportResult.NO_IDENTITY

    thumbs = manifest.get("thumbnails")
    created = isinstance(thumbs, dict) and thumbs.get("created") is True
    dirname = (thumbs.get("dirname") if isinstance(thumbs, dict) else None) or "thumbs"

    if connect is None:
        try:
            import psycopg
        except ImportError:  # pragma: no cover - a build without the driver
            LOGGER.warning("psycopg is not installed - cannot report to the database")
            return ReportResult.UNREACHABLE
        connect = psycopg.connect

    try:
        with connect(
            host=settings.host,
            port=settings.port,
            dbname=settings.dbname,
            user=settings.user,
            password=settings.password,
            connect_timeout=timeout,
            # Bound the statements too, not just the connect: a reachable but
            # WEDGED server would otherwise stall the scheduler thread
            # indefinitely. Passed as a connection option rather than a SET
            # statement because PostgreSQL's SET takes no bind parameters.
            options=f"-c statement_timeout={int(timeout) * 1000}",
        ) as conn:
            with conn.cursor() as cur:
                # No is_deleted filter, to match LWCAM's own resolver
                # (pg_statements.dart's projectIdByKeySql). A soft-deleted
                # project used to make this return NOT_YET forever - retried
                # every poll, never settled - while LWCAM wrote the row
                # regardless. Reporting a deleted project's folder is
                # harmless; an endless retry is not.
                cur.execute(
                    "SELECT id FROM projects WHERE project_key = %(project_key)s",
                    identity,
                )
                row = cur.fetchone()
                if row is None:
                    return ReportResult.NOT_YET
                project_id = row[0]

                cur.execute(
                    "SELECT box_id FROM capture_boxes "
                    "WHERE project_id = %(project_id)s AND box_name = %(box_name)s",
                    {"project_id": project_id, "box_name": identity["box_name"]},
                )
                row = cur.fetchone()
                if row is None:
                    return ReportResult.NOT_YET
                box_id = row[0]

                cur.execute(
                    "SELECT id FROM capture_folders "
                    "WHERE box_id = %(box_id)s AND folder_seq = %(folder_seq)s",
                    {"box_id": box_id, "folder_seq": identity["folder_seq"]},
                )
                row = cur.fetchone()
                if row is None:
                    return ReportResult.NOT_YET
                folder_id = row[0]

                # Transcribed from folderProcessingUpdateSql - see the module
                # docstring. Column set and values must match it exactly, because
                # LWCAM's agent writes the same row from the same manifest and the
                # two must be indistinguishable. qc_status moves to PENDING only
                # from a pre-QC state: this report can land days late (NOT_YET /
                # UNREACHABLE retries), by which time QC may have PASSed and
                # exported the folder, and an unconditional reset re-queued it.
                cur.execute(
                    "UPDATE capture_folders SET "
                    "is_deskewed = TRUE, is_cropped = TRUE, "
                    "is_created_thumbnail = %(is_created_thumbnail)s, "
                    "folder_path = %(folder_path)s, "
                    "thumbnail_path = %(thumbnail_path)s, "
                    "qc_status = CASE WHEN qc_status IS NULL "
                    "OR upper(qc_status) IN ('', 'PENDING', 'REWORK') "
                    "THEN 'PENDING' ELSE qc_status END "
                    "WHERE id = %(folder_id)s",
                    {
                        "is_created_thumbnail": created,
                        "folder_path": str(output_folder),
                        "thumbnail_path": str(output_folder / dirname) if created else None,
                        "folder_id": folder_id,
                    },
                )
            conn.commit()
        return ReportResult.REPORTED
    except Exception as exc:  # noqa: BLE001 - never raise into the scheduler
        LOGGER.warning("Could not report %s: %s", output_folder, exc)
        return ReportResult.UNREACHABLE

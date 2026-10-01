"""The 60-second service_heartbeat row and the schema-level check (Phase 3).

Both ride on the Supervisor's database probe. Nothing here may break the
service: a failed beat is logged at most once per 10 minutes and swallowed.
"""

from __future__ import annotations

import json
import logging
import socket
import time
from datetime import datetime, timezone
from pathlib import Path

from .cloud_report import REQUIRED_SCHEMA, schema_level, schema_message

LOGGER = logging.getLogger("deskew_crop_tool.health")
LOG_EVERY_SECONDS = 600.0

UPSERT_SQL = (
    "INSERT INTO service_heartbeat "
    "(part, host, version, started_at, last_seen, last_ok, last_error, last_error_at, backlog) "
    "VALUES (%(part)s, %(host)s, %(version)s, %(started_at)s, now(), "
    "CASE WHEN %(error)s::text IS NULL THEN now() END, %(error)s::text, "
    "CASE WHEN %(error)s::text IS NOT NULL THEN now() END, %(backlog)s::jsonb) "
    "ON CONFLICT (part, host) DO UPDATE SET version = EXCLUDED.version, "
    "started_at = EXCLUDED.started_at, last_seen = now(), "
    "last_ok = COALESCE(EXCLUDED.last_ok, service_heartbeat.last_ok), "
    "last_error = EXCLUDED.last_error, "
    "last_error_at = COALESCE(EXCLUDED.last_error_at, service_heartbeat.last_error_at), "
    "backlog = EXCLUDED.backlog"
)


def read_version() -> str:
    """The install root's VERSION.txt (layout {app}/backend/<package>); "dev" if absent."""
    try:
        text = (Path(__file__).resolve().parents[2] / "VERSION.txt").read_text(encoding="utf-8")
        return text.strip().splitlines()[0].strip() or "dev"
    except (OSError, IndexError):
        return "dev"


class Heartbeat:
    """`connect` is a zero-argument callable returning a psycopg-style
    connection (context manager) - the seam the tests use."""

    def __init__(self, part: str, connect, version: str | None = None, host: str | None = None) -> None:
        self.part = part
        self.connect = connect
        self.version = version or read_version()
        self.host = host or socket.gethostname()
        self.started_at = datetime.now(timezone.utc)
        self.schema_problem: str | None = None
        self._last_logged = float("-inf")

    def beat(self, backlog: dict, error: str | None = None) -> None:
        """Checks the schema level, then upserts the row when it is new enough."""
        try:
            with self.connect() as conn:
                with conn.cursor() as cur:
                    level = schema_level(cur)
                    if level < REQUIRED_SCHEMA:
                        self.schema_problem = schema_message(level)
                    else:
                        self.schema_problem = None
                        cur.execute(UPSERT_SQL, {
                            "part": self.part, "host": self.host, "version": self.version,
                            "started_at": self.started_at,
                            "error": (error or None) and error[:500],
                            "backlog": json.dumps(backlog),
                        })
                conn.commit()
        except Exception as exc:  # noqa: BLE001 - a heartbeat never breaks the service
            now = time.monotonic()
            if now - self._last_logged >= LOG_EVERY_SECONDS:
                self._last_logged = now
                LOGGER.warning("Could not write the heartbeat: %s", " ".join(str(exc).split()))


def backlog_of(waiting: list, failed: list, first_seen: dict[str, float], *, now: float,
               status: dict | None = None) -> dict:
    """waiting / oldest_waiting_minutes / failed. `waiting` is status.json's
    folder list, `failed` summarize_state()'s queue["failed"].

    ponytail: status.json carries no per-folder age, so the age is "since this
    process first saw the folder waiting" - resets on a service restart.
    """
    for folder in waiting:
        first_seen.setdefault(folder, now)
    for folder in [f for f in first_seen if f not in waiting]:
        del first_seen[folder]
    oldest = max((now - t for t in first_seen.values()), default=0.0)
    status = status or {}
    return {
        "waiting": len(waiting),
        "oldest_waiting_minutes": int(oldest // 60),
        "failed": len(failed),
        # finished but not yet in the DB (NOT_YET, DB down, schema too old)
        "unreported": int(status.get("unreported") or 0),
        "oldest_unreported_minutes": int(status.get("oldest_unreported_minutes") or 0),
    }

"""The 60-second service_heartbeat row, the schema-level check and the
capture_folders write-back (Phase 3).

Nothing here may break the service: a failed beat is logged at most once per
10 minutes and swallowed; a failed write-back is retried by the engine.
"""

from __future__ import annotations

import json
import socket
import time
from datetime import datetime, timezone
from pathlib import Path

from . import log

REQUIRED_SCHEMA = 7
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
INGESTED_SQL = (
    "UPDATE capture_folders SET is_ingested = true, ingested_time = now(), "
    "upload_error = NULL WHERE group_id = %s"
)
ERROR_SQL = "UPDATE capture_folders SET upload_error = %s WHERE group_id = %s"


def schema_message(level: int) -> str:
    return (
        f"The database is older than this program (needs level {REQUIRED_SCHEMA}, "
        f"has {level}). Run LWCamDatabaseSetup on the database PC."
    )


def schema_level(cur) -> int:
    """The applied migration level; a missing schema_migrations table is 0."""
    cur.execute("SELECT to_regclass('schema_migrations') IS NOT NULL")
    if not cur.fetchone()[0]:
        return 0
    cur.execute(
        "SELECT coalesce(max(substring(version from '^[0-9]+')::int), 0) "
        "FROM schema_migrations"
    )
    return int(cur.fetchone()[0])


def read_version() -> str:
    """The install root's VERSION.txt (layout {app}/backend/<package>); "dev" if absent."""
    try:
        text = (Path(__file__).resolve().parents[2] / "VERSION.txt").read_text(encoding="utf-8")
        return text.strip().splitlines()[0].strip() or "dev"
    except (OSError, IndexError):
        return "dev"


class Health:
    """`connect` is a zero-argument callable returning a psycopg-style
    connection (context manager) - the seam the tests use."""

    def __init__(self, connect, version: str | None = None, host: str | None = None) -> None:
        self.connect = connect
        self.version = version or read_version()
        self.host = host or socket.gethostname()
        self.started_at = datetime.now(timezone.utc)
        self.schema_problem: str | None = None
        self._last_logged = float("-inf")
        self._warned: set[str] = set()

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
                            "part": "upload", "host": self.host, "version": self.version,
                            "started_at": self.started_at,
                            "error": (error or None) and error[:500],
                            "backlog": json.dumps(backlog),
                        })
                conn.commit()
        except Exception as exc:  # noqa: BLE001 - a heartbeat never breaks the service
            now = time.monotonic()
            if now - self._last_logged >= LOG_EVERY_SECONDS:
                self._last_logged = now
                log("WARN", f"could not write the heartbeat: {' '.join(str(exc).split())}")

    def write_back(self, group_id: str, error: str | None) -> bool:
        """Marks the Group ID ingested (error None) or records `upload_error`.
        False = skipped (schema too old) or no single row matched the Group ID
        (logged once per Group ID); either way the engine keeps it pending.
        Raises when the database cannot be reached."""
        if self.schema_problem:
            return False
        with self.connect() as conn:
            with conn.cursor() as cur:
                if error is None:
                    cur.execute(INGESTED_SQL, (group_id,))
                else:
                    cur.execute(ERROR_SQL, (error[:500], group_id))
                matched = cur.rowcount
            conn.commit()
        if matched != 1:
            if group_id not in self._warned:
                self._warned.add(group_id)
                log("WARN", f"capture_folders has {matched} row(s) for {group_id}, expected 1; "
                            "the database write-back stays pending")
            return False
        return True

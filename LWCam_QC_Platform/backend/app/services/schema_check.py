"""Is the database new enough for this program? (schema level, migration 008)

Level = the highest migration number in `schema_migrations`; a missing table is
level 0. The answer is cached for a minute, so running LWCamDatabaseSetup fixes
a running server without a restart, and a DB routes check costs nothing.

The DB may be another PC, off or slow: the query runs OUTSIDE the lock (one hung
connect must not freeze every request behind it), has its own timeouts, and a
failed attempt is cached for a few seconds so a dead DB is asked once per
5 s rather than once per request.
"""

from __future__ import annotations

import logging
import threading
import time

from sqlalchemy import text
from sqlalchemy.exc import DBAPIError

from app.core.errors import ApiCodes, BusinessError
from app.db.session import engine

logger = logging.getLogger(__name__)

REQUIRED_SCHEMA = 8
SCHEMA_TOO_OLD_KEY = "schemaTooOld"
RECHECK_SECONDS = 60.0
FAILURE_RECHECK_SECONDS = 5.0
LOG_EVERY_SECONDS = 600.0
# Level reported when the login may not read schema_migrations at all.
NO_GRANT = -1

_LEVEL_SQL = text(
    "SELECT coalesce(max(substring(version from '^[0-9]+')::int), 0) FROM schema_migrations"
)

_lock = threading.Lock()
_cache: tuple[float, int | None] | None = None  # (checked at monotonic, level or None = unreachable)
_last_logged = float("-inf")


def too_old_message(level: int) -> str:
    if level == NO_GRANT:
        return (
            "The lwcam_qc login cannot read schema_migrations (grants missing - "
            "re-run LWCamDatabaseSetup on the database PC)."
        )
    return (
        f"The database is older than this program (needs level {REQUIRED_SCHEMA}, has {level}). "
        "Run LWCamDatabaseSetup on the database PC."
    )


def read_level() -> int | None:
    """The DB's schema level, 0 when the table is missing, NO_GRANT when the
    login may not read it, None when unreachable (or any other failure)."""
    try:
        with engine.connect() as connection:
            connection.execute(text("SET LOCAL statement_timeout = 5000"))
            return int(connection.execute(_LEVEL_SQL).scalar() or 0)
    except DBAPIError as error:
        code = getattr(error.orig, "sqlstate", None) or getattr(error.orig, "pgcode", None)
        if code == "42P01":  # undefined_table: LWCamDatabaseSetup never ran
            return 0
        if code == "42501":  # insufficient_privilege
            return NO_GRANT
        return None
    except Exception:
        return None


def schema_level(*, force: bool = False) -> int | None:
    """Cached level. Unreachable is cached briefly (FAILURE_RECHECK_SECONDS)."""
    global _cache
    now = time.monotonic()
    with _lock:
        cached = _cache
    if not force and cached:
        ttl = RECHECK_SECONDS if cached[1] is not None else FAILURE_RECHECK_SECONDS
        if now - cached[0] < ttl:
            return cached[1]
    level = read_level()  # outside the lock
    with _lock:
        _cache = (time.monotonic(), level)
    return level


def is_too_old() -> bool:
    level = schema_level()
    return level is not None and level < REQUIRED_SCHEMA


def gate_ok(name: str) -> bool:
    """For background sweeps: False (skip this tick) while the DB is too old.
    Logged once per 10 minutes, not every tick."""
    global _last_logged
    level = schema_level()
    if level is None or level >= REQUIRED_SCHEMA:
        return True
    if time.monotonic() - _last_logged > LOG_EVERY_SECONDS:
        _last_logged = time.monotonic()
        logger.warning("%s skipped: %s", name, too_old_message(level))
    return False


def ensure_current() -> None:
    """Raises 503 schemaTooOld when the DB is behind. An unreachable DB passes:
    the route then fails on its own, with the honest error."""
    level = schema_level()
    if level is not None and level < REQUIRED_SCHEMA:
        raise BusinessError(
            ApiCodes.SERVICE_UNAVAILABLE,
            too_old_message(level),
            503,
            data={"errorKey": SCHEMA_TOO_OLD_KEY, "required": REQUIRED_SCHEMA, "actual": level},
        )


__all__ = ["REQUIRED_SCHEMA", "SCHEMA_TOO_OLD_KEY", "ensure_current", "gate_ok", "schema_level"]

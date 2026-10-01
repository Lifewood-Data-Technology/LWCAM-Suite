"""The Upload console: one process, two jobs.

The upload sweep (engine.py) runs on the MAIN thread, on a timer, re-reading
config.json at the start of every scan; a small HTTP console
(stdlib ThreadingHTTPServer) runs on a daemon thread beside it and answers the
API the shared contract defines - status, a live log tail, Settings, and
Retry/Scan-now buttons that wake the sweep early. There is no child worker
process, unlike LWIP's supervisor: there is nothing here to crash independent
of the console itself.

The auth pieces (role parsing, bcrypt verify, the login rate limiter, session
cookies, the Host-header DNS-rebinding check, the CSRF header, the
probe-at-start-then-every-60s database reachability check and its "None means
not probed yet, so access defaults to reachable" rule) are copied from LWIP's
`deskew_crop_tool/service.py`, which copied them from QC in turn - the same
`users` table backs sign-in in all three. Only the cookie name changed
(`upload_session`) and only admin/super_admin accounts get console access,
same as LWIP.

Run as `python -m lwcam_upload --config <path>` (see __main__.py).
"""

from __future__ import annotations

import json
import logging
import os
import secrets
import ssl
import sys
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Callable
from urllib.parse import parse_qs, urlsplit

import bcrypt

from . import LOGGER_NAME, configure_logging, log, log_last_seq, log_lines_after, netlogin, tls
from . import lwcam_secrets
from .config import DEFAULT_LOG_FILE, Config, db_sslmode, load_config
from .config import _path as _resolve_config_path
from .engine import UploadCoordinator
from .health import Health
from .ledger import atomic_json
from .paths import fs_path

LOGGER = logging.getLogger("lwcam_upload.console")

# POST routes of the "Network folder logins" card (GET /api/network-logins lists).
NETWORK_LOGIN_ACTIONS = {
    "/api/network-logins": "save",
    "/api/network-logins/check": "check",
    "/api/network-logins/remove": "remove",
}

# One live sign-in per account (SessionStore.create). A session with no
# request for this long - its browser closed - no longer blocks a new one.
SESSION_IDLE_SECONDS = 180.0
ALREADY_SIGNED_IN = (
    "This account is already signed in on another browser or PC. Sign out there first; "
    "a browser closed without signing out frees the account after 3 minutes."
)
SIGNED_IN_ELSEWHERE = (
    "This account signed in on another browser or PC while this one was idle, "
    "so you were signed out here."
)
SESSION_COOKIE_NAME = "upload_session"
SESSION_LIFETIME_SECONDS = 8 * 60 * 60
MAX_BODY_BYTES = 64 * 1024
DB_PROBE_INTERVAL_SECONDS = 60.0
# A signed-in session is checked against the database (still active, still an
# admin) at most this often, while the database answers.
SESSION_REVALIDATE_SECONDS = 60.0
HEARTBEAT_SECONDS = 60.0

# The keys a POST /api/settings may change - every config key except
# state_file/log_file (not operator-facing: they are install layout, not
# upload behaviour). Anything else already in the file is carried over
# untouched - see merge_settings.
ALLOWED_SETTINGS_KEYS = (
    "watch_root",
    "done_root",
    "summary_root",
    "enabled",
    "s3_path",
    "s3_region",
    "s3_access_key",
    "s3_secret_key",
    "interval_seconds",
    "https_proxy",
    "db_host",
    "db_port",
    "db_name",
    "db_user",
    "db_password",
    "db_use_ssl",
    "ui_port",
    "ui_bind",
)

PLACEHOLDER_HTML = (
    "<!doctype html><html><head><title>LWCam Upload Console</title></head><body>"
    "<p>The console page (web/index.html) was not found next to this "
    "module. The API still works.</p></body></html>"
)


# --------------------------------------------------------------------------
# Pure helpers - no I/O, no locks, easy to unit test directly.
# --------------------------------------------------------------------------


def normalize_role(value: str) -> str:
    """Ported from QC's `app/models/user.py` `normalize_role` - must parse
    the shared `users.roles` column exactly the same way, or an account that
    QC accepts could be silently refused here (or the reverse)."""
    normalized = value.strip().lower().replace("-", "_")
    if normalized in {"superadmin", "super_admin"}:
        return "super_admin"
    return normalized


def role_set(raw_roles: str) -> set[str]:
    """`users.roles` is a comma-joined list shared with LWCAM/LWCamAdmin/QC/
    LWIP; a holder of several roles ('admin,qc') is normal, so this never
    collapses to one value."""
    text = raw_roles or ""
    for marker in ("{", "}", "[", "]", '"', "'"):
        text = text.replace(marker, "")
    return {
        normalize_role(part)
        for part in text.replace(";", ",").replace("|", ",").split(",")
        if part.strip()
    }


def compute_access_level(
    *, signed_in: bool, db_reachable: bool, client_is_local: bool
) -> tuple[str, bool]:
    """Returns (access, local_fallback=False).

    full: a valid session. Being at this PC grants nothing on its own.
    view: no session, the database is unreachable and the browser is on this
        PC (read-only status).
    none: otherwise - including a remote browser while the database is down,
        so a PC across the network gets nothing without signing in.
    """
    if signed_in:
        return "full", False
    return ("view", False) if client_is_local and not db_reachable else ("none", False)


# bcrypt ignores anything past 72 bytes; truncate explicitly rather than let
# the library decide, matching QC's app/core/security.py exactly - the
# `users.password` column is shared, so every reader must agree where a
# password is cut.
_BCRYPT_MAX_BYTES = 72


def verify_password(password: str, password_hash: str | None) -> bool:
    if not password_hash:
        return False
    try:
        return bcrypt.checkpw(
            password.encode("utf-8")[:_BCRYPT_MAX_BYTES],
            password_hash.strip().encode("utf-8"),
        )
    except ValueError:
        # Not a bcrypt hash at all - fail the check, never raise into a login.
        return False


LOGIN_ATTEMPT_LIMIT = 5
LOGIN_ATTEMPT_WINDOW_SECONDS = 60.0
# Across every username from one computer, so guessing through a list of
# names does not slip under the per-user limit.
IP_ATTEMPT_LIMIT = 20
IP_ATTEMPT_WINDOW_SECONDS = 600.0
# Most (user, IP) pairs / IPs remembered at once: a flood of made-up names
# must not grow this without bound.
MAX_TRACKED = 5000


class RateLimiter:
    """5 failed tries per (client IP, username) per 60 seconds, a
    lock-protected plain dict, only wrong passwords count, and a success
    resets the counter.

    `now` is an injection point for tests only; production always passes
    None and gets the real monotonic clock.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._failures: dict[tuple[str, str], list[float]] = {}
        self._ip_failures: dict[str, list[float]] = {}

    @staticmethod
    def _key(client_ip: str, username: str) -> tuple[str, str]:
        return (client_ip, username.strip().lower())

    def _prune_expired(self, moment: float) -> None:
        """Forgets every pair and every IP with no failure inside its window,
        then, if a flood of distinct names still overfills a table, the oldest.
        Caller holds the lock."""
        for table, window in (
            (self._failures, LOGIN_ATTEMPT_WINDOW_SECONDS),
            (self._ip_failures, IP_ATTEMPT_WINDOW_SECONDS),
        ):
            for key in [k for k, times in table.items() if not any(t > moment - window for t in times)]:
                table.pop(key, None)
            if len(table) > MAX_TRACKED:
                for key in sorted(table, key=lambda k: max(table[k]))[: len(table) - MAX_TRACKED]:
                    table.pop(key, None)

    def check(self, client_ip: str, username: str, *, now: float | None = None) -> bool:
        """True if this pair, and this IP overall, may still attempt a login."""
        moment = time.monotonic() if now is None else now
        key = self._key(client_ip, username)
        window_start = moment - LOGIN_ATTEMPT_WINDOW_SECONDS
        with self._lock:
            ip_recent = [
                t for t in self._ip_failures.get(client_ip, ())
                if t > moment - IP_ATTEMPT_WINDOW_SECONDS
            ]
            if ip_recent:
                self._ip_failures[client_ip] = ip_recent
            else:
                self._ip_failures.pop(client_ip, None)
            self._prune_expired(moment)
            attempts = [t for t in self._failures.get(key, ()) if t > window_start]
            if attempts:
                self._failures[key] = attempts
            else:
                self._failures.pop(key, None)
        return len(attempts) < LOGIN_ATTEMPT_LIMIT and len(ip_recent) < IP_ATTEMPT_LIMIT

    def record_failure(self, client_ip: str, username: str, *, now: float | None = None) -> None:
        moment = time.monotonic() if now is None else now
        with self._lock:
            self._prune_expired(moment)
            self._failures.setdefault(self._key(client_ip, username), []).append(moment)
            self._ip_failures.setdefault(client_ip, []).append(moment)

    def reset(self, client_ip: str, username: str) -> None:
        with self._lock:
            self._failures.pop(self._key(client_ip, username), None)


class SessionStore:
    """In-memory sessions only - lost on a restart, by design."""

    def __init__(self, lifetime_seconds: float = SESSION_LIFETIME_SECONDS) -> None:
        self._lifetime = lifetime_seconds
        self._lock = threading.Lock()
        self._sessions: dict[str, tuple[str, float]] = {}
        self._last_seen: dict[str, float] = {}
        # Idle sessions a later sign-in took over, until they would have
        # expired anyway - so that browser is told why it was signed out.
        self._replaced: dict[str, float] = {}
        # Tokens signed in from the saved admin list (database unreachable).
        self._from_cache: set[str] = set()
        # When each token's account was last confirmed against the database.
        self._checked: dict[str, float] = {}

    def revalidate_due(self, token: str, every: float = SESSION_REVALIDATE_SECONDS) -> bool:
        """True (and starts a new period) when `token` has not been checked
        against the database for `every` seconds."""
        now = time.monotonic()
        with self._lock:
            if now - self._checked.get(token, float("-inf")) < every:
                return False
            self._checked[token] = now
            return True

    def create(
        self, username: str, *, current_token: str | None = None, from_cache: bool = False
    ) -> str | None:
        """One live sign-in per account, the FIRST winning: None while
        another browser holds this account and is still in use.

        "In use" means it made a request in the last SESSION_IDLE_SECONDS -
        the console polls every few seconds while open - so a browser closed
        without signing out frees the account in minutes, not when its
        session would expire hours later. The same browser signing in again
        (`current_token`, its own cookie) is never blocked by itself."""
        now = time.monotonic()
        key = username.casefold()
        with self._lock:
            mine = [
                token for token, (user, expires_at) in self._sessions.items()
                if user.casefold() == key and expires_at > now
            ]
            if any(
                token != current_token and now - self._last_seen.get(token, 0.0) < SESSION_IDLE_SECONDS
                for token in mine
            ):
                return None
            for token in mine:
                expires_at = self._sessions.pop(token)[1]
                self._last_seen.pop(token, None)
                if token != current_token:
                    self._replaced[token] = expires_at
            self._replaced = {t: e for t, e in self._replaced.items() if e > now}
            token = secrets.token_urlsafe(32)
            self._sessions[token] = (username, now + self._lifetime)
            self._last_seen[token] = now
            self._checked[token] = now
            self._from_cache.discard(token)
            if from_cache:
                self._from_cache.add(token)
        return token

    def is_from_cache(self, token: str) -> bool:
        with self._lock:
            return token in self._from_cache

    def username_for(self, token: str) -> str | None:
        now = time.monotonic()
        with self._lock:
            entry = self._sessions.get(token)
            if entry is None:
                return None
            username, expires_at = entry
            if expires_at < now:
                self._sessions.pop(token, None)
                self._last_seen.pop(token, None)
                self._checked.pop(token, None)
                return None
            self._last_seen[token] = now
            return username

    def was_replaced(self, token: str) -> bool:
        with self._lock:
            return self._replaced.get(token, 0.0) > time.monotonic()

    def remove(self, token: str) -> None:
        with self._lock:
            self._sessions.pop(token, None)
            self._last_seen.pop(token, None)
            self._from_cache.discard(token)
            self._checked.pop(token, None)


def try_load_config(path: Path) -> tuple[Config | None, str | None]:
    try:
        return load_config(path), None
    except Exception as exc:  # noqa: BLE001 - reported to the operator, not raised
        return None, str(exc)


def _read_json_file(path: Path) -> dict | None:
    try:
        data = json.loads(fs_path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def parse_ui_settings(raw: dict) -> tuple[int, str]:
    """The lenient (never-raises) ui_port/ui_bind reader: the console must be
    able to start and show an error even when the rest of the file is bad
    enough that config.load_config would reject it."""
    port = raw.get("ui_port", 8091)
    try:
        port = int(port)
    except (TypeError, ValueError):
        port = 8091
    if not 1 <= port <= 65535:
        port = 8091
    bind = str(raw.get("ui_bind") or "0.0.0.0").strip() or "0.0.0.0"
    return port, bind


def read_ui_settings(path: Path) -> tuple[int, str]:
    return parse_ui_settings(_read_json_file(path) or {})


def _lenient_log_file(config_path: Path) -> Path:
    """The log_file path, read the same lenient way as ui_port/ui_bind: the
    console must be able to log its own startup line - including "the config
    is broken" - before `load_config` has had a chance to succeed even once."""
    raw = _read_json_file(config_path) or {}
    value = str(raw.get("log_file") or DEFAULT_LOG_FILE)
    try:
        return _resolve_config_path(value, config_path.parent)
    except OSError:
        return config_path.parent.parent / "logs" / "upload.log"


# --------------------------------------------------------------------------
# Settings: read (lenient) and write (validated, atomic).
# --------------------------------------------------------------------------

_SETTINGS_DEFAULTS: dict[str, object] = {
    "watch_root": "",
    "done_root": "",
    "summary_root": "",
    "enabled": True,
    "s3_path": "",
    "s3_region": "",
    "s3_access_key": "",
    "interval_seconds": 60,
    "https_proxy": "",
    "db_host": "",
    "db_port": 5432,
    "db_name": "lwcam",
    "db_user": "",
    "db_use_ssl": False,
    "ui_port": 8091,
    "ui_bind": "0.0.0.0",
}


def read_settings_view(config_path: Path) -> dict:
    """The GET /api/settings shape. Reads the raw file leniently (not through
    load_config) so a broken config can still be shown and fixed from here;
    the two secrets are never returned, only whether one is set."""
    raw = _read_json_file(config_path) or {}
    view = {key: raw.get(key, default) for key, default in _SETTINGS_DEFAULTS.items()}
    view["s3_secret_key_set"] = bool(raw.get("s3_secret_key", ""))
    view["db_password_set"] = bool(raw.get("db_password", ""))
    return view


# Changing where the database (or the S3 bucket) is must not reuse the stored
# secret on a new address: the save has to carry the secret again.
DB_CONNECTION_KEYS = ("db_host", "db_port", "db_user", "db_name")
DB_REENTER_MESSAGE = "Enter the database password again to change the database connection."
S3_CONNECTION_KEYS = ("s3_path", "s3_region", "s3_access_key")
S3_REENTER_MESSAGE = (
    "Enter the S3 secret key again to change the S3 path, region or access key."
)


def changed_without_secret(current: dict, updates: dict, keys: tuple, secret: str) -> bool:
    if str(updates.get(secret) or ""):
        return False
    return any(
        key in updates
        and str(updates[key]).strip()
        != str(current.get(key, _SETTINGS_DEFAULTS.get(key, ""))).strip()
        for key in keys
    )


def merge_settings(current: dict, updates: dict) -> dict:
    """Merges only ALLOWED_SETTINGS_KEYS into `current`, keeping every other
    key untouched. A blank `s3_secret_key`/`db_password` means "keep the
    current value" - the one pair never blindly overwritten."""
    merged = dict(current)
    for key in ALLOWED_SETTINGS_KEYS:
        if key not in updates:
            continue
        if key in ("s3_secret_key", "db_password") and not updates[key]:
            continue
        merged[key] = updates[key]
    return merged


# The HTTP server is threaded and the temp name is per process, so two saves
# at once would write the same temp file. One lock: saves are rare.
_SETTINGS_WRITE_LOCK = threading.Lock()


def apply_settings_update(config_path: Path, updates: dict) -> tuple[int, dict]:
    """Merges `updates` into the config on disk, validating the result with
    `config.load_config` before it ever replaces the live file.

    Writes the candidate to a temp file IN THE SAME FOLDER (so load_config's
    relative-path resolution matches the real file), validates it, and only
    then `os.replace`s it in. On any failure the temp file is removed and the
    original is left byte-for-byte untouched.
    """
    try:
        current = json.loads(fs_path(config_path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return 500, {"error": f"Could not read the current configuration: {exc}"}
    if not isinstance(current, dict):
        current = {}
    if changed_without_secret(current, updates, DB_CONNECTION_KEYS, "db_password"):
        return 400, {"error": DB_REENTER_MESSAGE}
    if changed_without_secret(current, updates, S3_CONNECTION_KEYS, "s3_secret_key"):
        return 400, {"error": S3_REENTER_MESSAGE}
    merged = merge_settings(current, updates)
    # Fixed name, not per-pid: one process owns this config and saves are
    # serialised below, and Upload.iss's ProtectUploadConfig removes exactly
    # this name if a crash ever leaves it behind.
    temp_path = config_path.with_name(f".{config_path.name}.tmp")
    with _SETTINGS_WRITE_LOCK:
        return _validate_and_replace(config_path, temp_path, merged)


def _validate_and_replace(config_path: Path, temp_path: Path, merged: dict) -> tuple[int, dict]:
    try:
        # New secrets arrive plain from the console; store them protected.
        # (Kept ones are already dpapi:... and are returned unchanged.)
        merged = {
            **merged,
            **{k: lwcam_secrets.protect(str(merged.get(k, ""))) for k in ("db_password", "s3_secret_key")},
        }
        with fs_path(temp_path).open("w", encoding="utf-8", newline="\n") as stream:
            json.dump(merged, stream, indent=2, sort_keys=True)
            stream.write("\n")
        load_config(temp_path)
    except Exception as exc:  # noqa: BLE001 - reported to the caller as a 400
        fs_path(temp_path).unlink(missing_ok=True)
        return 400, {"error": str(exc)}
    os.replace(fs_path(temp_path), fs_path(config_path))
    return 200, {"saved": True}


# --------------------------------------------------------------------------
# Database access. Both raise DbUnavailable rather than returning a sentinel,
# so a caller can tell "no such user" (return None) apart from "could not
# even ask" - the two need different HTTP status codes.
# --------------------------------------------------------------------------


class DbUnavailable(Exception):
    pass


def _connect_kwargs(config: Config, timeout: int) -> dict:
    return {
        "host": config.db_host,
        "port": config.db_port,
        "dbname": config.db_name,
        "user": config.db_user,
        "password": config.db_password,
        "sslmode": db_sslmode(config.db_host, config.db_use_ssl),
        "connect_timeout": timeout,
        "options": f"-c statement_timeout={int(timeout) * 1000}",
    }


def lookup_user(config: Config, username: str, *, timeout: int = 5) -> dict | None:
    """`SELECT password, roles, active, is_deleted FROM users WHERE user_id
    = %s`. Raises DbUnavailable if the database cannot be reached at all;
    returns None only for "no such user"."""
    try:
        import psycopg
    except ImportError as exc:  # pragma: no cover - a build without the driver
        raise DbUnavailable(str(exc)) from exc
    try:
        with psycopg.connect(**_connect_kwargs(config, timeout)) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT password, roles, active, is_deleted FROM users WHERE user_id = %s",
                    (username,),
                )
                row = cur.fetchone()
    except Exception as exc:
        raise DbUnavailable(str(exc)) from exc
    if row is None:
        return None
    password, roles, active, is_deleted = row
    return {
        "password": password,
        "roles": roles or "",
        "active": bool(active),
        "is_deleted": bool(is_deleted),
    }


def probe_db(config: Config, *, timeout: int = 5) -> bool:
    try:
        import psycopg
    except ImportError:
        return False
    try:
        with psycopg.connect(**_connect_kwargs(config, timeout)) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
                cur.fetchone()
        return True
    except Exception:
        return False


# --------------------------------------------------------------------------
# The saved admin list (admin_cache.json, beside the config file): lets an
# admin sign in while the database is down. Holds ONLY active admin /
# super_admin accounts (user_id, bcrypt hash, roles, cached_at) - refreshed in
# full every ADMIN_CACHE_REFRESH_SECONDS while the database answers, and one
# account at a time at each good sign-in. The config folder is admin-locked.
# --------------------------------------------------------------------------

ADMIN_ROLES = {"super_admin", "admin"}
ADMIN_CACHE_REFRESH_SECONDS = 600.0
# A real bcrypt hash of a throwaway password. An unknown username is checked
# against it so the answer takes as long as for a real account.
DUMMY_HASH = "$2b$12$qx/hTguQwMb86ig2m9.BEOu6uTngDcKsy1u/oU23i7959Mv5Mko1e"


# The HTTP threads (sign-ins) and the main loop (full refresh) both read-modify-
# write admin_cache.json; one lock keeps either from overwriting the other.
_ADMIN_CACHE_LOCK = threading.Lock()


def admin_cache_path(config_path: Path) -> Path:
    return Path(config_path).with_name("admin_cache.json")


def read_admin_cache(config_path: Path) -> list[dict]:
    rows = (_read_json_file(admin_cache_path(config_path)) or {}).get("admins")
    return [row for row in rows if isinstance(row, dict)] if isinstance(rows, list) else []


def cached_admin_record(config_path: Path, username: str) -> dict | None:
    """The saved account shaped like lookup_user's answer, or None."""
    for row in read_admin_cache(config_path):
        if row.get("user_id") == username and role_set(row.get("roles", "")) & ADMIN_ROLES:
            return {
                "password": row.get("password"),
                "roles": row.get("roles", ""),
                "active": True,
                "is_deleted": False,
            }
    return None


def remember_admin(config_path: Path, username: str, password_hash: str, roles: str) -> None:
    with _ADMIN_CACHE_LOCK:
        rows = [r for r in read_admin_cache(config_path) if r.get("user_id") != username]
        rows.append(
            {"user_id": username, "password": password_hash, "roles": roles, "cached_at": _now_iso()}
        )
        atomic_json(admin_cache_path(config_path), {"admins": rows})


def fetch_admin_accounts(config: Config, *, timeout: int = 5) -> list[tuple[str, str, str]]:
    """(user_id, password hash, roles) of every active admin. Raises
    DbUnavailable. Only columns the lwcam_upload role may read."""
    try:
        import psycopg
    except ImportError as exc:  # pragma: no cover - a build without the driver
        raise DbUnavailable(str(exc)) from exc
    try:
        with psycopg.connect(**_connect_kwargs(config, timeout)) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT user_id, password, roles FROM users WHERE active AND NOT is_deleted"
                )
                rows = cur.fetchall()
    except Exception as exc:
        raise DbUnavailable(str(exc)) from exc
    return [
        (user_id, password, roles or "")
        for user_id, password, roles in rows
        if password and role_set(roles or "") & ADMIN_ROLES
    ]


def refresh_admin_cache(
    config: Config, config_path: Path, fetch: Callable[[Config], list] = fetch_admin_accounts
) -> None:
    """Full replace: an admin disabled or removed disappears here."""
    stamp = _now_iso()
    admins = [
        {"user_id": u, "password": p, "roles": r, "cached_at": stamp} for u, p, r in fetch(config)
    ]
    with _ADMIN_CACHE_LOCK:  # the (slow) fetch stays outside the lock
        atomic_json(admin_cache_path(config_path), {"admins": admins})


# --------------------------------------------------------------------------
# Shared state the HTTP handlers read and the loop writes.
# --------------------------------------------------------------------------


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class ServiceState:
    """One dict guarded by one lock - small and short-lived enough that a
    coarse lock costs nothing here."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._data: dict[str, object] = {
            "config": None,
            "config_problem": None,
            # None = not probed yet. Access treats it as reachable, so the
            # no-login fallback never opens in the moment before the first
            # probe answers; only a probe that actually failed opens it.
            "database_reachable": None,
            "database_checked_at": None,
            "schema_problem": None,
            "last_scan_at": None,
            "next_scan_at": None,
        }

    def update(self, **kwargs: object) -> None:
        with self._lock:
            self._data.update(kwargs)

    def snapshot(self) -> dict[str, object]:
        with self._lock:
            return dict(self._data)


def _stop_request_path(config: Config | None) -> Path | None:
    if config is None:
        return None
    return config.state_file.parent / "stop.request"


def _stop_requested(config: Config | None) -> bool:
    """Peeks at the stop file without consuming it - safe to call from
    inside a scan, which must not itself decide to shut the process down."""
    path = _stop_request_path(config)
    return path is not None and fs_path(path).exists()


def _consume_stop_request(config: Config | None) -> None:
    path = _stop_request_path(config)
    if path is not None:
        fs_path(path).unlink(missing_ok=True)


# --------------------------------------------------------------------------
# HTTP layer.
# --------------------------------------------------------------------------


@dataclass
class ServiceContext:
    config_path: Path
    coordinator: UploadCoordinator
    state: ServiceState
    wake: threading.Event
    sessions: SessionStore = field(default_factory=SessionStore)
    rate_limiter: RateLimiter = field(default_factory=RateLimiter)
    db_lookup: Callable[[Config, str], dict | None] = lookup_user
    web_dir: Path = field(default_factory=lambda: Path(__file__).resolve().parent / "web")
    version: str = "dev"


def build_handler(ctx: ServiceContext) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "LwcamUploadConsole/1"
        # A client that connects and goes quiet (or stalls the TLS handshake)
        # frees its thread after this long instead of holding it forever.
        timeout = 30

        def log_message(self, format: str, *args: object) -> None:  # noqa: A002
            # Method + path + status only - never headers or a body, so a
            # password typed into /api/login can never reach this log.
            status = str(args[1]) if len(args) > 1 else ""
            # The page polls /api/log and /api/status every few seconds; a
            # line per poll would bury the console in its own traffic. Only
            # actions (POST) and failures are worth an operator's attention.
            if self.command == "GET" and (
                not status.startswith(("4", "5")) or self.path == "/favicon.ico"
            ):
                return
            LOGGER.info("%s %s %s", self.command, self.path.split("?", 1)[0], status)

        # -- small helpers --------------------------------------------------

        def _client_is_local(self) -> bool:
            # The Host check stops DNS rebinding: a web page on this PC whose
            # name resolves to 127.0.0.1 would pass the address test alone,
            # and "local" is what grants the no-login fallback.
            host = (self.headers.get("Host") or "").strip().lower()
            if host.startswith("["):
                host = host[1:].split("]", 1)[0]
            else:
                host = host.rsplit(":", 1)[0] if host.count(":") == 1 else host
            return self.client_address[0] in ("127.0.0.1", "::1") and host in (
                "localhost", "127.0.0.1", "::1"
            )

        def _cookie_token(self) -> str | None:
            cookie_header = self.headers.get("Cookie")
            if not cookie_header:
                return None
            jar = SimpleCookie()
            try:
                jar.load(cookie_header)
            except Exception:
                return None
            morsel = jar.get(SESSION_COOKIE_NAME)
            return morsel.value if morsel is not None else None

        def _sign_in_required(self) -> dict:
            """The 401 body: says so when an idle session of this browser
            was taken over by a sign-in elsewhere, instead of a bare "sign in"."""
            token = self._cookie_token()
            if token and ctx.sessions.was_replaced(token):
                return {"error": SIGNED_IN_ELSEWHERE, "replaced": True}
            return {"error": "Sign in required."}

        def _session_username(self) -> str | None:
            token = self._cookie_token()
            if token is None:
                return None
            username = ctx.sessions.username_for(token)
            if username is None:
                return None
            if (
                ctx.state.snapshot().get("database_reachable") is not False
                and ctx.sessions.revalidate_due(token)
            ):
                config, _error = try_load_config(ctx.config_path)
                if config is not None and config.db_host and not self._still_admin(config, username):
                    ctx.sessions.remove(token)
                    return None
            return username

        @staticmethod
        def _still_admin(config: Config, username: str) -> bool:
            """Whether the database still calls this account an active admin.
            An unreachable database keeps the session (the saved-admin sign-in
            already trusts it while the database is down)."""
            try:
                record = ctx.db_lookup(config, username)
            except DbUnavailable:
                return True
            return bool(
                record
                and record.get("active")
                and not record.get("is_deleted")
                and role_set(record.get("roles", "")) & ADMIN_ROLES
            )

        def _access(self) -> tuple[str, bool, str | None]:
            username = self._session_username()
            db_reachable = ctx.state.snapshot().get("database_reachable") is not False
            access, local_fallback = compute_access_level(
                signed_in=username is not None,
                db_reachable=db_reachable,
                client_is_local=self._client_is_local(),
            )
            return access, local_fallback, username

        def _send_json(
            self,
            status: int,
            payload: dict,
            *,
            set_cookie: str | None = None,
            clear_cookie: bool = False,
        ) -> None:
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            secure = tls.secure_flag(self)
            if set_cookie:
                self.send_header("Set-Cookie", set_cookie + secure)
            if clear_cookie:
                self.send_header(
                    "Set-Cookie",
                    f"{SESSION_COOKIE_NAME}=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0{secure}",
                )
            self.end_headers()
            self.wfile.write(body)

        def _read_json_body(self) -> dict | None:
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = 0
            if length > MAX_BODY_BYTES:
                self._send_json(413, {"error": "Request body is too large."})
                return None
            raw = self.rfile.read(length) if length else b""
            if not raw:
                return {}
            try:
                data = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, ValueError):
                self._send_json(400, {"error": "Invalid JSON body."})
                return None
            if not isinstance(data, dict):
                self._send_json(400, {"error": "Invalid JSON body."})
                return None
            return data

        def _require_csrf(self) -> bool:
            if self.headers.get("X-Requested-With") != "lwip":
                self._send_json(403, {"error": "Missing required header."})
                return False
            return True

        def _require_full_access(self, access: str) -> bool:
            if access == "full":
                return True
            self._send_json(
                401 if access == "none" else 403,
                self._sign_in_required() if access == "none" else {"error": "Sign in required."},
            )
            return False

        # -- routing ----------------------------------------------------------

        def do_GET(self) -> None:  # noqa: N802
            parsed = urlsplit(self.path)
            if parsed.path == "/":
                self._serve_index()
            elif parsed.path == "/api/session":
                self._get_session()
            elif parsed.path == "/api/status":
                self._get_status()
            elif parsed.path == "/api/log":
                self._get_log(parse_qs(parsed.query))
            elif parsed.path == "/api/settings":
                self._get_settings()
            elif parsed.path == "/api/network-logins":
                self._network_logins("list")
            else:
                self._send_json(404, {"error": "Not found."})

        def do_POST(self) -> None:  # noqa: N802
            if not self._require_csrf():
                return
            parsed = urlsplit(self.path)
            if parsed.path in NETWORK_LOGIN_ACTIONS:
                self._network_logins(NETWORK_LOGIN_ACTIONS[parsed.path])
            elif parsed.path == "/api/login":
                self._post_login()
            elif parsed.path == "/api/logout":
                self._post_logout()
            elif parsed.path == "/api/settings":
                self._post_settings()
            elif parsed.path == "/api/retry":
                self._post_retry()
            elif parsed.path == "/api/scan":
                self._post_scan()
            else:
                self._send_json(404, {"error": "Not found."})

        # -- endpoints --------------------------------------------------------

        def _serve_index(self) -> None:
            try:
                body = (ctx.web_dir / "index.html").read_bytes()
            except OSError:
                body = PLACEHOLDER_HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _get_session(self) -> None:
            access, _local_fallback, username = self._access()
            token = self._cookie_token()
            snap = ctx.state.snapshot()
            self._send_json(
                200,
                {
                    "signed_in": username is not None,
                    "signed_out_reason": (
                        self._sign_in_required().get("error")
                        if username is None and access == "none" else None
                    ),
                    "user": username,
                    "access": access,
                    # Same reading as access: not probed yet counts as reachable.
                    "db_reachable": snap.get("database_reachable") is not False,
                    "from_cache": bool(username and token and ctx.sessions.is_from_cache(token)),
                },
            )

        def _post_login(self) -> None:
            body = self._read_json_body()
            if body is None:
                return
            username = str(body.get("username", "")).strip()
            password = str(body.get("password", ""))
            client_ip = self.client_address[0]

            if not ctx.rate_limiter.check(client_ip, username):
                self._send_json(
                    429,
                    {"error": "Too many failed login attempts. Wait a few minutes and try again."},
                )
                return

            config, _error = try_load_config(ctx.config_path)
            if config is None:
                self._send_json(503, {"error": "Database settings are not available."})
                return

            from_cache = False
            try:
                record = ctx.db_lookup(config, username)
            except DbUnavailable:
                ctx.state.update(database_reachable=False, database_checked_at=_now_iso())
                record = cached_admin_record(ctx.config_path, username)
                from_cache = True
            else:
                ctx.state.update(database_reachable=True, database_checked_at=_now_iso())

            # An unknown username still runs bcrypt, so timing does not reveal it.
            password_ok = verify_password(
                password, record.get("password") if record else DUMMY_HASH
            )
            if record is None or not password_ok:
                ctx.rate_limiter.record_failure(client_ip, username)
                self._send_json(
                    401,
                    {
                        "error": (
                            "Incorrect username or password, or the database is unreachable "
                            "and this account is not on the saved admin list."
                            if from_cache else "Incorrect username or password."
                        )
                    },
                )
                return
            if not record.get("active") or record.get("is_deleted"):
                self._send_json(403, {"error": "This account is disabled."})
                return
            if not role_set(record.get("roles", "")) & {"super_admin", "admin"}:
                self._send_json(403, {"error": "This account has no console access."})
                return

            if not from_cache:
                try:
                    remember_admin(
                        ctx.config_path, username, record.get("password"), record.get("roles", "")
                    )
                except OSError as exc:
                    LOGGER.warning("Could not save the admin list: %s", exc)
            ctx.rate_limiter.reset(client_ip, username)
            token = ctx.sessions.create(
                username, current_token=self._cookie_token(), from_cache=from_cache
            )
            if token is None:
                self._send_json(409, {"error": ALREADY_SIGNED_IN})
                return
            cookie = f"{SESSION_COOKIE_NAME}={token}; HttpOnly; SameSite=Strict; Path=/"
            self._send_json(200, {"user": username}, set_cookie=cookie)

        def _post_logout(self) -> None:
            cookie_header = self.headers.get("Cookie")
            if cookie_header:
                jar = SimpleCookie()
                try:
                    jar.load(cookie_header)
                    morsel = jar.get(SESSION_COOKIE_NAME)
                    if morsel is not None:
                        ctx.sessions.remove(morsel.value)
                except Exception:
                    pass
            self._send_json(200, {}, clear_cookie=True)

        def _get_status(self) -> None:
            access, _local_fallback, _username = self._access()
            if access not in ("full", "view"):
                self._send_json(401, self._sign_in_required())
                return
            snap = ctx.state.snapshot()
            config, error = try_load_config(ctx.config_path)
            payload = ctx.coordinator.status(
                config,
                config_problem=error,
                last_scan_at=snap.get("last_scan_at"),
                next_scan_at=snap.get("next_scan_at"),
            )
            if payload.get("ledgerProblem") and not payload.get("permanentProblem"):
                payload["permanentProblem"] = payload["ledgerProblem"]  # the page's red banner
            if payload.get("watchProblem") and not payload.get("permanentProblem"):
                payload["permanentProblem"] = payload["watchProblem"]
            payload["schemaProblem"] = snap.get("schema_problem")
            payload["version"] = ctx.version
            self._send_json(200, payload)

        def _get_log(self, query: dict) -> None:
            access, _local_fallback, _username = self._access()
            if access not in ("full", "view"):
                self._send_json(401, self._sign_in_required())
                return
            try:
                after = int(query.get("after", ["0"])[0])
            except (TypeError, ValueError):
                after = 0
            lines = log_lines_after(max(0, after))
            self._send_json(200, {"lines": lines, "last": log_last_seq()})

        def _get_settings(self) -> None:
            access, _local_fallback, _username = self._access()
            if not self._require_full_access(access):
                return
            self._send_json(200, read_settings_view(ctx.config_path))

        def _post_settings(self) -> None:
            access, _local_fallback, username = self._access()
            if not self._require_full_access(access):
                return
            body = self._read_json_body()
            if body is None:
                return
            status, payload = apply_settings_update(ctx.config_path, body)
            self._send_json(status, payload)
            if status == 200:
                log("CONFIG", f"Settings saved by {username or 'local'}")
                ctx.wake.set()

        def _post_retry(self) -> None:
            access, _local_fallback, _username = self._access()
            if not self._require_full_access(access):
                return
            ctx.coordinator.retry_failed()  # a flag; the scan thread does the work
            ctx.wake.set()
            self._send_json(200, {"ok": True})

        def _network_logins(self, action: str) -> None:
            access, _local_fallback, _username = self._access()
            if not self._require_full_access(access):
                return
            body = self._read_json_body() if self.command == "POST" else {}
            if body is None:
                return
            view = read_settings_view(ctx.config_path)
            paths = [view.get(key) or "" for key in ("watch_root", "done_root", "summary_root")]
            self._send_json(*netlogin.console_request(action, body, paths))

        def _post_scan(self) -> None:
            access, _local_fallback, _username = self._access()
            if not self._require_full_access(access):
                return
            ctx.wake.set()
            self._send_json(200, {"ok": True})

    return Handler


# --------------------------------------------------------------------------
# The loop.
# --------------------------------------------------------------------------


def send_heartbeat(health: Health, coordinator: UploadCoordinator, config: Config) -> None:
    """One beat: pending / failed / last_error_kind from the ledger. Never raises."""
    try:
        status = coordinator.status(config)
        failures = status["failures"]
        backlog = {
            "pending": len(status["pending"]),
            "failed": len(failures),
            "last_error_kind": status.get("lastErrorKind"),
            "db_pending": status.get("dbPending", 0),
        }
        if getattr(config, "enabled", True):  # a switched-off service scans nothing; not "stalled"
            backlog["last_scan_minutes_ago"] = coordinator.scan_age_minutes()
            backlog["scan_interval_minutes"] = status.get("scanIntervalMinutes")
        health.beat(
            backlog,
            error=status.get("ledgerProblem")
            or status.get("watchProblem")
            or (failures[0].get("error") if failures else None),
        )
    except Exception as exc:  # noqa: BLE001
        LOGGER.debug("Heartbeat skipped: %s", exc)


class ConsoleServer(ThreadingHTTPServer):
    """The stdlib server, minus its default habit of printing a full traceback
    to stderr (service.log) for every scanner, port probe or half-open TLS
    handshake that touches the console."""

    def handle_error(self, request, client_address) -> None:  # noqa: ANN001
        error = sys.exc_info()[1]
        kind = "TLS" if isinstance(error, ssl.SSLError) else "connection"
        LOGGER.warning(
            "console %s error from %s: %s", kind, client_address[0], error or "unknown"
        )


def _heartbeat_loop(state: ServiceState, health: Health, coordinator: UploadCoordinator,
                    stop: threading.Event) -> None:
    """Beats every HEARTBEAT_SECONDS on its own thread, so a scan that spends an
    hour on one large package never makes this PC look dead on the status page."""
    while True:
        config = state.snapshot().get("config")
        if config is not None:
            send_heartbeat(health, coordinator, config)
            state.update(schema_problem=health.schema_problem)
        if stop.wait(HEARTBEAT_SECONDS):
            return


def run(config_path: Path) -> int:
    """Runs the console + sweep until a stop.request file is dropped beside
    state_file. Returns 0. A console that cannot bind logs [ERROR] and the
    sweep runs anyway - a taken port must not take image delivery down with it.
    """
    config_path = Path(config_path)
    # Configured before the first log line, from a lenient read of the same
    # file load_config will validate properly below - startup and "the config
    # is broken" must both reach log_file, not just whatever a later
    # successful load turns up.
    configure_logging(_lenient_log_file(config_path))
    log("SYSTEM", f"starting, config: {config_path}")
    try:
        if lwcam_secrets.protect_file(config_path, ("db_password", "s3_secret_key")):
            log("SYSTEM", "the stored passwords and keys are now protected")
    except Exception as exc:  # noqa: BLE001 - run with the plain file rather than not at all
        log("ERROR", f"could not protect the stored secrets: {type(exc).__name__}")
    # Into this service's own tagged log, and signed in to any network folder
    # before the first sweep looks at it.
    netlogin.LOGGER = logging.getLogger(f"{LOGGER_NAME}.netlogin")
    netlogin.start_keeper()

    coordinator = UploadCoordinator()
    state = ServiceState()
    wake = threading.Event()

    def health_connect():
        import psycopg

        config = state.snapshot().get("config")
        if config is None or not config.db_host:
            raise DbUnavailable("no database configured")
        return psycopg.connect(**_connect_kwargs(config, 5))

    health = Health(health_connect)
    coordinator.db_writer = health.write_back
    ctx = ServiceContext(
        config_path=config_path, coordinator=coordinator, state=state, wake=wake,
        version=health.version,
    )

    port, bind = read_ui_settings(config_path)
    httpd: ThreadingHTTPServer | None = None
    try:
        httpd = ConsoleServer((bind, port), build_handler(ctx))
    except OSError as exc:
        log("ERROR", f"console could not listen on {bind}:{port}: {exc}")
    if httpd is not None:
        try:
            tls.wrap_if_configured(httpd, config_path)
        except Exception as exc:  # noqa: BLE001 - wrap_if_configured already closed the socket
            # Never fall back to plain http (a downgrade) and never let a bad
            # certificate stop the uploads: run without a console instead.
            httpd = None
            log("ERROR", f"console NOT started, the certificate is unusable ({exc}); uploads continue")
    if httpd is not None:
        threading.Thread(
            target=httpd.serve_forever, name="lwcam-upload-console-http", daemon=True
        ).start()
        log("SYSTEM", f"console listening on {httpd.server_address[0]}:{httpd.server_address[1]}")

    heartbeat_stop = threading.Event()
    threading.Thread(
        target=_heartbeat_loop, args=(state, health, coordinator, heartbeat_stop),
        name="lwcam-upload-heartbeat", daemon=True,
    ).start()

    last_probe_at = float("-inf")
    last_admin_refresh_at = float("-inf")
    last_config_error: str | None = None

    try:
        while True:
            config, error = try_load_config(config_path)
            if error != last_config_error:
                if error:
                    log("CONFIG", error)
                last_config_error = error
            state.update(config=config, config_problem=error)

            if _stop_requested(config):
                _consume_stop_request(config)
                log("SYSTEM", "stop requested")
                break

            now = time.monotonic()
            if now - last_probe_at >= DB_PROBE_INTERVAL_SECONDS:
                last_probe_at = now
                reachable = probe_db(config) if config is not None else False
                state.update(database_reachable=reachable, database_checked_at=_now_iso())
                if (
                    reachable
                    and config is not None
                    and now - last_admin_refresh_at >= ADMIN_CACHE_REFRESH_SECONDS
                ):
                    last_admin_refresh_at = now
                    try:
                        refresh_admin_cache(config, config_path)
                    except Exception as exc:  # noqa: BLE001 - the saved list is a convenience
                        log("ERROR", f"could not refresh the saved admin list: {exc}")

            interval = config.interval_seconds if config is not None else 60
            if config is not None and config.enabled:
                try:
                    coordinator.scan_once(config, stop_check=lambda: _stop_requested(config))
                except Exception as exc:  # noqa: BLE001 - keep the loop alive
                    log("ERROR", f"scan failed: {exc}")
                state.update(
                    last_scan_at=_now_iso(),
                    next_scan_at=(
                        datetime.now(timezone.utc) + timedelta(seconds=interval)
                    ).isoformat(),
                )

            deadline = time.monotonic() + interval
            stopped = False
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                if wake.wait(min(1.0, remaining)):
                    wake.clear()
                    break
                if _stop_requested(config):
                    _consume_stop_request(config)
                    stopped = True
                    break
            if stopped:
                log("SYSTEM", "stop requested")
                break
    finally:
        heartbeat_stop.set()
        if httpd is not None:
            httpd.shutdown()
            httpd.server_close()
    log("SYSTEM", "stopped")
    return 0


__all__ = ["run", "ServiceContext", "ServiceState", "build_handler"]

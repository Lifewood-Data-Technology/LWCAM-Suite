"""The LWIP console: a supervisor that runs the deskew/crop worker as a child
process and serves a small HTTP console beside it.

Run as `python -m deskew_crop_tool.service --config <path>` - this is what
START_LWIP.bat now launches instead of the worker directly. The supervisor
starts the worker (`python -m deskew_crop_tool --config <path>`), restarts it
on crash with a backoff, and answers a JSON API (see the API_ROUTES table
below) plus the console page itself (web/index.html, built by a sibling
workstream) on its own port - independent of whether the worker can even
start, so a bad config is something an operator can see and fix from a
browser rather than only from service.log.

Stdlib-only except bcrypt (password hashing, matches QC's convention exactly)
and psycopg (imported lazily, only when a database call is actually made -
see cloud_report.py for the precedent). No web framework: one
ThreadingHTTPServer and a handful of pure functions, most of which need no
database or process to test (role parsing, access levels, the rate limiter,
settings merge/validate, status/log summarising).
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import secrets
import ssl
import subprocess
import sys
import threading
import time
import uuid
from dataclasses import dataclass, field
from datetime import date, datetime, timezone
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Callable
from urllib.parse import parse_qs, urlsplit

import bcrypt

from .config import DEFAULT_CONFIG_PATH, DEFAULT_CROP_PADDING, ToolConfig, db_sslmode, load_config
from .config import _path as _resolve_config_path
from . import health, lwcam_secrets, netlogin, tls
from .orchestrator import FolderOrchestrator

LOGGER = logging.getLogger("deskew_crop_tool.service")

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
SESSION_COOKIE_NAME = "lwip_session"
SESSION_LIFETIME_SECONDS = 8 * 60 * 60
MAX_BODY_BYTES = 64 * 1024

# The keys a POST /api/settings may change. Anything else already in the
# config file is carried over untouched - see merge_settings.
ALLOWED_SETTINGS_KEYS = (
    "input_root",
    "output_root",
    "crop_padding",
    "workers",
    "db_host",
    "db_port",
    "db_name",
    "db_user",
    "db_use_ssl",
    "db_password",
)

PLACEHOLDER_HTML = (
    "<!doctype html><html><head><title>LWIP Console</title></head><body>"
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
    """Ported from QC's `User.role_set` property. `users.roles` is a
    comma-joined list shared with LWCAM/LWCamAdmin/QC; a holder of several
    roles ('admin,qc') is normal, so this never collapses to one value."""
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
    view: no session, the database is unreachable and the browser is ON this PC
          (read-only status). A remote browser gets the sign-in form only.
    none: otherwise (database reachable, no session).
    """
    if signed_in:
        return "full", False
    if db_reachable:
        return "none", False
    return ("view", False) if client_is_local else ("none", False)


# bcrypt ignores anything past 72 bytes; truncate explicitly rather than let
# the library decide, matching QC's app/core/security.py exactly - the
# `users.password` column is shared, so both readers must agree on where a
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


MAX_TRACKED_CLIENTS = 5000


class RateLimiter:
    """Ported from QC's `app/routers/auth.py` login rate limiter: 5 failed
    tries per (client IP, username) per 60 seconds, a lock-protected plain
    dict (not a defaultdict - see the QC source for why), only wrong
    passwords count, and a success resets the counter.

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

    def _prune_expired(self, window_start: float) -> None:
        for key in [
            k for k, times in self._failures.items() if not any(t > window_start for t in times)
        ]:
            self._failures.pop(key, None)

    def check(self, client_ip: str, username: str, *, now: float | None = None) -> bool:
        """True if this pair, and this IP overall, may still attempt a login."""
        moment = time.monotonic() if now is None else now
        key = self._key(client_ip, username)
        window_start = moment - LOGIN_ATTEMPT_WINDOW_SECONDS
        with self._lock:
            ip_start = moment - IP_ATTEMPT_WINDOW_SECONDS
            for ip in [k for k, times in self._ip_failures.items() if not any(t > ip_start for t in times)]:
                self._ip_failures.pop(ip, None)  # every IP, not just the caller's
            ip_recent = [t for t in self._ip_failures.get(client_ip, ()) if t > ip_start]
            if ip_recent:
                self._ip_failures[client_ip] = ip_recent
            self._prune_expired(window_start)
            attempts = [t for t in self._failures.get(key, ()) if t > window_start]
            if attempts:
                self._failures[key] = attempts
            else:
                self._failures.pop(key, None)
        return len(attempts) < LOGIN_ATTEMPT_LIMIT and len(ip_recent) < IP_ATTEMPT_LIMIT

    def record_failure(self, client_ip: str, username: str, *, now: float | None = None) -> None:
        moment = time.monotonic() if now is None else now
        with self._lock:
            self._failures.setdefault(self._key(client_ip, username), []).append(moment)
            self._ip_failures.setdefault(client_ip, []).append(moment)
            for table in (self._failures, self._ip_failures):  # oldest entries go first
                while len(table) > MAX_TRACKED_CLIENTS:
                    table.pop(next(iter(table)))

    def reset(self, client_ip: str, username: str) -> None:
        with self._lock:
            self._failures.pop(self._key(client_ip, username), None)


class SessionStore:
    """In-memory sessions only - lost on service restart, by design (the
    contract's stated behaviour, not an oversight)."""

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
        # When each session was last checked against the database.
        self._checked_at: dict[str, float] = {}

    def due_for_check(self, token: str, interval: float = 60.0) -> bool:
        """True (and starts the next interval) when this session has not been
        re-validated for `interval` seconds."""
        now = time.monotonic()
        with self._lock:
            if now - self._checked_at.get(token, float("-inf")) < interval:
                return False
            self._checked_at[token] = now
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
            self._checked_at[token] = now
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
                self._checked_at.pop(token, None)
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
            self._checked_at.pop(token, None)
            self._from_cache.discard(token)


# Changing where the database is (or who logs in) must not reuse the stored
# password on a new address: the save has to carry the password again.
DB_CONNECTION_KEYS = ("db_host", "db_port", "db_user", "db_name")
DB_CONNECTION_DEFAULTS = {"db_host": "", "db_port": 5432, "db_user": "", "db_name": "lwcam"}
DB_REENTER_MESSAGE = "Enter the database password again to change the database connection."


def changed_without_secret(current: dict, updates: dict, keys: tuple, secret: str,
                           defaults: dict) -> bool:
    if str(updates.get(secret) or ""):
        return False
    return any(
        key in updates
        and str(updates[key]).strip() != str(current.get(key, defaults.get(key, ""))).strip()
        for key in keys
    )


def merge_settings(current: dict, updates: dict) -> dict:
    """Merges only ALLOWED_SETTINGS_KEYS into `current`, keeping every other
    key untouched. `db_password` absent or blank means "keep the current
    value" - it is the one key never blindly overwritten."""
    merged = dict(current)
    for key in ALLOWED_SETTINGS_KEYS:
        if key not in updates:
            continue
        if key == "db_password" and not updates[key]:
            continue
        merged[key] = updates[key]
    return merged


def read_settings_view(config_path: Path) -> dict:
    """The GET /api/settings shape. Reads the raw file leniently (not through
    load_config) so a broken config can still be shown and fixed from here;
    `db_password` itself is never returned, only whether one is set."""
    raw = _read_json_file(config_path) or {}
    return {
        "input_root": raw.get("input_root", ""),
        "output_root": raw.get("output_root", ""),
        "crop_padding": raw.get("crop_padding", DEFAULT_CROP_PADDING),
        "workers": raw.get("workers", 4),
        "db_host": raw.get("db_host", ""),
        "db_port": raw.get("db_port", 5432),
        "db_name": raw.get("db_name", "lwcam"),
        "db_user": raw.get("db_user", ""),
        "db_use_ssl": bool(raw.get("db_use_ssl", False)),
        "db_password_set": bool(raw.get("db_password", "")),
    }


def apply_settings_update(config_path: Path, updates: dict) -> tuple[int, dict]:
    """Merges `updates` into the config on disk, validating the result with
    `config.load_config` before it ever replaces the live file.

    Writes the candidate to a temp file IN THE SAME FOLDER (so load_config's
    relative-path resolution matches the real file), validates it, and only
    then `os.replace`s it in. On any failure the temp file is removed and the
    original is left byte-for-byte untouched.
    """
    try:
        current = json.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return 500, {"error": f"Could not read the current configuration: {exc}"}
    if not isinstance(current, dict):
        current = {}
    if changed_without_secret(
        current, updates, DB_CONNECTION_KEYS, "db_password", DB_CONNECTION_DEFAULTS
    ):
        return 400, {"error": DB_REENTER_MESSAGE}
    merged = merge_settings(current, updates)
    temp_path = config_path.with_name(f".{config_path.name}.{os.getpid()}.tmp")
    with _SETTINGS_WRITE_LOCK:
        return _validate_and_replace(config_path, temp_path, merged)


# The HTTP server is threaded and the temp name is per process, so two saves
# at once would write the same temp file. One lock: saves are rare.
_SETTINGS_WRITE_LOCK = threading.Lock()


def _validate_and_replace(config_path: Path, temp_path: Path, merged: dict) -> tuple[int, dict]:
    try:
        # A new password arrives plain from the console; store it protected.
        # (A kept one is already dpapi:... and is returned unchanged.)
        merged = {**merged, "db_password": lwcam_secrets.protect(str(merged.get("db_password", "")))}
        with temp_path.open("w", encoding="utf-8", newline="\n") as stream:
            json.dump(merged, stream, indent=2, sort_keys=True)
            stream.write("\n")
        load_config(temp_path)
    except Exception as exc:
        temp_path.unlink(missing_ok=True)
        return 400, {"error": str(exc)}
    os.replace(temp_path, config_path)
    return 200, {"restarting": True}


def summarize_state(status_doc: dict | None, state_doc: dict | None, *, today: date) -> dict:
    """Builds the `queue` object plus `last_report_at` for GET /api/status
    from status.json (written by the worker each scan pass) and state.json
    (the worker's completion journal). Deliberately does no filesystem work
    of its own - both documents are handed in already read."""
    waiting = list((status_doc or {}).get("waiting") or [])
    processing = list((status_doc or {}).get("processing") or [])
    updated_at = (status_doc or {}).get("updated_at")
    done_today = 0
    failed: list[dict[str, str]] = []
    last_report_at: str | None = None
    completed = (state_doc or {}).get("completed")
    if isinstance(completed, dict):
        for folder, item in completed.items():
            if not isinstance(item, dict):
                continue
            if item.get("retry_required"):
                failed.append({"folder": folder})
            if _is_today(item.get("completed_at"), today):
                done_today += 1
            reported_at = item.get("reported_at")
            if isinstance(reported_at, str) and (
                last_report_at is None or reported_at > last_report_at
            ):
                last_report_at = reported_at
    failures = (state_doc or {}).get("failures")
    if isinstance(failures, dict):
        listed = {entry["folder"] for entry in failed}
        for folder, item in failures.items():
            if isinstance(item, dict) and item.get("failed") and folder not in listed:
                failed.append({"folder": folder, "reason": str(item.get("error") or "")})
    return {
        "queue": {
            "waiting": len(waiting),
            "processing": len(processing),
            "done_today": done_today,
            "failed": failed,
            "updated_at": updated_at,
        },
        "last_report_at": last_report_at,
    }


def _is_today(value: object, today: date) -> bool:
    if not isinstance(value, str):
        return False
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return False
    if parsed.tzinfo is not None:
        parsed = parsed.astimezone()
    return parsed.date() == today


def parse_ui_settings(raw: dict) -> tuple[int, str]:
    """The lenient (never-raises) ui_port/ui_bind reader the contract asks
    for: the console must start even when the rest of the file is bad enough
    that config.load_config would reject it."""
    port = raw.get("ui_port", 8090)
    try:
        port = int(port)
    except (TypeError, ValueError):
        port = 8090
    if not 1 <= port <= 65535:
        port = 8090
    bind = str(raw.get("ui_bind") or "0.0.0.0").strip() or "0.0.0.0"
    return port, bind


def read_ui_settings(path: Path) -> tuple[int, str]:
    try:
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
        if not isinstance(raw, dict):
            raw = {}
    except (OSError, ValueError):
        raw = {}
    return parse_ui_settings(raw)


def read_log_tail(path: Path, lines: int) -> list[str]:
    """The whole file is small enough to read in one go: the worker's own
    RotatingFileHandler caps it at 10 MB, so there is no reverse-seek tail
    reader to write here."""
    try:
        with Path(path).open("r", encoding="utf-8", errors="replace") as stream:
            content = stream.readlines()
    except OSError:
        return []
    return [line.rstrip("\r\n") for line in content[-lines:]]


def _read_json_file(path: Path) -> dict | None:
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def try_load_config(path: Path) -> tuple[ToolConfig | None, str | None]:
    try:
        return load_config(path), None
    except Exception as exc:
        return None, str(exc)


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


# --------------------------------------------------------------------------
# Database access. Both functions raise DbUnavailable rather than returning a
# sentinel, so a caller can tell "no such user" (return None) apart from
# "could not even ask" - the two need different HTTP status codes.
# --------------------------------------------------------------------------


class DbUnavailable(Exception):
    pass


def _connect_kwargs(config: ToolConfig, timeout: int) -> dict:
    return {
        "host": config.db_host,
        "port": config.db_port,
        "dbname": config.db_name,
        "user": config.db_user,
        "password": config.db_password,
        "sslmode": db_sslmode(config.db_host, config.db_use_ssl),
        "connect_timeout": timeout,
        # Bounds the statement too, not just the connect - see
        # cloud_report.py's identical comment for why.
        "options": f"-c statement_timeout={int(timeout) * 1000}",
    }


def lookup_user(config: ToolConfig, username: str, *, timeout: int = 5) -> dict | None:
    """`SELECT password, roles, active, is_deleted FROM users WHERE user_id
    = %s` - the exact query and columns the contract specifies. Raises
    DbUnavailable if the database cannot be reached at all; returns None only
    for "no such user"."""
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


def probe_db(config: ToolConfig, *, timeout: int = 5) -> str | None:
    """None when the database answered, else why not - the driver's own
    message (host, user, database; never the password), which is the only
    thing that tells a wrong address from a pg_hba refusal or a bad login."""
    try:
        import psycopg
    except ImportError as exc:
        return f"The PostgreSQL driver is missing: {exc}"
    try:
        with psycopg.connect(**_connect_kwargs(config, timeout)) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
                cur.fetchone()
        return None
    except Exception as exc:
        return " ".join(str(exc).split()) or type(exc).__name__


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


# The handler threads and the supervisor's refresh all read-modify-write the
# same file: one lock, and a temp name no two writers can share.
_ADMIN_CACHE_LOCK = threading.Lock()


def _atomic_write_json(path: Path, payload: dict) -> None:
    """fsync BEFORE the rename: a power cut must not leave an empty file."""
    temp = path.with_name(f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp")
    try:
        with temp.open("w", encoding="utf-8", newline="\n") as stream:
            json.dump(payload, stream, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


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
        _atomic_write_json(admin_cache_path(config_path), {"admins": rows})


def fetch_admin_accounts(config: ToolConfig, *, timeout: int = 5) -> list[tuple[str, str, str]]:
    """(user_id, password hash, roles) of every active admin. Raises
    DbUnavailable. Only columns the lwcam_lwip / lwcam_upload roles may read."""
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
    config: ToolConfig, config_path: Path, fetch: Callable[[ToolConfig], list] = fetch_admin_accounts
) -> None:
    """Full replace: an admin disabled or removed disappears here."""
    stamp = _now_iso()
    admins = [
        {"user_id": u, "password": p, "roles": r, "cached_at": stamp} for u, p, r in fetch(config)
    ]
    with _ADMIN_CACHE_LOCK:
        _atomic_write_json(admin_cache_path(config_path), {"admins": admins})


# --------------------------------------------------------------------------
# The supervisor: owns the child worker process and the shared state the
# HTTP handlers read. Runs in the main thread; the HTTP server runs in a
# daemon thread beside it (see main()).
# --------------------------------------------------------------------------


class SharedState:
    """One dict guarded by one lock, per the contract. Small and short-lived
    enough that a coarse lock costs nothing here."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._data: dict[str, object] = {
            "state": "starting",
            "since": _now_iso(),
            "pid": None,
            "last_exit_code": None,
            "last_error": None,
            "config_error": None,
            # None = not probed yet. Access treats it as reachable, so the
            # no-login fallback never opens in the moment before the first
            # probe answers; only a probe that actually failed opens it.
            "database_reachable": None,
            "database_checked_at": None,
            "database_error": None,
            "schema_problem": None,
        }

    def update(self, **kwargs: object) -> None:
        with self._lock:
            self._data.update(kwargs)

    def snapshot(self) -> dict[str, object]:
        with self._lock:
            return dict(self._data)


ChildCommandFactory = Callable[[Path], list[str]]


def _default_child_command(config_path: Path) -> list[str]:
    return [sys.executable, "-m", "deskew_crop_tool", "--config", str(config_path)]


def _lenient_work_root(config_path: Path) -> Path:
    """Best-effort work_root when the config cannot be fully loaded - just
    enough to find the orchestrator's stop file for a graceful restart."""
    raw = _read_json_file(config_path) or {}
    base = Path(config_path).expanduser().resolve().parent
    return _resolve_config_path(raw.get("work_root", "runtime/deskew_crop/work"), base)


class Supervisor:
    DB_PROBE_INTERVAL_SECONDS = 60.0
    # Work is queued but the worker has not advanced (status.json progress_at)
    # for this long: it is hung, and gets restarted.
    STALL_SECONDS = 30 * 60.0
    STALL_CHECK_SECONDS = 30.0

    def __init__(
        self,
        config_path: Path,
        *,
        backoff_seconds: float = 30.0,
        restart_wait_seconds: float = 90.0,
        poll_interval: float = 0.5,
        db_probe_interval_seconds: float | None = None,
        child_command_factory: ChildCommandFactory | None = None,
    ) -> None:
        self.config_path = Path(config_path)
        self.backoff_seconds = backoff_seconds
        self.restart_wait_seconds = restart_wait_seconds
        self.poll_interval = poll_interval
        self.db_probe_interval_seconds = (
            self.DB_PROBE_INTERVAL_SECONDS
            if db_probe_interval_seconds is None
            else db_probe_interval_seconds
        )
        self._child_command_factory = child_command_factory or _default_child_command
        self.state = SharedState()
        self._restart_event = threading.Event()
        self._shutdown = threading.Event()
        self._admin_cache_refreshed_at = float("-inf")
        self.version = health.read_version()
        self._heartbeat: health.Heartbeat | None = None
        self._first_seen: dict[str, float] = {}
        self._stall_error: str | None = None

    def worker_stalled(self, config: ToolConfig, child_started_at: float) -> bool:
        """Queued work and no progress for STALL_SECONDS (the restart itself
        counts as progress, so a fresh worker gets a full window)."""
        doc = _read_json_file(config.state_file.parent / "status.json") or {}
        progress = doc.get("progress_at")
        if not doc.get("processing") or not isinstance(progress, (int, float)):
            return False
        return time.time() - max(float(progress), child_started_at) > self.STALL_SECONDS

    def send_heartbeat(self, config: ToolConfig) -> None:
        """Called after a good database check (so once a probe interval, 60 s):
        schema check + service_heartbeat upsert. Never raises into the loop."""
        try:
            if self._heartbeat is None:
                import psycopg

                self._heartbeat = health.Heartbeat(
                    "lwip", lambda: psycopg.connect(**_connect_kwargs(self._config, 5)),
                    version=self.version,
                )
            self._config = config
            status_doc = _read_json_file(config.state_file.parent / "status.json")
            state_doc = _read_json_file(config.state_file)
            queue = summarize_state(status_doc, state_doc, today=date.today())["queue"]
            waiting = list((status_doc or {}).get("waiting") or [])
            backlog = health.backlog_of(waiting, queue["failed"], self._first_seen, now=time.monotonic(),
                                        status=status_doc)
            snap = self.state.snapshot()
            error = (
                snap.get("last_error") if snap.get("state") == "crashed" else snap.get("config_error")
            ) or self._stall_error or (status_doc or {}).get("input_error")
            self._heartbeat.beat(backlog, error=error)
            self.state.update(schema_problem=self._heartbeat.schema_problem)
        except Exception as exc:  # noqa: BLE001
            LOGGER.debug("Heartbeat skipped: %s", exc)

    def refresh_admin_cache_if_due(self, config: ToolConfig, *, now: float) -> None:
        """Called after a good database check; never raises into the loop."""
        if now - self._admin_cache_refreshed_at < ADMIN_CACHE_REFRESH_SECONDS:
            return
        self._admin_cache_refreshed_at = now
        try:
            refresh_admin_cache(config, self.config_path)
        except Exception as exc:  # noqa: BLE001 - the saved list is a convenience
            LOGGER.warning("Could not refresh the saved admin list: %s", exc)

    def record_probe(self, error: str | None) -> None:
        """Stores a database check's outcome and logs it only when it CHANGES,
        so a database that stays down writes one line, not one a minute."""
        previous = self.state.snapshot()
        if error is not None and error != previous.get("database_error"):
            LOGGER.warning("Database unreachable: %s", error)
        elif error is None and previous.get("database_reachable") is False:
            LOGGER.info("Database reachable again.")
        self.state.update(
            database_reachable=error is None,
            database_checked_at=_now_iso(),
            database_error=error,
        )

    def request_restart(self) -> None:
        self._restart_event.set()

    def request_shutdown(self) -> None:
        self._shutdown.set()
        self._restart_event.set()

    @staticmethod
    def _shared_stop_file() -> Path | None:
        program_data = os.environ.get("ProgramData")
        if not program_data:
            return None
        return Path(program_data, "LWCAM", "lwip.stop")

    def _consume_shared_stop_file(self) -> bool:
        target = self._shared_stop_file()
        if target is None or not target.is_file():
            return False
        try:
            target.unlink(missing_ok=True)
        except OSError:
            return False
        return True

    def run(self) -> int:
        backend_dir = Path(__file__).resolve().parents[1]
        while True:
            if self._shutdown.is_set():
                self.state.update(state="stopped")
                return 0
            if self._consume_shared_stop_file():
                self.state.update(state="stopped")
                return 0

            config, config_error = try_load_config(self.config_path)
            self.state.update(config_error=config_error)
            if config_error:
                LOGGER.error("Configuration problem: %s", config_error)
            command = self._child_command_factory(self.config_path)
            proc = subprocess.Popen(command, cwd=str(backend_dir))
            self.state.update(
                state="running", since=_now_iso(), pid=proc.pid, last_exit_code=None
            )

            restart_requested = False
            child_started_at = time.time()
            child_started_mono = time.monotonic()
            last_stall_check = time.monotonic()
            # Probe at once, not after the first interval: until a probe runs,
            # database_reachable reads False, and "unreachable" is what grants
            # the no-login local fallback and remote read-only view.
            last_probe_at = float("-inf")
            while proc.poll() is None:
                if self._restart_event.is_set():
                    self._restart_event.clear()
                    restart_requested = True
                    self._graceful_stop(proc, config)
                    break
                now = time.monotonic()
                if config is not None and now - last_probe_at >= self.db_probe_interval_seconds:
                    last_probe_at = now
                    probe_error = probe_db(config)
                    self.record_probe(probe_error)
                    if probe_error is None:
                        self.refresh_admin_cache_if_due(config, now=now)
                        self.send_heartbeat(config)
                if config is not None and now - last_stall_check >= self.STALL_CHECK_SECONDS:
                    last_stall_check = now
                    if self.worker_stalled(config, child_started_at):
                        LOGGER.error("The worker has made no progress for %d s; restarting it", self.STALL_SECONDS)
                        self._stall_error = "worker stalled"
                        restart_requested = True
                        self._graceful_stop(proc, config)
                        break
                    if self._stall_error and now - child_started_mono > 300:
                        self._stall_error = None  # a worker has run 5 minutes since
                time.sleep(self.poll_interval)

            exit_code = proc.poll()
            if exit_code is None:
                exit_code = proc.wait()

            if restart_requested:
                if self._shutdown.is_set():
                    self.state.update(state="stopped", last_exit_code=exit_code)
                    return 0
                self.state.update(state="restarting", last_exit_code=exit_code)
                continue

            if exit_code == 0:
                self.state.update(state="stopped", last_exit_code=0)
                return 0

            self.state.update(
                state="crashed", last_exit_code=exit_code, last_error=self._tail_service_log()
            )
            if self._consume_shared_stop_file():
                self.state.update(state="stopped")
                return 0
            self._interruptible_sleep(self.backoff_seconds)

    def _graceful_stop(self, proc: subprocess.Popen, config: ToolConfig | None) -> None:
        if config is not None:
            stop_path = config.work_root / FolderOrchestrator.STOP_FILE_NAME
        else:
            stop_path = _lenient_work_root(self.config_path) / FolderOrchestrator.STOP_FILE_NAME
        try:
            stop_path.parent.mkdir(parents=True, exist_ok=True)
            stop_path.write_text("", encoding="utf-8")
        except OSError as exc:
            LOGGER.warning("Could not write the restart stop file %s: %s", stop_path, exc)
        deadline = time.monotonic() + self.restart_wait_seconds
        while proc.poll() is None and time.monotonic() < deadline:
            time.sleep(min(self.poll_interval, max(0.0, deadline - time.monotonic())))
        if proc.poll() is None:
            proc.kill()
            proc.wait()

    def _interruptible_sleep(self, seconds: float) -> None:
        deadline = time.monotonic() + seconds
        while (
            not self._restart_event.is_set()
            and not self._shutdown.is_set()
            and time.monotonic() < deadline
        ):
            time.sleep(min(0.2, max(0.0, deadline - time.monotonic())))

    def _tail_service_log(self, lines: int = 20) -> str | None:
        # service.log is what START_LWIP.bat redirects this whole process's
        # (and so the child's, since stdio is inherited) stdout/stderr into -
        # see the module docstring and the installer contract. Its path is
        # not itself configurable; it lives beside the config's grandparent,
        # matching START_LWIP.bat's own %ROOT%\logs\service.log.
        log_path = self.config_path.parent.parent / "logs" / "service.log"
        tail = read_log_tail(log_path, lines)
        return "\n".join(tail) if tail else None


# --------------------------------------------------------------------------
# HTTP layer.
# --------------------------------------------------------------------------


@dataclass
class ServiceContext:
    config_path: Path
    supervisor: Supervisor
    sessions: SessionStore = field(default_factory=SessionStore)
    rate_limiter: RateLimiter = field(default_factory=RateLimiter)
    db_lookup: Callable[[ToolConfig, str], dict | None] = lookup_user
    web_dir: Path = field(default_factory=lambda: Path(__file__).resolve().parent / "web")


class ConsoleServer(ThreadingHTTPServer):
    def handle_error(self, request, client_address) -> None:  # noqa: A003
        """A dropped or garbled connection (TLS scanner, closed browser tab,
        timeout) is one log line, not a traceback."""
        exc = sys.exc_info()[1]
        if isinstance(exc, OSError):  # ssl.SSLError, ConnectionError and TimeoutError are all OSErrors
            LOGGER.info("Connection from %s dropped: %s: %s", client_address[0], type(exc).__name__, exc)
            return
        super().handle_error(request, client_address)


def build_handler(ctx: ServiceContext) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "LwipConsole/1"
        # A client that connects and says nothing (or stalls mid-handshake)
        # frees its thread after this long instead of holding it for ever.
        timeout = 30

        def log_message(self, format: str, *args: object) -> None:  # noqa: A002
            # Method + path + status only - never headers or a body, so a
            # password typed into /api/login can never reach this log.
            # A request that fails to parse (plain bytes, or https:// sent to
            # this http port) is logged before `path` is ever set - log_error
            # below has already written the one line it deserves.
            if not hasattr(self, "path"):
                return
            status = args[1] if len(args) > 1 else ""
            LOGGER.info("%s %s %s", self.command, self.path, status)

        def log_error(self, format: str, *args: object) -> None:  # noqa: A002
            if not hasattr(self, "path"):
                LOGGER.warning(
                    "Unreadable request from %s (was it opened with https:// "
                    "instead of http://?)",
                    self.client_address[0],
                )
                return
            self.log_message(format, *args)

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
            cookie_header = self.headers.get("Cookie")
            if not cookie_header:
                return None
            jar = SimpleCookie()
            try:
                jar.load(cookie_header)
            except Exception:
                return None
            morsel = jar.get(SESSION_COOKIE_NAME)
            if morsel is None:
                return None
            return ctx.sessions.username_for(morsel.value)

        def _revalidate(self, token: str, username: str) -> str | None:
            """A signed-in session is checked against the database at most once a
            minute: an account disabled or demoted meanwhile is signed out.
            An unreachable database keeps the session (the probe notices it)."""
            config, _config_error = try_load_config(ctx.config_path)
            if config is None:
                return username
            try:
                record = ctx.db_lookup(config, username)
            except DbUnavailable:
                return username
            if (
                record is None
                or not record.get("active")
                or record.get("is_deleted")
                or not role_set(record.get("roles", "")) & ADMIN_ROLES
            ):
                LOGGER.info("Signing out %s: the account is no longer an active admin.", username)
                ctx.sessions.remove(token)
                return None
            return username

        def _access(self) -> tuple[str, bool, str | None]:
            username = self._session_username()
            db_reachable = ctx.supervisor.state.snapshot().get("database_reachable") is not False
            token = self._cookie_token()
            if username is not None and db_reachable and token and ctx.sessions.due_for_check(token):
                username = self._revalidate(token, username)
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
            elif parsed.path == "/api/restart":
                self._post_restart()
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
            snap = ctx.supervisor.state.snapshot()
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
                    "db_reachable": bool(snap.get("database_reachable")),
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

            config, _config_error = try_load_config(ctx.config_path)
            if config is None:
                self._send_json(503, {"error": "Database settings are not available."})
                return

            from_cache = False
            try:
                record = ctx.db_lookup(config, username)
            except DbUnavailable as exc:
                ctx.supervisor.state.update(
                    database_reachable=False,
                    database_checked_at=_now_iso(),
                    database_error=" ".join(str(exc).split()) or "Database is unreachable.",
                )
                record = cached_admin_record(ctx.config_path, username)
                from_cache = True
            else:
                ctx.supervisor.state.update(
                    database_reachable=True, database_checked_at=_now_iso(), database_error=None
                )

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
            snap = ctx.supervisor.state.snapshot()
            config, config_error = try_load_config(ctx.config_path)
            status_doc = None
            state_doc = None
            if config is not None:
                status_doc = _read_json_file(config.state_file.parent / "status.json")
                state_doc = _read_json_file(config.state_file)
            summary = summarize_state(status_doc, state_doc, today=date.today())
            self._send_json(
                200,
                {
                    "service": {
                        "state": snap.get("state"),
                        "since": snap.get("since"),
                        "last_exit_code": snap.get("last_exit_code"),
                        "last_error": snap.get("last_error"),
                    },
                    "database": {
                        "reachable": bool(snap.get("database_reachable")),
                        "checked_at": snap.get("database_checked_at"),
                        "error": snap.get("database_error"),
                        "last_report_at": summary["last_report_at"],
                    },
                    "queue": summary["queue"],
                    "config_error": config_error,
                    "schema_problem": snap.get("schema_problem"),
                    "version": getattr(ctx.supervisor, "version", "dev"),
                },
            )

        def _get_log(self, query: dict) -> None:
            access, _local_fallback, _username = self._access()
            if access not in ("full", "view"):
                self._send_json(401, self._sign_in_required())
                return
            try:
                requested = int(query.get("lines", ["50"])[0])
            except (TypeError, ValueError):
                requested = 50
            requested = max(1, min(500, requested))
            config, _config_error = try_load_config(ctx.config_path)
            if config is None:
                self._send_json(200, {"lines": []})
                return
            self._send_json(200, {"lines": read_log_tail(config.log_file, requested)})

        def _get_settings(self) -> None:
            access, _local_fallback, _username = self._access()
            if not self._require_full_access(access):
                return
            self._send_json(200, read_settings_view(ctx.config_path))

        def _post_settings(self) -> None:
            access, _local_fallback, _username = self._access()
            if not self._require_full_access(access):
                return
            body = self._read_json_body()
            if body is None:
                return
            status, payload = apply_settings_update(ctx.config_path, body)
            self._send_json(status, payload)
            if status == 200:
                ctx.supervisor.request_restart()

        def _network_logins(self, action: str) -> None:
            access, _local_fallback, _username = self._access()
            if not self._require_full_access(access):
                return
            body = self._read_json_body() if self.command == "POST" else {}
            if body is None:
                return
            view = read_settings_view(ctx.config_path)
            paths = [view.get("input_root") or "", view.get("output_root") or ""]
            self._send_json(*netlogin.console_request(action, body, paths))

        def _post_restart(self) -> None:
            access, _local_fallback, _username = self._access()
            if not self._require_full_access(access):
                return
            ctx.supervisor.request_restart()
            self._send_json(200, {"restarting": True})

    return Handler


def protect_stored_password(config_path: Path) -> bool:
    """Start-up migration: a plain db_password in the config is rewritten
    protected. Logs one line, never the value."""
    try:
        changed = lwcam_secrets.protect_file(config_path, ("db_password",))
    except Exception as exc:  # noqa: BLE001 - run with the plain file rather than not at all
        LOGGER.error("Could not protect the stored password: %s", type(exc).__name__)
        return False
    if changed:
        LOGGER.info("Protected the stored password in %s", config_path)
    return changed


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Supervise the deskew/crop worker and serve its console."
    )
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG_PATH)
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    # Before the worker starts, so a network input folder is signed in to by
    # the time it first looks.
    netlogin.start_keeper()
    protect_stored_password(args.config)
    supervisor = Supervisor(args.config)
    port, bind = read_ui_settings(args.config)
    ctx = ServiceContext(config_path=args.config, supervisor=supervisor)
    # A console that cannot bind (port taken, bad ui_bind) must not take image
    # processing down with it: log it and supervise the worker anyway.
    try:
        httpd = ConsoleServer((bind, port), build_handler(ctx))
        tls.wrap_if_configured(httpd, args.config)
    except OSError as exc:
        LOGGER.error("LWIP console could not listen on %s:%s: %s", bind, port, exc)
        return supervisor.run()
    http_thread = threading.Thread(
        target=httpd.serve_forever, name="lwip-console-http", daemon=True
    )
    http_thread.start()
    LOGGER.info("LWIP console listening on %s:%s", bind, port)
    try:
        return supervisor.run()
    finally:
        httpd.shutdown()


if __name__ == "__main__":
    # multiprocessing workers re-import this module on Windows (spawn start
    # method) - without this guard the console/supervisor would try to start
    # a second time inside every worker process.
    raise SystemExit(main())

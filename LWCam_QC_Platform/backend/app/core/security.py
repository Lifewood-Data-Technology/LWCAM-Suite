"""Passwords, JWT access tokens and the one-live-sign-in-per-account rule.

QC Platform stage. Password hashes are bcrypt in the same format LWCAM and
LWCam Admin write, because `users.password` is shared. Sign-in state (current
session per account, revoked sessions) is kept IN MEMORY in this process, so
it is lost on restart; see the ponytail notes below for the limits. The
dependencies in app/dependencies.py call the is_* helpers here on every request.
"""
import secrets
import threading
import time
from datetime import datetime, timedelta, timezone
from typing import Any

import bcrypt
import jwt

from app.core.errors import ApiCodes, BusinessError
from app.core.config import settings


# `users.password` is shared with LWCAM and LWCamAdmin (Dart `bcrypt` package,
# PasswordHasher.hash → BCrypt.gensalt() defaults). Match its prefix and cost so
# hashes written here are indistinguishable from theirs in either direction.
_BCRYPT_PREFIX = b"2a"
_BCRYPT_ROUNDS = 10

# bcrypt ignores everything past 72 bytes. Truncate explicitly rather than let
# the library decide — a silent change in that behaviour would invalidate every
# stored hash for long passwords.
_BCRYPT_MAX_BYTES = 72


def _encode(password: str) -> bytes:
    return password.encode("utf-8")[:_BCRYPT_MAX_BYTES]


def hash_password(password: str) -> str:
    salt = bcrypt.gensalt(rounds=_BCRYPT_ROUNDS, prefix=_BCRYPT_PREFIX)
    return bcrypt.hashpw(_encode(password), salt).decode("ascii")


def verify_password(password: str, password_hash: str | None) -> bool:
    if not password_hash:
        return False
    try:
        return bcrypt.checkpw(_encode(password), password_hash.strip().encode("utf-8"))
    except ValueError:
        # Not a bcrypt hash (e.g. a leftover MD5 row from before this change).
        # Fail the check instead of raising — a corrupt row must not 500 login.
        return False


# Checked against when the username does not exist (or has no hash), so an
# unknown user costs the same bcrypt time as a wrong password and response
# timing does not reveal which usernames exist.
DUMMY_PASSWORD_HASH = hash_password("timing-equaliser-not-a-real-password")


# One live sign-in per account: the FIRST wins, and a second sign-in is refused
# while it is in use. Each token carries a session id ("sid"); this map holds
# each account's current one and when it last made a request.
#
# "In use" is the part that matters: a token is stateless, so a browser closed
# without signing out looks exactly like one left open. The console checks in
# every minute while it is open (main.ts), so a session silent for
# SESSION_IDLE_SECONDS is treated as gone and a new sign-in takes over - a
# closed browser frees the account in minutes, not when its token expires
# hours later. Signing out (POST /auth/logout) frees it at once.
# ponytail: in memory, one process (run_server.py starts one). After a restart
# the map is empty and the first token seen per account is adopted. A second
# process or worker needs this in the database instead.
SESSION_IDLE_SECONDS = 180.0
_current_session: dict[int, tuple[str | None, float]] = {}
_session_lock = threading.Lock()

# Signed-out (or admin-ended) session ids, with the wall-clock time after which
# the token would have expired anyway and the entry can be forgotten. Without
# it, a logout deleted the account's entry and is_current_session then ADOPTED
# any valid token - so a copied old token worked again until it expired.
# ponytail: in memory like the map above; a restart clears it, so a token
# revoked before a restart is adopted again (it still expires on its own within
# jwt_expire_minutes). Move both to the database if that ever matters.
_revoked_sessions: dict[str, float] = {}

# Per account: tokens issued at or before this moment (epoch seconds, matched
# against the token's `iat`) are dead. An admin reset/disable/role change sets
# it, so it also kills tokens that were no longer the "current" session -
# revoking only the current sid left every older one alive.
# ponytail: in memory like the maps above; a restart forgets it.
_sessions_invalid_before: dict[int, float] = {}

# Revoked because another sign-in took over (not a sign-out): the console shows
# "signed in elsewhere" for these rather than "you were signed out".
_displaced_sessions: set[str] = set()

ALREADY_SIGNED_IN_KEY = "auth.alreadySignedIn"
SIGNED_IN_ELSEWHERE_KEY = "auth.signedInElsewhere"


def create_access_token(
    user_id: int, username: str, role: str, *, current_session_id: str | None = None
) -> str:
    """Refuses (409) while another browser holds this account and is in use.
    `current_session_id` is the signing-in browser's own token, if it still
    has one: a browser is never blocked by itself."""
    now = datetime.now(timezone.utc)
    session_id = secrets.token_urlsafe(16)
    moment = time.monotonic()
    with _session_lock:
        current = _current_session.get(user_id)
        if (
            current is not None
            and current[0] != current_session_id
            and moment - current[1] < SESSION_IDLE_SECONDS
        ):
            raise BusinessError(
                ApiCodes.CONFLICT,
                "This account is already signed in on another browser or PC. Sign out there "
                "first; a browser closed without signing out frees the account after 3 minutes.",
                409,
                data={"errorKey": ALREADY_SIGNED_IN_KEY},
            )
        if current is not None:
            # Taken over (idle): the displaced token must not revive later,
            # once the new one signs out or an admin resets the account.
            _revoke_locked(current[0])
            if current[0]:
                _displaced_sessions.add(current[0])
        _current_session[user_id] = (session_id, moment)
    payload: dict[str, Any] = {
        "sub": str(user_id),
        "username": username,
        "role": role,
        "sid": session_id,
        "iat": now.timestamp(),  # float: compared with _sessions_invalid_before
        "exp": now + timedelta(minutes=settings.jwt_expire_minutes),
    }
    return jwt.encode(payload, settings.jwt_secret.get_secret_value(), algorithm=settings.jwt_algorithm)


def is_current_session(user_id: int, session_id: str | None) -> bool:
    """Whether this token is its account's live sign-in, and marks it in use.
    With nothing recorded (after a restart, or a token from before this check)
    the token is adopted."""
    moment = time.monotonic()
    with _session_lock:
        if _is_revoked_locked(session_id):
            return False
        current = _current_session.get(user_id)
        if current is None or current[0] == session_id:
            _current_session[user_id] = (session_id, moment)
            return True
        return False


def _is_revoked_locked(session_id: str | None) -> bool:
    """Caller holds `_session_lock`. Also forgets revocations past their expiry."""
    wall = time.time()
    for sid in [s for s, until in _revoked_sessions.items() if until <= wall]:
        del _revoked_sessions[sid]
        _displaced_sessions.discard(sid)
    return session_id is not None and session_id in _revoked_sessions


def is_revoked(session_id: str | None) -> bool:
    with _session_lock:
        return _is_revoked_locked(session_id)


def was_displaced(session_id: str | None) -> bool:
    with _session_lock:
        return session_id in _displaced_sessions


def _revoke_locked(session_id: str | None) -> None:
    if session_id:
        _revoked_sessions[session_id] = time.time() + settings.jwt_expire_minutes * 60 + 60


def end_session(user_id: int, session_id: str | None) -> None:
    """Sign-out: frees the account at once (only if this is its own session)
    and revokes the token, so it cannot be used again."""
    with _session_lock:
        _revoke_locked(session_id)
        current = _current_session.get(user_id)
        if current is not None and current[0] == session_id:
            del _current_session[user_id]


def end_user_sessions(user_id: int) -> None:
    """An admin reset, role change, disable or delete: ends whatever this
    account has live right now."""
    with _session_lock:
        _sessions_invalid_before[user_id] = time.time()
        current = _current_session.pop(user_id, None)
        if current is not None:
            _revoke_locked(current[0])


def issued_before_reset(user_id: int, issued_at: float | None) -> bool:
    """Whether this token predates its account's last reset/disable."""
    with _session_lock:
        cutoff = _sessions_invalid_before.get(user_id)
    return cutoff is not None and (issued_at is None or float(issued_at) <= cutoff)


def decode_access_token(token: str) -> dict[str, Any]:
    try:
        return jwt.decode(token, settings.jwt_secret.get_secret_value(), algorithms=[settings.jwt_algorithm])
    except jwt.ExpiredSignatureError as exc:
        raise BusinessError(ApiCodes.UNAUTHORIZED, "Your session has expired.", 401) from exc
    except jwt.InvalidTokenError as exc:
        raise BusinessError(ApiCodes.UNAUTHORIZED, "Invalid login credentials.", 401) from exc


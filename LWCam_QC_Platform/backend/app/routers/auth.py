import threading
import time
from datetime import datetime, timezone

from fastapi import APIRouter, Request
from sqlalchemy import select

from app.core.errors import ApiCodes, BusinessError
from app.core.responses import ApiResponse, ok
from app.core.security import create_access_token, hash_password, verify_password
from app.dependencies import CurrentUser, DbSession
from app.models.user import User

from app.schemas.auth import AuthResponse, ChangePasswordRequest, LoginRequest, UserVO
from app.services.serializers import to_user_vo

router = APIRouter(prefix="/auth", tags=["auth"])


# --- Login rate limiting -----------------------------------------------------
# /login is now reachable from the whole office LAN, not just this PC's own
# loopback, and bcrypt verification (app/core/security.py, cost factor 10) is
# the one deliberately expensive thing an UNAUTHENTICATED request can trigger
# here. That makes this endpoint both a credential-guessing target and a free
# CPU-exhaustion knob. A dict with a time window is proportionate for one
# server - slowapi/redis would be infrastructure for a problem a dozen lines
# already solve.
#
# Keyed by (client IP, username), not either alone: IP alone would let one
# noisy station lock out every operator behind the same office NAT hop;
# username alone would let an attacker anywhere lock a real operator out of
# their own account, which is a denial-of-service dressed up as a security
# feature. Cardinality is naturally bounded (a handful of station IPs times
# this server's own user list), so the dict is never explicitly pruned.
LOGIN_ATTEMPT_LIMIT = 5
LOGIN_ATTEMPT_WINDOW_SECONDS = 60.0

# A plain dict, deliberately NOT a defaultdict. Reading `d[key]` on a
# defaultdict CREATES the key, and the read below happens on every /login call
# before the username has been checked against anything - so a scanner posting
# a few thousand different usernames from one address would have grown this
# dict permanently, for the life of a process that is now a long-lived server
# rather than one operator's sidecar. Every access here is `.get`, and expired
# keys are dropped rather than left holding an empty list.
_login_failures: dict[tuple[str, str], list[float]] = {}

# FastAPI runs a `def` endpoint in its threadpool, so two logins really do touch
# this dict at once. Without the lock, _prune_expired's comprehension can raise
# "dictionary changed size during iteration" and its `del` can raise KeyError -
# either of which turns a login into a 500. One module lock, held only for the
# few dict operations below.
# ponytail: one global lock; per-key locks if a login ever becomes hot.
_login_lock = threading.Lock()


def _login_key(client_ip: str, username: str) -> tuple[str, str]:
    return (client_ip, username.strip().lower())


def _prune_expired(window_start: float) -> None:
    """Drop every key whose failures have all aged out of the window.

    Without this the dict only ever shrinks for a pair that later logs in
    successfully - so a key created by a wrong guess that is never retried
    would live forever. Called on the check path, which is the one call every
    login makes, so the sweep happens exactly as often as the growth does.

    Caller holds `_login_lock`.
    """
    for key in [k for k, times in _login_failures.items() if not any(t > window_start for t in times)]:
        _login_failures.pop(key, None)


def check_login_rate_limit(client_ip: str, username: str, *, now: float | None = None) -> None:
    """Raise if this IP+username pair has too many recent FAILED attempts.

    Pure check - does not record anything itself, so a caller can check
    before paying for bcrypt and separately record only on an actual bad
    password (see record_login_failure). `now` is an injection point for
    tests only; production calls always take the real clock.
    """
    moment = time.monotonic() if now is None else now
    key = _login_key(client_ip, username)
    window_start = moment - LOGIN_ATTEMPT_WINDOW_SECONDS
    with _login_lock:
        _prune_expired(window_start)
        attempts = [t for t in _login_failures.get(key, ()) if t > window_start]
        if attempts:
            _login_failures[key] = attempts
        else:
            _login_failures.pop(key, None)
    if len(attempts) >= LOGIN_ATTEMPT_LIMIT:
        raise BusinessError(
            ApiCodes.FORBIDDEN,
            "Too many failed login attempts for this account. Wait a minute and try again.",
            429,
        )


def record_login_failure(client_ip: str, username: str, *, now: float | None = None) -> None:
    """Count one failed attempt. Only call this for an actually WRONG password -
    an account that is merely disabled or role-less didn't fail a guess."""
    moment = time.monotonic() if now is None else now
    with _login_lock:
        _login_failures.setdefault(_login_key(client_ip, username), []).append(moment)


def reset_login_attempts(client_ip: str, username: str) -> None:
    """Clear the counter on a successful login - a legitimate operator who
    mistyped a password earlier in the window must not stay locked out."""
    with _login_lock:
        _login_failures.pop(_login_key(client_ip, username), None)


@router.post("/login", response_model=ApiResponse[AuthResponse])
def login(request: LoginRequest, http_request: Request, db: DbSession) -> ApiResponse[AuthResponse]:
    """Verify the credentials, record the login time and issue an access token."""
    client_ip = http_request.client.host if http_request.client else "unknown"
    username = request.username.strip()
    check_login_rate_limit(client_ip, username)

    user = db.scalar(select(User).where(User.user_id == username))
    if user is None or not verify_password(request.password, user.password):
        record_login_failure(client_ip, username)
        raise BusinessError(ApiCodes.UNAUTHORIZED, "Incorrect username or password.", 401)
    if user.status != "active":
        raise BusinessError(ApiCodes.FORBIDDEN, "This account is disabled. Contact an administrator.", 403)

    if user.role not in {"super_admin", "admin", "qc"}:
        raise BusinessError(ApiCodes.FORBIDDEN, "This account has no usable platform role.", 403)
    reset_login_attempts(client_ip, username)
    user.last_login_at = datetime.now(timezone.utc)
    db.commit()
    token = create_access_token(user.id, user.user_id, user.role)
    return ok(AuthResponse(token=token, user=to_user_vo(user)))


@router.get("/me", response_model=ApiResponse[UserVO])
def me(current_user: CurrentUser) -> ApiResponse[UserVO]:
    """Return the signed-in user's basic profile."""
    return ok(to_user_vo(current_user))


@router.put("/password", response_model=ApiResponse[UserVO])
def change_password(
    request: ChangePasswordRequest,
    current_user: CurrentUser,
    db: DbSession,
) -> ApiResponse[UserVO]:
    """Allow a logged-in user to replace the initial password."""
    if not verify_password(request.oldPassword, current_user.password):
        raise BusinessError(ApiCodes.UNAUTHORIZED, "Your current password is incorrect.", 401)
    if verify_password(request.newPassword, current_user.password):
        raise BusinessError(ApiCodes.BAD_REQUEST, "The new password must differ from the current one.")

    current_user.password = hash_password(request.newPassword)
    current_user.must_change_password = False
    db.commit()
    db.refresh(current_user)
    return ok(to_user_vo(current_user))

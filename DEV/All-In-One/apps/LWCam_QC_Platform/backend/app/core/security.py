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


def create_access_token(user_id: int, username: str, role: str) -> str:
    now = datetime.now(timezone.utc)
    payload: dict[str, Any] = {
        "sub": str(user_id),
        "username": username,
        "role": role,
        "iat": int(now.timestamp()),
        "exp": now + timedelta(minutes=settings.jwt_expire_minutes),
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)


def decode_access_token(token: str) -> dict[str, Any]:
    try:
        return jwt.decode(token, settings.jwt_secret, algorithms=[settings.jwt_algorithm])
    except jwt.ExpiredSignatureError as exc:
        raise BusinessError(ApiCodes.UNAUTHORIZED, "Your session has expired.", 401) from exc
    except jwt.InvalidTokenError as exc:
        raise BusinessError(ApiCodes.UNAUTHORIZED, "Invalid login credentials.", 401) from exc


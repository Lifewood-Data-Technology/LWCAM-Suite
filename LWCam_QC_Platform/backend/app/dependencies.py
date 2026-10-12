"""FastAPI dependencies: who is calling, and are they allowed.

Authentication checks the bearer token, then that the account is active, the
session is not revoked or displaced by a newer sign-in, and (for most routes)
that no password change is owed. Routers use the ready-made aliases at the
bottom: CurrentUser, AdminUser, QcUser, SuperAdminUser, DbSession.
"""
from typing import Annotated

from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from app.core.errors import ApiCodes, BusinessError
from app.core.security import SIGNED_IN_ELSEWHERE_KEY, decode_access_token, is_current_session, is_revoked, issued_before_reset, was_displaced
from app.db.session import get_db
from app.models.user import User

bearer_scheme = HTTPBearer(auto_error=False)
DbSession = Annotated[Session, Depends(get_db)]


def _signed_in_elsewhere() -> BusinessError:
    return BusinessError(
        ApiCodes.UNAUTHORIZED,
        "This account signed in on another browser or PC while this one was idle, "
        "so you were signed out here.",
        401,
        data={"errorKey": SIGNED_IN_ELSEWHERE_KEY},
    )


MUST_CHANGE_PASSWORD_KEY = "auth.mustChangePassword"


def _authenticate(
    db: DbSession,
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
) -> User:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise BusinessError(ApiCodes.UNAUTHORIZED, "Sign in first.", 401)

    payload = decode_access_token(credentials.credentials)
    user_id = payload.get("sub")
    if not user_id:
        raise BusinessError(ApiCodes.UNAUTHORIZED, "Invalid login credentials.", 401)

    user = db.get(User, int(user_id))
    if user is None:
        raise BusinessError(ApiCodes.UNAUTHORIZED, "The user does not exist.", 401)
    if user.status != "active":
        raise BusinessError(ApiCodes.FORBIDDEN, "This account is disabled. Contact an administrator.", 403)
    if is_revoked(payload.get("sid")) and was_displaced(payload.get("sid")):
        raise _signed_in_elsewhere()
    if is_revoked(payload.get("sid")) or issued_before_reset(user.id, payload.get("iat")):
        raise BusinessError(ApiCodes.UNAUTHORIZED, "You were signed out. Sign in again.", 401)
    if not is_current_session(user.id, payload.get("sid")):
        raise _signed_in_elsewhere()
    return user


def get_current_user_any_state(
    db: DbSession,
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
) -> User:
    """Signed in, whether or not a password change is still owed. Only
    /auth/me and /auth/password use this."""
    return _authenticate(db, credentials)


def get_current_user(
    db: DbSession,
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
) -> User:
    user = _authenticate(db, credentials)
    # Server-side, not just the console's redirect: a reset or new account must
    # not be usable through the API until its initial password is replaced.
    if getattr(user, "must_change_password", False):
        raise BusinessError(
            ApiCodes.FORBIDDEN,
            "You must change your password before using the platform.",
            403,
            data={"errorKey": MUST_CHANGE_PASSWORD_KEY},
        )
    return user


CurrentUser = Annotated[User, Depends(get_current_user)]
CurrentUserAnyState = Annotated[User, Depends(get_current_user_any_state)]


def require_roles(*roles: str):
    def dependency(current_user: CurrentUser) -> User:
        # Against role_set, not role: an account may hold several roles, and
        # `role` reports only the highest-precedence one. Checking that would
        # deny a 'qc,admin' user every QC endpoint, because admin outranks qc.
        if current_user.role_set.isdisjoint(roles):
            raise BusinessError(ApiCodes.FORBIDDEN, "You do not have permission to access this.", 403)
        return current_user

    return dependency


AdminUser = Annotated[User, Depends(require_roles("admin", "super_admin"))]
QcUser = Annotated[User, Depends(require_roles("qc"))]
# User management is SuperAdmin-only: a plain admin must get 403 even calling
# the API directly, not merely have the button hidden in the console.
SuperAdminUser = Annotated[User, Depends(require_roles("super_admin"))]


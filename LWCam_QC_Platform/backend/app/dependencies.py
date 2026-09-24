from typing import Annotated

from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from app.core.errors import ApiCodes, BusinessError
from app.core.security import decode_access_token
from app.db.session import get_db
from app.models.user import User

bearer_scheme = HTTPBearer(auto_error=False)
DbSession = Annotated[Session, Depends(get_db)]


def get_current_user(
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
    return user


CurrentUser = Annotated[User, Depends(get_current_user)]


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


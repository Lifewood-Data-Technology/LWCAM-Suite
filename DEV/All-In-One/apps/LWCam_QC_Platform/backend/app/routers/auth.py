from fastapi import APIRouter
from sqlalchemy import select

from app.core.errors import ApiCodes, BusinessError
from app.core.responses import ApiResponse, ok
from app.core.security import create_access_token, hash_password, verify_password
from app.dependencies import CurrentUser, DbSession
from app.models.user import User
from datetime import datetime, timezone

from app.schemas.auth import AuthResponse, ChangePasswordRequest, LoginRequest, UserVO
from app.services.serializers import to_user_vo

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/login", response_model=ApiResponse[AuthResponse])
def login(request: LoginRequest, db: DbSession) -> ApiResponse[AuthResponse]:
    """Verify the credentials, record the login time and issue an access token."""
    user = db.scalar(select(User).where(User.user_id == request.username.strip()))
    if user is None or not verify_password(request.password, user.password):
        raise BusinessError(ApiCodes.UNAUTHORIZED, "Incorrect username or password.", 401)
    if user.status != "active":
        raise BusinessError(ApiCodes.FORBIDDEN, "This account is disabled. Contact an administrator.", 403)

    if user.role not in {"super_admin", "admin", "qc"}:
        raise BusinessError(ApiCodes.FORBIDDEN, "This account has no usable platform role.", 403)
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

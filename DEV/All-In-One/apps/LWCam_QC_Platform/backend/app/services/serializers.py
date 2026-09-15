from app.models.user import User
from app.schemas.admin import UserAdminVO
from app.schemas.auth import UserVO


def user_home_path(role: str) -> str:
    if role in {"admin", "super_admin"}:
        return "/admin/stats"
    if role == "qc":
        return "/qc/tasks"
    return "/login"


def to_user_vo(user: User) -> UserVO:
    return UserVO(
        id=user.id,
        userId=user.user_id,
        role=user.role,
        roles=sorted(user.role_set),
        status=user.status,
        homePath=user_home_path(user.role),
        mustChangePassword=user.must_change_password,
    )


def to_user_admin_vo(user: User) -> UserAdminVO:
    projects = sorted(user.projects, key=lambda project: project.project_name.lower())
    return UserAdminVO(
        id=user.id,
        userId=user.user_id,
        role=user.role,
        status=user.status,
        projectIds=[project.id for project in projects],
        projectNames=[project.project_name for project in projects],
        createdAt=user.created_at,
        lastLoginAt=user.last_login_at,
        mustChangePassword=user.must_change_password,
    )

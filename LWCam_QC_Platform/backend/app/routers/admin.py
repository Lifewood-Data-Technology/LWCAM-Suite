"""Admin API under /admin: users, running reviews, dashboard stats, server settings.

Part of the QC Platform server (capture -> LWIP -> QC Platform -> Upload). The
console's Admin pages call this router. User management and project creation
are SuperAdmin only (SuperAdminUser); everything else needs an Admin
(AdminUser). A plain QC reviewer never reaches these endpoints.

Sections: user accounts, reviewing tasks and release, status and stats,
path validation, network folder logins, and saving server settings.

Ideas to know before editing:
- users.roles is a comma list shared with LWCAM, so role changes go through
  merge_roles and role filters run in Python on role_set, not in SQL.
- Settings are saved to config.txt (write_server_settings) and applied live
  to the running settings object; secrets are never sent back to the console.
- Path checks must report why a folder is unreachable (mapped drives, refused
  network logins) instead of a generic error; see check_directory.
"""
import logging
import os
import stat
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Query
from pydantic import SecretStr
from sqlalchemy import delete, func, or_, select
from sqlalchemy.orm import Session, lazyload, selectinload

from app.core import netlogin, runtime_settings
from app.core.config import Settings, settings
from app.core.errors import ApiCodes, BusinessError
from app.core.paths import fs_path, relocate_under
from app.core.responses import ApiResponse, PageResult, ok
from app.core.security import end_user_sessions, hash_password
from app.core.server_settings import CONTROL_CHARACTERS, write_server_settings
from app.dependencies import AdminUser, DbSession, SuperAdminUser
from app.models.capture import CaptureBox, CaptureFolder, CaptureImage
from app.models.project import Project, Role, UserProject
from app.models.user import ROLE_ADMIN, ROLE_QC, ROLE_SUPER_ADMIN, User, normalize_role
from app.schemas.admin import (
    AdminQcTaskVO,
    AiSettingVO,
    AiScannerSettingVO,
    CreateUserRequest,
    NetworkLoginRequest,
    PathCheckVO,
    PathSettingsVO,
    PathSettingVO,
    PathValidationVO,
    ProjectOptionVO,
    ResetPasswordRequest,
    StatsOverviewVO,
    UpdatePathSettingsRequest,
    UpdateServerSettingsRequest,
    UpdateUserRequest,
    UserAdminVO,
)
from app.services.ai_preanalysis import ai_preanalysis_scheduler
from app.services.ai_review import api_key_configured
from app.services.heartbeat import forget_host, system_status
from app.services.export import directory_write_error
from app.services.qc_drafts import discard_draft
from app.services.serializers import to_user_admin_vo

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/admin", tags=["admin"])
ALLOWED_ROLES = {"admin": ROLE_ADMIN, "qc": ROLE_QC}
# Normalized roles this platform grants and revokes. Anything else in
# `users.roles` belongs to another app in the suite — see merge_roles.
MANAGED_ROLES = {normalize_role(ROLE_ADMIN), normalize_role(ROLE_QC)}
ALLOWED_STATUSES = {"active", "disabled"}
FOLDER_STATUS_LABELS = {
    "pending": "pending",
    "reviewing": "reviewing",
    "pass": "passed",
    "rework": "rework",
}


# --- User account helpers -----------------------------------------------------
def now() -> datetime:
    return datetime.now(timezone.utc)


def user_or_404(db, user_id: int) -> User:
    """Load a user that is not soft-deleted, or raise 404."""
    user = db.scalar(select(User).options(selectinload(User.projects)).where(User.id == user_id))
    if user is None or user.is_deleted is True:
        raise BusinessError(ApiCodes.NOT_FOUND, "The user does not exist.", 404)
    return user


def canonical_role(role: str) -> str:
    """Map the console's role name (admin or qc) to the stored role; anything else is refused."""
    result = ALLOWED_ROLES.get(role.strip().lower())
    if result is None:
        raise BusinessError(ApiCodes.BAD_REQUEST, "Only administrator or QC accounts can be created.")
    return result


def active_projects(db, project_ids: list[int]) -> list[Project]:
    """Load the given projects; refuses the whole list if any is missing or deleted."""
    ids = list(dict.fromkeys(project_ids))
    if not ids:
        return []
    projects = db.scalars(
        select(Project).where(Project.id.in_(ids), Project.is_deleted.is_not(True))
    ).all()
    if len(projects) != len(ids):
        raise BusinessError(ApiCodes.BAD_REQUEST, "One or more projects do not exist or have been deleted.")
    return list(projects)


def merge_roles(existing: str | None, role: str) -> str:
    """Swap in `role`, keeping every token this platform does not own.

    `users.roles` is shared with LWCAM/LWCamAdmin, where an account is commonly
    'admin,capture'. Assigning the column outright would silently strip 'capture'
    (and any role a future module adds), locking that operator out of capture —
    so only the roles in MANAGED_ROLES are replaced.
    """
    kept = [
        token
        for token in (segment.strip() for segment in (existing or "").split(","))
        if token and normalize_role(token) not in MANAGED_ROLES
    ]
    return ",".join([role, *kept])


def apply_role_projects(user: User, role: str, status: str, projects: list[Project]) -> None:
    """Set the user's role and active flag; an active QC user must have at least one project."""
    if status not in ALLOWED_STATUSES:
        raise BusinessError(ApiCodes.BAD_REQUEST, "Unsupported user status.")
    if role == ROLE_QC and status == "active" and not projects:
        raise BusinessError(ApiCodes.BAD_REQUEST, "An active QC account must be assigned at least one project.")
    user.roles = merge_roles(user.roles, role)
    user.active = status == "active"


def role_id_for(db, role_name: str) -> int:
    """Database id of a role by name (case-insensitive), or a 400 if it does not exist."""
    role_id = db.scalar(select(Role.id).where(func.lower(Role.role_name) == role_name.lower()))
    if role_id is None:
        raise BusinessError(ApiCodes.BAD_REQUEST, f"Role {role_name} does not exist")
    return role_id


def replace_user_projects(db, user: User, role: str, projects: list[Project]) -> None:
    """Replace the user's project assignments. Only QC users get any; admins are not project-scoped."""
    db.execute(delete(UserProject).where(UserProject.user_id == user.id))
    if role != ROLE_QC:
        return
    role_id = role_id_for(db, ROLE_QC)
    db.add_all([
        UserProject(user_id=user.id, project_id=project.id, role_id=role_id)
        for project in projects
    ])


# --- Endpoints: user management (SuperAdmin only) -----------------------------
@router.get("/users", response_model=ApiResponse[PageResult[UserAdminVO]])
def list_users(
    _: SuperAdminUser,
    db: DbSession,
    page: int = Query(1, ge=1),
    size: int = Query(20, ge=1, le=200),
    keyword: str | None = None,
    role: str | None = None,
    status: str | None = None,
) -> ApiResponse[PageResult[UserAdminVO]]:
    """List accounts, filtered by name, role and status, one page at a time."""
    statement = select(User).options(selectinload(User.projects)).where(User.is_deleted.is_not(True))
    if keyword and keyword.strip():
        statement = statement.where(User.user_id.ilike(f"%{keyword.strip()}%"))
    if status:
        if status not in ALLOWED_STATUSES:
            raise BusinessError(ApiCodes.BAD_REQUEST, "Unsupported user status.")
        statement = statement.where(User.active.is_(status == "active"))

    wanted_role: str | None = None
    if role:
        role_value = role.strip().lower()
        database_role = ALLOWED_ROLES.get(role_value)
        if role_value == "super_admin":
            database_role = ROLE_SUPER_ADMIN
        if database_role is None:
            raise BusinessError(ApiCodes.BAD_REQUEST, "Unsupported user role.")
        wanted_role = normalize_role(database_role)

    # The role filter and the paging run in Python, on role_set, NOT as an
    # equality match on User.roles in SQL. users.roles is a comma-joined list
    # shared with LWCAM, where holding several ('qc,admin') is normal - the
    # same reason reviewer_workload filters this way. `== 'qc'` matched only
    # accounts holding that one role, so every multi-role account was missing
    # from the list a SuperAdmin manages them from, while still logging in and
    # working normally. Paging has to follow the filter for the count and the
    # window to agree. The users table is per-site and small, so reading it
    # whole costs nothing; revisit only if a site's user count ever grows.
    users = db.scalars(statement.order_by(User.created_at.desc())).unique().all()
    if wanted_role is not None:
        users = [user for user in users if wanted_role in user.role_set]
    offset = (page - 1) * size
    window = users[offset : offset + size]
    return ok(
        PageResult(
            records=[to_user_admin_vo(user) for user in window],
            total=len(users),
            page=page,
            size=size,
        )
    )


@router.post("/users", response_model=ApiResponse[UserAdminVO])
def create_user(request: CreateUserRequest, current_user: SuperAdminUser, db: DbSession) -> ApiResponse[UserAdminVO]:
    """Create an admin or QC account. The new user must change the password at first sign-in."""
    login_id = request.userId.strip()
    if db.scalar(select(User.id).where(User.user_id == login_id)) is not None:
        raise BusinessError(ApiCodes.CONFLICT, "This account already exists.", 409)
    role = canonical_role(request.role)
    projects = active_projects(db, request.projectIds)
    user = User(
        user_id=login_id,
        password=hash_password(request.password),
        roles=role,
        active=True,
        must_change_password=True,
        created_by=current_user.id,
        updated_by=current_user.id,
        is_deleted=False,
    )
    apply_role_projects(user, role, "active", projects)
    db.add(user)
    db.flush()
    replace_user_projects(db, user, role, projects)
    db.commit()
    db.expire(user, ["projects"])
    return ok(to_user_admin_vo(user_or_404(db, user.id)))


@router.put("/users/{user_id}", response_model=ApiResponse[UserAdminVO])
def update_user(
    user_id: int,
    request: UpdateUserRequest,
    current_user: SuperAdminUser,
    db: DbSession,
) -> ApiResponse[UserAdminVO]:
    """Change a user's role, status and projects, and end their sessions so it applies at once."""
    user = user_or_404(db, user_id)
    if user.id == current_user.id and request.status == "disabled":
        raise BusinessError(ApiCodes.BAD_REQUEST, "You cannot disable the account you are signed in with.")
    if user.role == "super_admin":
        raise BusinessError(ApiCodes.BAD_REQUEST, "SuperAdmin accounts cannot be modified here.")
    role = canonical_role(request.role)
    projects = active_projects(db, request.projectIds)
    apply_role_projects(user, role, request.status, projects)
    replace_user_projects(db, user, role, projects)
    user.updated_by = current_user.id
    db.commit()
    end_user_sessions(user.id)  # new role/status applies to a fresh sign-in
    db.expire(user, ["projects"])
    return ok(to_user_admin_vo(user_or_404(db, user.id)))


@router.delete("/users/{user_id}", response_model=ApiResponse[None])
def delete_user(user_id: int, current_user: SuperAdminUser, db: DbSession) -> ApiResponse[None]:
    """Soft-delete a user: the row stays, but the account is disabled and loses its projects."""
    if user_id == current_user.id:
        raise BusinessError(ApiCodes.BAD_REQUEST, "You cannot delete the account you are signed in with.")
    user = user_or_404(db, user_id)
    if user.role == "super_admin":
        raise BusinessError(ApiCodes.BAD_REQUEST, "SuperAdmin accounts cannot be deleted.")
    user.active = False
    user.is_deleted = True
    user.deleted_at = now()
    user.updated_by = current_user.id
    db.execute(delete(UserProject).where(UserProject.user_id == user.id))
    db.commit()
    end_user_sessions(user.id)
    return ok(None)


@router.put("/users/{user_id}/password", response_model=ApiResponse[None])
def reset_password(
    user_id: int,
    request: ResetPasswordRequest,
    current_user: SuperAdminUser,
    db: DbSession,
) -> ApiResponse[None]:
    """Set a new password for a user, who must change it at next sign-in."""
    user = user_or_404(db, user_id)
    user.password = hash_password(request.newPassword)
    user.must_change_password = True
    user.updated_by = current_user.id
    db.commit()
    end_user_sessions(user.id)
    return ok(None)


@router.get("/projects/options", response_model=ApiResponse[list[ProjectOptionVO]])
def project_options(_: AdminUser, db: DbSession) -> ApiResponse[list[ProjectOptionVO]]:
    """Projects that can be assigned to a QC user (for the user form's dropdown)."""
    projects = db.scalars(
        select(Project).where(Project.is_deleted.is_not(True)).order_by(Project.project_name.asc())
    ).all()
    return ok([
        ProjectOptionVO(id=project.id, projectId=project.project_id, projectName=project.project_name)
        for project in projects
    ])


# --- Endpoints: folders under review, system status, dashboard stats ----------
@router.get("/qc-tasks", response_model=ApiResponse[PageResult[AdminQcTaskVO]])
def list_reviewing_qc_tasks(
    _: AdminUser,
    db: DbSession,
    page: int = Query(1, ge=1),
    size: int = Query(20, ge=1, le=200),
    keyword: str | None = None,
    project_id: int | None = Query(default=None, alias="projectId"),
) -> ApiResponse[PageResult[AdminQcTaskVO]]:
    """List folders a reviewer currently has claimed (pending and locked), oldest claim first."""
    conditions = [
        func.lower(CaptureFolder.qc_status) == "pending",
        CaptureFolder.qc_locked_by.is_not(None),
        CaptureFolder.is_deleted.is_not(True),
        CaptureBox.is_deleted.is_not(True),
    ]
    if keyword and keyword.strip():
        pattern = f"%{keyword.strip()}%"
        conditions.append(or_(
            CaptureFolder.folder_name.ilike(pattern),
            CaptureBox.box_name.ilike(pattern),
            CaptureFolder.qc_locked_by.ilike(pattern),
            Project.project_name.ilike(pattern),
            Project.project_id.ilike(pattern),
        ))
    if project_id is not None:
        conditions.append(CaptureBox.project_id == project_id)

    image_count = (
        select(func.count(CaptureImage.id))
        .where(CaptureImage.folder_id == CaptureFolder.id)
        .correlate(CaptureFolder)
        .scalar_subquery()
    )
    statement = (
        select(CaptureFolder, CaptureBox, Project, image_count.label("image_count"))
        .join(CaptureBox, CaptureBox.box_id == CaptureFolder.box_id)
        .outerjoin(Project, Project.id == CaptureBox.project_id)
        .where(*conditions)
    )
    total = db.scalar(
        select(func.count(CaptureFolder.id))
        .select_from(CaptureFolder)
        .join(CaptureBox, CaptureBox.box_id == CaptureFolder.box_id)
        .outerjoin(Project, Project.id == CaptureBox.project_id)
        .where(*conditions)
    ) or 0
    rows = db.execute(
        statement.order_by(CaptureFolder.qc_locked_at.asc().nullslast(), CaptureFolder.id.asc())
        .offset((page - 1) * size)
        .limit(size)
    ).all()

    records = []
    for folder, box, project, count in rows:
        reviewer_id = None
        if folder.qc_locked_by:
            reviewer_id = db.scalar(select(User.id).where(User.user_id == folder.qc_locked_by))
        records.append(AdminQcTaskVO(
            folderId=folder.id,
            folderName=folder.folder_name,
            folderSeq=folder.folder_seq,
            boxId=box.box_id,
            boxName=box.box_name,
            projectId=project.id if project else None,
            projectCode=project.project_id if project else None,
            projectName=project.project_name if project else None,
            reviewerId=reviewer_id,
            reviewerUserId=folder.qc_locked_by or "",
            imageCount=count or 0,
            claimedAt=folder.qc_locked_at,
            updatedAt=folder.updated_at,
        ))
    return ok(PageResult(records=records, total=total, page=page, size=size))


@router.post("/qc-tasks/{folder_id}/release", response_model=ApiResponse[None])
def admin_release_qc_task(
    folder_id: int,
    current_user: AdminUser,
    db: DbSession,
) -> ApiResponse[None]:
    """Take a claimed folder away from its reviewer so someone else can claim it."""
    folder = db.scalar(
        select(CaptureFolder)
        .options(lazyload("*"))
        .where(CaptureFolder.id == folder_id)
        .with_for_update()
    )
    if folder is None or folder.is_deleted is True:
        raise BusinessError(ApiCodes.NOT_FOUND, "The QC task does not exist.", 404)
    if folder.qc_status.lower() != "pending":
        raise BusinessError(ApiCodes.CONFLICT, "This task is no longer under review. Refresh the list.", 409)
    if folder.qc_locked_by is None:
        raise BusinessError(ApiCodes.CONFLICT, "This task has not been claimed. Refresh the list.", 409)

    released_user_id = folder.qc_locked_by
    folder.qc_locked_by = None
    folder.qc_locked_at = None
    folder.updated_at = now()
    db.commit()
    # Same as the reviewer's own release: a draft that outlives the claim is
    # re-adopted on the next claim, possibly over recaptured files.
    try:
        discard_draft(folder.id, released_user_id)
    except Exception:
        logger.exception("QC draft cleanup failed after admin release; folder=%s", folder_id)
    return ok(None)


def reviewer_workload(db: Session) -> list[dict[str, Any]]:
    """Per-QC-user PASS/REWORK counts, real rather than the old hardcoded 0/0/0.

    Grouped by capture_folders.qc_reviewed_by, the only column that can answer
    "who reviewed this folder" (see migration 004 and the model comment on
    qc_reviewed_by for why qc_locked_by, rework_logs.assigned_uid and the audit
    JSONL cannot). A folder decided before that column existed has
    qc_reviewed_by NULL and is excluded here, not guessed at.

    A standalone function, not inlined in the route, so it is testable by
    calling it directly with a mock db - the pattern this suite already uses
    (test_rework_guards.py) rather than a TestClient/fixture setup.
    """
    # Filtered in Python on role_set, NOT with an equality match on User.roles
    # in SQL. users.roles is a comma-joined list shared with LWCAM, where
    # holding several ('qc,admin') is normal - models/user.py says so, and
    # require_roles/QcUser already reads it that way, so such an account really
    # can claim and approve folders. An `== 'qc'` filter drops exactly those
    # people: their counts get aggregated below and then silently discarded for
    # want of a row here, which is the same undercount this function exists to
    # stop. The users table is per-site and small, so this costs nothing.
    qc_users = [
        (user.id, user.user_id)
        for user in db.execute(
            select(User).where(User.is_deleted.is_not(True)).order_by(User.user_id.asc())
        )
        .scalars()
        .all()
        if ROLE_QC in user.role_set
    ]

    counts = db.execute(
        select(
            CaptureFolder.qc_reviewed_by,
            func.lower(CaptureFolder.qc_status),
            func.count(CaptureFolder.id),
        )
        .where(
            CaptureFolder.is_deleted.is_not(True),
            CaptureFolder.qc_reviewed_by.is_not(None),
            func.lower(CaptureFolder.qc_status).in_(["pass", "rework"]),
        )
        .group_by(CaptureFolder.qc_reviewed_by, func.lower(CaptureFolder.qc_status))
    ).all()
    approved = {reviewer_id: count for reviewer_id, status, count in counts if status == "pass"}
    rejected = {reviewer_id: count for reviewer_id, status, count in counts if status == "rework"}

    return [
        {
            "reviewerId": user_id,
            "reviewerName": name,
            "total": approved.get(user_id, 0) + rejected.get(user_id, 0),
            "approved": approved.get(user_id, 0),
            "rejected": rejected.get(user_id, 0),
        }
        for user_id, name in qc_users
    ]


@router.get("/system-status", response_model=ApiResponse[dict[str, Any]])
def system_status_route(_: AdminUser, db: DbSession, all: int = 0) -> ApiResponse[dict[str, Any]]:
    """Health of every suite part, from the heartbeats each part writes to the database."""
    return ok(system_status(db, show_all=bool(all)))


@router.delete("/system-status/{part}/{host}", response_model=ApiResponse[dict])
def forget_pc_route(part: str, host: str, _: AdminUser, db: DbSession) -> ApiResponse[dict]:
    """Forget a PC that was retired: its row would otherwise sit there for a week."""
    if not forget_host(db, part, host):
        raise BusinessError(ApiCodes.NOT_FOUND, "That PC is not on the status page.", 404)
    return ok({})


@router.get("/stats/overview", response_model=ApiResponse[StatsOverviewVO])
def stats_overview(_: AdminUser, db: DbSession) -> ApiResponse[StatsOverviewVO]:
    """Dashboard numbers: today's counts, queue sizes, status split, 7-day trend and reviewer workload."""
    today_start = datetime.combine(date.today(), time.min, tzinfo=timezone.utc)
    tomorrow = today_start + timedelta(days=1)

    today_new = db.scalar(
        select(func.count()).select_from(CaptureFolder).where(
            CaptureFolder.is_deleted.is_not(True),
            CaptureFolder.source_created_at >= today_start,
            CaptureFolder.source_created_at < tomorrow,
        )
    ) or 0
    today_reviews = db.scalar(
        select(func.count()).select_from(CaptureFolder).where(
            CaptureFolder.is_deleted.is_not(True),
            func.lower(CaptureFolder.qc_status).in_(["pass", "rework"]),
            CaptureFolder.updated_at >= today_start,
            CaptureFolder.updated_at < tomorrow,
        )
    ) or 0
    today_passed = db.scalar(
        select(func.count()).select_from(CaptureFolder).where(
            CaptureFolder.is_deleted.is_not(True),
            func.lower(CaptureFolder.qc_status) == "pass",
            CaptureFolder.updated_at >= today_start,
            CaptureFolder.updated_at < tomorrow,
        )
    ) or 0
    total_users = db.scalar(select(func.count()).select_from(User).where(User.is_deleted.is_not(True))) or 0
    total_tasks = db.scalar(
        select(func.count()).select_from(CaptureFolder).where(CaptureFolder.is_deleted.is_not(True))
    ) or 0
    pending = db.scalar(
        select(func.count()).select_from(CaptureFolder).where(
            CaptureFolder.is_deleted.is_not(True),
            func.lower(CaptureFolder.qc_status) == "pending",
            CaptureFolder.qc_locked_by.is_(None),
            # Same gate as qc.visible_folder_conditions — a folder LWIP hasn't
            # finished has no image directory and cannot be claimed, so counting
            # it here would report more claimable work than the QC queue offers.
            CaptureFolder.folder_path.is_not(None),
        )
    ) or 0
    reviewing = db.scalar(
        select(func.count()).select_from(CaptureFolder).where(
            CaptureFolder.is_deleted.is_not(True),
            func.lower(CaptureFolder.qc_status) == "pending",
            CaptureFolder.qc_locked_by.is_not(None),
        )
    ) or 0

    distribution_rows = db.execute(
        select(func.lower(CaptureFolder.qc_status), func.count(CaptureFolder.id))
        .where(CaptureFolder.is_deleted.is_not(True), CaptureFolder.qc_status.is_not(None))
        .group_by(func.lower(CaptureFolder.qc_status))
    ).all()
    distribution = []
    for status, count in distribution_rows:
        adjusted_count = pending if status == "pending" else count
        distribution.append({
            "status": FOLDER_STATUS_LABELS.get(status, status),
            "label": status,
            "count": adjusted_count,
        })
    if reviewing:
        distribution.append({"status": "reviewing", "label": "reviewing", "count": reviewing})

    trend = []
    for offset in range(6, -1, -1):
        day = date.today() - timedelta(days=offset)
        start = datetime.combine(day, time.min, tzinfo=timezone.utc)
        end = start + timedelta(days=1)
        count = db.scalar(
            select(func.count()).select_from(CaptureFolder).where(
                CaptureFolder.is_deleted.is_not(True),
                func.lower(CaptureFolder.qc_status).in_(["pass", "rework"]),
                CaptureFolder.updated_at >= start,
                CaptureFolder.updated_at < end,
            )
        ) or 0
        trend.append({"date": day.isoformat(), "count": count})

    workload = reviewer_workload(db)

    return ok(StatsOverviewVO(
        todayNewTasks=today_new,
        todayCompletedTasks=today_reviews,
        todayQcPassRate=round(today_passed * 100 / today_reviews, 2) if today_reviews else 0.0,
        totalUsers=total_users,
        totalTasks=total_tasks,
        pendingClaimTasks=pending,
        taskTrend=trend,
        taskStatusDistribution=distribution,
        reviewerWorkload=workload,
    ))


# --- Settings: path checks, network logins, saving ----------------------------
def path_settings_vo() -> PathSettingsVO:
    """What this server is actually using, and where each value came from.

    Settings in config.txt are displayed here; the paths endpoint can also
    update the export paths and output switches live.
    """
    described = runtime_settings.describe()
    return PathSettingsVO(
        configuredBy="QC server config.txt",
        qcImagesRoot=PathSettingVO(
            value=settings.qc_images_root,
            source="console" if settings.qc_images_root else "default",
        ),
        luminanceEnabled=settings.luminance_enabled,
        exportTiffOutput=settings.export_tiff_output,
        exportZipOutput=settings.export_zip_output,
        exportAutoEnabled=settings.export_auto_enabled,
        ai=AiSettingVO(
            enabled=settings.ai_review_enabled,
            preanalysisEnabled=settings.ai_preanalysis_enabled,
            keyConfigured=api_key_configured(),
            extractModel=settings.openrouter_extract_model,
            compareModel=settings.openrouter_compare_model,
        ),
        aiScanner=AiScannerSettingVO(
            enabled=settings.ai_preanalysis_enabled,
            available=ai_preanalysis_scheduler.available(),
            running=ai_preanalysis_scheduler.is_running(),
            scanIntervalSeconds=settings.ai_preanalysis_scan_interval_seconds,
        ),
        **{key: PathSettingVO(**value) for key, value in described.items()},
    )


def unavailable_drive_message(value: str) -> str | None:
    """Why a drive letter this server cannot see is refused, or None.

    Almost always a mapped network drive: it belongs to one user's logon
    session, and the installed server runs as a Windows service, which never
    sees it. A UNC path (\\\\server\\share) has no drive letter and passes.
    """
    drive = os.path.splitdrive(value)[0]
    if len(drive) != 2 or os.path.isdir(drive + "\\"):
        return None
    return (
        f"Drive {drive} is not available to the QC server. It runs as a Windows service, "
        "which cannot see drive letters mapped by a logged-in user - enter the network "
        "path instead (\\\\server\\share\\...)."
    )


def directory_state(directory: Path) -> tuple[bool, OSError | None]:
    """Whether `directory` is a folder, or the error that stopped us finding out.

    Not `Path.is_dir()`: on Python 3.13 - the shipped runtime - it RAISES for a
    network error it does not recognise, such as a PC refusing the login
    (WinError 1326), where 3.14 answers False. One returned a 500 from Validate
    paths, the other would call a refused login "does not exist". Both are
    wrong; the admin needs the reason.
    """
    try:
        return stat.S_ISDIR(os.stat(fs_path(directory)).st_mode), None
    except OSError as error:
        winerror = getattr(error, "winerror", None)
        if winerror in (2, 3) or (
            winerror is None and isinstance(error, (FileNotFoundError, NotADirectoryError))
        ):
            return False, None
        return False, error


def unreachable_message(value: str, error: OSError) -> str:
    """Explain why a folder could not be reached, pointing at the network login when that is the likely cause."""
    reason = f"This folder could not be reached: {error.strerror or error}."
    host = netlogin.host_of(value)
    if host and getattr(error, "winerror", None) in (5, 86, 1326):
        # The installed server is a SYSTEM task: without a saved login it
        # signs in to another PC as this PC's computer account, which a PC
        # outside a domain refuses.
        saved = any(row["saved"] and row["host"].lower() == host.lower()
                    for row in netlogin.list_logins())
        reason += (
            f" The login saved for {host} has no permission on this folder." if saved else
            f" Add a login for {host} under Network folder logins below."
        )
    return reason


def check_directory(
    key: str, raw_value: str, *, require_writable: bool, must_exist: bool = False
) -> PathCheckVO:
    """Check one folder setting: reachable, existing and (if required) writable. Never creates the folder."""
    value = (raw_value or "").strip()
    if not value:
        return PathCheckVO(key=key, path="", exists=False, writable=False, message="Not set.")
    directory = Path(value).expanduser()
    drive_message = unavailable_drive_message(value)
    if drive_message:
        return PathCheckVO(key=key, path=str(directory), exists=False, writable=False, message=drive_message)
    # Sign in first with this PC's saved network login, if the folder is on a
    # PC that has one - a refused login is the answer, not a folder error.
    login_error = netlogin.connect_for_path(value)
    if login_error:
        return PathCheckVO(key=key, path=str(directory), exists=False, writable=False, message=login_error)
    exists, error = directory_state(directory)
    if error is not None:
        return PathCheckVO(
            key=key, path=str(directory), exists=False, writable=False,
            message=unreachable_message(value, error),
        )
    if not exists and (must_exist or not require_writable):
        # Never created here: a typo in a share name must be reported, not
        # made into a new empty folder QC then finds nothing in.
        return PathCheckVO(
            key=key, path=str(directory), exists=False, writable=False,
            message="This folder does not exist.",
        )
    if not require_writable:
        return PathCheckVO(key=key, path=str(directory), exists=True, writable=False, message=None)
    error = directory_write_error(directory)
    return PathCheckVO(
        key=key,
        path=str(directory),
        exists=directory_state(directory)[0],
        writable=error is None,
        message=None if error is None else f"This folder could not be written to: {error.strerror or error}.",
    )


def count_resolved_folders(
    db: Session, images_root: str = ""
) -> tuple[int, int]:
    """How many folders waiting for QC a candidate input root resolves to a real directory.

    This is the check that tells an admin whether a remap is actually correct,
    rather than merely well-formed. Only PENDING folders count - the ones a
    reviewer will open next, a reverted client rework included. Finished
    folders are left out: their batches are routinely archived after delivery,
    and counting them kept a "resolves 0 of N" warning up for good on a
    station whose every open folder resolved.
    """
    stored_paths = db.scalars(
        select(CaptureFolder.folder_path).where(
            func.upper(CaptureFolder.qc_status) == "PENDING",
            CaptureFolder.is_deleted.is_not(True),
            CaptureFolder.folder_path.is_not(None),
            CaptureFolder.folder_path != "",
        )
    ).all()
    resolved = 0
    for stored in stored_paths:
        try:
            # images_root wins when given, matching to_local's own precedence -
            # the count has to be computed the way the real lookup will do it,
            # or it reassures an admin about a mapping that then fails.
            candidate = relocate_under(str(stored), images_root)
            if candidate is None:
                candidate = Path(str(stored)).expanduser()
            if fs_path(candidate).is_dir():
                resolved += 1
        except OSError:
            # A malformed stored path is a miss, not a 500.
            continue
    return resolved, len(stored_paths)


def _same_or_inside(candidate: Path, root: Path) -> bool:
    # resolve() follows junctions and expands 8.3 short names, so an aliased
    # folder is still caught.
    try:
        a, b = candidate.resolve(), root.resolve()
    except OSError:
        return False
    return a == b or a.is_relative_to(b)


def validate_path_settings(db: Session, request: UpdatePathSettingsRequest) -> PathValidationVO:
    """Check the QC input root, work folder and output folder together, including that the work folder is separate."""
    checks = [
        check_directory("exportTempDir", request.exportTempDir, require_writable=True),
        check_directory("exportOutputDir", request.exportOutputDir, require_writable=True),
    ]
    # An unset path is not a failure — it just falls back to the configured value.
    ok_so_far = all(check.exists and check.writable for check in checks if check.path)
    images_root = (request.qcImagesRoot or "").strip()
    if images_root:
        # Writable, not just readable: approval writes qc_ops.json into each
        # capture folder, so a read-only share passes review and fails there.
        checks.append(check_directory("qcImagesRoot", images_root, require_writable=True, must_exist=True))
        ok_so_far = ok_so_far and checks[-1].exists and checks[-1].writable
    work_root = request.exportTempDir.strip()
    for other in (request.exportOutputDir.strip(), images_root):
        if work_root and other and (
            _same_or_inside(Path(work_root), Path(other)) or _same_or_inside(Path(other), Path(work_root))
        ):
            ok_so_far = False
            checks.append(PathCheckVO(
                key="exportTempDirSeparate",
                path=work_root,
                exists=True,
                writable=False,
                message="The temporary work folder must be a separate folder: not the QC input or "
                        "output root, not inside either, and not containing either.",
            ))
            break
    resolved, total = count_resolved_folders(db, images_root)
    return PathValidationVO(
        ok=ok_so_far,
        checks=checks,
        resolvedFolders=resolved,
        totalFolders=total,
    )


@router.get("/settings/paths", response_model=ApiResponse[PathSettingsVO])
def get_path_settings(_: AdminUser) -> ApiResponse[PathSettingsVO]:
    """Return the image and export paths in force, and where each one came from."""
    return ok(path_settings_vo())


@router.post("/settings/paths/validate", response_model=ApiResponse[PathValidationVO])
def check_path_settings(
    request: UpdatePathSettingsRequest,
    _: AdminUser,
    db: DbSession,
) -> ApiResponse[PathValidationVO]:
    """Probe candidate paths without saving them."""
    return ok(validate_path_settings(db, request))


def _server_folder_paths() -> list[str]:
    """The folders this server uses, so the logins list can show which PC each one lives on."""
    return [settings.qc_images_root, settings.export_temp_dir, settings.export_output_dir]


# Network folder logins: one list per PC, shared with LWIP and Upload on the
# same PC (app/core/netlogin.py says why). Passwords go in, never out.
@router.get("/settings/network-logins", response_model=ApiResponse[dict[str, Any]])
def list_network_logins(_: AdminUser) -> ApiResponse[dict[str, Any]]:
    return ok({"logins": netlogin.list_logins(_server_folder_paths())})


@router.post("/settings/network-logins/check", response_model=ApiResponse[dict[str, Any]])
def check_network_logins(_: AdminUser) -> ApiResponse[dict[str, Any]]:
    return ok({"logins": netlogin.check_all(_server_folder_paths())})


@router.post("/settings/network-logins", response_model=ApiResponse[dict[str, Any]])
def save_network_login(request: NetworkLoginRequest, _: AdminUser) -> ApiResponse[dict[str, Any]]:
    try:
        error = netlogin.save_login(request.host, request.username, request.password or None)
    except ValueError as exc:
        raise BusinessError(ApiCodes.BAD_REQUEST, str(exc)) from exc
    except OSError as exc:
        raise BusinessError(ApiCodes.BAD_REQUEST, f"The login could not be saved: {exc}") from exc
    return ok({"error": error})


@router.post("/settings/network-logins/remove", response_model=ApiResponse[dict[str, Any]])
def remove_network_login(request: NetworkLoginRequest, _: AdminUser) -> ApiResponse[dict[str, Any]]:
    try:
        netlogin.delete_login(request.host)
    except ValueError as exc:
        raise BusinessError(ApiCodes.BAD_REQUEST, str(exc)) from exc
    return ok({})


@router.put("/settings", response_model=ApiResponse[PathSettingsVO])
def update_server_settings(
    request: UpdateServerSettingsRequest,
    _: AdminUser,
    db: DbSession,
) -> ApiResponse[PathSettingsVO]:
    """Persist console-owned settings and apply them live.

    Export paths reuse validate_path_settings; omitted AI fields stay
    untouched so older consoles can still save the other settings.
    """
    export_temp_dir = request.exportTempDir.strip()
    export_output_dir = request.exportOutputDir.strip()
    images_root = request.qcImagesRoot.strip()
    # Path validation skips blank values, but exports require both roots.
    missing = [
        key
        for key, value in (("exportTempDir", export_temp_dir), ("exportOutputDir", export_output_dir))
        if not value
    ]
    if missing:
        raise BusinessError(
            ApiCodes.BAD_REQUEST,
            f"These export paths cannot be left blank: {', '.join(missing)}.",
        )
    validation = validate_path_settings(
        db,
        UpdatePathSettingsRequest(
            qcImagesRoot=images_root,
            exportTempDir=export_temp_dir,
            exportOutputDir=export_output_dir,
        ),
    )
    if not validation.ok:
        raise BusinessError(
            ApiCodes.BAD_REQUEST,
            "One or more export paths are invalid.",
            data=validation.model_dump(),
        )

    # Build the full set of values to save: the fixed ones first, then the
    # optional AI fields below.
    values = {
        "qc_images_root": images_root,
        "export_temp_dir": export_temp_dir,
        "export_output_dir": export_output_dir,
        "export_zip_output": request.exportZipOutput,
        "export_tiff_output": request.exportTiffOutput,
        "luminance_enabled": request.luminanceEnabled,
        # The sweep reads this on every tick, so the live assignment below
        # takes effect on the next pass without a restart.
        "export_auto_enabled": request.exportAutoEnabled,
    }
    optional_fields = {
        "aiReviewEnabled": "ai_review_enabled",
        "aiPreanalysisEnabled": "ai_preanalysis_enabled",
        "openrouterApiKey": "openrouter_api_key",
        "openrouterExtractModel": "openrouter_extract_model",
        "openrouterCompareModel": "openrouter_compare_model",
    }
    secret_fields = {"openrouter_api_key"}
    for request_field, setting_field in optional_fields.items():
        value = getattr(request, request_field)
        # Omitted = keep: an older console that has never heard of a field
        # must not wipe it.
        if value is None:
            continue
        if isinstance(value, str):
            value = value.strip()
            if not value:
                if setting_field in secret_fields:
                    # The console never receives a secret, so its box is
                    # empty unless someone typed a new one: blank = keep.
                    continue
                # Blank clears: the code default applies, live and after a
                # restart alike (the reader skips a blank line). For a model
                # name that is the default model, never an empty one.
                value = Settings.model_fields[setting_field].default
        if setting_field in secret_fields:
            value = SecretStr(value)
        values[setting_field] = value

    # Every value becomes one `key = value` line in config.txt. Refuse a line
    # break here, as a 400 naming the field, rather than let the writer's own
    # refusal surface as a 500. Never echo the value: it may be a secret.
    request_names = {**{"qc_images_root": "qcImagesRoot", "export_temp_dir": "exportTempDir",
                        "export_output_dir": "exportOutputDir"},
                     **{field: name for name, field in optional_fields.items()}}
    for setting_field, value in values.items():
        text = value.get_secret_value() if isinstance(value, SecretStr) else value
        if isinstance(text, str) and CONTROL_CHARACTERS.search(text):
            raise BusinessError(
                ApiCodes.BAD_REQUEST,
                f"{request_names.get(setting_field, setting_field)} contains a line break or control character.",
            )

    # Keep background sweeps on the saved values until validation succeeds.
    candidate = settings.model_copy(update=values)
    if candidate.ai_review_enabled and not (
        candidate.openrouter_api_key
        and candidate.openrouter_api_key.get_secret_value().strip()
    ):
        raise BusinessError(ApiCodes.BAD_REQUEST, "An OpenRouter API key is required for AI review.")

    write_server_settings(values)
    for field, value in values.items():
        setattr(settings, field, value)
    return ok(path_settings_vo())

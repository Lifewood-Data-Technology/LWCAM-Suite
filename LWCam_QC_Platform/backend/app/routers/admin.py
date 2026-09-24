import logging
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Query
from pydantic import SecretStr
from sqlalchemy import delete, func, or_, select
from sqlalchemy.orm import Session, lazyload, selectinload

from app.core import runtime_settings
from app.core.config import Settings, settings
from app.core.errors import ApiCodes, BusinessError
from app.core.paths import fs_path, relocate_under, resolve_with
from app.core.responses import ApiResponse, PageResult, ok
from app.core.security import hash_password
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
    PathCheckVO,
    PathSettingsVO,
    PathSettingVO,
    PathValidationVO,
    ProjectOptionVO,
    ResetPasswordRequest,
    StatsOverviewVO,
    UpdatePathSettingsRequest,
    UpdateServerSettingsRequest,
    UploadSettingVO,
    UpdateUserRequest,
    UserAdminVO,
)
from app.services.ai_preanalysis import ai_preanalysis_scheduler
from app.services.ai_review import api_key_configured
from app.services.export import ExportError, directory_write_error
from app.services.upload import (
    UploadError,
    _same_or_inside,
    parse_s3_path,
    upload_runtime_config,
)
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


def now() -> datetime:
    return datetime.now(timezone.utc)


def user_or_404(db, user_id: int) -> User:
    user = db.scalar(select(User).options(selectinload(User.projects)).where(User.id == user_id))
    if user is None or user.is_deleted is True:
        raise BusinessError(ApiCodes.NOT_FOUND, "The user does not exist.", 404)
    return user


def canonical_role(role: str) -> str:
    result = ALLOWED_ROLES.get(role.strip().lower())
    if result is None:
        raise BusinessError(ApiCodes.BAD_REQUEST, "Only administrator or QC accounts can be created.")
    return result


def active_projects(db, project_ids: list[int]) -> list[Project]:
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
    if status not in ALLOWED_STATUSES:
        raise BusinessError(ApiCodes.BAD_REQUEST, "Unsupported user status.")
    if role == ROLE_QC and status == "active" and not projects:
        raise BusinessError(ApiCodes.BAD_REQUEST, "An active QC account must be assigned at least one project.")
    user.roles = merge_roles(user.roles, role)
    user.active = status == "active"


def role_id_for(db, role_name: str) -> int:
    role_id = db.scalar(select(Role.id).where(func.lower(Role.role_name) == role_name.lower()))
    if role_id is None:
        raise BusinessError(ApiCodes.BAD_REQUEST, f"Role {role_name} does not exist")
    return role_id


def replace_user_projects(db, user: User, role: str, projects: list[Project]) -> None:
    db.execute(delete(UserProject).where(UserProject.user_id == user.id))
    if role != ROLE_QC:
        return
    role_id = role_id_for(db, ROLE_QC)
    db.add_all([
        UserProject(user_id=user.id, project_id=project.id, role_id=role_id)
        for project in projects
    ])


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
    db.expire(user, ["projects"])
    return ok(to_user_admin_vo(user_or_404(db, user.id)))


@router.delete("/users/{user_id}", response_model=ApiResponse[None])
def delete_user(user_id: int, current_user: SuperAdminUser, db: DbSession) -> ApiResponse[None]:
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
    return ok(None)


@router.put("/users/{user_id}/password", response_model=ApiResponse[None])
def reset_password(
    user_id: int,
    request: ResetPasswordRequest,
    current_user: SuperAdminUser,
    db: DbSession,
) -> ApiResponse[None]:
    user = user_or_404(db, user_id)
    user.password = hash_password(request.newPassword)
    user.must_change_password = True
    user.updated_by = current_user.id
    db.commit()
    return ok(None)


@router.get("/projects/options", response_model=ApiResponse[list[ProjectOptionVO]])
def project_options(_: AdminUser, db: DbSession) -> ApiResponse[list[ProjectOptionVO]]:
    projects = db.scalars(
        select(Project).where(Project.is_deleted.is_not(True)).order_by(Project.project_name.asc())
    ).all()
    return ok([
        ProjectOptionVO(id=project.id, projectId=project.project_id, projectName=project.project_name)
        for project in projects
    ])


@router.get("/qc-tasks", response_model=ApiResponse[PageResult[AdminQcTaskVO]])
def list_reviewing_qc_tasks(
    _: AdminUser,
    db: DbSession,
    page: int = Query(1, ge=1),
    size: int = Query(20, ge=1, le=200),
    keyword: str | None = None,
    project_id: int | None = Query(default=None, alias="projectId"),
) -> ApiResponse[PageResult[AdminQcTaskVO]]:
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


@router.get("/stats/overview", response_model=ApiResponse[StatsOverviewVO])
def stats_overview(_: AdminUser, db: DbSession) -> ApiResponse[StatsOverviewVO]:
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
        upload=UploadSettingVO(
            enabled=settings.upload_enabled,
            s3Path=settings.upload_s3_path,
            region=settings.upload_s3_region,
            accessKey=settings.upload_s3_access_key,
            secretKeyConfigured=bool(
                settings.upload_s3_secret_key
                and settings.upload_s3_secret_key.get_secret_value().strip()
            ),
            doneRoot=settings.upload_done_dir,
            summaryRoot=settings.upload_summary_dir,
        ),
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


def check_directory(key: str, raw_value: str, *, require_writable: bool) -> PathCheckVO:
    value = (raw_value or "").strip()
    if not value:
        return PathCheckVO(key=key, path="", exists=False, writable=False, message="Not set.")
    directory = Path(value).expanduser()
    if not require_writable:
        # The image root is only ever read, so demanding write access would reject a
        # perfectly good read-only share.
        exists = fs_path(directory).is_dir()
        return PathCheckVO(
            key=key,
            path=str(directory),
            exists=exists,
            writable=False,
            message=None if exists else "This folder does not exist.",
        )
    error = directory_write_error(directory)
    return PathCheckVO(
        key=key,
        path=str(directory),
        exists=fs_path(directory).is_dir(),
        writable=error is None,
        message=None if error is None else f"This folder could not be written to: {error.strerror or error}.",
    )


def count_resolved_folders(
    db: Session, stored_prefix: str, local_root: str, images_root: str = ""
) -> tuple[int, int]:
    """How many capture_folders rows a candidate mapping resolves to a real directory.

    This is the check that tells an admin whether a remap is actually correct,
    rather than merely well-formed.
    """
    stored_paths = db.scalars(
        select(CaptureFolder.folder_path).where(
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
                candidate = resolve_with(str(stored), stored_prefix, local_root)
            if fs_path(candidate).is_dir():
                resolved += 1
        except OSError:
            # A malformed stored path is a miss, not a 500.
            continue
    return resolved, len(stored_paths)


def validate_path_settings(db: Session, request: UpdatePathSettingsRequest) -> PathValidationVO:
    checks = [
        check_directory("captureImageLocalRoot", request.captureImageLocalRoot, require_writable=False),
        check_directory("exportTempDir", request.exportTempDir, require_writable=True),
        check_directory("exportOutputDir", request.exportOutputDir, require_writable=True),
    ]
    # An unset path is not a failure — it just falls back to the configured value.
    ok_so_far = all(
        check.exists and (check.writable or check.key == "captureImageLocalRoot")
        for check in checks
        if check.path
    )
    stored_prefix = request.captureImageStoredPrefix.strip()
    local_root = request.captureImageLocalRoot.strip()
    if bool(stored_prefix) != bool(local_root):
        ok_so_far = False
        checks.append(PathCheckVO(
            key="captureImageStoredPrefix",
            path=stored_prefix,
            exists=bool(stored_prefix),
            writable=False,
            message="The stored prefix and the local root must be set together, or both left blank.",
        ))
    images_root = (request.qcImagesRoot or "").strip()
    if images_root:
        checks.append(check_directory("qcImagesRoot", images_root, require_writable=False))
        ok_so_far = ok_so_far and checks[-1].exists
    resolved, total = count_resolved_folders(db, stored_prefix, local_root, images_root)
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


@router.put("/settings", response_model=ApiResponse[PathSettingsVO])
def update_server_settings(
    request: UpdateServerSettingsRequest,
    _: AdminUser,
    db: DbSession,
) -> ApiResponse[PathSettingsVO]:
    """Persist console-owned settings and apply them live.

    Export paths reuse validate_path_settings; omitted upload and AI fields
    stay untouched so older consoles can still save the other settings.
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
        "uploadEnabled": "upload_enabled",
        "uploadS3Path": "upload_s3_path",
        "uploadS3Region": "upload_s3_region",
        "uploadS3AccessKey": "upload_s3_access_key",
        "uploadS3SecretKey": "upload_s3_secret_key",
        "uploadDoneRoot": "upload_done_dir",
        "uploadSummaryRoot": "upload_summary_dir",
        "aiReviewEnabled": "ai_review_enabled",
        "aiPreanalysisEnabled": "ai_preanalysis_enabled",
        "openrouterApiKey": "openrouter_api_key",
        "openrouterExtractModel": "openrouter_extract_model",
        "openrouterCompareModel": "openrouter_compare_model",
    }
    secret_fields = {"upload_s3_secret_key", "openrouter_api_key"}
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
    if candidate.upload_enabled:
        try:
            parse_s3_path(candidate.upload_s3_path)
        except UploadError as error:
            raise BusinessError(ApiCodes.BAD_REQUEST, str(error)) from error
        if not candidate.upload_s3_region.strip():
            raise BusinessError(ApiCodes.BAD_REQUEST, "The S3 region is required.")
        for key, raw_path in (
            ("uploadDoneRoot", candidate.upload_done_dir),
            ("uploadSummaryRoot", candidate.upload_summary_dir),
        ):
            directory = Path(raw_path).expanduser()
            if key == "uploadSummaryRoot" and _same_or_inside(
                directory, Path(export_output_dir).expanduser()
            ):
                raise BusinessError(
                    ApiCodes.BAD_REQUEST,
                    "uploadSummaryRoot must be outside the export output folder",
                )
            if not raw_path.strip() or not fs_path(directory).is_dir():
                raise BusinessError(
                    ApiCodes.BAD_REQUEST,
                    f"{key} must be an existing writable directory.",
                )
            check = check_directory(key, raw_path, require_writable=True)
            if not check.writable:
                raise BusinessError(
                    ApiCodes.BAD_REQUEST,
                    f"{key} must be writable: {check.message or 'permission denied'}",
                )
        try:
            upload_runtime_config(candidate, export_output_dir=export_output_dir)
        except (UploadError, ExportError) as error:
            raise BusinessError(ApiCodes.BAD_REQUEST, str(error)) from error

    if candidate.ai_review_enabled and not (
        candidate.openrouter_api_key
        and candidate.openrouter_api_key.get_secret_value().strip()
    ):
        raise BusinessError(ApiCodes.BAD_REQUEST, "An OpenRouter API key is required for AI review.")

    write_server_settings(values)
    for field, value in values.items():
        setattr(settings, field, value)
    return ok(path_settings_vo())

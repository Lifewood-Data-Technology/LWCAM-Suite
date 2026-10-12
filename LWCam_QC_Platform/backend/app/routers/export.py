"""Admin API for the export step (approved folders -> delivery package).

QC Platform stage, after QC review. Exposes preflight checks, the list of
folders, start/retry of an export run, the failure ledger and the current run.
The heavy work is in app.services.export (export_coordinator); this router only
validates the folder state and maps ExportError to the API error format.
All routes need an admin account.
"""
from typing import Any

from fastapi import APIRouter, Body, Query
from app.core.errors import ApiCodes, BusinessError
from app.core.responses import ApiResponse, PageResult, ok
from app.dependencies import AdminUser, DbSession
from app.models.capture import CaptureFolder
from app.schemas.export import ExportFolderVO, ExportPreflightVO
from app.services.export import ExportError, export_coordinator, list_export_folders

router = APIRouter(prefix="/admin/exports", tags=["exports"])


def _require_exportable(db: DbSession, folder_id: int) -> None:
    """Raises the reason a folder cannot be exported, or returns quietly."""
    folder = db.get(CaptureFolder, folder_id)
    if folder is None or folder.is_deleted:
        raise as_business_error(ExportError("folderMissing"), 404)
    if folder.is_exported:
        raise as_business_error(ExportError("folderAlreadyExported"), 409)
    if folder.qc_status.lower() != "pass":
        raise as_business_error(ExportError("folderNotPass"))


def as_business_error(error: ExportError, status: int = 400) -> BusinessError:
    if status == 404:
        code = ApiCodes.NOT_FOUND
    elif status == 409:
        code = ApiCodes.CONFLICT
    else:
        code = ApiCodes.BAD_REQUEST
    return BusinessError(code, str(error), status, error.to_dict())


@router.get("/preflight", response_model=ApiResponse[ExportPreflightVO])
def export_preflight(_: AdminUser, db: DbSession) -> ApiResponse[ExportPreflightVO]:
    return ok(ExportPreflightVO.model_validate(export_coordinator.preflight(db)))


@router.get("/folders", response_model=ApiResponse[PageResult[ExportFolderVO]])
def export_folders(
    _: AdminUser,
    db: DbSession,
    export_status: str = Query(default="all", alias="exportStatus", pattern="^(all|exported|unexported)$"),
    page: int = Query(1, ge=1),
    size: int = Query(20, ge=1, le=200),
) -> ApiResponse[PageResult[ExportFolderVO]]:
    folders, total = list_export_folders(
        db,
        export_status,
        page=page,
        size=size,
    )
    return ok(
        PageResult(
            records=[ExportFolderVO.model_validate(folder) for folder in folders],
            total=total,
            page=page,
            size=size,
        )
    )


@router.post("/folders/{folder_id}", response_model=ApiResponse[dict[str, Any]])
def run_folder_export(
    folder_id: int,
    current_user: AdminUser,
    db: DbSession,
) -> ApiResponse[dict[str, Any]]:
    _require_exportable(db, folder_id)
    try:
        return ok(export_coordinator.start(current_user.user_id, [folder_id]))
    except ExportError as error:
        raise as_business_error(error, 409) from error


@router.get("/failures", response_model=ApiResponse[list[dict[str, Any]]])
def export_failures(_: AdminUser, db: DbSession) -> ApiResponse[list[dict[str, Any]]]:
    """Folders whose export failed and has not since succeeded.

    Outlives the run that produced it - active.json only ever holds the latest
    run - so a failure stays visible until somebody fixes it.
    """
    entries = export_coordinator.read_failures()
    # The ledger stores ids, not names. Resolving here rather than at write time
    # keeps it correct after a rename, and a folder that has since been deleted
    # still lists rather than vanishing from the screen.
    names = {
        row.id: row.folder_name
        for row in db.query(CaptureFolder.id, CaptureFolder.folder_name)
        .filter(CaptureFolder.id.in_([e.get("folderId") for e in entries] or [0]))
        .all()
    }
    for entry in entries:
        entry["folderName"] = names.get(entry.get("folderId"))
    return ok(entries)


@router.post("/retry", response_model=ApiResponse[dict[str, Any]])
def retry_exports(
    current_user: AdminUser,
    db: DbSession,
    folderIds: list[int] | None = Body(default=None, embed=True),
) -> ApiResponse[dict[str, Any]]:
    """Re-exports failed folders: the ones named, or every unresolved failure.

    ONE run for the whole batch, not a call per folder - start() refuses to run
    while another is alive, so a caller looping over ids would fail on its
    second request.
    """
    if folderIds:
        # Named folders: a stale one is refused with its reason, like
        # run_folder_export.
        wanted = folderIds
        for folder_id in wanted:
            _require_exportable(db, folder_id)
    else:
        # Every unresolved failure that can still be exported. One that cannot
        # (deleted, exported by another station, sent back to rework) is
        # dropped from the ledger instead: nothing else ever clears it, and a
        # single stale entry must not make "retry all" refuse the rest.
        wanted = []
        for entry in export_coordinator.read_failures():
            folder_id = entry.get("folderId")
            if folder_id is None:
                continue
            try:
                _require_exportable(db, int(folder_id))
            except BusinessError:
                export_coordinator.clear_failure(folder_id)
            else:
                wanted.append(int(folder_id))
    if not wanted:
        raise as_business_error(ExportError("noEligibleFolders"))

    try:
        return ok(export_coordinator.start(current_user.user_id, wanted))
    except ExportError as error:
        raise as_business_error(error, 409) from error


@router.post("/run", response_model=ApiResponse[dict[str, Any]])
def run_export(current_user: AdminUser, db: DbSession) -> ApiResponse[dict[str, Any]]:
    preflight = export_coordinator.preflight(db)
    if not preflight["ready"]:
        issue = preflight["errors"][0]
        raise as_business_error(
            ExportError(issue["errorKey"], issue.get("errorParams")),
        )
    try:
        return ok(export_coordinator.start(current_user.user_id))
    except ExportError as error:
        raise as_business_error(error, 409) from error


@router.get("/current", response_model=ApiResponse[dict[str, Any] | None])
def current_export(_: AdminUser) -> ApiResponse[dict[str, Any] | None]:
    return ok(export_coordinator.current())

from collections.abc import Callable, Sequence
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from hashlib import sha256
import json
import logging
import os
import shutil
from pathlib import Path
from typing import Any

from fastapi import APIRouter, File, Form, Query, UploadFile
from fastapi.responses import FileResponse
from PIL import Image, ImageOps, UnidentifiedImageError
from sqlalchemy import func, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, object_session

from app.core.config import settings
from app.core.errors import ApiCodes, BusinessError
from app.core.paths import fs_path, to_db, to_local
from app.core.responses import ApiResponse, PageResult, ok
from app.dependencies import DbSession, QcUser
from app.models.capture import CaptureBox, CaptureFolder, CaptureImage
from app.models.project import Project, UserProject
from app.models.qc_session import ReworkLog
from app.models.user import User
from app.schemas.qc import (
    AiReviewApplyRequest,
    AiReviewJobVO,
    AiReviewStartRequest,
    BatchDeleteRequest,
    BatchDeskewRequest,
    BatchLuminanceRequest,
    BatchRotateRequest,
    FolderMetadataVO,
    CropImageRequest,
    DeskewImageRequest,
    LuminanceRequest,
    MetadataTemplateFieldVO,
    MetadataTemplateVO,
    MetadataUpdateRequest,
    MetadataQcImageVO,
    MetadataQcTaskVO,
    RejectRequest,
    ReorderImagesRequest,
    ReviewRequest,
    RotateImageRequest,
    SeparationMarkersRequest,
)
from app.services.ai_review import (
    APPLY_CONFIDENCE,
    AiReviewDisabledError,
    AiReviewError,
    AiReviewNotFoundError,
    AiReviewSnapshot,
    ai_review_coordinator,
    canonical_metadata_value,
)
from app.services.ai_preanalysis import ai_preanalysis_scheduler
from app.services.geometry_ops import replay_pending_ops
from app.services.luminance import apply_luminance
from app.services.lwip_baseline import baseline_ops
from app.services.previews import (
    PREVIEW_MIME_TYPE,
    generate_preview_image,
    generate_thumbnail_file,
    set_pending_op_replay,
)
from app.services.qc_audit import write_qc_audit
from app.services.qc_ops_store import (
    committed_ops as qc_ops_committed,
    effective_ops,
    ignore_lwip as qc_ops_ignore_lwip,
    qc_ops_path,
    read_qc_ops,
)
from app.services.qc_separation import SeparationFileError, SeparationFileTransaction
from app.services.qc_drafts import (
    add_pending_deskew,
    create_inserted_image,
    delete_image as draft_delete_image,
    dirty_image_ids_from_manifest,
    discard_draft,
    draft_dir,
    draft_image_item,
    draft_image_path,
    draft_summary,
    draft_version,
    ensure_work_copy,
    add_pending_op,
    clear_pending_ops,
    mark_baked,
    mark_dirty,
    mark_dirty_no_history,
    metadata_dirty_from_manifest,
    metadata_values_from_manifest,
    pending_ops_of,
    read_manifest,
    redo_manifest,
    replace_image as draft_replace_image,
    restore_original as draft_restore_original,
    save_metadata_draft,
    set_order,
    set_separation_markers,
    undo_manifest,
    visible_order,
)

router = APIRouter(prefix="/qc/metadata-tasks", tags=["metadata-qc"])
logger = logging.getLogger(__name__)
DB_TO_API_STATUS = {"pending": "pending", "pass": "passed", "rework": "rework"}

# Accepted for Replace / Insert-before. Capture output is .jpg today and only
# becomes .tif at export (capture_folders.is_tif_converted), so restricting
# these actions to .tif made them unusable on pre-export folders. Matches the
# set the bundled Luminance Correction tool already accepts.
UPLOAD_IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".tif", ".tiff"}
TITLE_RECORD_TYPE_MAP = {
    "WWI South African Mounted Rifles Military Personnel Cards": "Military Service Records",
    "WWI South African Mounted Rifles Military Indexes": "Military Service Record Indexes",
    "WWI Medical Files": "Military Medical Records",
    "WWII Medical Files": "Military Medical Records",
}
DEFAULT_METADATA_TEMPLATE = {
    "fields": [
        {
            "key": "coverTag",
            "label": "Cover Tag",
            "input": "select",
            "mandatory": True,
            "exported": False,
            "options": [
                "Cover Will Be Captured",
                "Cover Will not Be Captured",
                "Cover Unavailable or Missing",
            ],
        },
        {
            "key": "imageTags",
            "label": "Image Tags",
            "input": "select",
            "mandatory": False,
            "exported": False,
            "options": [
                "Faded or Damaged Documents",
                "Reflective Surface",
                "Document Glued Together",
            ],
        },
        {
            "key": "title",
            "label": "Title",
            "input": "select",
            "mandatory": True,
            "exported": True,
            "options": list(TITLE_RECORD_TYPE_MAP.keys()),
        },
        {"key": "volume", "label": "Volume", "input": "text", "mandatory": True, "exported": True},
        {
            "key": "startDate",
            "label": "Start Date",
            "input": "select",
            "mandatory": True,
            "exported": True,
            "options": ["1914", "1939"],
        },
        {
            "key": "endDate",
            "label": "End Date",
            "input": "select",
            "mandatory": True,
            "exported": True,
            "options": ["1918", "1945"],
        },
        {
            "key": "archivalRefNo",
            "label": "Archival Reference Number",
            "input": "text",
            "mandatory": False,
            "exported": True,
        },
        {"key": "place", "label": "Place", "input": "fixed", "value": "South Africa"},
        {"key": "language", "label": "Language", "input": "fixed", "value": "English"},
        {
            "key": "recordCustodian",
            "label": "Record Custodian",
            "input": "fixed",
            "value": "South Africa Department of Defense",
        },
        {"key": "digitizingEntity", "label": "Digitizing Entity", "input": "fixed", "value": "Lifewood"},
        {"key": "captureOperatorId", "label": "Capture Operator ID", "input": "fixed", "value": "cis.user.MM38-RXW3"},
        {"key": "captureOperatorName", "label": "Capture Operator Name", "input": "fixed", "value": "lifewoodza01"},
    ],
    "titleRecordTypeMap": TITLE_RECORD_TYPE_MAP,
}
METADATA_FIELD_MAP = {
    "coverTag": "cover_tag",
    "imageTags": "image_tags",
    "title": "title",
    "volume": "volume",
    "startDate": "start_date",
    "endDate": "end_date",
    "archivalRefNo": "archival_ref_no",
    "recordType": "record_type",
    "place": "place",
    "language": "language",
    "recordCustodian": "record_custodian",
    "captureOperatorId": "capture_operator_id",
    "captureOperatorName": "capture_operator_name",
    "digitizingEntity": "digitizing_entity",
}


def now() -> datetime:
    """Return the current UTC time."""
    return datetime.now(timezone.utc)


def folder_options():
    """Eager-load options for images, box, project and device when querying folders."""
    from sqlalchemy.orm import selectinload
    return (
        selectinload(CaptureFolder.images),
        selectinload(CaptureFolder.box).selectinload(CaptureBox.project),
        selectinload(CaptureFolder.device),
    )


def project_ids_for_user(db, user_id: int) -> list[int]:
    """Project IDs this QC user is authorised to access."""
    return list(db.scalars(select(UserProject.project_id).where(UserProject.user_id == user_id)).all())


def visible_folder_conditions(project_ids: list[int]):
    """Shared filter conditions for the folders a QC user can see.

    folder_path is written by LWCAM only after LWIP finishes deskew/crop/thumbnail
    processing, while qc_status defaults to 'PENDING' the moment the row syncs.
    Without the NULL check a folder becomes claimable before its images exist on
    disk, and every image request then 404s — so treat "has an image directory"
    as part of being a QC task at all.
    """
    return (
        CaptureFolder.is_deleted.is_not(True),
        CaptureFolder.folder_path.is_not(None),
        CaptureFolder.box.has(CaptureBox.is_deleted.is_not(True)),
        CaptureFolder.box.has(CaptureBox.project_id.in_(project_ids)),
        CaptureFolder.box.has(CaptureBox.project.has(Project.is_deleted.is_not(True))),
        CaptureFolder.images.any(),
    )


def safe_filename(value: str) -> str:
    """Reject anything but a bare filename, blocking path traversal."""
    filename = value.strip()
    if not filename or filename in {".", ".."} or "/" in filename or "\\" in filename:
        raise BusinessError(ApiCodes.BAD_REQUEST, "Invalid image filename.")
    return filename


def safe_backup_part(value: str) -> str:
    return "".join(char if char.isalnum() or char in {"-", "_", "."} else "_" for char in value)


def thumbnail_target_path(folder: CaptureFolder, image: CaptureImage) -> Path | None:
    if not folder.thumbnail_path:
        return None
    directory = to_local(folder.thumbnail_path).resolve()
    filename = safe_filename(image.image_name)
    path = (directory / filename).resolve()
    try:
        path.relative_to(directory)
    except ValueError as error:
        raise BusinessError(ApiCodes.FORBIDDEN, "The thumbnail path escapes its folder.", 403) from error
    return path


def expected_image_path(folder: CaptureFolder, image: CaptureImage, thumbnail: bool = False) -> Path:
    """Where this image belongs, whether or not it is actually there.

    Split out of [resolve_image_file] so the commit can write a REPLACEMENT for
    a page whose file has gone. The traversal guard still applies - only the
    existence check is the caller's to decide.
    """
    directory_value = folder.thumbnail_path if thumbnail else folder.folder_path
    if not directory_value:
        raise BusinessError(ApiCodes.NOT_FOUND, "The image directory is not configured.", 404)
    directory = to_local(directory_value).resolve()
    filename = safe_filename(image.image_name)
    path = (directory / filename).resolve()
    try:
        path.relative_to(directory)
    except ValueError as error:
        raise BusinessError(ApiCodes.FORBIDDEN, "The image path escapes its folder.", 403) from error
    return path


def resolve_image_file(folder: CaptureFolder, image: CaptureImage, thumbnail: bool = False) -> Path:
    """Resolve and validate the on-disk path of an image or its thumbnail."""
    path = expected_image_path(folder, image, thumbnail)
    if not fs_path(path).is_file():
        raise BusinessError(
            ApiCodes.NOT_FOUND, f"The image file does not exist: {path.name}", 404
        )
    return path


def image_available(folder: CaptureFolder, image: CaptureImage) -> bool:
    try:
        resolve_image_file(folder, image)
        return True
    except BusinessError:
        return False


def available_image_names(
    folder: CaptureFolder, thumbnail: bool = False
) -> set[str] | None:
    """The filenames actually present in [folder]'s image directory.

    ONE directory listing, in place of three filesystem operations per image
    (`to_local(...).resolve()`, `(directory / filename).resolve()`,
    `path.is_file()`). That is free on local disk and ruinous when the share is
    remote.

    Measured on station QC-STATION 2026-09-09, where the images live on
    \\\\CAPTURE-PC\\2.Batches over a Tailscale/WireGuard tunnel: every one of those
    operations is an SMB round trip at 23-65 ms against ~0.04 ms locally. The
    pending page held 11 folders / 1,184 images, so listing the tasks cost
    1,200-3,500 round trips - 78 seconds of filesystem I/O - and the Flutter
    client gave up first. Quality Check could not open at all, and the banner
    said "The QC engine did not respond in time", which pointed at the engine.
    The engine was healthy; the share was not, and Station Setup's connection
    test only probes PostgreSQL, so it passed throughout.

    On one 246-file directory: 246 individual resolve()+is_file() calls took
    ~16 s, one os.scandir() of the same directory took 16 ms. The cost was
    never the volume of data, only the number of round trips.

    Returns None when the directory is unconfigured, missing or unreadable -
    the same verdict the per-image check reached in those cases, so the caller
    can treat None as "nothing is available" without changing behaviour.
    """
    directory_value = folder.thumbnail_path if thumbnail else folder.folder_path
    if not directory_value:
        return None
    try:
        directory = to_local(directory_value).resolve()
        with os.scandir(fs_path(directory)) as entries:
            # normcase so matching keeps the platform's own rules:
            # case-insensitive on Windows, exact on a Linux container.
            return {
                os.path.normcase(entry.name) for entry in entries if entry.is_file()
            }
    except OSError:
        return None


def image_disk_stats(folder: CaptureFolder) -> dict[str, tuple[int, int]]:
    """(mtime_ns, size) of every real file in [folder]'s image directory.

    capture_images.image_updated_at is a QC-write timestamp; the LWIP reprocess
    that follows a CAPTURE rework overwrites a page's bytes directly on disk
    and never touches that column, so source_hash and the per-image preview
    stamp - both built only from DB columns - could not see it: identical
    before and after every byte of a page changed. Folding the file's own
    stat in fixes that.

    One os.scandir for the WHOLE folder, exactly like available_image_names
    (see its docstring for the measured cost of doing this call-by-call over a
    network share) - not one stat() per image, so this is cheap enough to run
    on every task load, list pages included.
    """
    directory_value = folder.folder_path
    if not directory_value:
        return {}
    try:
        directory = to_local(directory_value).resolve()
        with os.scandir(fs_path(directory)) as entries:
            stats: dict[str, tuple[int, int]] = {}
            for entry in entries:
                if entry.is_file():
                    info = entry.stat()
                    stats[os.path.normcase(entry.name)] = (info.st_mtime_ns, info.st_size)
            return stats
    except OSError:
        return {}


def image_available_in(names: set[str] | None, image: CaptureImage) -> bool:
    """[image_available]'s verdict, taken from a pre-listed set. No I/O.

    safe_filename still runs, so the traversal guard is unchanged and an
    unusable filename is False exactly as before.
    """
    if not names:
        return False
    try:
        filename = safe_filename(image.image_name)
    except BusinessError:
        return False
    return os.path.normcase(filename) in names


def metadata_snapshot(folder: CaptureFolder) -> dict:
    box = folder.box
    project = box.project
    return {
        "folderId": folder.id,
        "boxId": box.box_id,
        "boxName": box.box_name,
        "projectId": project.id if project else None,
        "projectName": project.project_name if project else None,
        "folderName": folder.folder_name,
        "folderSeq": folder.folder_seq,
        "deviceId": folder.device.device_id,
        "coverTag": folder.cover_tag,
        "imageTags": folder.image_tags,
        "title": folder.title,
        "volume": folder.volume,
        "startDate": folder.start_date,
        "endDate": folder.end_date,
        "archivalRefNo": folder.archival_ref_no,
        "recordType": folder.record_type,
        "place": folder.place,
        "language": folder.language,
        "recordCustodian": folder.record_custodian,
        "captureOperatorId": folder.capture_operator_id,
        "captureOperatorName": folder.capture_operator_name,
        "digitizingEntity": folder.digitizing_entity,
        "sourceCreatedAt": folder.source_created_at.isoformat() if folder.source_created_at else None,
        "sourceUpdatedAt": folder.source_updated_at.isoformat() if folder.source_updated_at else None,
    }


def metadata_template(folder: CaptureFolder) -> MetadataTemplateVO:
    project_template = (folder.box.project.template if folder.box and folder.box.project else None) or {}
    raw_fields = project_template.get("fields") if isinstance(project_template, dict) else None
    raw_mapping = project_template.get("titleRecordTypeMap") if isinstance(project_template, dict) else None
    fields_source = raw_fields if isinstance(raw_fields, list) and raw_fields else DEFAULT_METADATA_TEMPLATE["fields"]
    mapping_source = raw_mapping if isinstance(raw_mapping, dict) and raw_mapping else TITLE_RECORD_TYPE_MAP
    fields = []
    for item in fields_source:
        if not isinstance(item, dict):
            continue
        key = item.get("key") or item.get("id")
        if not key or item.get("enabled") is False:
            continue
        normalized_item = dict(item)
        normalized_item["key"] = str(key)
        if not normalized_item.get("input"):
            input_type = str(normalized_item.get("inputType") or "").lower()
            mode = str(normalized_item.get("mode") or "").lower()
            normalized_item["input"] = (
                "fixed"
                if mode == "fixed"
                # A mapped field is derived, so its inputType is irrelevant -
                # Station Setup leaves it at whatever it was before the field was
                # switched to mapped, and rendering that as an editable dropdown
                # would invite an edit the mapping immediately overwrites.
                else "mapped"
                if mode == "mapped"
                else "select" if input_type == "dropdown" else "text"
            )
        if "value" not in normalized_item and "fixedValue" in normalized_item:
            normalized_item["value"] = normalized_item.get("fixedValue")
        default_item = next(
            (field for field in DEFAULT_METADATA_TEMPLATE["fields"] if field["key"] == str(key)),
            {},
        )
        merged = {**default_item, **normalized_item}
        options = merged.get("options") or []
        fields.append(MetadataTemplateFieldVO(
            key=str(merged["key"]),
            label=str(merged.get("label") or merged["key"]),
            input=str(merged.get("input") or "text"),
            mandatory=bool(merged.get("mandatory")),
            exported=bool(merged.get("exported")),
            options=[str(option) for option in options],
            value=merged.get("value"),
            mappedFrom=str(merged["mappedFrom"]) if merged.get("mappedFrom") else None,
            valueMap={
                str(source): str(target)
                for source, target in (merged.get("valueMap") or {}).items()
            },
        ))
    return MetadataTemplateVO(
        fields=fields,
        titleRecordTypeMap={str(key): str(value) for key, value in mapping_source.items()},
    )


def derive_record_type(title: str | None, template: MetadataTemplateVO) -> str | None:
    if not title:
        return None
    return template.titleRecordTypeMap.get(title) or TITLE_RECORD_TYPE_MAP.get(title)


def apply_template_mappings(values: dict, template: MetadataTemplateVO) -> dict:
    """Derive every mapped field from the field it is mapped from.

    Mapping is resolved ONE LEVEL DEEP and the source must itself be editable,
    matching the capture form (`metadata_template.dart`, `effectiveValueOf`): a
    mapped-from-mapped or mapped-from-fixed chain resolves to None rather than
    recursing, so a template cannot make the order of evaluation matter.

    A source value the map does not cover derives None. That can block approval
    on a mandatory mapped field, which is the honest outcome - the operator
    cannot type the value, so the template has a hole and the message names the
    field.
    """
    by_key = {field.key: field for field in template.fields}
    for field in template.fields:
        if field.input != "mapped":
            continue
        source_key = field.mappedFrom
        source = by_key.get(source_key) if source_key else None
        source_is_editable = source is not None and source.input in {"text", "select"}
        if not source_key or source_key == field.key or not source_is_editable:
            values[field.key] = None
            continue
        source_value = values.get(source_key)
        mapped = field.valueMap.get(str(source_value).strip()) if source_value is not None else None
        values[field.key] = mapped or None
    return values


def normalize_metadata_values(values: dict, template: MetadataTemplateVO) -> dict:
    result = dict(values)
    for field in template.fields:
        if field.input == "fixed":
            result[field.key] = field.value
    # The legacy top-level titleRecordTypeMap, for templates predating per-field
    # mapping - those have no recordType field at all. Any template that
    # declares one owns the value, so the legacy shape must not touch it.
    #
    # This used to skip only when recordType was declared MAPPED, which meant an
    # EDITABLE recordType took the legacy path: derive_record_type returns None
    # for a title outside the map, so saving metadata in QC silently wiped the
    # value the operator had keyed from the dropdown. A mapped field is derived
    # by apply_template_mappings immediately below regardless, so restricting
    # this to templates with no recordType field loses nothing.
    record_type_field = next(
        (field for field in template.fields if field.key == "recordType"), None
    )
    if record_type_field is None:
        result["recordType"] = derive_record_type(result.get("title"), template)
    apply_template_mappings(result, template)
    for key, value in list(result.items()):
        if isinstance(value, str):
            result[key] = value.strip() or None
    # LAST, after the strip/empty pass: canonicalise the datetime fields (the
    # source timestamps; startDate/endDate are verbatim text and not touched) to UTC
    # so a pre-1901 date cannot carry a seconds-precision offset that Pydantic
    # refuses (see rfc3339).
    #
    # HERE rather than in metadata_snapshot, deliberately. source_hash hashes
    # metadata_snapshot's output directly, so normalising there would change
    # EVERY folder's sourceHash - the optimistic-concurrency token the QC page
    # holds while an operator has a folder open - and a one-time global
    # invalidation mid-shift surfaces as spurious "the source changed"
    # rejections on work in progress. This is instead the single funnel every
    # metadata path already goes through: the folder snapshot, a draft
    # manifest, an AI-review suggestion, the approval validator and the write
    # path, all covered consistently rather than patching the one call site
    # that happened to blow up.
    for key in SNAPSHOT_DATE_FIELDS:
        if key in result:
            result[key] = rfc3339(result[key])
    return result


def metadata_date(value):
    if isinstance(value, datetime) or value is None:
        return value
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        try:
            parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
            return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
        except ValueError:
            return value
    return value


# The datetime-typed fields on FolderMetadataVO. Canonicalised to UTC before
# they are handed to Pydantic - see rfc3339. startDate/endDate are NOT here:
# capture_folders.start_date/end_date are text and travel verbatim.
SNAPSHOT_DATE_FIELDS = ("sourceCreatedAt", "sourceUpdatedAt")


def rfc3339(value):
    """[value] as an ISO string whose UTC offset Pydantic will accept.

    A pre-1901 date cannot be serialised in a non-UTC zone without producing an
    offset Pydantic rejects. An operator keying the year 1877 gets
    datetime(1877, 1, 1, tzinfo=utc), Postgres stores 1877-01-01T00:00:00Z, and
    psycopg reads timestamptz back in the CONNECTION's zone. Malaysia had no
    standard time before 1901, so Asia/Kuala_Lumpur is local mean time there -
    +06:55:25 - and .isoformat() emits

        1877-01-01T06:55:25+06:55:25
                            ^^^^^^^^ an offset with SECONDS

    datetime.fromisoformat accepts that; Pydantic does not, because RFC 3339
    offsets are +-HH:MM. One folder failing validation fails the whole page
    response, so the Completed tab went completely dark with only

        Input should be a valid datetime or date, unexpected extra characters

    to go on. Not an exotic edge case here: these are 19th-century parish
    registers and tombstone records, so ANY folder dated before 1901 hits it.

    Converting to UTC first makes the offset +00:00, which is representable in
    every era, and leaves the instant untouched. Built on metadata_date so it
    inherits that function's handling of empty strings and unparseable text,
    which pass through unchanged.

    Since 2026-09-10 startDate/endDate are verbatim text (the archive's own
    notation, delivered to FamilySearch as keyed), so this only covers
    sourceCreatedAt/sourceUpdatedAt.
    """
    parsed = metadata_date(value)
    if isinstance(parsed, datetime):
        return parsed.astimezone(timezone.utc).isoformat()
    return parsed


def ai_queue_gating_active() -> bool:
    """Whether pending folders are withheld until their AI review is done.

    The scheduler's own switch, deliberately reused rather than restated: it is
    already "stage 1 on, a key to call with, and stage 2 on". Withholding work on
    any looser condition would hide the queue with nothing able to clear it - a
    missing API key stops the scanner, and every folder would wait forever.
    """
    return ai_preanalysis_scheduler.enabled()


def ai_visible_pending_ids(db: Session, project_ids: list[int]) -> list[int]:
    """Pending folder ids a QC operator may see, oldest first.

    Ordered exactly as the queue and claim-next order them, so paging and
    "Claim next" agree about what exists. A folder is included once its review
    has finished OR has definitively given up - a failed review must never keep
    work out of the queue.
    """
    ids = list(db.scalars(
        select(CaptureFolder.id)
        .where(
            *visible_folder_conditions(project_ids),
            func.lower(CaptureFolder.qc_status) == "pending",
            CaptureFolder.qc_locked_by.is_(None),
        )
        .order_by(CaptureFolder.source_created_at.asc().nullslast(), CaptureFolder.id.asc())
    ))
    if not ids:
        return []
    state = ai_review_coordinator.queue_visibility(ids)
    return [folder_id for folder_id in ids if state.get(folder_id) in {"ready", "failed"}]


def validate_batch_delete(current_order: list[int], requested_ids: list[int]) -> None:
    """Guards a batch delete before any image is removed.

    Both checks run up front, not inside the delete loop. A batch that failed
    halfway would leave the draft in a state the caller never asked for, and the
    emptiness rule cannot be expressed one image at a time in any case: deleting
    the last of four images is allowed, deleting all four is not.

    [requested_ids] is expected to be deduplicated, so its length is the number
    of images the batch actually removes.
    """
    if any(image_id not in current_order for image_id in requested_ids):
        raise BusinessError(ApiCodes.NOT_FOUND, "The image does not exist.", 404)
    if len(current_order) - len(requested_ids) < 1:
        raise BusinessError(ApiCodes.BAD_REQUEST, "At least one image must remain.", 400)


def effective_metadata_snapshot(folder: CaptureFolder, manifest: dict | None, template: MetadataTemplateVO) -> dict:
    snapshot = normalize_metadata_values(metadata_snapshot(folder), template)
    draft_values = metadata_values_from_manifest(manifest)
    if draft_values:
        snapshot.update(normalize_metadata_values(draft_values, template))
    return snapshot


def editable_metadata_to_dict(values) -> dict:
    return {
        "coverTag": values.coverTag,
        "imageTags": values.imageTags,
        "title": values.title,
        "volume": values.volume,
        "startDate": values.startDate,
        "endDate": values.endDate,
        "archivalRefNo": values.archivalRefNo,
        "recordType": values.recordType,
        "place": values.place,
        "language": values.language,
        "recordCustodian": values.recordCustodian,
        "captureOperatorId": values.captureOperatorId,
        "captureOperatorName": values.captureOperatorName,
        "digitizingEntity": values.digitizingEntity,
    }


def apply_metadata_to_folder(folder: CaptureFolder, values: dict, template: MetadataTemplateVO) -> None:
    normalized = normalize_metadata_values(values, template)
    for api_key, model_key in METADATA_FIELD_MAP.items():
        if api_key in normalized:
            setattr(folder, model_key, normalized[api_key])


def validate_metadata_for_approval(values: dict, template: MetadataTemplateVO) -> None:
    normalized = normalize_metadata_values(values, template)
    missing = [
        field.label
        for field in template.fields
        if field.mandatory and not normalized.get(field.key)
    ]
    if missing:
        raise BusinessError(ApiCodes.BAD_REQUEST, f"Required metadata is missing: {', '.join(missing)}", 400)


def image_snapshot(folder: CaptureFolder, disk_stats: dict[str, tuple[int, int]] | None = None) -> list[dict]:
    if disk_stats is None:
        disk_stats = image_disk_stats(folder)
    entries = []
    for image in sorted(folder.images, key=lambda item: (item.image_created_at or datetime.min.replace(tzinfo=timezone.utc), item.id)):
        try:
            disk_key = os.path.normcase(safe_filename(image.image_name))
        except BusinessError:
            disk_key = None
        entries.append({
            "id": image.id,
            "name": image.image_name,
            "format": image.file_format,
            "createdAt": image.image_created_at.isoformat() if image.image_created_at else None,
            "updatedAt": image.image_updated_at.isoformat() if image.image_updated_at else None,
            # (mtime_ns, size) of the actual file - see image_disk_stats.
            "fileStat": list(disk_stats[disk_key]) if disk_key in disk_stats else None,
        })
    return entries


def source_hash(folder: CaptureFolder, disk_stats: dict[str, tuple[int, int]] | None = None) -> str:
    """Stable SHA-256 fingerprint over the current metadata and image snapshot."""
    payload = {"metadata": metadata_snapshot(folder), "images": image_snapshot(folder, disk_stats)}
    raw = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return sha256(raw.encode("utf-8")).hexdigest()


def ai_review_snapshot(folder: CaptureFolder, user_id: str) -> AiReviewSnapshot:
    template = metadata_template(folder)
    manifest = read_manifest(folder.id, user_id)
    effective_metadata = effective_metadata_snapshot(folder, manifest, template)
    official_images = sorted(
        folder.images,
        key=lambda item: (item.image_created_at or datetime.min.replace(tzinfo=timezone.utc), item.id),
    )
    official_by_id = {item.id: item for item in official_images}
    image_ids = visible_order(manifest, [item.id for item in official_images])
    images: list[tuple[int, str, Path]] = []
    for image_id in image_ids:
        draft_item = draft_image_item(manifest, image_id)
        if image_id < 0:
            path = draft_image_path(folder.id, user_id, image_id)
            if path is None or not draft_item:
                raise BusinessError(ApiCodes.BAD_REQUEST, "A draft image is missing and cannot be analyzed.", 400)
            filename = str(draft_item.get("image_name") or path.name)
        else:
            image = official_by_id.get(image_id)
            if image is None:
                continue
            path = draft_image_path(folder.id, user_id, image_id) or resolve_image_file(folder, image)
            filename = image.image_name
        images.append((image_id, filename, path))
    try:
        return AiReviewSnapshot.create(
            folder_id=folder.id,
            user_id=user_id,
            source_hash=source_hash(folder),
            metadata=effective_metadata,
            template=template.model_dump(),
            images=images,
            draft_version=draft_version(folder.id, user_id),
        )
    except OSError as error:
        raise BusinessError(ApiCodes.BAD_REQUEST, "An image is missing and cannot be analyzed.", 400) from error


def official_ai_review_snapshot(folder: CaptureFolder) -> AiReviewSnapshot:
    """Build the preanalysis input strictly from the committed folder state."""
    template = metadata_template(folder)
    metadata = normalize_metadata_values(metadata_snapshot(folder), template)
    images = [
        (image.id, image.image_name, resolve_image_file(folder, image))
        for image in ordered_official_images(folder)
    ]
    return AiReviewSnapshot.create(
        folder_id=folder.id,
        user_id="system:ai-preanalysis",
        source_hash=source_hash(folder),
        metadata=metadata,
        template=template.model_dump(),
        images=images,
        draft_version=None,
    )


def folder_or_404(db, folder_id: int, user_id: int, lock: bool = False) -> CaptureFolder:
    """Fetch a folder within the QC user's project scope, optionally row-locking it
    for a following write."""
    project_ids = project_ids_for_user(db, user_id)
    if not project_ids:
        raise BusinessError(ApiCodes.FORBIDDEN, "No projects are assigned to this QC account.", 403)
    from sqlalchemy.orm import selectinload
    statement = select(CaptureFolder).options(*folder_options()).where(
        CaptureFolder.id == folder_id, *visible_folder_conditions(project_ids)
    )
    if lock:
        statement = statement.with_for_update()
    folder = db.scalar(statement)
    if folder is None:
        raise BusinessError(ApiCodes.NOT_FOUND, "The QC task does not exist or you do not have access to it.", 404)
    return folder


def assert_lock_owner(folder: CaptureFolder, user_id: str) -> None:
    """Assert the current user holds the review lock, else raise a conflict."""
    if folder.qc_locked_by != user_id:
        raise BusinessError(ApiCodes.CONFLICT, "This task is no longer assigned to you.", 409)


def cancel_ai_jobs_after_finalization(folder_id: int, *, reason: str) -> None:
    try:
        ai_preanalysis_scheduler.cancel_for_finalization(folder_id, reason=reason)
    except Exception:
        # The QC transaction is already committed. AI cancellation is best effort
        # and must never turn a successful approve/reject into an HTTP failure.
        logger.exception(
            "AI review cancellation failed after QC finalization; folder=%s reason=%s",
            folder_id,
            reason,
        )


def cancel_manual_ai_after_release(folder_id: int) -> None:
    try:
        ai_preanalysis_scheduler.cancel_manual_for_release(folder_id)
    except Exception:
        # The unlock is already committed. A cancellation failure is logged while
        # the successful release response is preserved.
        logger.exception("Manual AI review cancellation failed after release; folder=%s", folder_id)


def completed_search_clause(term: str | None):
    """The Completed list's search, or None when there is nothing to search for.

    Matches the Group ID, the folder name and the capture group's name. The
    Group ID is what the ingest team quotes, but it is only assigned at EXPORT -
    so on its own it would not find a folder that is approved and waiting for
    the sweep, and would never find one sent back for rework. Matching the two
    names as well is what makes every row in the list reachable.

    `%` and `_` are escaped: an operator pasting a Group ID is searching for
    literal text, and an unescaped `_` would quietly match any character.
    """
    cleaned = (term or "").strip()
    if not cleaned:
        return None
    escaped = cleaned.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    like = f"%{escaped}%"
    return or_(
        CaptureFolder.group_id.ilike(like, escape="\\"),
        CaptureFolder.folder_name.ilike(like, escape="\\"),
        CaptureFolder.box.has(CaptureBox.box_name.ilike(like, escape="\\")),
    )


def ops_cache_component(ops: list[dict]) -> int:
    """A deterministic int folded into a preview cache-buster for [ops].

    Committed geometry (qc_ops.json) can change WITHOUT the page file's own
    mtime moving at all - that is the entire point of deferring it - so the
    disk-stat XOR below cannot see it. This is the other half of the key.
    """
    if not ops:
        return 0
    digest = sha256(json.dumps(ops, sort_keys=True, separators=(",", ":")).encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big")


def to_task_vo(db, folder: CaptureFolder, viewer_user_id: str) -> MetadataQcTaskVO:
    """Assemble a folder and its images into the task view model the QC page uses."""
    locked_by_viewer = folder.qc_locked_by == viewer_user_id
    if locked_by_viewer:
        status = "reviewing"
    else:
        status = DB_TO_API_STATUS.get(folder.qc_status.lower(), folder.qc_status.lower())

    assigned_user_id: int | None = None
    if folder.qc_locked_by:
        assigned_user_id = db.scalar(
            select(User.id).where(User.user_id == folder.qc_locked_by)
        )

    template = metadata_template(folder)
    manifest = read_manifest(folder.id, viewer_user_id) if locked_by_viewer else None
    dirty_image_ids = dirty_image_ids_from_manifest(manifest)
    metadata_dirty = metadata_dirty_from_manifest(manifest)
    current_draft_version = draft_version(folder.id, viewer_user_id) if dirty_image_ids or manifest else None
    official_images = sorted(
        folder.images,
        key=lambda item: (item.image_created_at or datetime.min.replace(tzinfo=timezone.utc), item.id),
    )
    official_by_id = {item.id: item for item in official_images}
    image_ids = visible_order(manifest, [item.id for item in official_images]) if locked_by_viewer else [item.id for item in official_images]
    marker_ids = set((manifest or {}).get("separation_markers", []))

    images = []
    # Listed ONCE for the whole folder, before the loop. This also hoists the
    # directory resolve() out of it - the same directory used to be re-resolved
    # over the network for every image in it. See available_image_names.
    on_disk = available_image_names(folder)
    # Same idea, for the same reason: one scandir feeds every image's preview
    # stamp AND the sourceHash below instead of a stat() each - see
    # image_disk_stats.
    disk_stats = image_disk_stats(folder)
    folder_path = to_local(folder.folder_path) if folder.folder_path else None
    # One read of the shared qc_ops.json for the whole folder, same reasoning
    # as disk_stats/on_disk above: effective_ops() would otherwise reopen it
    # once per image, and qc_ops.json is exactly the kind of small-file-per-
    # network-round-trip cost this codebase has already been burned by.
    folder_qc_ops_images = (read_qc_ops(folder_path).get("images") or {}) if folder_path is not None else {}
    for image_id in image_ids:
        draft_item = draft_image_item(manifest, image_id)
        if image_id < 0 and draft_item:
            version = draft_item.get("version") or current_draft_version or int(now().timestamp() * 1000)
            work_path = Path(draft_item.get("work_path", ""))
            images.append(MetadataQcImageVO(
                id=image_id,
                filename=draft_item.get("image_name") or work_path.name,
                available=fs_path(work_path).is_file(),
                previewUrl=f"/api/qc/metadata-tasks/{folder.id}/images/{image_id}/preview?v={version}",
                draftState=draft_item.get("status"),
                separationStart=image_id in marker_ids,
            ))
            continue
        image = official_by_id.get(image_id)
        if image is None:
            continue
        if draft_item and (draft_item.get("version") or current_draft_version) is not None:
            # This image's OWN stamp when it has one, so an edit to another page
            # leaves this URL alone and the rail does not re-render it. Falls
            # back to the folder-wide version for a manifest written before
            # per-image stamps existed, which is the old behaviour exactly.
            version = draft_item.get("version") or current_draft_version
        else:
            version = int(((image.image_updated_at or image.image_created_at) or now()).timestamp() * 1000)
            try:
                disk_key = os.path.normcase(safe_filename(image.image_name))
            except BusinessError:
                disk_key = None
            stat = disk_stats.get(disk_key) if disk_key else None
            if stat is not None:
                # A capture rework overwrites this file directly and never
                # bumps image_updated_at (see image_disk_stats), so without
                # this the rail would keep serving a cached, superseded
                # thumbnail under the same URL. XOR is enough here - this is a
                # cache-busting token, not a security value.
                version = version ^ stat[0] ^ stat[1]
            if folder_path is not None:
                # Committed geometry (qc_ops.json) can change an approved
                # page's OWN effective ops without ever touching the page
                # file's bytes or mtime - the disk-stat XOR above cannot see
                # that, so this is what makes LWCAM refetch after approval.
                # Built from the pre-read folder_qc_ops_images, not another
                # effective_ops() call, to keep this a single file read for
                # the whole folder rather than one per image (see above).
                entry = folder_qc_ops_images.get(image.image_name) or {}
                page_ops = [op for op in (entry.get("ops") or []) if isinstance(op, dict)]
                page_baseline = [] if entry.get("ignore_lwip") else baseline_ops(folder_path, image.image_name)
                version = version ^ ops_cache_component(page_baseline + page_ops)
        images.append(MetadataQcImageVO(
            id=image.id,
            filename=image.image_name,
            available=image_available_in(on_disk, image),
            previewUrl=f"/api/qc/metadata-tasks/{folder.id}/images/{image.id}/preview?v={version}",
            draftState=(draft_item or {}).get("status"),
            separationStart=image.id in marker_ids,
        ))

    return MetadataQcTaskVO(
        id=folder.id,
        status=status,
        sourceHash=source_hash(folder, disk_stats),
        hasDraft=bool(dirty_image_ids or metadata_dirty or (manifest or {}).get("order") or (manifest or {}).get("separation_markers")),
        draftImageIds=dirty_image_ids,
        draftMetadataDirty=metadata_dirty,
        assignedTo=assigned_user_id,
        claimedAt=folder.qc_locked_at,
        submittedAt=folder.source_created_at or folder.updated_at,
        metadata=FolderMetadataVO(**effective_metadata_snapshot(folder, manifest, template)),
        metadataTemplate=template,
        imageCount=len(images),
        imageAvailable=bool(images) and all(item.available for item in images),
        images=images,
        groupId=folder.group_id,
        isExported=bool(folder.is_exported),
        clientRework=bool(folder.client_rework),
    )


def verify_reviewable_folder(folder: CaptureFolder, source_hash_value: str) -> None:
    current_hash = source_hash(folder)
    if source_hash_value != current_hash:
        raise BusinessError(ApiCodes.CONFLICT, "This folder has changed. Refresh it and review again.", 409)
    if folder.qc_status.lower() != "pending":
        raise BusinessError(ApiCodes.CONFLICT, "This task's status has changed.", 409)


def ordered_official_images(folder: CaptureFolder) -> list[CaptureImage]:
    return sorted(folder.images, key=lambda item: (item.image_created_at or datetime.min.replace(tzinfo=timezone.utc), item.id))


def official_image_ids(folder: CaptureFolder) -> list[int]:
    return [image.id for image in ordered_official_images(folder)]


def draft_or_official_path(folder: CaptureFolder, user_id: str, image_id: int) -> Path:
    source_path = draft_image_path(folder.id, user_id, image_id)
    if source_path is not None:
        return source_path
    image = next((item for item in folder.images if item.id == image_id), None)
    if image is None:
        raise BusinessError(ApiCodes.NOT_FOUND, "That image does not belong to this folder.", 404)
    return resolve_image_file(folder, image)


def ensure_editable_work_path(folder: CaptureFolder, user_id: str, image_id: int) -> tuple[Path, str]:
    manifest = read_manifest(folder.id, user_id)
    draft_item = draft_image_item(manifest, image_id)
    if image_id < 0:
        if not draft_item:
            raise BusinessError(ApiCodes.NOT_FOUND, "The draft image does not exist.", 404)
        path = draft_image_path(folder.id, user_id, image_id)
        if path is None:
            raise BusinessError(ApiCodes.NOT_FOUND, "The draft image file does not exist.", 404)
        return path, draft_item.get("image_name") or path.name
    image = next((item for item in folder.images if item.id == image_id), None)
    if image is None:
        raise BusinessError(ApiCodes.NOT_FOUND, "That image does not belong to this folder.", 404)
    source_path = resolve_image_file(folder, image)
    return ensure_work_copy(
        folder.id,
        user_id,
        image.id,
        image.image_name,
        source_path,
        official_ids=official_image_ids(folder),
    ), image.image_name


def validate_upload_filename(filename: str | None) -> str:
    """Extension gate for Replace/Insert. Content is checked separately."""
    name = safe_filename(filename or "")
    if Path(name).suffix.lower() not in UPLOAD_IMAGE_EXTENSIONS:
        allowed = "/".join(sorted(UPLOAD_IMAGE_EXTENSIONS))
        raise BusinessError(
            ApiCodes.BAD_REQUEST, f"Replace/Insert only supports {allowed} files", 400
        )
    return name


def replacement_image_name(existing_name: str, upload_name: str) -> str:
    """The name a replaced official image keeps.

    Page identity is the filename (see MODULE_1_QC_REWORK_DESIGN: "image_name =
    identity", and a recapture keeps the same one), so the stem is preserved and
    ordering with it. The extension follows the uploaded file, because keeping
    `.tif` on PNG bytes would leave a file whose name contradicts its content.
    """
    existing_suffix = Path(existing_name).suffix.lower()
    upload_suffix = Path(upload_name).suffix.lower()
    if existing_suffix == upload_suffix:
        return existing_name
    return f"{Path(existing_name).stem}{upload_suffix}"


def save_upload_to_temp(folder_id: int, user_id: str, file: UploadFile, filename: str) -> Path:
    upload_dir = draft_dir(folder_id, user_id) / "uploads"
    fs_path(upload_dir).mkdir(parents=True, exist_ok=True)
    target = (upload_dir / f"{int(now().timestamp() * 1000000)}_{safe_filename(filename)}").resolve()
    target.relative_to(draft_dir(folder_id, user_id).resolve())
    with fs_path(target).open("wb") as buffer:
        shutil.copyfileobj(file.file, buffer)
    # The extension is caller-supplied, so it proves nothing about the bytes.
    # Every later step (rotate, crop, thumbnail, commit) assumes a real image,
    # so reject anything Pillow can't parse here rather than letting a corrupt
    # file reach the official folder.
    try:
        with Image.open(fs_path(target)) as probe:
            probe.verify()
    except Exception as error:
        fs_path(target).unlink(missing_ok=True)
        raise BusinessError(ApiCodes.BAD_REQUEST, "The uploaded file is not a valid image.", 400) from error
    return target


DESKEW_MIN_DEGREES = 0.1
DESKEW_MAX_DEGREES = 10.0


def validate_deskew_degrees(degrees: float) -> None:
    """Bound the straighten step.

    Deskew is the fine correction after LWIP has already deskewed, not a second
    pass - and every application re-encodes and re-expands the canvas, so a big
    angle here degrades the page rather than fixing it. The reviewer sets the
    step, so this is the guard rail rather than the fixed 1 degree it replaced;
    a real turn is what the rotate endpoint is for.
    """
    if degrees == 0 or not (DESKEW_MIN_DEGREES <= abs(degrees) <= DESKEW_MAX_DEGREES):
        raise BusinessError(
            ApiCodes.BAD_REQUEST,
            f"Deskew must be between {DESKEW_MIN_DEGREES} and "
            f"{DESKEW_MAX_DEGREES} degrees in either direction.",
            400,
        )


# replay_pending_ops itself now lives in services/geometry_ops.py, so
# services/export.py can share it without importing this router. Previews
# still get it by injection rather than a direct import, to keep previews.py
# free of the draft model - see set_pending_op_replay's docstring.
set_pending_op_replay(replay_pending_ops)


_EXIF_GPS_IFD = 0x8825
_EXIF_ORIENTATION = 0x0112


def sanitise_capture_exif(exif_bytes: bytes) -> bytes:
    """EXIF with the two edits LWIP already makes, for a page LWIP never saw.

    Duplicated from LWIP's image_ops._source_metadata by the same convention
    that keeps lib/theme duplicated across the Flutter apps: the two are
    separate codebases with no shared library. CHANGE ONE, CHANGE THE OTHER.

    - Orientation forced to 1. LWIP only corrects a literal 0 (Xiaomi writes
      one, and it is not a legal value); here it is set to 1 whatever it was,
      because the caller has already run ImageOps.exif_transpose and the pixels
      ARE upright - leaving a 6 behind would rotate the page a second time in
      every viewer, which is the trap the caller's own comment warns about.
      Note exif_transpose does not clear the tag for an INVALID value: it
      rewrites only 2..8, so a 0 passes straight through the re-encode.
      It is not cosmetic either - libtiff REFUSES the value, so the export of
      any folder holding such a page fails outright (export.sanitise_tiff_tag).
    - GPS removed. It pins the building the records were photographed in and
      nothing downstream wants it. Everything else, MakerNote included, is
      carried verbatim.

    Only reached on a path that is re-encoding anyway, so it costs no extra
    generation of loss. Degrades to the original bytes if EXIF cannot be
    parsed - metadata is worth keeping, not worth failing an edit over.
    """
    if not exif_bytes:
        return exif_bytes
    try:
        exif = Image.Exif()
        exif.load(exif_bytes)
        if not exif:
            return exif_bytes
        # Materialise the nested IFDs before serialising: Exif.tobytes() emits
        # only the sub-IFDs it has already been asked for, so skipping this
        # silently drops ISO, exposure and lens data.
        for ifd in (0x8769, 0xA005):
            try:
                exif.get_ifd(ifd)
            except Exception:
                pass
        if _EXIF_GPS_IFD in exif:
            del exif[_EXIF_GPS_IFD]
        if exif.get(_EXIF_ORIENTATION) != 1:
            exif[_EXIF_ORIENTATION] = 1
        return exif.tobytes()
    except Exception:
        logger.warning("Could not sanitise EXIF; carrying it unchanged", exc_info=True)
        return exif_bytes


def apply_pending_ops(path: Path, ops: list[dict]) -> None:
    """Bake [ops] into the full-resolution file: ONE decode, ONE encode.

    Applying them as they were clicked cost a decode and a JPEG re-encode each
    (~380ms even for a crop, whose own pixel work is 13ms) and re-encoded the
    page once per edit, compounding generational loss. Replaying the chain in a
    single pass pays that once.

    This is the ONLY re-encode in the backend that reaches the client — insert,
    replace and the approval commit are all byte copies. It used to save at
    quality 95 with Pillow's DEFAULT chroma subsampling, which is 4:2:0: it
    halved the colour resolution of every page a reviewer touched, making an
    edited page measurably worse than an untouched one, and it dropped EXIF, ICC
    and DPI on the way through. Quality 100 with 4:4:4 matches what LWIP writes
    and what the camera itself encodes, so a page that passes through QC is not
    distinguishable from one that did not.
    """
    if not ops:
        return
    try:
        with Image.open(fs_path(path)) as src:
            frame = ImageOps.exif_transpose(src)
            original_format = src.format or path.suffix.lstrip(".").upper()
            save_format = "JPEG" if original_format == "JPG" else original_format
            # Read off the TRANSPOSED frame, not src: exif_transpose bakes the
            # orientation into the pixels and clears the tag, so carrying src's
            # own EXIF would rotate the page a second time in every viewer.
            # Captured before the replay, which rebuilds the frame and keeps
            # none of this.
            save_kwargs: dict = {"format": save_format}
            for key in ("exif", "icc_profile", "dpi"):
                value = frame.info.get(key)
                if value:
                    save_kwargs[key] = value
            # An inserted page has never been through LWIP, so nothing has
            # corrected its Orientation or dropped its GPS yet. Doing it here
            # covers every page this function touches, whatever its provenance.
            if save_kwargs.get("exif"):
                save_kwargs["exif"] = sanitise_capture_exif(save_kwargs["exif"])
            frame = replay_pending_ops(frame, ops)
            temp_path = path.with_name(f".{path.stem}.ops_tmp{path.suffix}")
            if save_format == "JPEG":
                if frame.mode not in {"RGB", "L"}:
                    frame = frame.convert("RGB")
                save_kwargs["quality"] = 100
                save_kwargs["subsampling"] = 0
                save_kwargs["optimize"] = True
            frame.save(fs_path(temp_path), **save_kwargs)
        os.replace(fs_path(temp_path), fs_path(path))
    except UnidentifiedImageError as error:
        raise BusinessError(ApiCodes.BAD_REQUEST, "Unsupported image format.", 400) from error


def ops_to_bake(folder: CaptureFolder, manifest: dict | None, image_id: int) -> list[dict]:
    """What a flush must bake into this image's work copy - not just what is
    still pending.

    LWIP's baseline and any earlier committed round live outside the page file
    (see services/qc_ops_store), so a flush that only replayed `pending_ops`
    would produce a work copy missing them entirely. An already-`baked` item
    is the one exception: its pixels already hold the full chain up to the
    last flush, so baking again must replay only what has piled up SINCE then
    - the fresh `pending_ops` - or the baseline and prior rounds would be
    applied a second time.

    Insert/replace/restored items never fold in a baseline: an inserted or
    replaced page is a different capture LWIP never measured, and a restored
    item's baseline is nothing more than the baseline itself (see
    commit_current_draft's `restored` handling).
    """
    item = draft_image_item(manifest, image_id)
    pending = pending_ops_of(manifest, image_id)
    if image_id < 0 or (item and item.get("status") in {"inserted", "replaced"}):
        return pending
    if item and item.get("baked"):
        return pending
    image = next((entry for entry in folder.images if entry.id == image_id), None)
    if image is None:
        return pending
    folder_path = to_local(folder.folder_path or "")
    if item and item.get("restored"):
        return baseline_ops(folder_path, image.image_name)
    return effective_ops(folder_path, image.image_name, pending)


def flush_pending_ops(folder: CaptureFolder, user_id: str, image_id: int, work_path: Path) -> None:
    """Bake this image's full deferred chain into its working copy.

    Luminance's pre-step, and its ONLY remaining caller: a tone correction
    needs real, upright, cropped pixels to operate on, so whatever would
    otherwise stay deferred forever - LWIP's baseline, earlier committed
    rounds, this session's pending ops - has to become real here. That is also
    why the result is marked `baked` (see qc_drafts.mark_baked): from this
    point the work copy's PIXELS are the source of truth for this image, not
    qc_ops.json, and commit_current_draft has to know that.

    Approval itself no longer calls this. A page whose edits are pure geometry
    - the overwhelming majority - must reach the delivered file as data, never
    as re-encoded pixels; see commit_current_draft.
    """
    manifest = read_manifest(folder.id, user_id)
    ops = ops_to_bake(folder, manifest, image_id)
    if not ops:
        return
    apply_pending_ops(work_path, ops)
    clear_pending_ops(folder.id, user_id, image_id)
    mark_baked(folder.id, user_id, image_id)


def batch_image_workers(count: int) -> int:
    """Threads to run a batch image operation across.

    THREADS, not processes. Pillow releases the GIL for decode, resample and
    encode, which is where all the time goes: measured on an 18 MP page,
    12 deskews drop from 16.9s to 3.9s. Processes would parallelise a little
    better still, but every one of them pays a Windows interpreter spawn and
    has to pickle its way in and out - the same reason `export.py` keeps its
    pool long-lived and refuses to use it for small batches.

    Capped at 8 because MEMORY is the binding constraint here, not cores: each
    worker holds a decoded page (~56 MB at 3566x5206 RGB) plus the expanded
    rotation of it, and an export may be converting on the same station at the
    same time.
    """
    if count <= 1:
        return 1
    return max(1, min(count, 8, os.cpu_count() or 2))


def run_image_batch(operation: Callable[[Any], None], items: Sequence[Any]) -> None:
    """Apply [operation] to every item, in parallel where it is worth it.

    Order does not matter: each call reads and writes one page's own working
    copy, and the caller has already marked every one of them dirty. A failure
    is re-raised as-is so the endpoints keep their existing error handling.
    """
    if not items:
        return
    workers = batch_image_workers(len(items))
    if workers == 1:
        for item in items:
            operation(item)
        return
    with ThreadPoolExecutor(max_workers=workers) as pool:
        # list() so an exception in any worker surfaces here rather than being
        # swallowed by a lazy map that nobody iterates.
        list(pool.map(operation, items))


def deleted_root(folder_id: int, user_id: str) -> Path:
    path = draft_dir(folder_id, user_id).parent.parent / "qc_deleted" / str(folder_id) / str(int(now().timestamp() * 1000))
    fs_path(path).mkdir(parents=True, exist_ok=True)
    return path


def child_group_id(parent_group_id: str | None, index: int) -> str | None:
    """The `group_id` for child folder [index] of a Separation split (1-based).

    `capture_folders.group_id` carries a UNIQUE constraint, so children cannot
    inherit the parent's value verbatim: the second child would collide, and the
    parent is only soft-deleted so its row still holds the original. Splitting it
    with the same `_001`/`_002` suffix `folder_name` already uses keeps the two
    columns in step.

    A parent with no group_id yields None for every child — PostgreSQL treats
    NULLs as distinct under a plain UNIQUE, so those never collide.
    """
    if parent_group_id is None or not parent_group_id.strip():
        return None
    return f"{parent_group_id}_{index:03d}"


def unique_official_name(folder: CaptureFolder, preferred_name: str, existing_names: set[str]) -> str:
    preferred = safe_filename(preferred_name)
    stem = Path(preferred).stem
    suffix = Path(preferred).suffix or ".tif"
    candidate = preferred
    index = 1
    official_dir = to_local(folder.folder_path or "").resolve()
    while candidate in existing_names or fs_path(official_dir / candidate).exists():
        candidate = f"{stem}_{index}{suffix}"
        index += 1
    existing_names.add(candidate)
    return candidate


def apply_separation_commit(
    db,
    folder: CaptureFolder,
    marker_ids: list[int],
    ordered_ids: list[int],
    commit_time: datetime,
) -> SeparationFileTransaction:
    marker_set = set(marker_ids)
    if len(marker_set) < 2:
        raise ValueError("Separation needs at least two start pages.")
    if ordered_ids and ordered_ids[0] not in marker_set:
        raise ValueError("The first image must be marked as a start page for separation.")

    groups: list[list[int]] = []
    current_group: list[int] = []
    for image_id in ordered_ids:
        if image_id in marker_set and current_group:
            groups.append(current_group)
            current_group = []
        current_group.append(image_id)
    if current_group:
        groups.append(current_group)
    if len(groups) < 2:
        raise ValueError("Separation must produce at least two child folders.")

    max_seq = db.scalar(select(func.max(CaptureFolder.folder_seq)).where(CaptureFolder.box_id == folder.box_id)) or 0
    image_lookup = {
        image.id: image
        for image in db.scalars(
            select(CaptureImage).where(
                CaptureImage.id.in_(ordered_ids),
                CaptureImage.folder_id == folder.id,
            )
        ).all()
    }
    if set(image_lookup) != set(ordered_ids):
        raise ValueError("One or more images do not belong to this folder.")
    if not folder.folder_path:
        raise ValueError("The folder's source image directory is not configured.")

    grouped_names = [
        [safe_filename(image_lookup[image_id].image_name) for image_id in group]
        for group in groups
    ]
    file_transaction = SeparationFileTransaction(
        to_local(folder.folder_path),
        to_local(folder.thumbnail_path) if folder.thumbnail_path else None,
        grouped_names,
    )
    file_transaction.apply()

    try:
        for index, group in enumerate(groups, start=1):
            file_group = file_transaction.groups[index - 1]
            child = CaptureFolder(
                group_id=child_group_id(folder.group_id, index),
                folder_name=f"{folder.folder_name}_{index:03d}",
                box_id=folder.box_id,
                device_id=folder.device_id,
                folder_seq=max_seq + index,
                cover_tag=folder.cover_tag,
                image_tags=folder.image_tags,
                title=folder.title,
                volume=folder.volume,
                start_date=folder.start_date,
                end_date=folder.end_date,
                archival_ref_no=folder.archival_ref_no,
                record_type=folder.record_type,
                place=folder.place,
                language=folder.language,
                record_custodian=folder.record_custodian,
                capture_operator_id=folder.capture_operator_id,
                capture_operator_name=folder.capture_operator_name,
                digitizing_entity=folder.digitizing_entity,
                source_created_at=commit_time,
                source_updated_at=commit_time,
                updated_at=commit_time,
                is_deleted=False,
                client_qc_status=folder.client_qc_status,
                client_rework=False,
                is_deskewed=folder.is_deskewed,
                is_cropped=folder.is_cropped,
                is_created_thumbnail=folder.is_created_thumbnail,
                # Written back in LWCAM's own path form — LWCAM and LWIP read these.
                folder_path=to_db(file_group.final_image_dir),
                thumbnail_path=(
                    to_db(file_group.final_thumbnail_dir)
                    if file_group.final_thumbnail_dir
                    else None
                ),
                qc_status="PENDING",
                is_tif_converted=folder.is_tif_converted,
            )
            db.add(child)
            db.flush()
            for image_id in group:
                image_lookup[image_id].folder_id = child.id

        folder.qc_status = "PASS"
        folder.qc_locked_by = None
        folder.qc_locked_at = None
        folder.is_deleted = True
        folder.deleted_at = commit_time
        folder.folder_path = None
        folder.thumbnail_path = None
        db.flush()
    except Exception:
        try:
            file_transaction.rollback()
        except SeparationFileError as rollback_error:
            raise SeparationFileError(
                f"Database separation failed and rolling back the files also failed: {rollback_error}"
            ) from rollback_error
        raise
    return file_transaction


def _stage_sibling(path: Path, tag: str) -> Path:
    """A hidden sibling of [path] - same directory, same suffix.

    Same directory keeps every finalize/abort rename on one filesystem (a
    cross-volume os.replace fails outright on Windows), and the real suffix
    keeps it readable as an image (Pillow, via generate_thumbnail_file, keys
    off the extension) while it is still not the visible file.
    """
    return path.with_name(f".{path.stem}.{tag}{path.suffix}")


def commit_current_draft(
    folder: CaptureFolder,
    user_id: str,
) -> tuple[SeparationFileTransaction | None, Callable[[], None], Callable[[], None]]:
    """Apply the current draft's image edits to the folder's official files.

    Returns (separation_transaction, finalize, abort). Every file this touches
    is staged under a hidden sibling name during the loop below and is NEVER
    written under its real, visible name here - that only happens in
    [finalize], which the caller must run strictly after its db.commit()
    succeeds. If the commit raises instead, the caller runs [abort]: every
    staged file is either a fresh temp copy nothing else references yet, or
    the pre-existing official file renamed in place (same directory, so the
    rename is one cheap, trivially-reversible filesystem op). This is the
    smallest ordering that survives a DB commit failing on a two-PC site -
    deliberately not a general transaction framework, just "don't make a file
    change visible until the row behind it is durable."
    """
    commit_time = now()
    db = object_session(folder)
    if db is None:
        raise ValueError("Folder is not attached to a database session")
    manifest = read_manifest(folder.id, user_id)
    if not manifest:
        return None, (lambda: None), (lambda: None)
    images_by_id = {image.id: image for image in folder.images}
    template = metadata_template(folder)
    has_metadata_changes = metadata_dirty_from_manifest(manifest)
    committed: list[CaptureImage] = []
    id_map: dict[int, int] = {}
    # qc_ops.json is ONE shared file for the whole folder, so its writes
    # accumulate here instead of hitting disk per image (like write_image_ops
    # would) - it gets exactly one staged temp file and one finalize/abort
    # step, same as every page file below.
    qc_ops_updates: dict[str, dict] = {}
    qc_ops_deletions: set[str] = set()
    folder_path = to_local(folder.folder_path or "").resolve()
    if not fs_path(folder_path).is_dir():
        raise ValueError("Folder official image directory is missing")
    existing_names = {image.image_name for image in folder.images}
    thumbnail_dir = to_local(folder.thumbnail_path).resolve() if folder.thumbnail_path else None
    if thumbnail_dir:
        fs_path(thumbnail_dir).mkdir(parents=True, exist_ok=True)

    finalize_steps: list[Callable[[], None]] = []
    abort_steps: list[Callable[[], None]] = []

    def defer_write(source: Path, final_path: Path) -> Path:
        """Copy [source]'s bytes in now; queue the swap to [final_path] for
        finalize, and the temp copy's removal for abort. Returns the staged
        path, e.g. so a thumbnail can be rendered from the new bytes before
        they are visible under the real name."""
        staged = _stage_sibling(final_path, "draft_commit_tmp")
        shutil.copy2(fs_path(source), fs_path(staged))
        abort_steps.append(lambda: fs_path(staged).unlink(missing_ok=True))
        finalize_steps.append(lambda: os.replace(fs_path(staged), fs_path(final_path)))
        return staged

    def defer_retirement(path: Path, target_dir: Path) -> None:
        """Move an existing file out of its visible name now (same directory
        rename - cheap and reversible), and queue its move into [target_dir] -
        the same qc_deleted archive a real delete uses - for finalize."""
        staged = _stage_sibling(path, "qc_deleted_pending")
        os.replace(fs_path(path), fs_path(staged))
        abort_steps.append(lambda: os.replace(fs_path(staged), fs_path(path)))
        finalize_steps.append(
            lambda: shutil.move(str(fs_path(staged)), str(fs_path(target_dir / path.name)))
        )

    for raw_id, item in list((manifest.get("images") or {}).items()):
        image_id = int(raw_id)
        status = item.get("status")
        if status == "deleted" and image_id > 0:
            image = images_by_id.get(image_id)
            if image is None:
                continue
            # The file may already be gone - a page inserted during QC does not
            # survive a capture rework, so a row can outlive its file. Deleting
            # that row IS the recovery, so there is nothing to archive and
            # nothing here should fail.
            official_path = expected_image_path(folder, image)
            target_dir = deleted_root(folder.id, user_id)
            if fs_path(official_path).is_file():
                defer_retirement(official_path, target_dir)
            thumb = thumbnail_target_path(folder, image)
            if thumb and fs_path(thumb).is_file():
                defer_retirement(thumb, target_dir)
            qc_ops_deletions.add(image.image_name)
            db.delete(image)
            committed.append(image)
            continue
        if status == "inserted" and image_id < 0:
            work_path = Path(item["work_path"]).resolve()
            if not fs_path(work_path).is_file():
                raise FileNotFoundError(f"Draft image missing: {work_path}")
            image_name = unique_official_name(folder, item.get("image_name") or work_path.name, existing_names)
            official_path = (folder_path / image_name).resolve()
            staged = defer_write(work_path, official_path)
            # An inserted page's work copy is a plain copy of the upload (see
            # qc_drafts.create_inserted_image), so any rotate or crop the
            # reviewer made is still only pending. It has to become committed
            # data here or it dies with the draft - which is exactly what the
            # preview cannot show you, since previews DO replay pending.
            # ignore_lwip: this page was never in LWIP's manifest, and a name
            # it happens to reuse must not drag a dead baseline in with it.
            inserted_ops = pending_ops_of(manifest, image_id)
            qc_ops_updates[image_name] = {"ops": inserted_ops, "ignore_lwip": True}
            new_image = CaptureImage(
                image_name=image_name,
                device_id=folder.device_id,
                folder_id=folder.id,
                file_format=official_path.suffix.lstrip(".").lower() or "tif",
                image_created_at=commit_time,
                image_updated_at=commit_time,
            )
            db.add(new_image)
            db.flush()
            id_map[image_id] = new_image.id
            images_by_id[new_image.id] = new_image
            if thumbnail_dir:
                target_thumb = thumbnail_dir / image_name
                staged_thumb = _stage_sibling(target_thumb, "draft_commit_tmp")
                if generate_thumbnail_file(staged, staged_thumb, inserted_ops) is not None:
                    abort_steps.append(lambda s=staged_thumb: fs_path(s).unlink(missing_ok=True))
                    finalize_steps.append(
                        lambda s=staged_thumb, o=target_thumb: os.replace(fs_path(s), fs_path(o))
                    )
            committed.append(new_image)
            continue
        if image_id > 0 and (item.get("dirty") or status == "replaced" or item.get("restored")):
            image = images_by_id.get(image_id)
            if image is None:
                raise ValueError(f"Draft image no longer belongs to folder: {image_id}")
            # A replacement or a luminance bake already holds final pixels -
            # those still land on disk exactly as before. Everything else
            # (the overwhelming majority: pure deskew/rotate/crop, or a bare
            # restore) must leave the delivered page file BYTE IDENTICAL - see
            # the module docstring - so its geometry becomes qc_ops.json data
            # instead, replayed once at export.
            full_pixel_commit = status == "replaced" or bool(item.get("baked"))

            if full_pixel_commit:
                work_path = Path(item["work_path"]).resolve()
                if not fs_path(work_path).is_file():
                    raise FileNotFoundError(f"Draft image missing: {work_path}")
                # A baked item can still pick up a geometry op or two AFTER its
                # last flush (say, a rotate clicked once more after luminance):
                # those never got baked in, and deferring them now would mean
                # replaying LWIP's baseline a second time on top of pixels that
                # already contain it (see ops_to_bake). A page whose pixels are
                # already a corrected product is the one case where baking a
                # little more geometry costs nothing new.
                deferred_ops: list[dict] = []
                if item.get("baked"):
                    leftover = pending_ops_of(manifest, image_id)
                    if leftover:
                        apply_pending_ops(work_path, leftover)
                else:
                    # Not baked, so the work copy holds the upload and nothing
                    # else: geometry the reviewer added after the replace is
                    # still pending, and dropping it here is what made an edit
                    # to a replaced page vanish between QC and the export.
                    # Deferred rather than baked - a replacement is delivered
                    # bytes too, and must not be re-encoded to carry a rotate.
                    deferred_ops = pending_ops_of(manifest, image_id)
                # expected_, not resolve_: replacing a page whose file has gone is
                # exactly when a reviewer reaches for Replace, and demanding the
                # original still exist made that the one repair they could not make.
                # The work copy is what gets published either way.
                official_path = expected_image_path(folder, image)
                old_thumbnail = thumbnail_target_path(folder, image)
                # replacement_image_name (see replace_image) keeps the OLD
                # extension when it matches the upload and follows the upload's
                # extension otherwise, recording the result in the draft item's
                # image_name. A page replaced across formats (.tif -> .jpg) must
                # therefore land under a NEW filename - reusing official_path here
                # left a `.tif`-named file holding JPEG bytes, with the row still
                # claiming file_format='tif'.
                new_name = item.get("image_name") or image.image_name
                renamed = new_name != image.image_name
                final_path = (official_path.parent / new_name).resolve() if renamed else official_path
                staged = defer_write(work_path, final_path)
                if renamed:
                    image.image_name = new_name
                    image.file_format = final_path.suffix.lstrip(".").lower() or image.file_format
                    if fs_path(official_path).is_file() or (
                        old_thumbnail is not None and fs_path(old_thumbnail).is_file()
                    ):
                        stale_dir = deleted_root(folder.id, user_id)
                        if fs_path(official_path).is_file():
                            defer_retirement(official_path, stale_dir)
                        if old_thumbnail is not None and fs_path(old_thumbnail).is_file():
                            defer_retirement(old_thumbnail, stale_dir)
                target_thumbnail = thumbnail_target_path(folder, image)
                if target_thumbnail is not None:
                    staged_thumbnail = _stage_sibling(target_thumbnail, "draft_commit_tmp")
                    if generate_thumbnail_file(staged, staged_thumbnail, deferred_ops) is None:
                        fs_path(staged_thumbnail).unlink(missing_ok=True)
                        raise ValueError(f"Thumbnail generation failed: {target_thumbnail}")
                    abort_steps.append(lambda s=staged_thumbnail: fs_path(s).unlink(missing_ok=True))
                    finalize_steps.append(
                        lambda s=staged_thumbnail, o=target_thumbnail: os.replace(fs_path(s), fs_path(o))
                    )
                # The work copy's pixels already ARE the whole picture - LWIP's
                # baseline (if any applied), every earlier committed round, and
                # this session's edits. Nothing left to describe as data, and
                # ignore_lwip=True stops a future read from replaying the
                # baseline on top of pixels that already contain it.
                qc_ops_updates[image.image_name] = {"ops": deferred_ops, "ignore_lwip": True}
            else:
                pending = pending_ops_of(manifest, image_id)
                if item.get("restored"):
                    # "Original" is LWIP's own straightened baseline now, not
                    # whatever an earlier approval round committed - drop that
                    # history rather than layering under it.
                    new_ops: list[dict] = list(pending)
                    new_ignore = False
                else:
                    new_ops = qc_ops_committed(folder_path, image.image_name) + pending
                    new_ignore = qc_ops_ignore_lwip(folder_path, image.image_name)
                qc_ops_updates[image.image_name] = {"ops": new_ops, "ignore_lwip": new_ignore}
                target_thumbnail = thumbnail_target_path(folder, image)
                if target_thumbnail is not None:
                    # LWIP's own thumbnail is only right until now - regenerate
                    # from the SAME chain export will replay, so a read-only
                    # viewer sees the approved geometry too without a preview
                    # render (see previews.generate_thumbnail_file). Composed
                    # from the in-memory new_ops/new_ignore, NOT a fresh
                    # effective_ops() read - qc_ops.json on disk is still the
                    # PRE-commit state until finalize() runs below.
                    render_ops = ([] if new_ignore else baseline_ops(folder_path, image.image_name)) + new_ops
                    source_path = expected_image_path(folder, image)
                    staged_thumbnail = _stage_sibling(target_thumbnail, "draft_commit_tmp")
                    if generate_thumbnail_file(source_path, staged_thumbnail, render_ops) is not None:
                        abort_steps.append(lambda s=staged_thumbnail: fs_path(s).unlink(missing_ok=True))
                        finalize_steps.append(
                            lambda s=staged_thumbnail, o=target_thumbnail: os.replace(fs_path(s), fs_path(o))
                        )
            image.image_updated_at = commit_time
            committed.append(image)

    if has_metadata_changes:
        apply_metadata_to_folder(folder, metadata_values_from_manifest(manifest), template)

    ordered_ids = [id_map.get(int(item), int(item)) for item in visible_order(manifest, official_image_ids(folder))]
    db.flush()
    latest_images = {image.id: image for image in images_by_id.values() if image.id in ordered_ids}
    for index, image_id in enumerate(ordered_ids):
        image = latest_images.get(image_id)
        if image:
            image.image_created_at = commit_time + timedelta(seconds=index)

    markers = [id_map.get(int(item), int(item)) for item in manifest.get("separation_markers", [])]
    separation_transaction = None
    if markers:
        if folder.qc_locked_by != user_id:
            raise ValueError("This task is no longer assigned to you.")
        separation_transaction = apply_separation_commit(
            db,
            folder,
            markers,
            ordered_ids,
            commit_time,
        )

    if committed or has_metadata_changes or manifest.get("order") or markers:
        folder.is_created_thumbnail = True
        folder.source_updated_at = commit_time
        folder.updated_at = commit_time

    if qc_ops_updates or qc_ops_deletions:
        # One shared file for the whole folder gets exactly one staged write,
        # merged over whatever is on disk NOW - reading it here rather than
        # per image is also why the geometry-only branch above composes its
        # own render_ops instead of calling effective_ops() again.
        qc_ops_data = read_qc_ops(folder_path)
        qc_ops_data.setdefault("version", 1)
        qc_ops_images = qc_ops_data.get("images")
        if not isinstance(qc_ops_images, dict):
            qc_ops_images = {}
            qc_ops_data["images"] = qc_ops_images
        for name in qc_ops_deletions:
            qc_ops_images.pop(name, None)
        qc_ops_images.update(qc_ops_updates)
        qc_ops_target = qc_ops_path(folder_path)
        staged_qc_ops = _stage_sibling(qc_ops_target, "draft_commit_tmp")
        fs_path(staged_qc_ops).write_text(
            json.dumps(qc_ops_data, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        abort_steps.append(lambda s=staged_qc_ops: fs_path(s).unlink(missing_ok=True))
        finalize_steps.append(lambda s=staged_qc_ops, o=qc_ops_target: os.replace(fs_path(s), fs_path(o)))

    def finalize() -> None:
        for step in finalize_steps:
            step()

    def abort() -> None:
        # Reverse order: undo the most recently staged change first, though
        # each step only ever touches its own file so the order is not load
        # bearing. Broad catch - this already runs from an except block, and
        # one stuck temp file must not shadow the real error or leave the rest
        # of the batch un-restored.
        for step in reversed(abort_steps):
            try:
                step()
            except Exception:
                logger.exception("QC draft commit abort step failed; folder=%s", folder.id)

    return separation_transaction, finalize, abort


@router.get("", response_model=ApiResponse[PageResult[MetadataQcTaskVO]])
def list_tasks(
    current_user: QcUser,
    db: DbSession,
    scope: str = Query("pending", pattern="^(pending|mine|completed)$"),
    q: str | None = Query(None, max_length=255),
    page: int = Query(1, ge=1),
    size: int = Query(20, ge=1, le=200),
) -> ApiResponse[PageResult[MetadataQcTaskVO]]:
    """List QC-visible folders by page, scoped to pending, mine or completed."""
    project_ids = project_ids_for_user(db, current_user.id)
    if not project_ids:
        return ok(PageResult(records=[], total=0, page=page, size=size))

    statement = select(CaptureFolder).options(*folder_options()).where(*visible_folder_conditions(project_ids))

    if scope == "pending":
        if ai_queue_gating_active():
            # Withhold folders whose review has not finished. Paged in Python
            # over the allowed ids, because filtering AFTER a SQL page would
            # hand back short pages and a total that counts hidden rows.
            allowed = ai_visible_pending_ids(db, project_ids)
            page_ids = allowed[(page - 1) * size:(page - 1) * size + size]
            if not page_ids:
                return ok(PageResult(records=[], total=len(allowed), page=page, size=size))
            by_id = {
                folder.id: folder
                for folder in db.scalars(
                    select(CaptureFolder)
                    .options(*folder_options())
                    .where(CaptureFolder.id.in_(page_ids))
                ).unique().all()
            }
            return ok(PageResult(
                records=[
                    vo
                    for vo in (
                        task_vo_or_skip(db, by_id[folder_id], current_user.user_id)
                        for folder_id in page_ids
                        if folder_id in by_id
                    )
                    if vo is not None
                ],
                total=len(allowed),
                page=page,
                size=size,
            ))
        statement = statement.where(
            func.lower(CaptureFolder.qc_status) == "pending",
            CaptureFolder.qc_locked_by.is_(None),
        )
        statement = statement.order_by(CaptureFolder.source_created_at.asc().nullslast(), CaptureFolder.id.asc())
    elif scope == "mine":
        statement = statement.where(
            func.lower(CaptureFolder.qc_status) == "pending",
            CaptureFolder.qc_locked_by == current_user.user_id,
        )
        statement = statement.order_by(CaptureFolder.qc_locked_at.desc().nullslast(), CaptureFolder.id.asc())
    else:  # completed
        statement = statement.where(
            func.lower(CaptureFolder.qc_status).in_(["pass", "rework"]),
        )
        clause = completed_search_clause(q)
        if clause is not None:
            # Filtered in SQL, BEFORE the page is taken: filtering the page in
            # the client would return short pages and a total that counts rows
            # the operator cannot see.
            statement = statement.where(clause)
        statement = statement.order_by(CaptureFolder.updated_at.desc())

    total = db.scalar(select(func.count()).select_from(statement.order_by(None).subquery())) or 0
    folders = db.scalars(statement.offset((page - 1) * size).limit(size)).unique().all()

    # Serves plain pending, mine AND completed - the three non-gated scopes
    # share this one comprehension.
    return ok(PageResult(
        records=[
            vo
            for vo in (
                task_vo_or_skip(db, folder, current_user.user_id)
                for folder in folders
            )
            if vo is not None
        ],
        total=total,
        page=page,
        size=size,
    ))


def task_vo_or_skip(db: Session, folder: CaptureFolder, user_id: str):
    """[to_task_vo] for a list page, or None if this one folder cannot build.

    list_tasks used to build every folder's view model eagerly, so ONE bad
    folder failed the whole page response. On 2026-09-09 a folder dated 1877
    serialised with a sub-minute UTC offset that Pydantic refuses, and the
    Completed tab went completely dark - 19 of the 20 rows were perfectly
    serviceable. That specific cause is fixed (see rfc3339), but any future
    per-folder data fault would do the same thing.

    Broad catch ON PURPOSE. to_task_vo cannot raise BusinessError as the code
    stands - safe_filename's raise is already swallowed by image_available_in,
    and resolve_image_file is no longer on this path - so the realistic failure
    is a Pydantic ValidationError, or a KeyError/AttributeError on malformed
    data. A narrow catch would miss exactly the unforeseen case this exists for.

    NOTE the page then returns fewer records than `total`, which the two
    comments in list_tasks argue AGAINST. Those govern deliberate FILTERING,
    where a mismatched total is a systematic lie an operator can never
    reconcile. This is an exceptional fault, and the alternative is not an
    honest total but no rows at all - so `total` keeps answering "how much work
    exists" while the row count answers "how much can be shown".
    """
    try:
        return to_task_vo(db, folder, user_id)
    except Exception as error:  # noqa: BLE001 - deliberately broad, see above
        logger.exception(
            "Task list skipped a folder; folder_id=%s error_type=%s",
            folder.id,
            type(error).__name__,
        )
        return None


@router.post("/claim-next", response_model=ApiResponse[MetadataQcTaskVO])
def claim_next(current_user: QcUser, db: DbSession) -> ApiResponse[MetadataQcTaskVO]:
    """Atomically claim the oldest reviewable folder within the user's project scope."""
    project_ids = project_ids_for_user(db, current_user.id)
    if not project_ids:
        raise BusinessError(ApiCodes.NOT_FOUND, "There are no QC tasks available to claim.", 404)

    # Check if user already has a claimed folder
    existing = db.scalar(
        select(CaptureFolder)
        .options(*folder_options())
        .where(
            *visible_folder_conditions(project_ids),
            func.lower(CaptureFolder.qc_status) == "pending",
            CaptureFolder.qc_locked_by == current_user.user_id,
        )
        .order_by(CaptureFolder.qc_locked_at.desc().nullslast())
        .limit(1)
    )
    if existing:
        db.commit()
        return ok(to_task_vo(db, existing, current_user.user_id))

    # Claim next available folder. Restricted to what the queue is showing:
    # handing out a folder the list is withholding would let "Take next" jump
    # straight past the review the operator is meant to be waiting for.
    claimable_conditions = [
        *visible_folder_conditions(project_ids),
        func.lower(CaptureFolder.qc_status) == "pending",
        CaptureFolder.qc_locked_by.is_(None),
    ]
    if ai_queue_gating_active():
        allowed = ai_visible_pending_ids(db, project_ids)
        if not allowed:
            db.commit()
            raise BusinessError(ApiCodes.NOT_FOUND, "There are no QC tasks available to claim.", 404)
        claimable_conditions.append(CaptureFolder.id.in_(allowed))
    folder = db.scalar(
        select(CaptureFolder)
        .options(*folder_options())
        .where(*claimable_conditions)
        .order_by(CaptureFolder.source_created_at.asc().nullslast(), CaptureFolder.id.asc())
        .with_for_update(skip_locked=True)
        .limit(1)
    )
    if folder is None:
        db.commit()
        raise BusinessError(ApiCodes.NOT_FOUND, "There are no QC tasks available to claim.", 404)

    folder.qc_locked_by = current_user.user_id
    folder.qc_locked_at = now()
    db.commit()
    write_qc_audit("claim_next", current_user.user_id, folder.id, result="success")

    refreshed = folder_or_404(db, folder.id, current_user.id)
    return ok(to_task_vo(db, refreshed, current_user.user_id))


@router.get("/{folder_id}", response_model=ApiResponse[MetadataQcTaskVO])
def get_detail(folder_id: int, current_user: QcUser, db: DbSession) -> ApiResponse[MetadataQcTaskVO]:
    """Return the review detail for a folder the QC user may access."""
    folder = folder_or_404(db, folder_id, current_user.id)
    write_qc_audit("open", current_user.user_id, folder.id, result="success")
    return ok(to_task_vo(db, folder, current_user.user_id))


@router.post("/{folder_id}/claim", response_model=ApiResponse[MetadataQcTaskVO])
def claim_task(folder_id: int, current_user: QcUser, db: DbSession) -> ApiResponse[MetadataQcTaskVO]:
    """Claim a specific folder."""
    project_ids = project_ids_for_user(db, current_user.id)
    if not project_ids:
        raise BusinessError(ApiCodes.NOT_FOUND, "There are no QC tasks available to claim.", 404)

    existing = db.scalar(
        select(CaptureFolder)
        .where(
            *visible_folder_conditions(project_ids),
            func.lower(CaptureFolder.qc_status) == "pending",
            CaptureFolder.qc_locked_by == current_user.user_id,
            CaptureFolder.id != folder_id,
        )
        .order_by(CaptureFolder.qc_locked_at.desc().nullslast(), CaptureFolder.id.asc())
        .limit(1)
    )
    if existing:
        raise BusinessError(ApiCodes.CONFLICT, "You already have a claimed task. Finish it first.", 409)

    folder = folder_or_404(db, folder_id, current_user.id, lock=True)

    # Already claimed by this user?
    if folder.qc_locked_by == current_user.user_id:
        db.commit()
        return ok(to_task_vo(db, folder, current_user.user_id))

    # Claimed by someone else?
    if folder.qc_locked_by is not None:
        db.rollback()
        raise BusinessError(ApiCodes.CONFLICT, "Another reviewer has already claimed this task.", 409)

    # Wrong status?
    if folder.qc_status.lower() != "pending":
        db.rollback()
        raise BusinessError(ApiCodes.CONFLICT, "This task's status has changed and it can no longer be claimed.", 409)

    # A draft present at claim time is stale by construction: release, reject
    # and approve all discard, so anything left is from a crash or an admin
    # force-release - and may predate a capture rework of these very files.
    try:
        discard_draft(folder.id, current_user.user_id)
    except Exception:
        logger.exception("QC stale draft cleanup failed at claim; folder=%s", folder_id)
    folder.qc_locked_by = current_user.user_id
    folder.qc_locked_at = now()
    try:
        db.commit()
    except IntegrityError as error:
        db.rollback()
        raise BusinessError(ApiCodes.CONFLICT, "You already have a claimed task. Finish it first.", 409) from error
    write_qc_audit("claim", current_user.user_id, folder.id, result="success")

    return ok(to_task_vo(db, folder_or_404(db, folder_id, current_user.id), current_user.user_id))


@router.post("/{folder_id}/release", response_model=ApiResponse[None])
def release_task(folder_id: int, current_user: QcUser, db: DbSession) -> ApiResponse[None]:
    """Release a claimed task, putting it back in the pending queue."""
    folder = folder_or_404(db, folder_id, current_user.id, lock=True)
    assert_lock_owner(folder, current_user.user_id)

    manifest = read_manifest(folder.id, current_user.user_id)
    folder.qc_locked_by = None
    folder.qc_locked_at = None
    db.commit()
    cancel_manual_ai_after_release(folder.id)
    try:
        discard_draft(folder.id, current_user.user_id)
    except Exception:
        logger.exception("QC draft cleanup failed after release; folder=%s", folder_id)
    write_qc_audit(
        "release",
        current_user.user_id,
        folder.id,
        draft_summary=draft_summary(manifest),
        result="success",
    )
    return ok(None)


@router.post("/{folder_id}/approve", response_model=ApiResponse[None])
def approve_task(folder_id: int, request: ReviewRequest, current_user: QcUser, db: DbSession) -> ApiResponse[None]:
    """Approve the folder as a whole."""
    folder = folder_or_404(db, folder_id, current_user.id, lock=True)
    assert_lock_owner(folder, current_user.user_id)

    verify_reviewable_folder(folder, request.sourceHash)
    manifest = read_manifest(folder.id, current_user.user_id)
    template = metadata_template(folder)
    effective_metadata = effective_metadata_snapshot(folder, manifest, template)
    validate_metadata_for_approval(effective_metadata, template)

    # Every page the APPROVAL will publish has to be readable - which is not
    # the same as every row currently in the database. The draft is applied by
    # commit_current_draft below, so a page the reviewer deleted is still a row
    # here, and refusing on it made a missing page unfixable: deleting it was
    # the repair, and the repair could never be approved.
    #
    # Skipped, therefore: rows the draft deletes, and rows the draft replaces or
    # edits, whose work copy is what gets published rather than the file here.
    if not visible_order(manifest, [image.id for image in folder.images]):
        raise BusinessError(ApiCodes.BAD_REQUEST, "The folder has no images and cannot be approved.")
    for image in folder.images:
        item = draft_image_item(manifest, image.id)
        if item and (item.get("status") == "deleted" or item.get("work_path")):
            continue
        resolve_image_file(folder, image)

    separation_transaction = None
    finalize_files: Callable[[], None] = lambda: None
    abort_files: Callable[[], None] = lambda: None
    try:
        # No flush here any more. A pending deskew/rotate/crop must reach the
        # delivered file as DATA - qc_ops.json, replayed at export - never as
        # re-encoded pixels; commit_current_draft below is what writes it.
        # Anything that genuinely needed real pixels first (luminance) already
        # flushed and marked itself `baked` at its own click, not now.
        separation_transaction, finalize_files, abort_files = commit_current_draft(folder, current_user.user_id)
        # Update status and release lock
        folder.qc_status = "PASS"
        folder.qc_locked_by = None
        folder.qc_locked_at = None
        # commit_current_draft only STAGED its file changes (see its
        # docstring) - nothing official is touched until finalize_files() runs
        # below. db.commit() is the durability line: a two-PC site can lose
        # its DB connection right here, and until this returns successfully
        # every staged file is still sitting exactly where abort_files() can
        # put it back.
        db.commit()
        try:
            finalize_files()
        except Exception:
            # The approval is already durable in the database at this point,
            # so this cannot roll back - only log loudly. The affected files
            # are left under their .draft_commit_tmp / .qc_deleted_pending
            # sibling names for manual finishing rather than half-applied
            # under their real ones.
            logger.exception(
                "QC draft finalize failed after approve commit; folder=%s. Files may be "
                "left staged under .draft_commit_tmp/.qc_deleted_pending names.",
                folder_id,
            )
    except Exception as error:
        db.rollback()
        abort_files()
        if separation_transaction:
            try:
                separation_transaction.rollback()
            except Exception as rollback_error:
                logger.exception(
                    "QC separation rollback failed after approve commit error; folder=%s",
                    folder_id,
                )
                raise BusinessError(
                    ApiCodes.BAD_REQUEST,
                    f"Failed to save the draft, and rolling back the physical files also failed: {rollback_error}",
                    400,
                ) from error
        if isinstance(error, SeparationFileError):
            raise BusinessError(ApiCodes.BAD_REQUEST, str(error), 400) from error
        raise BusinessError(ApiCodes.BAD_REQUEST, "Failed to save the draft.", 400) from error

    cancel_ai_jobs_after_finalization(folder.id, reason="qc_approved")
    try:
        discard_draft(folder.id, current_user.user_id)
        if separation_transaction:
            separation_transaction.cleanup_empty_parent_directories()
    except Exception:
        logger.exception("QC draft cleanup failed after approve; folder=%s", folder_id)
    write_qc_audit(
        "approve",
        current_user.user_id,
        folder.id,
        source_hash=request.sourceHash,
        draft_summary=draft_summary(manifest),
        result="success",
        note=request.comment,
    )

    return ok(None)


@router.post("/{folder_id}/revert", response_model=ApiResponse[MetadataQcTaskVO])
def revert_task(
    folder_id: int,
    request: ReviewRequest,
    current_user: QcUser,
    db: DbSession,
) -> ApiResponse[MetadataQcTaskVO]:
    """Send a finished folder back to QC as a client rework, and claim it.

    The client has asked for changes to work already delivered. The folder goes
    back to PENDING carrying `client_rework`, which reaches the ingest team as
    the export CSV's Rework column, and KEEPS its group_id: FamilySearch want
    the corrected package to replace the original under the same Group ID
    rather than arrive as a second one.

    `is_exported` is cleared too, or the export sweep would never look at the
    folder again (`eligible_folder_ids` wants pass AND not exported) and the
    correction would never leave the station.

    Claimed by the reverter on the way through, so they land straight in the
    review screen on the folder they just reopened rather than hunting for it
    in the pending queue.

    Unlike every other mutating endpoint here this one canNOT assert lock
    ownership: approve and reject both release the lock, so a finished folder is
    never claimed by anyone. sourceHash is the guard instead - it refuses a
    revert issued against a stale list.
    """
    folder = folder_or_404(db, folder_id, current_user.id, lock=True)

    # PASS only. A folder in REWORK is being recaptured: LWIP will republish
    # it under whatever claim this endpoint hands out, and the pixels on disk
    # are the ones QC just rejected.
    if folder.qc_status.lower() != "pass":
        raise BusinessError(
            ApiCodes.CONFLICT,
            "Only a PASS folder can be sent back for client rework. A folder in capture rework must be recaptured first.",
            409,
        )
    if source_hash(folder) != request.sourceHash:
        raise BusinessError(
            ApiCodes.CONFLICT,
            "This folder has changed. Refresh the list and try again.",
            409,
        )
    if folder.qc_locked_by is not None and folder.qc_locked_by != current_user.user_id:
        # Not reachable through the normal flow, since finishing releases the
        # lock - but a folder someone is holding must not be pulled out from
        # under them by a list that was stale.
        raise BusinessError(
            ApiCodes.CONFLICT, "Another reviewer has already claimed this task.", 409
        )

    # The same one-task-per-person rule claim_task enforces, checked BEFORE
    # anything changes: reverting must not become a way to hold two tasks, and
    # must not leave the folder reopened-but-unclaimed if it refuses.
    project_ids = project_ids_for_user(db, current_user.id)
    existing = db.scalar(
        select(CaptureFolder)
        .where(
            *visible_folder_conditions(project_ids),
            func.lower(CaptureFolder.qc_status) == "pending",
            CaptureFolder.qc_locked_by == current_user.user_id,
            CaptureFolder.id != folder_id,
        )
        .limit(1)
    )
    if existing:
        raise BusinessError(
            ApiCodes.CONFLICT, "You already have a claimed task. Finish it first.", 409
        )

    folder.qc_status = "PENDING"
    folder.client_rework = True
    folder.is_exported = False
    folder.qc_locked_by = current_user.user_id
    folder.qc_locked_at = now()
    db.commit()

    write_qc_audit(
        "revert_to_pending",
        current_user.user_id,
        folder.id,
        source_hash=request.sourceHash,
        result="success",
        note=request.comment,
    )
    return ok(to_task_vo(db, folder_or_404(db, folder_id, current_user.id), current_user.user_id))


@router.post("/{folder_id}/reject", response_model=ApiResponse[None])
def reject_task(folder_id: int, request: RejectRequest, current_user: QcUser, db: DbSession) -> ApiResponse[None]:
    """Reject the folder with per-image rework reasons."""
    folder = folder_or_404(db, folder_id, current_user.id, lock=True)
    assert_lock_owner(folder, current_user.user_id)

    verify_reviewable_folder(folder, request.sourceHash)

    rejected_reason_by_id = {}
    if request.rejectedImages:
        for item in request.rejectedImages:
            reason = item.rejectReason.strip()
            if not reason:
                raise BusinessError(ApiCodes.BAD_REQUEST, "Every reworked image needs a rework reason.")
            rejected_reason_by_id[item.imageId] = reason
    elif request.imageIds and request.rejectReason:
        legacy_reason = request.rejectReason.strip()
        rejected_reason_by_id = {image_id: legacy_reason for image_id in request.imageIds if legacy_reason}
    if not rejected_reason_by_id:
        raise BusinessError(ApiCodes.BAD_REQUEST, "Select at least one image to rework and give each a reason.")

    requested_ids = list(rejected_reason_by_id.keys())
    rejected_images = [image for image in folder.images if image.id in requested_ids]
    if len(rejected_images) != len(requested_ids):
        raise BusinessError(ApiCodes.BAD_REQUEST, "One or more images do not belong to this folder.")

    # Update folder status and reset processing flags (per design doc §6)
    manifest = read_manifest(folder.id, current_user.user_id)
    folder.qc_status = "REWORK"
    folder.qc_locked_by = None
    folder.qc_locked_at = None
    folder.is_deskewed = False
    folder.is_cropped = False
    folder.is_created_thumbnail = False

    # Create rework logs for each rejected image
    for image in rejected_images:
        reason = rejected_reason_by_id[image.id]
        db.add(ReworkLog(
            image_id=image.id,
            assigned_uid=folder.box.user_id,
            folder_id=folder.id,
            created_at=now(),
            rework_comments=reason,
            rework_status="OPEN",
            rework_type="QC Rework",
        ))

    db.commit()
    cancel_ai_jobs_after_finalization(folder.id, reason="qc_rejected")
    try:
        discard_draft(folder.id, current_user.user_id)
    except Exception:
        logger.exception("QC draft cleanup failed after reject; folder=%s", folder_id)
    write_qc_audit(
        "reject",
        current_user.user_id,
        folder.id,
        image_ids=[image.id for image in rejected_images],
        source_hash=request.sourceHash,
        draft_summary=draft_summary(manifest),
        result="success",
        note="; ".join(f"{image.image_name}: {rejected_reason_by_id[image.id]}" for image in rejected_images),
    )
    return ok(None)


@router.put("/{folder_id}/metadata", response_model=ApiResponse[MetadataQcTaskVO])
def update_metadata(
    folder_id: int,
    request: MetadataUpdateRequest,
    current_user: QcUser,
    db: DbSession,
) -> ApiResponse[MetadataQcTaskVO]:
    """Edit folder metadata during review."""
    folder = folder_or_404(db, folder_id, current_user.id, lock=True)
    assert_lock_owner(folder, current_user.user_id)

    verify_reviewable_folder(folder, request.sourceHash)

    template = metadata_template(folder)
    values = normalize_metadata_values(editable_metadata_to_dict(request.metadata), template)

    save_metadata_draft(folder.id, current_user.user_id, values)
    write_qc_audit(
        "metadata_draft",
        current_user.user_id,
        folder.id,
        source_hash=request.sourceHash,
        draft_summary=draft_summary(read_manifest(folder.id, current_user.user_id)),
        result="success",
    )
    db.commit()

    return ok(to_task_vo(db, folder, current_user.user_id))


@router.post("/{folder_id}/ai-review/jobs", response_model=ApiResponse[AiReviewJobVO])
def start_ai_review(
    folder_id: int,
    request: AiReviewStartRequest,
    current_user: QcUser,
    db: DbSession,
) -> ApiResponse[AiReviewJobVO]:
    """Start or reuse an AI-assisted metadata review job."""
    folder = folder_or_404(db, folder_id, current_user.id, lock=True)
    assert_lock_owner(folder, current_user.user_id)
    verify_reviewable_folder(folder, request.sourceHash)
    snapshot = ai_review_snapshot(folder, current_user.user_id)
    try:
        job = ai_review_coordinator.enqueue(snapshot, force=request.force)
    except AiReviewDisabledError as error:
        raise BusinessError(ApiCodes.SERVICE_UNAVAILABLE, str(error), 503) from error
    except AiReviewError as error:
        raise BusinessError(ApiCodes.BAD_REQUEST, str(error), 400) from error
    write_qc_audit(
        "ai_metadata_review",
        current_user.user_id,
        folder.id,
        source_hash=request.sourceHash,
        result="queued",
        note=f"job_id={job['jobId']}",
    )
    return ok(AiReviewJobVO(**job))


@router.get("/{folder_id}/ai-review/jobs/{job_id}", response_model=ApiResponse[AiReviewJobVO])
def get_ai_review_job(
    folder_id: int,
    job_id: str,
    current_user: QcUser,
    db: DbSession,
) -> ApiResponse[AiReviewJobVO]:
    """Return progress for one AI-assisted metadata review job."""
    folder = folder_or_404(db, folder_id, current_user.id)
    if folder.qc_locked_by != current_user.user_id:
        raise BusinessError(ApiCodes.FORBIDDEN, "Only the current task owner can view this AI review.", 403)
    snapshot = ai_review_snapshot(folder, current_user.user_id)
    try:
        job = ai_review_coordinator.get_job(folder_id, job_id, current_input_hash=snapshot.input_hash)
    except AiReviewNotFoundError as error:
        raise BusinessError(ApiCodes.NOT_FOUND, str(error), 404) from error
    return ok(AiReviewJobVO(**job))


@router.get("/{folder_id}/ai-review/latest", response_model=ApiResponse[AiReviewJobVO | None])
def get_latest_ai_review(
    folder_id: int,
    current_user: QcUser,
    db: DbSession,
) -> ApiResponse[AiReviewJobVO | None]:
    """Return the latest AI review that is visible to the current task owner."""
    folder = folder_or_404(db, folder_id, current_user.id)
    if folder.qc_locked_by != current_user.user_id:
        raise BusinessError(ApiCodes.FORBIDDEN, "Only the current task owner can view this AI review.", 403)
    snapshot = ai_review_snapshot(folder, current_user.user_id)
    job = ai_review_coordinator.latest(snapshot)
    return ok(AiReviewJobVO(**job) if job else None)


@router.post("/{folder_id}/ai-review/apply", response_model=ApiResponse[MetadataQcTaskVO])
def apply_ai_review_suggestions(
    folder_id: int,
    request: AiReviewApplyRequest,
    current_user: QcUser,
    db: DbSession,
) -> ApiResponse[MetadataQcTaskVO]:
    """Apply selected high-confidence AI suggestions to the QC metadata draft."""
    folder = folder_or_404(db, folder_id, current_user.id, lock=True)
    assert_lock_owner(folder, current_user.user_id)
    verify_reviewable_folder(folder, request.sourceHash)
    snapshot = ai_review_snapshot(folder, current_user.user_id)
    if snapshot.input_hash != request.inputHash:
        raise BusinessError(ApiCodes.CONFLICT, "The AI review is stale. Run it again before applying suggestions.", 409)
    try:
        cached = ai_review_coordinator.result_for_apply(folder.id, request.inputHash)
    except AiReviewNotFoundError as error:
        raise BusinessError(ApiCodes.NOT_FOUND, str(error), 404) from error

    reviews = {
        str(item.get("key")): item
        for item in (cached.get("result") or {}).get("fieldReviews", [])
        if isinstance(item, dict)
    }
    template = metadata_template(folder)
    manifest = read_manifest(folder.id, current_user.user_id)
    effective = effective_metadata_snapshot(folder, manifest, template)
    values = {key: effective.get(key) for key in METADATA_FIELD_MAP}
    selected_keys = list(dict.fromkeys(request.fieldKeys))
    for key in selected_keys:
        review = reviews.get(key)
        if not review:
            raise BusinessError(ApiCodes.BAD_REQUEST, f"AI review has no suggestion for {key}.", 400)
        suggested = canonical_metadata_value(key, review.get("suggestedValue"))
        if (
            review.get("verdict") != "mismatch"
            or float(review.get("confidence") or 0) < APPLY_CONFIDENCE
            or not suggested
        ):
            raise BusinessError(ApiCodes.BAD_REQUEST, f"AI suggestion for {key} cannot be applied.", 400)
        current = canonical_metadata_value(key, effective.get(key))
        original = canonical_metadata_value(key, review.get("currentValue"))
        if current != original:
            raise BusinessError(ApiCodes.CONFLICT, f"Metadata field {key} changed after AI review.", 409)
        values[key] = suggested

    normalized = normalize_metadata_values(values, template)
    save_metadata_draft(folder.id, current_user.user_id, normalized, operation="ai_metadata")
    ai_review_coordinator.record_acceptance(folder.id, request.inputHash, selected_keys, current_user.user_id)
    write_qc_audit(
        "ai_metadata_apply",
        current_user.user_id,
        folder.id,
        source_hash=request.sourceHash,
        draft_summary=draft_summary(read_manifest(folder.id, current_user.user_id)),
        result="success",
        note=",".join(selected_keys),
    )
    db.commit()
    return ok(to_task_vo(db, folder, current_user.user_id))


@router.post("/{folder_id}/images/{image_id}/crop", response_model=ApiResponse[MetadataQcTaskVO])
def crop_image(
    folder_id: int,
    image_id: int,
    request: CropImageRequest,
    current_user: QcUser,
    db: DbSession,
) -> ApiResponse[MetadataQcTaskVO]:
    """Crop one image; the replace is atomic and the original is kept under old/."""
    folder = folder_or_404(db, folder_id, current_user.id, lock=True)
    assert_lock_owner(folder, current_user.user_id)

    verify_reviewable_folder(folder, request.sourceHash)

    # Deferred, like every other geometry edit: the rectangle is recorded and
    # the preview shows the result. Nothing is decoded or re-encoded here - a
    # crop's own pixel work is ~13ms against ~380ms for the decode and JPEG
    # re-encode it used to pay on every click.
    ensure_editable_work_path(folder, current_user.user_id, image_id)

    # NORMALISED against the preview it was drawn on, so the same rect applies
    # at any size and lands on the geometry the reviewer was looking at -
    # including any rotate or deskew still pending ahead of it in the chain.
    preview_width = request.previewWidth or 0
    preview_height = request.previewHeight or 0
    if preview_width <= 0 or preview_height <= 0:
        raise BusinessError(ApiCodes.BAD_REQUEST, "The crop area is outside the image.")
    x0 = request.x / preview_width
    y0 = request.y / preview_height
    x1 = (request.x + request.width) / preview_width
    y1 = (request.y + request.height) / preview_height
    if x1 <= x0 or y1 <= y0 or x0 < 0 or y0 < 0 or x1 > 1.0001 or y1 > 1.0001:
        raise BusinessError(ApiCodes.BAD_REQUEST, "The crop area is outside the image.")
    add_pending_op(
        folder.id,
        current_user.user_id,
        image_id,
        {"op": "crop", "rect": [min(x0, 1.0), min(y0, 1.0), min(x1, 1.0), min(y1, 1.0)]},
    )

    write_qc_audit(
        "crop_draft",
        current_user.user_id,
        folder.id,
        image_ids=[image_id],
        source_hash=request.sourceHash,
        draft_summary=draft_summary(read_manifest(folder.id, current_user.user_id)),
        result="success",
    )
    db.commit()

    return ok(to_task_vo(db, folder, current_user.user_id))


def assert_luminance_enabled() -> None:
    """Refuse the request when the station has luminance correction switched off.

    LWCAM hides the button when the flag is off, but the button is not the
    security boundary: a stale client, or anything speaking to the engine
    directly, must not be able to tone-correct a page for a client whose
    standards forbid it. 503 rather than 403 - the capability is absent on this
    station, not denied to this user - matching how AI review reports the same
    situation.
    """
    if not settings.luminance_enabled:
        raise BusinessError(
            ApiCodes.SERVICE_UNAVAILABLE,
            "Luminance correction is switched off for this station. It can be "
            "turned on in LWCam Admin.",
            503,
        )


@router.post("/{folder_id}/images/{image_id}/luminance", response_model=ApiResponse[MetadataQcTaskVO])
def luminance_image(
    folder_id: int,
    image_id: int,
    request: LuminanceRequest,
    current_user: QcUser,
    db: DbSession,
) -> ApiResponse[MetadataQcTaskVO]:
    """Apply luminance correction to a draft copy of one image."""
    assert_luminance_enabled()
    folder = folder_or_404(db, folder_id, current_user.id, lock=True)
    assert_lock_owner(folder, current_user.user_id)
    verify_reviewable_folder(folder, request.sourceHash)

    work_path, _image_name = ensure_editable_work_path(folder, current_user.user_id, image_id)
    flush_pending_ops(folder, current_user.user_id, image_id, work_path)
    mark_dirty(folder.id, current_user.user_id, image_id, "luminance")
    try:
        apply_luminance(work_path)
    except Exception as error:
        raise BusinessError(ApiCodes.BAD_REQUEST, "Luminance correction failed.", 400) from error
    write_qc_audit(
        "luminance",
        current_user.user_id,
        folder.id,
        image_ids=[image_id],
        source_hash=request.sourceHash,
        draft_summary=draft_summary(read_manifest(folder.id, current_user.user_id)),
        result="success",
    )
    db.commit()

    refreshed = folder_or_404(db, folder_id, current_user.id)
    return ok(to_task_vo(db, refreshed, current_user.user_id))


@router.post("/{folder_id}/images/luminance-batch", response_model=ApiResponse[MetadataQcTaskVO])
def luminance_batch(
    folder_id: int,
    request: BatchLuminanceRequest,
    current_user: QcUser,
    db: DbSession,
) -> ApiResponse[MetadataQcTaskVO]:
    """Apply luminance correction to draft copies of selected images."""
    assert_luminance_enabled()
    folder = folder_or_404(db, folder_id, current_user.id, lock=True)
    assert_lock_owner(folder, current_user.user_id)
    verify_reviewable_folder(folder, request.sourceHash)

    requested_ids = list(dict.fromkeys(request.imageIds))
    # Claim every working copy and mark it dirty FIRST, on this thread: both
    # touch the manifest and the session, neither of which is thread-safe. Only
    # the pixel work is parallel.
    work_items = []
    for image_id in requested_ids:
        work_path, image_name = ensure_editable_work_path(folder, current_user.user_id, image_id)
        flush_pending_ops(folder, current_user.user_id, image_id, work_path)
        mark_dirty(folder.id, current_user.user_id, image_id, "luminance")
        work_items.append((work_path, image_name))

    def _luminance(item):
        path, name = item
        try:
            apply_luminance(path)
        except Exception as error:
            # Named per image, as before: which page failed is the whole
            # message. Raised from the worker, re-surfaced by run_image_batch.
            raise BusinessError(ApiCodes.BAD_REQUEST, f"Luminance correction failed: {name}", 400) from error

    run_image_batch(_luminance, work_items)

    write_qc_audit(
        "luminance_batch",
        current_user.user_id,
        folder.id,
        image_ids=requested_ids,
        source_hash=request.sourceHash,
        draft_summary=draft_summary(read_manifest(folder.id, current_user.user_id)),
        result="success",
    )
    db.commit()

    refreshed = folder_or_404(db, folder_id, current_user.id)
    return ok(to_task_vo(db, refreshed, current_user.user_id))


@router.post("/{folder_id}/images/{image_id}/replace", response_model=ApiResponse[MetadataQcTaskVO])
def replace_image(
    folder_id: int,
    image_id: int,
    current_user: QcUser,
    db: DbSession,
    sourceHash: str = Form(...),
    file: UploadFile = File(...),
) -> ApiResponse[MetadataQcTaskVO]:
    folder = folder_or_404(db, folder_id, current_user.id, lock=True)
    assert_lock_owner(folder, current_user.user_id)
    verify_reviewable_folder(folder, sourceHash)
    filename = validate_upload_filename(file.filename)
    temp_path = save_upload_to_temp(folder.id, current_user.user_id, file, filename)
    if image_id > 0:
        image = next((item for item in folder.images if item.id == image_id), None)
        if image is None:
            raise BusinessError(ApiCodes.NOT_FOUND, "That image does not belong to this folder.", 404)
        image_name = replacement_image_name(image.image_name, filename)
    else:
        item = draft_image_item(read_manifest(folder.id, current_user.user_id), image_id)
        if not item:
            raise BusinessError(ApiCodes.NOT_FOUND, "The draft image does not exist.", 404)
        image_name = filename
    draft_replace_image(folder.id, current_user.user_id, image_id, image_name, temp_path, official_image_ids(folder))
    # The deferred edits belonged to the page that was just swapped out.
    # Carrying a crop or a straighten onto the replacement would edit a page
    # nobody asked to edit.
    clear_pending_ops(folder.id, current_user.user_id, image_id)
    db.commit()
    write_qc_audit("replace", current_user.user_id, folder.id, image_ids=[image_id], source_hash=sourceHash, result="success")
    return ok(to_task_vo(db, folder_or_404(db, folder_id, current_user.id), current_user.user_id))


@router.post("/{folder_id}/images/{image_id}/insert-before", response_model=ApiResponse[MetadataQcTaskVO])
def insert_image_before(
    folder_id: int,
    image_id: int,
    current_user: QcUser,
    db: DbSession,
    sourceHash: str = Form(...),
    file: UploadFile = File(...),
) -> ApiResponse[MetadataQcTaskVO]:
    folder = folder_or_404(db, folder_id, current_user.id, lock=True)
    assert_lock_owner(folder, current_user.user_id)
    verify_reviewable_folder(folder, sourceHash)
    filename = validate_upload_filename(file.filename)
    if image_id not in visible_order(read_manifest(folder.id, current_user.user_id), official_image_ids(folder)):
        raise BusinessError(ApiCodes.NOT_FOUND, "The image to insert before does not exist.", 404)
    temp_path = save_upload_to_temp(folder.id, current_user.user_id, file, filename)
    temp_id = create_inserted_image(folder.id, current_user.user_id, filename, temp_path, image_id, official_image_ids(folder))
    db.commit()
    write_qc_audit("insert_before", current_user.user_id, folder.id, image_ids=[temp_id], source_hash=sourceHash, result="success")
    return ok(to_task_vo(db, folder_or_404(db, folder_id, current_user.id), current_user.user_id))


@router.post("/{folder_id}/images/{image_id}/delete", response_model=ApiResponse[MetadataQcTaskVO])
def delete_qc_image(
    folder_id: int,
    image_id: int,
    request: ReviewRequest,
    current_user: QcUser,
    db: DbSession,
) -> ApiResponse[MetadataQcTaskVO]:
    folder = folder_or_404(db, folder_id, current_user.id, lock=True)
    assert_lock_owner(folder, current_user.user_id)
    verify_reviewable_folder(folder, request.sourceHash)
    manifest = read_manifest(folder.id, current_user.user_id)
    current_order = visible_order(manifest, official_image_ids(folder))
    if image_id not in current_order:
        raise BusinessError(ApiCodes.NOT_FOUND, "The image does not exist.", 404)
    if len(current_order) <= 1:
        raise BusinessError(ApiCodes.BAD_REQUEST, "The last image cannot be deleted.", 400)
    draft_delete_image(folder.id, current_user.user_id, image_id, official_image_ids(folder))
    db.commit()
    write_qc_audit("delete", current_user.user_id, folder.id, image_ids=[image_id], source_hash=request.sourceHash, result="success")
    return ok(to_task_vo(db, folder_or_404(db, folder_id, current_user.id), current_user.user_id))


@router.post("/{folder_id}/images/delete-batch", response_model=ApiResponse[MetadataQcTaskVO])
def delete_qc_images_batch(
    folder_id: int,
    request: BatchDeleteRequest,
    current_user: QcUser,
    db: DbSession,
) -> ApiResponse[MetadataQcTaskVO]:
    """Delete several images from the draft in one revision."""
    folder = folder_or_404(db, folder_id, current_user.id, lock=True)
    assert_lock_owner(folder, current_user.user_id)
    verify_reviewable_folder(folder, request.sourceHash)
    manifest = read_manifest(folder.id, current_user.user_id)
    current_order = visible_order(manifest, official_image_ids(folder))
    requested_ids = list(dict.fromkeys(request.imageIds))
    validate_batch_delete(current_order, requested_ids)
    for image_id in requested_ids:
        draft_delete_image(folder.id, current_user.user_id, image_id, official_image_ids(folder))
    db.commit()
    write_qc_audit("delete_batch", current_user.user_id, folder.id, image_ids=requested_ids, source_hash=request.sourceHash, result="success")
    return ok(to_task_vo(db, folder_or_404(db, folder_id, current_user.id), current_user.user_id))


@router.post("/{folder_id}/images/{image_id}/rotate", response_model=ApiResponse[MetadataQcTaskVO])
def rotate_qc_image(
    folder_id: int,
    image_id: int,
    request: RotateImageRequest,
    current_user: QcUser,
    db: DbSession,
) -> ApiResponse[MetadataQcTaskVO]:
    folder = folder_or_404(db, folder_id, current_user.id, lock=True)
    assert_lock_owner(folder, current_user.user_id)
    verify_reviewable_folder(folder, request.sourceHash)
    if request.degrees not in {-90, 90, 180}:
        raise BusinessError(ApiCodes.BAD_REQUEST, "Rotation is limited to 90, -90 or 180 degrees.", 400)
    # Deferred: recorded in the chain and shown on the preview. A quarter turn
    # is cheap in itself (~49ms) but used to cost a full decode and JPEG
    # re-encode of the page on every click.
    ensure_editable_work_path(folder, current_user.user_id, image_id)
    add_pending_op(
        folder.id, current_user.user_id, image_id,
        {"op": "rotate", "degrees": float(request.degrees)},
    )
    db.commit()
    write_qc_audit("rotate", current_user.user_id, folder.id, image_ids=[image_id], source_hash=request.sourceHash, result="success")
    return ok(to_task_vo(db, folder_or_404(db, folder_id, current_user.id), current_user.user_id))


@router.post("/{folder_id}/images/rotate-batch", response_model=ApiResponse[MetadataQcTaskVO])
def rotate_qc_batch(
    folder_id: int,
    request: BatchRotateRequest,
    current_user: QcUser,
    db: DbSession,
) -> ApiResponse[MetadataQcTaskVO]:
    folder = folder_or_404(db, folder_id, current_user.id, lock=True)
    assert_lock_owner(folder, current_user.user_id)
    verify_reviewable_folder(folder, request.sourceHash)
    if request.degrees not in {-90, 90, 180}:
        raise BusinessError(ApiCodes.BAD_REQUEST, "Rotation is limited to 90, -90 or 180 degrees.", 400)
    requested_ids = list(dict.fromkeys(request.imageIds))
    # Claim every working copy and mark it dirty FIRST, on this thread: both
    # touch the manifest and the session, neither of which is thread-safe. Only
    # the pixel work is parallel.
    # Deferred for every image in the batch, same as the single endpoint.
    for image_id in requested_ids:
        ensure_editable_work_path(folder, current_user.user_id, image_id)
        add_pending_op(
            folder.id, current_user.user_id, image_id,
            {"op": "rotate", "degrees": float(request.degrees)},
        )
    db.commit()
    write_qc_audit("rotate_batch", current_user.user_id, folder.id, image_ids=requested_ids, source_hash=request.sourceHash, result="success")
    return ok(to_task_vo(db, folder_or_404(db, folder_id, current_user.id), current_user.user_id))


@router.post("/{folder_id}/images/{image_id}/deskew", response_model=ApiResponse[MetadataQcTaskVO])
def deskew_qc_image(
    folder_id: int,
    image_id: int,
    request: DeskewImageRequest,
    current_user: QcUser,
    db: DbSession,
) -> ApiResponse[MetadataQcTaskVO]:
    folder = folder_or_404(db, folder_id, current_user.id, lock=True)
    assert_lock_owner(folder, current_user.user_id)
    verify_reviewable_folder(folder, request.sourceHash)
    validate_deskew_degrees(request.degrees)
    # Deferred: the angle accumulates and the PREVIEW shows it. The full
    # resolution resample happens once, at the next operation that needs real
    # pixels or at approval - see flush_pending_ops.
    ensure_editable_work_path(folder, current_user.user_id, image_id)
    try:
        add_pending_deskew(folder.id, current_user.user_id, image_id, request.degrees)
    except ValueError as error:
        raise BusinessError(ApiCodes.BAD_REQUEST, str(error), 400) from error
    db.commit()
    write_qc_audit("deskew", current_user.user_id, folder.id, image_ids=[image_id], source_hash=request.sourceHash, result="success")
    return ok(to_task_vo(db, folder_or_404(db, folder_id, current_user.id), current_user.user_id))


@router.post("/{folder_id}/images/deskew-batch", response_model=ApiResponse[MetadataQcTaskVO])
def deskew_qc_batch(
    folder_id: int,
    request: BatchDeskewRequest,
    current_user: QcUser,
    db: DbSession,
) -> ApiResponse[MetadataQcTaskVO]:
    """Nudge several images level in one revision."""
    folder = folder_or_404(db, folder_id, current_user.id, lock=True)
    assert_lock_owner(folder, current_user.user_id)
    verify_reviewable_folder(folder, request.sourceHash)
    validate_deskew_degrees(request.degrees)
    requested_ids = list(dict.fromkeys(request.imageIds))
    # Claim every working copy and mark it dirty FIRST, on this thread: both
    # touch the manifest and the session, neither of which is thread-safe. Only
    # the pixel work is parallel.
    # Deferred, exactly as the single-image endpoint: no pixels are touched here.
    for image_id in requested_ids:
        ensure_editable_work_path(folder, current_user.user_id, image_id)
        try:
            add_pending_deskew(folder.id, current_user.user_id, image_id, request.degrees)
        except ValueError as error:
            raise BusinessError(ApiCodes.BAD_REQUEST, str(error), 400) from error
    db.commit()
    write_qc_audit("deskew_batch", current_user.user_id, folder.id, image_ids=requested_ids, source_hash=request.sourceHash, result="success")
    return ok(to_task_vo(db, folder_or_404(db, folder_id, current_user.id), current_user.user_id))


@router.post("/{folder_id}/images/reorder", response_model=ApiResponse[MetadataQcTaskVO])
def reorder_qc_images(
    folder_id: int,
    request: ReorderImagesRequest,
    current_user: QcUser,
    db: DbSession,
) -> ApiResponse[MetadataQcTaskVO]:
    folder = folder_or_404(db, folder_id, current_user.id, lock=True)
    assert_lock_owner(folder, current_user.user_id)
    verify_reviewable_folder(folder, request.sourceHash)
    current_ids = visible_order(read_manifest(folder.id, current_user.user_id), official_image_ids(folder))
    if set(request.imageIds) != set(current_ids) or len(request.imageIds) != len(current_ids):
        raise BusinessError(ApiCodes.BAD_REQUEST, "The order list must match the current images exactly.", 400)
    set_order(folder.id, current_user.user_id, request.imageIds, official_image_ids(folder))
    db.commit()
    write_qc_audit("reorder", current_user.user_id, folder.id, image_ids=request.imageIds, source_hash=request.sourceHash, result="success")
    return ok(to_task_vo(db, folder_or_404(db, folder_id, current_user.id), current_user.user_id))


@router.post("/{folder_id}/images/{image_id}/restore-original", response_model=ApiResponse[MetadataQcTaskVO])
def restore_qc_image(
    folder_id: int,
    image_id: int,
    request: ReviewRequest,
    current_user: QcUser,
    db: DbSession,
) -> ApiResponse[MetadataQcTaskVO]:
    folder = folder_or_404(db, folder_id, current_user.id, lock=True)
    assert_lock_owner(folder, current_user.user_id)
    verify_reviewable_folder(folder, request.sourceHash)
    draft_restore_original(folder.id, current_user.user_id, image_id, official_image_ids(folder))
    # Restoring the original means restoring it: a deferred crop or straighten
    # would leave the "restored" page still edited in the preview.
    clear_pending_ops(folder.id, current_user.user_id, image_id)
    db.commit()
    write_qc_audit("restore_original", current_user.user_id, folder.id, image_ids=[image_id], source_hash=request.sourceHash, result="success")
    return ok(to_task_vo(db, folder_or_404(db, folder_id, current_user.id), current_user.user_id))


@router.post("/{folder_id}/draft/undo", response_model=ApiResponse[MetadataQcTaskVO])
def undo_qc_draft(folder_id: int, current_user: QcUser, db: DbSession) -> ApiResponse[MetadataQcTaskVO]:
    folder = folder_or_404(db, folder_id, current_user.id, lock=True)
    assert_lock_owner(folder, current_user.user_id)
    undo_manifest(folder.id, current_user.user_id)
    db.commit()
    write_qc_audit("undo", current_user.user_id, folder.id, result="success")
    return ok(to_task_vo(db, folder_or_404(db, folder_id, current_user.id), current_user.user_id))


@router.post("/{folder_id}/draft/redo", response_model=ApiResponse[MetadataQcTaskVO])
def redo_qc_draft(folder_id: int, current_user: QcUser, db: DbSession) -> ApiResponse[MetadataQcTaskVO]:
    folder = folder_or_404(db, folder_id, current_user.id, lock=True)
    assert_lock_owner(folder, current_user.user_id)
    redo_manifest(folder.id, current_user.user_id)
    db.commit()
    write_qc_audit("redo", current_user.user_id, folder.id, result="success")
    return ok(to_task_vo(db, folder_or_404(db, folder_id, current_user.id), current_user.user_id))


@router.put("/{folder_id}/separation-markers", response_model=ApiResponse[MetadataQcTaskVO])
def update_separation_markers(
    folder_id: int,
    request: SeparationMarkersRequest,
    current_user: QcUser,
    db: DbSession,
) -> ApiResponse[MetadataQcTaskVO]:
    folder = folder_or_404(db, folder_id, current_user.id, lock=True)
    assert_lock_owner(folder, current_user.user_id)
    verify_reviewable_folder(folder, request.sourceHash)
    current_ids = visible_order(read_manifest(folder.id, current_user.user_id), official_image_ids(folder))
    marker_ids = list(dict.fromkeys(request.firstPageImageIds))
    if any(image_id not in current_ids for image_id in marker_ids):
        raise BusinessError(ApiCodes.BAD_REQUEST, "A separation start page is not among the current images.", 400)
    if marker_ids and (len(marker_ids) < 2 or current_ids[0] not in marker_ids):
        raise BusinessError(ApiCodes.BAD_REQUEST, "Separation needs at least two start pages, and the first image must be marked.", 400)
    set_separation_markers(folder.id, current_user.user_id, marker_ids, official_image_ids(folder))
    db.commit()
    write_qc_audit("separation_markers", current_user.user_id, folder.id, image_ids=marker_ids, source_hash=request.sourceHash, result="success")
    return ok(to_task_vo(db, folder_or_404(db, folder_id, current_user.id), current_user.user_id))


@router.post("/{folder_id}/draft/save", response_model=ApiResponse[MetadataQcTaskVO])
def save_draft(
    folder_id: int,
    request: ReviewRequest,
    current_user: QcUser,
    db: DbSession,
) -> ApiResponse[MetadataQcTaskVO]:
    """Commit current user's QC draft image changes to official images."""
    folder = folder_or_404(db, folder_id, current_user.id, lock=True)
    assert_lock_owner(folder, current_user.user_id)
    verify_reviewable_folder(folder, request.sourceHash)
    manifest = read_manifest(folder.id, current_user.user_id)
    metadata_values = normalize_metadata_values(
        metadata_values_from_manifest(manifest),
        metadata_template(folder),
    )
    has_separation = bool((manifest or {}).get("separation_markers"))
    parent_folder_name = folder.folder_name

    def response_folder_after_save() -> CaptureFolder:
        if not has_separation:
            return folder
        child = db.scalar(
            select(CaptureFolder)
            .options(*folder_options())
            .where(
                CaptureFolder.box_id == folder.box_id,
                CaptureFolder.folder_name.like(f"{parent_folder_name}_%"),
                func.lower(CaptureFolder.qc_status) == "pending",
            )
            .order_by(CaptureFolder.folder_seq.asc(), CaptureFolder.id.asc())
            .limit(1)
        )
        if child is None:
            return folder
        if child.qc_locked_by is None:
            child.qc_locked_by = current_user.user_id
            child.qc_locked_at = now()
            db.commit()
        return child

    separation_transaction = None
    finalize_files: Callable[[], None] = lambda: None
    abort_files: Callable[[], None] = lambda: None
    try:
        separation_transaction, finalize_files, abort_files = commit_current_draft(folder, current_user.user_id)
        # See commit_current_draft's docstring: its file changes are staged,
        # not yet visible, until finalize_files() runs below - after this
        # db.commit() is the durability line a two-PC site can lose mid-commit.
        db.commit()
        try:
            finalize_files()
        except Exception:
            # Already durable in the database; cannot roll back from here.
            logger.exception(
                "QC draft finalize failed after save commit; folder=%s. Files may be "
                "left staged under .draft_commit_tmp/.qc_deleted_pending names.",
                folder_id,
            )
    except Exception as error:
        db.rollback()
        abort_files()
        if separation_transaction:
            try:
                separation_transaction.rollback()
            except Exception as rollback_error:
                logger.exception(
                    "QC separation rollback failed after save commit error; folder=%s",
                    folder_id,
                )
                raise BusinessError(
                    ApiCodes.BAD_REQUEST,
                    f"Failed to save the draft, and rolling back the physical files also failed: {rollback_error}",
                    400,
                ) from error
        if isinstance(error, SeparationFileError):
            raise BusinessError(ApiCodes.BAD_REQUEST, str(error), 400) from error
        raise BusinessError(ApiCodes.BAD_REQUEST, "Failed to save the draft.", 400) from error

    # The session keeps in-memory values after commit (expire_on_commit=False),
    # but sourceHash is built from timestamp isoformat() strings — and the
    # in-memory representation differs from what PostgreSQL hands back on the
    # next request: TIMESTAMPTZ(3) rounds our microsecond datetimes to
    # milliseconds, and reads come back in the connection's timezone, not UTC.
    # Hashing the in-memory values therefore returned a sourceHash no later
    # request could ever match (409 "This folder has changed" on the very next action).
    # Expiring forces the VO below to rebuild from persisted values — exactly
    # the representation every subsequent request will compute against.
    db.expire_all()

    try:
        discard_draft(folder.id, current_user.user_id)
        if separation_transaction:
            separation_transaction.cleanup_empty_parent_directories()
    except Exception:
        logger.exception("QC draft cleanup failed after save; folder=%s", folder_id)
    write_qc_audit(
        "save",
        current_user.user_id,
        folder.id,
        source_hash=request.sourceHash,
        draft_summary=draft_summary(manifest),
        result="success",
        note=request.comment,
    )

    return ok(to_task_vo(db, response_folder_after_save(), current_user.user_id))


@router.post("/{folder_id}/draft/discard", response_model=ApiResponse[MetadataQcTaskVO])
def discard_current_draft(
    folder_id: int,
    current_user: QcUser,
    db: DbSession,
) -> ApiResponse[MetadataQcTaskVO]:
    """Discard current user's QC draft image changes."""
    folder = folder_or_404(db, folder_id, current_user.id, lock=True)
    assert_lock_owner(folder, current_user.user_id)
    manifest = read_manifest(folder.id, current_user.user_id)
    discard_draft(folder.id, current_user.user_id)
    db.commit()
    write_qc_audit(
        "discard",
        current_user.user_id,
        folder.id,
        draft_summary=draft_summary(manifest),
        result="success",
    )

    refreshed = folder_or_404(db, folder_id, current_user.id)
    return ok(to_task_vo(db, refreshed, current_user.user_id))


def preview_ops(
    folder: CaptureFolder,
    image: CaptureImage | None,
    manifest: dict | None,
    image_id: int,
    claimed_by_viewer: bool,
) -> list[dict]:
    """What to replay onto a PREVIEW/thumbnail render for this image.

    Mirrors commit_current_draft's own dispatch, so what a reviewer sees is
    exactly what approval will commit: an inserted-but-uncommitted page or one
    mid-replace has no baseline history to layer under (the work copy already
    IS the whole picture); a restored item shows the baseline alone, since
    that is what "restore" now means; anything else gets LWIP's baseline plus
    every earlier committed round plus whatever is still pending - only the
    claim holder has pending ops at all, since nobody else has a draft.
    """
    item = draft_image_item(manifest, image_id) if manifest else None
    pending = pending_ops_of(manifest, image_id) if claimed_by_viewer else []
    if image_id < 0 or (item and item.get("status") in {"inserted", "replaced"}):
        return pending
    if image is None:
        return pending
    folder_path = to_local(folder.folder_path or "")
    if item and item.get("restored"):
        return baseline_ops(folder_path, image.image_name)
    return effective_ops(folder_path, image.image_name, pending)


@router.get("/{folder_id}/images/{image_id}/preview")
def preview(folder_id: int, image_id: int, current_user: QcUser, db: DbSession) -> FileResponse:
    """Return the preview file for one image after checking QC permission."""
    folder = folder_or_404(db, folder_id, current_user.id)
    claimed_by_viewer = folder.qc_locked_by == current_user.user_id
    manifest = read_manifest(folder.id, current_user.user_id) if claimed_by_viewer else None
    source_path = None
    if claimed_by_viewer:
        source_path = draft_image_path(folder.id, current_user.user_id, image_id)
    image = next((item for item in folder.images if item.id == image_id), None) if image_id > 0 else None
    used_thumbnail = False
    if source_path is None:
        if image is None:
            raise BusinessError(ApiCodes.NOT_FOUND, "That image does not belong to this folder.", 404)
        if claimed_by_viewer:
            # The reviewer holding the claim renders from the CAPTURE, not the
            # thumbnail. draft_image_path returns None until a page is first
            # edited, so most pages of an active task reach here - and serving
            # LWIP's 512px thumbnail meant a claimed folder was reviewed at a
            # fraction of its resolution until each page happened to be touched,
            # with a rotate silently sharpening it. Deskew, crop and legibility
            # are exactly the judgements that need the real pixels.
            source_path = resolve_image_file(folder, image)
        else:
            # Nobody is deciding anything from a read-only view, so it keeps the
            # thumbnail: far cheaper to render, and the full scan is a fallback
            # only when no thumbnail exists. The thumbnail is already baked
            # with the approved geometry (commit_current_draft regenerates it),
            # so it is used AS IS - replaying the chain again on top of it
            # would apply LWIP's baseline and every committed round twice.
            try:
                source_path = resolve_image_file(folder, image, thumbnail=True)
                used_thumbnail = True
            except BusinessError:
                source_path = resolve_image_file(folder, image)
    # The full chain is applied to the PREVIEW, never the source: that is what
    # makes an edit click feel instant AND what keeps the delivered page file
    # untouched. See preview_ops.
    ops = [] if used_thumbnail else preview_ops(folder, image, manifest, image_id, claimed_by_viewer)
    try:
        preview_path = generate_preview_image(source_path, ops)
    except Exception as error:
        raise BusinessError(ApiCodes.BAD_REQUEST, "Generating the image preview failed.", 400) from error
    if preview_path is None:
        raise BusinessError(ApiCodes.BAD_REQUEST, "Unsupported image format.", 400)
    return FileResponse(
        preview_path,
        media_type=PREVIEW_MIME_TYPE,
        filename=f"{source_path.stem}.jpg",
        content_disposition_type="inline",
    )

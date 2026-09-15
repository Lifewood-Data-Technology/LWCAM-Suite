from __future__ import annotations

import csv
import hashlib
import json
import logging
from concurrent.futures import ProcessPoolExecutor
from concurrent.futures.process import BrokenProcessPool
import os
import re
import shutil
import threading
import time
import uuid
import zipfile
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from PIL import Image, TiffImagePlugin
from sqlalchemy import func, select, text
from sqlalchemy.orm import Session, joinedload, lazyload, selectinload

from app.core.config import settings
from app.core.paths import fs_path, to_local
from app.db.session import SessionLocal, engine
from app.services.geometry_ops import replay_pending_ops
from app.services.ledger import JsonLedger, atomic_json
from app.services.qc_ops_store import effective_ops
from app.services.sweep import PeriodicSweep
from app.models.capture import CaptureBox, CaptureFolder, CaptureImage
from app.models.project import Project

logger = logging.getLogger(__name__)

# The two files every package carries. upload_summary reads them back by
# these names, so they live here and nowhere else.
GROUP_CSV_NAME = "GroupMetadataImage.csv"
ARTIFACT_CSV_NAME = "ArtifactMetadata.csv"

GROUP_CSV_HEADERS = [
    "Rework",
    "Title",
    "Place",
    "Start Date",
    "End Date",
    "Record Type",
    "Language",
    "Record Custodian",
    "Archival Reference Number",
    "Capture ID",
    "Capture Operator Name",
    "Capture Operator ID",
    "Total Artifacts",
    "Volume",
    "Capture Date",
    "Digitizing Entity",
]

# Group CSV column -> metadata-template field id, for the columns a template
# controls. A field the project's template DISABLES drops its column entirely
# (the columns after it move up); the four system columns - Rework, Capture ID,
# Total Artifacts, Capture Date - are not template fields and always appear.
GROUP_CSV_FIELD_IDS = {
    "Title": "title",
    "Place": "place",
    "Start Date": "startDate",
    "End Date": "endDate",
    "Record Type": "recordType",
    "Language": "language",
    "Record Custodian": "recordCustodian",
    "Archival Reference Number": "archivalRefNo",
    "Capture Operator Name": "captureOperatorName",
    "Capture Operator ID": "captureOperatorId",
    "Volume": "volume",
    "Digitizing Entity": "digitizingEntity",
}


def group_csv_headers(disabled_fields: frozenset[str] | set[str]) -> list[str]:
    """The group CSV's columns for a project, in the fixed order minus the
    template-disabled fields."""
    return [h for h in GROUP_CSV_HEADERS if GROUP_CSV_FIELD_IDS.get(h) not in disabled_fields]


ARTIFACT_CSV_HEADERS = [
    "Filename",
    "File Size",
    "Artifact Type",
    "Hash Algorithm",
    "Hash",
    "Image Width",
    "Image Height",
    "Capture ID",
]

SOURCE_NAME_PATTERN = re.compile(
    r"^(?P<user>[A-Za-z0-9_-]+)_IMG_(?P<date>\d{8})_(?P<time>\d{6})"
    r"(?:_\d{3})?\.[^.]+$",
    re.IGNORECASE,
)
SAFE_GROUP_PART = re.compile(r"^[A-Za-z0-9_-]+$")
DEFLATE_COMPRESSION_TAGS = {8, 32946}

# Capture provenance carried into the exported TIFF. Restricted to tags TIFF
# defines natively -- an EXIF-only tag has no legal home in a TIFF IFD, and the
# pointer tags (ExifIFD 34665, GPSIFD 34853) cannot be rewritten by Pillow at
# all. GPS is absent by design as well as by necessity: LWIP strips it.
TIFF_PROVENANCE_TAGS = (
    271,    # Make
    272,    # Model
    274,    # Orientation
    282,    # XResolution
    283,    # YResolution
    296,    # ResolutionUnit
    305,    # Software
    306,    # DateTime
    315,    # Artist
    33432,  # Copyright
)

TIFF_ORIENTATION_TAG = 274
TIFF_RESOLUTION_TAGS = (282, 283)


def sanitise_tiff_tag(tag: int, value: Any) -> Any:
    """The value to write for [tag], or None to omit it.

    libtiff VALIDATES what it is given and refuses a value out of range, and
    Pillow surfaces that refusal as `RuntimeError: Error setting from
    dictionary` with no indication of which tag was at fault. The refusal is
    fatal to the whole export: one bad tag on one page fails its folder, the
    sweep retries with a doubling backoff, and the folder never ships.

    That is not hypothetical. A page inserted during QC on 2026-09-09 carried
    Orientation 0 - Xiaomi writes a literal 0, which is not a legal value - and
    took the entire folder's export down. Every captured page was fine, because
    LWIP normalises the same tag on its way through (image_ops._source_metadata);
    an inserted page never passes through LWIP, so nothing had corrected it.

    Metadata only. No pixel is touched here, and a tag that cannot be written
    is dropped rather than allowed to fail the delivery - provenance is worth
    having, not worth losing a batch over.
    """
    if tag == TIFF_ORIENTATION_TAG:
        try:
            orientation = int(value)
        except (TypeError, ValueError):
            return None
        # 1..8 per TIFF 6.0. Anything else, including Xiaomi's 0, is corrected
        # to 1 rather than dropped: by this point the pixels ARE upright
        # (apply_pending_ops bakes any rotation in), so 1 is the truthful value
        # and matches what LWIP writes for the same input.
        return orientation if 1 <= orientation <= 8 else 1
    if tag in TIFF_RESOLUTION_TAGS:
        # A zero or negative resolution is equally rejected, and a zero
        # denominator raises before libtiff is even reached.
        try:
            if float(value) <= 0:
                return None
        except (TypeError, ValueError, ZeroDivisionError):
            return None
    return value


EXPORT_ERROR_MESSAGES = {
    "configInvalid": "Invalid export configuration: {fields}",
    "pathNotWritable": "{setting} is not writable: {path}",
    "projectIdMissing": "Project {project} has no projects.project_id configured",
    "invalidGroupPart": "{label} may contain only letters, numbers, underscores and hyphens",
    "sourceFilenameInvalid": "No image filename matches <UserID>_IMG_YYYYMMDD_HHMMSS_NNN.ext: {filename}",
    "sourceDateInvalid": "The first image has an invalid date: {filename}",
    "projectIdInvalid": "The project ID is invalid",
    "sequenceExhausted": "The export sequence for project {projectId} is exhausted",
    "groupIdTooLong": "The Group ID exceeds 255 characters",
    "folderMissing": "The folder does not exist or has been deleted",
    "folderNotPass": "The folder has not passed QC and cannot be exported",
    "folderAlreadyExported": "The folder has already been exported and cannot be exported again",
    "sourceDirectoryNotConfigured": "The folder source image directory is not configured",
    "projectMissing": "The folder project does not exist or has been deleted",
    "sourceDirectoryMissing": "The folder source image directory does not exist: {path}",
    "imageFilenameInvalid": "Invalid image filename: {filename}",
    "imagePathEscape": "The image path escapes the source directory: {filename}",
    "imageMissing": "The image file does not exist: {filename}",
    "folderNoImages": "The folder contains no images",
    "metadataMissing": "Required folder export metadata is missing: {fields}",
    "tiffCompressionInvalid": "The TIFF does not use adobe_deflate compression: {filename}",
    "sourceDeleted": "A source image was deleted during export: {filename}",
    "sourceChanged": "A source image changed during export: {filename}",
    "zipStructureInvalid": "The ZIP file structure or entry order does not match the contract",
    "zipCrcInvalid": "ZIP CRC validation failed",
    "publishedZipInvalid": "Published ZIP validation failed",
    "publishedZipUnreadable": "The published ZIP cannot be read: {path}",
    "zipConflict": "A same-named ZIP with different content already exists: {filename}",
    "folderConflict": "A same-named export folder already exists: {filename}",
    "publishedFolderInvalid": "Published folder validation failed",
    "publishedFolderUnreadable": "The published folder cannot be read: {path}",
    "zipCopyValidationFailed": "ZIP validation failed after copying to the output directory",
    "folderMissingAtFinalize": "The folder no longer exists when finalising the export",
    "folderGroupConflict": "Another export assigned a different Group ID to this folder",
    "folderNotPassAtFinalize": "The folder is no longer PASS when finalising the export",
    "invalidProjects": "One or more projects have an invalid projects.project_id",
    "taskAlreadyRunning": "An export task is already running on this workstation",
    "noEligibleFolders": "There are no eligible PASS folders to export",
    "folderBusy": "Another workstation is exporting this folder",
    "serviceRestarted": "Processing resumed after the service restarted",
    "unexpected": "An unexpected export error occurred",
}


class ExportError(RuntimeError):
    def __init__(self, key: str, params: dict[str, Any] | None = None):
        self.key = key
        self.params = params or {}
        template = EXPORT_ERROR_MESSAGES.get(key, EXPORT_ERROR_MESSAGES["unexpected"])
        super().__init__(template.format(**self.params))

    def to_dict(self) -> dict[str, Any]:
        return {"errorKey": self.key, "errorParams": self.params}


@dataclass(frozen=True)
class ExportRuntimeConfig:
    temp_dir: Path
    output_dir: Path
    encoding: str
    line_ending_name: str
    line_ending: str

    def to_json(self) -> dict[str, Any]:
        return {
            "tempDir": str(self.temp_dir),
            "outputDir": str(self.output_dir),
            "csvEncoding": self.encoding,
            "csvLineEnding": self.line_ending_name,
        }


@dataclass(frozen=True)
class ImageSource:
    id: int
    name: str
    path: Path
    size: int
    mtime_ns: int
    # LWIP's baseline plus every approved round from qc_ops.json - NOT any
    # still-open draft, since a folder cannot export until it is PASS and a
    # draft is discarded at approval. Replayed once here, the same way a
    # reviewer's preview and commit did - see convert_to_tiff.
    ops: list[dict] = field(default_factory=list)


@dataclass(frozen=True)
class FolderExportSnapshot:
    folder_id: int
    project_id: int
    ingest_project_id: str
    location_code: str
    metadata: dict[str, Any]
    images: list[ImageSource]
    source_user_id: str
    source_date: date
    # Template field ids the project has switched off: no column, not required.
    disabled_fields: frozenset[str] = frozenset()


@dataclass(frozen=True)
class ExportedZip:
    """The built package, before it is published.

    `path` is a .zip file, or the staged DIRECTORY when the project takes its
    packages unzipped (`export_zip_output`). `sha256` is empty for a directory -
    a folder has no single digest, and its integrity is checked per file against
    ArtifactMetadata.csv instead, which is stronger and reuses hashes the export
    already computed.
    """

    path: Path
    size: int
    sha256: str


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def runtime_config() -> ExportRuntimeConfig:
    invalid_fields: list[str] = []
    temp_value = settings.export_temp_dir.strip()
    output_value = settings.export_output_dir.strip()
    encoding_value = settings.export_csv_encoding.strip().lower()
    line_ending_value = settings.export_csv_line_ending.strip().upper()
    if not temp_value:
        invalid_fields.append("EXPORT_TEMP_DIR")
    if not output_value:
        invalid_fields.append("EXPORT_OUTPUT_DIR")
    if encoding_value not in {"utf-8", "utf-8-sig"}:
        invalid_fields.append("EXPORT_CSV_ENCODING")
    if line_ending_value not in {"LF", "CRLF"}:
        invalid_fields.append("EXPORT_CSV_LINE_ENDING")
    if invalid_fields:
        raise ExportError("configInvalid", {"fields": ", ".join(invalid_fields)})
    return ExportRuntimeConfig(
        temp_dir=Path(temp_value).expanduser(),
        output_dir=Path(output_value).expanduser(),
        encoding=encoding_value,
        line_ending_name=line_ending_value,
        line_ending="\n" if line_ending_value == "LF" else "\r\n",
    )


def directory_write_error(directory: Path) -> OSError | None:
    """Create `directory` if needed and prove it is writable, returning the failure.

    Returns rather than raises so the Admin console can report every candidate path
    in one pass; `validate_runtime_paths` turns the same result into the export
    pipeline's `ExportError`. One implementation, two callers.
    """
    probe = directory / f".lwcam-write-test-{uuid.uuid4().hex}"
    try:
        fs_path(directory).mkdir(parents=True, exist_ok=True)
        fs_path(probe).write_bytes(b"ok")
    except OSError as error:
        return error
    finally:
        try:
            fs_path(probe).unlink(missing_ok=True)
        except OSError:
            pass
    return None


def validate_runtime_paths(config: ExportRuntimeConfig) -> None:
    for label, directory in (
        ("EXPORT_TEMP_DIR", config.temp_dir),
        ("EXPORT_OUTPUT_DIR", config.output_dir),
    ):
        error = directory_write_error(directory)
        if error is not None:
            raise ExportError(
                "pathNotWritable",
                {"setting": label, "path": str(directory)},
            ) from error


def project_ingest_id(project: Project) -> str:
    value = str(project.project_id or "").strip()
    if not value:
        raise ExportError("projectIdMissing", {"project": project.project_name})
    validate_group_part("ProjectID", value)
    return value


def disabled_template_fields(project: Project) -> frozenset[str]:
    """Field ids the project's template marks `enabled: false`. A project on
    the built-in template (null) disables nothing."""
    template = project.template if isinstance(project.template, dict) else {}
    fields = template.get("fields") if isinstance(template.get("fields"), list) else []
    return frozenset(
        str(item.get("key") or item.get("id"))
        for item in fields
        if isinstance(item, dict) and item.get("enabled") is False and (item.get("key") or item.get("id"))
    )


def fixed_template_value(project: Project, key: str) -> str:
    template = project.template if isinstance(project.template, dict) else {}
    fields = template.get("fields") if isinstance(template.get("fields"), list) else []
    for item in fields:
        if (
            isinstance(item, dict)
            and (item.get("key") or item.get("id")) == key
            and item.get("enabled") is not False
        ):
            return str(item.get("value") or item.get("fixedValue") or "").strip()
    return ""


def mapped_record_type(project: Project, title: str, fallback: str = "") -> str:
    """Record Type for the CSV.

    A template whose Record Type is EDITABLE means the operator keys it, so the
    keyed value wins and no map is consulted. This matters because switching the
    field from mapped to editable does not clear the old `valueMap`: the Taiping
    template carries a dropdown of church record types alongside four leftover
    South African military mappings. Consulting the map regardless of mode meant
    a title that happened to match a stale entry silently replaced the
    operator's choice with a value not even in the dropdown.

    Mapped (the default) keeps deriving from the title, falling back to whatever
    is stored when the title is not in the map.
    """
    template = project.template if isinstance(project.template, dict) else {}
    fields = template.get("fields") if isinstance(template.get("fields"), list) else []
    record_type_field = next(
        (
            item
            for item in fields
            if isinstance(item, dict)
            and (item.get("key") or item.get("id")) == "recordType"
            and item.get("enabled") is not False
        ),
        None,
    )
    if record_type_field and record_type_field.get("mode") == "editable":
        return str(fallback or "").strip()

    mapping = (
        template.get("titleRecordTypeMap")
        if isinstance(template.get("titleRecordTypeMap"), dict)
        else {}
    )
    mapped_value = mapping.get(title)
    if not mapped_value:
        value_map = record_type_field.get("valueMap") if record_type_field else None
        if isinstance(value_map, dict):
            mapped_value = value_map.get(title)
    return str(mapped_value or fallback or "").strip()


def validate_group_part(label: str, value: str) -> None:
    if not value or not SAFE_GROUP_PART.fullmatch(value):
        raise ExportError("invalidGroupPart", {"label": label})


def parse_source_identity(*filenames: str) -> tuple[str, date]:
    """Capture identity from the first filename that carries it.

    Not simply the first page: a page inserted during QC is committed under the
    reviewer's upload name and, inserted before page 1, sorts first - and the
    folder would then never export.
    """
    filename = filenames[0] if filenames else ""
    match = next((m for m in map(SOURCE_NAME_PATTERN.fullmatch, filenames) if m), None)
    if match is None:
        raise ExportError("sourceFilenameInvalid", {"filename": filename})
    user_id = match.group("user")
    try:
        source_date = datetime.strptime(match.group("date"), "%Y%m%d").date()
    except ValueError as error:
        raise ExportError("sourceDateInvalid", {"filename": filename}) from error
    return user_id, source_date


def allocate_sequence(db: Session, project_id: int) -> int:
    if project_id <= 0:
        raise ExportError("projectIdInvalid")
    sequence_name = f"lwcam_export_project_{project_id}_seq"
    db.execute(
        text("SELECT pg_advisory_xact_lock(hashtextextended(:resource, 0))"),
        {"resource": f"lwcam-export-sequence:{project_id}"},
    )
    db.execute(
        text(
            f"CREATE SEQUENCE IF NOT EXISTS public.{sequence_name} "
            "AS BIGINT START WITH 1 INCREMENT BY 1 MAXVALUE 999999 NO CYCLE"
        )
    )
    value = int(
        db.scalar(text(f"SELECT nextval('public.{sequence_name}'::regclass)")) or 0
    )
    if value < 1 or value > 999999:
        raise ExportError("sequenceExhausted", {"projectId": project_id})
    return value


def build_group_id(snapshot: FolderExportSnapshot, sequence: int) -> str:
    validate_group_part("LocationCode", snapshot.location_code)
    validate_group_part("UserID", snapshot.source_user_id)
    group_id = (
        f"{snapshot.ingest_project_id}{snapshot.location_code}{snapshot.source_user_id}"
        f"{snapshot.source_date.strftime('%y%m%d')}{sequence:06d}"
    )
    if len(group_id) > 255:
        raise ExportError("groupIdTooLong")
    return group_id


def ordered_images(folder: CaptureFolder) -> list[CaptureImage]:
    minimum = datetime.min.replace(tzinfo=timezone.utc)
    return sorted(folder.images, key=lambda item: (item.image_created_at or minimum, item.id))


def load_folder_snapshot(db: Session, folder_id: int) -> FolderExportSnapshot:
    folder = db.scalar(
        select(CaptureFolder)
        .options(
            selectinload(CaptureFolder.images),
            joinedload(CaptureFolder.box).joinedload(CaptureBox.project),
        )
        .where(CaptureFolder.id == folder_id)
    )
    if folder is None or folder.is_deleted:
        raise ExportError("folderMissing")
    if folder.qc_status.lower() != "pass":
        raise ExportError("folderNotPass")
    if folder.is_exported:
        raise ExportError("folderAlreadyExported")
    if not folder.folder_path:
        raise ExportError("sourceDirectoryNotConfigured")
    project = folder.box.project
    if project is None or project.is_deleted:
        raise ExportError("projectMissing")
    image_dir = to_local(folder.folder_path).resolve()
    if not fs_path(image_dir).is_dir():
        raise ExportError("sourceDirectoryMissing", {"path": str(image_dir)})
    image_sources: list[ImageSource] = []
    for image in ordered_images(folder):
        if Path(image.image_name).name != image.image_name:
            raise ExportError("imageFilenameInvalid", {"filename": image.image_name})
        source_path = (image_dir / image.image_name).resolve()
        try:
            source_path.relative_to(image_dir)
        except ValueError as error:
            raise ExportError("imagePathEscape", {"filename": image.image_name}) from error
        if not fs_path(source_path).is_file():
            raise ExportError("imageMissing", {"filename": image.image_name})
        source_stat = fs_path(source_path).stat()
        image_sources.append(
            ImageSource(
                id=image.id,
                name=image.image_name,
                path=source_path,
                size=source_stat.st_size,
                mtime_ns=source_stat.st_mtime_ns,
                ops=effective_ops(image_dir, image.image_name),
            )
        )
    if not image_sources:
        raise ExportError("folderNoImages")
    source_user_id, source_date = parse_source_identity(*(source.name for source in image_sources))
    metadata = {
        "clientRework": bool(folder.client_rework),
        "title": folder.title or "",
        "place": fixed_template_value(project, "place"),
        "startDate": folder.start_date,
        "endDate": folder.end_date,
        "recordType": mapped_record_type(
            project,
            folder.title or "",
            getattr(folder, "record_type", None) or "",
        ),
        "language": fixed_template_value(project, "language"),
        "recordCustodian": fixed_template_value(project, "recordCustodian"),
        "archivalRefNo": folder.archival_ref_no or "",
        "captureOperatorName": fixed_template_value(project, "captureOperatorName"),
        "captureOperatorId": fixed_template_value(project, "captureOperatorId"),
        "volume": folder.volume or "",
        "digitizingEntity": fixed_template_value(project, "digitizingEntity"),
    }
    required_metadata = {
        "Title": metadata["title"],
        "Place": metadata["place"],
        "Start Date": metadata["startDate"],
        "End Date": metadata["endDate"],
        "Record Type": metadata["recordType"],
        "Language": metadata["language"],
        "Record Custodian": metadata["recordCustodian"],
        "Capture Operator Name": metadata["captureOperatorName"],
        "Capture Operator ID": metadata["captureOperatorId"],
        "Volume": metadata["volume"],
        "Digitizing Entity": metadata["digitizingEntity"],
    }
    disabled = disabled_template_fields(project)
    missing = [
        name
        for name, value in required_metadata.items()
        if value in (None, "") and GROUP_CSV_FIELD_IDS.get(name) not in disabled
    ]
    if missing:
        raise ExportError("metadataMissing", {"fields": ", ".join(missing)})
    return FolderExportSnapshot(
        folder_id=folder.id,
        project_id=project.id,
        ingest_project_id=project_ingest_id(project),
        location_code=project.country_location_code,
        metadata=metadata,
        images=image_sources,
        source_user_id=source_user_id,
        source_date=source_date,
        disabled_fields=disabled,
    )


def md5_file(path: Path) -> str:
    digest = hashlib.md5(usedforsecurity=False)
    with fs_path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with fs_path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def convert_to_tiff(source_path: Path, target_path: Path, ops: list[dict] | None = None) -> tuple[int, int]:
    """Decode [source_path], replay [ops], and write the lossless TIFF.

    [ops] is the ONLY place LWIP's baseline straighten/crop and a reviewer's
    approved geometry ever become pixels - see services/qc_ops_store and
    routers/qc.py's module docstring on why they are never baked any earlier.
    Width/height below are read off the SAVED file, so they already reflect
    whatever the replay did to the frame's size.
    """
    fs_path(target_path.parent).mkdir(parents=True, exist_ok=True)
    temp_path = target_path.with_name(f".{target_path.name}.tmp")
    try:
        with Image.open(fs_path(source_path)) as source:
            if getattr(source, "n_frames", 1) > 1:
                source.seek(0)
            frame = source.copy()
            if ops:
                frame = replay_pending_ops(frame, ops)
            save_options: dict[str, Any] = {"compression": "tiff_adobe_deflate"}
            if source.info.get("icc_profile"):
                save_options["icc_profile"] = source.info["icc_profile"]
            if source.info.get("dpi"):
                save_options["dpi"] = source.info["dpi"]
            # The last step in the pipeline, and until now the one that undid the
            # rest: ICC and DPI were carried but the capture's identity was not,
            # so the provenance LWIP and QC preserve was discarded at the finish
            # line and the client received an artifact with no camera metadata.
            #
            # It has to be copied tag by tag. Handing TIFF the JPEG EXIF blob as
            # `exif=` does not degrade, it CRASHES: libtiff rejects the APP1
            # block's ExifIFD pointer ("Bad LONG8 or IFD8 value ... for
            # EXIFIFDOffset") and the save raises, which would have failed every
            # export. Only the tags TIFF defines natively can travel; the EXIF
            # sub-IFD (ISO, exposure, focal length) has no TIFF home and stays
            # behind in the working JPEG.
            camera_tags = source.getexif()
            carried = TiffImagePlugin.ImageFileDirectory_v2()
            for tag in TIFF_PROVENANCE_TAGS:
                value = camera_tags.get(tag)
                if value in (None, ""):
                    continue
                value = sanitise_tiff_tag(tag, value)
                if value in (None, ""):
                    continue
                carried[tag] = value
            if carried:
                save_options["tiffinfo"] = carried
            frame.save(fs_path(temp_path), format="TIFF", **save_options)
        os.replace(fs_path(temp_path), fs_path(target_path))
    finally:
        fs_path(temp_path).unlink(missing_ok=True)
    with Image.open(fs_path(target_path)) as result:
        compression = result.tag_v2.get(259)
        if compression not in DEFLATE_COMPRESSION_TAGS:
            raise ExportError(
                "tiffCompressionInvalid",
                {"filename": target_path.name},
            )
        width, height = result.size
        result.verify()
    return width, height


def write_csv(
    path: Path,
    headers: list[str],
    rows: list[dict[str, Any]],
    config: ExportRuntimeConfig,
) -> None:
    with fs_path(path).open("w", encoding=config.encoding, newline="") as output:
        writer = csv.DictWriter(
            output,
            fieldnames=headers,
            extrasaction="raise",
            lineterminator=config.line_ending,
        )
        writer.writeheader()
        writer.writerows(rows)


def verify_sources_unchanged(snapshot: FolderExportSnapshot) -> None:
    for source in snapshot.images:
        if not fs_path(source.path).is_file():
            raise ExportError("sourceDeleted", {"filename": source.name})
        current = fs_path(source.path).stat()
        if current.st_size != source.size or current.st_mtime_ns != source.mtime_ns:
            raise ExportError("sourceChanged", {"filename": source.name})


# Below this, a process pool costs more than it saves: on Windows each worker is
# a fresh interpreter that must import PIL and this module before it converts
# anything, and that startup outweighs a couple of images.
EXPORT_PARALLEL_MIN_IMAGES = 4


def export_worker_count() -> int:
    """How many processes to convert images with.

    Mirrors LWIP's sizing rule (`deskew_crop_tool/config.py`) deliberately: both
    run on the same station, so they should agree about what the hardware can
    take. Every core but one, capped at 61 - Windows cannot wait on more process
    handles than that.
    """
    configured = settings.export_worker_count
    if configured > 0:
        return min(61, configured)
    # Also covers a negative: the setting is typed into a free-text box, and
    # "auto" is the only sane reading of a number that cannot be a worker count.
    return min(61, max(1, (os.cpu_count() or 2) - 1))


_pool_lock = threading.Lock()
_pool: ProcessPoolExecutor | None = None
_pool_size = 0


def conversion_pool(workers: int) -> ProcessPoolExecutor:
    """The shared TIFF-conversion pool, created on first use and kept.

    A pool per folder meant spawning `workers` fresh Windows interpreters -
    each importing PIL and this module - for every folder, then throwing them
    away: a couple of seconds of pure overhead per folder that dominates small
    ones. Workers in a kept pool are spawned lazily as jobs arrive and then
    stay warm. The pool is grown, never shrunk, if a later call wants more
    workers; `shutdown_conversion_pool` (lifespan end, or after a broken pool)
    releases it.
    """
    global _pool, _pool_size
    with _pool_lock:
        if _pool is None or _pool_size < workers:
            if _pool is not None:
                _pool.shutdown(wait=False, cancel_futures=True)
            _pool = ProcessPoolExecutor(max_workers=workers)
            _pool_size = workers
        return _pool


def shutdown_conversion_pool() -> None:
    global _pool, _pool_size
    with _pool_lock:
        pool, _pool, _pool_size = _pool, None, 0
    if pool is not None:
        pool.shutdown(wait=True, cancel_futures=True)


def convert_all(jobs: list[tuple[str, str, str, list[dict]]]) -> list[dict[str, Any]]:
    """Converts every job, in order, across the shared pool when it pays.

    A worker killed underneath us (a crash, an OOM) breaks the whole pool; that
    is retried once on a fresh pool before the folder is failed, since the
    images themselves were not the cause.
    """
    workers = min(export_worker_count(), len(jobs))
    if workers <= 1 or len(jobs) < EXPORT_PARALLEL_MIN_IMAGES:
        return [convert_and_hash(job) for job in jobs]
    for attempt in range(2):
        try:
            return list(conversion_pool(workers).map(convert_and_hash, jobs))
        except BrokenProcessPool:
            shutdown_conversion_pool()
            if attempt == 1:
                raise
            logger.warning("Conversion pool broke; retrying the folder on a fresh pool")
    raise AssertionError("unreachable")


def convert_and_hash(job: tuple[str, str, str, list[dict]]) -> dict[str, Any]:
    """One image: convert to TIFF, measure it, hash it. Runs in a worker process.

    Module level and plain-tuple arguments because a process pool has to pickle
    both the callable and its arguments - `ops` is plain dicts/lists, so it
    pickles the same way.

    Errors are simply raised: the pool re-raises them in the parent, exactly as
    the serial path did. ExportError survives that round trip intact - pickling
    an exception carries its __dict__, so `key` and `params` are restored after
    construction, and the "unexpected" fallback message has no placeholders so
    the intermediate construction cannot throw either. (Verified in
    test_export_parallel.py, which fails if that ever stops being true.)
    """
    source_path, target_path, artifact_name, ops = job
    target = Path(target_path)
    width, height = convert_to_tiff(Path(source_path), target, ops)
    return {
        "Filename": artifact_name,
        "File Size": fs_path(target).stat().st_size,
        "Artifact Type": "Image",
        "Hash Algorithm": "MD5",
        "Hash": md5_file(target),
        "Image Width": width,
        "Image Height": height,
        "Capture ID": target.stem,
    }


def build_export_zip(
    snapshot: FolderExportSnapshot,
    group_id: str,
    run_id: str,
    config: ExportRuntimeConfig,
) -> ExportedZip:
    work_dir = config.temp_dir / ".lwcam-export" / "work" / run_id / str(snapshot.folder_id)
    if fs_path(work_dir).exists():
        shutil.rmtree(fs_path(work_dir))
    artifacts_dir = work_dir / "artifacts"
    fs_path(artifacts_dir).mkdir(parents=True, exist_ok=True)
    jobs = [
        (
            str(source.path),
            str(artifacts_dir / f"{group_id}_Image{index:04d}.tif"),
            f"{group_id}_Image{index:04d}.tif",
            source.ops,
        )
        for index, source in enumerate(snapshot.images, start=1)
    ]
    # Decoding a JPEG and re-encoding it as deflate TIFF is CPU-bound, and the
    # GIL means threads would not help - only processes. Each image writes to its
    # own path and reads nothing shared, so they are independent. `map` keeps the
    # order, which matters: the artifact rows are the CSV's page order.
    artifact_rows = convert_all(jobs)
    metadata = snapshot.metadata
    group_rows = [
        {
            "Rework": "TRUE" if metadata["clientRework"] else "FALSE",
            "Title": metadata["title"],
            "Place": metadata["place"],
            # Verbatim: the archive's own notation, as keyed. FamilySearch takes it as-is.
            "Start Date": metadata["startDate"] or "",
            "End Date": metadata["endDate"] or "",
            "Record Type": metadata["recordType"],
            "Language": metadata["language"],
            "Record Custodian": metadata["recordCustodian"],
            "Archival Reference Number": metadata["archivalRefNo"],
            "Capture ID": group_id,
            "Capture Operator Name": metadata["captureOperatorName"],
            "Capture Operator ID": metadata["captureOperatorId"],
            "Total Artifacts": len(artifact_rows),
            "Volume": metadata["volume"],
            "Capture Date": snapshot.source_date.isoformat(),
            "Digitizing Entity": metadata["digitizingEntity"],
        }
    ]
    headers = group_csv_headers(snapshot.disabled_fields)
    group_rows = [{h: row[h] for h in headers} for row in group_rows]
    write_csv(work_dir / GROUP_CSV_NAME, headers, group_rows, config)
    write_csv(work_dir / ARTIFACT_CSV_NAME, ARTIFACT_CSV_HEADERS, artifact_rows, config)
    verify_sources_unchanged(snapshot)

    if not settings.export_zip_output:
        # Nothing more to build: work_dir already IS the package layout - the two
        # CSVs beside an artifacts/ directory - which is exactly what the zip
        # below would contain. publish_package copies and renames it into place.
        return ExportedZip(path=work_dir, size=package_size(work_dir), sha256="")

    zip_path = work_dir / f"{group_id}.zip"
    with zipfile.ZipFile(fs_path(zip_path), "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.write(fs_path(work_dir / GROUP_CSV_NAME), GROUP_CSV_NAME)
        archive.write(fs_path(work_dir / ARTIFACT_CSV_NAME), ARTIFACT_CSV_NAME)
        for row in artifact_rows:
            artifact_name = str(row["Filename"])
            archive.write(fs_path(artifacts_dir / artifact_name), f"artifacts/{artifact_name}")
    expected_names = [
        GROUP_CSV_NAME,
        ARTIFACT_CSV_NAME,
        *[f"artifacts/{row['Filename']}" for row in artifact_rows],
    ]
    with zipfile.ZipFile(fs_path(zip_path)) as archive:
        if archive.namelist() != expected_names:
            raise ExportError("zipStructureInvalid")
        if archive.testzip() is not None:
            raise ExportError("zipCrcInvalid")
    return ExportedZip(
        path=zip_path,
        size=fs_path(zip_path).stat().st_size,
        sha256=sha256_file(zip_path),
    )


def verify_published_zip(path: Path, group_id: str, artifact_count: int) -> None:
    expected_names = [
        GROUP_CSV_NAME,
        ARTIFACT_CSV_NAME,
        *[
            f"artifacts/{group_id}_Image{index:04d}.tif"
            for index in range(1, artifact_count + 1)
        ],
    ]
    try:
        with zipfile.ZipFile(fs_path(path)) as archive:
            if archive.namelist() != expected_names or archive.testzip() is not None:
                raise ExportError("publishedZipInvalid")
    except (OSError, zipfile.BadZipFile) as error:
        raise ExportError("publishedZipUnreadable", {"path": str(path)}) from error


def package_size(path: Path) -> int:
    if fs_path(path).is_dir():
        # Walked from the prefixed root, so every yielded child is already
        # extended-form - no need to re-wrap f for the stat()/is_file() below.
        return sum(f.stat().st_size for f in fs_path(path).rglob("*") if f.is_file())
    return fs_path(path).stat().st_size


def package_digest(path: Path) -> str:
    """sha256 for a published zip; empty for a folder.

    A directory has no single digest, and inventing one would mean re-hashing
    every TIFF on a resume. The folder's own ArtifactMetadata.csv already carries
    a per-file MD5, so verify_published_folder is what re-checks it.
    """
    if fs_path(path).is_dir():
        return ""
    return sha256_file(path)


def published_package_path(group_id: str, config: ExportRuntimeConfig) -> Path:
    """Where this group's package lands, in whichever form the project takes."""
    if settings.export_zip_output:
        return config.output_dir / f"{group_id}.zip"
    return config.output_dir / group_id


def verify_published_folder(
    path: Path, group_id: str, artifact_count: int, encoding: str
) -> None:
    """The unzipped counterpart of verify_published_zip.

    A folder has no CRC table, so its own ArtifactMetadata.csv is the checklist:
    every artifact named there must be present and hash to the MD5 recorded when
    it was converted. That is a stronger check than the zip's, and free - those
    hashes were computed during the export.
    """
    expected_names = [
        f"{group_id}_Image{index:04d}.tif"
        for index in range(1, artifact_count + 1)
    ]
    manifest = path / ARTIFACT_CSV_NAME
    try:
        if not fs_path(path / GROUP_CSV_NAME).is_file() or not fs_path(manifest).is_file():
            raise ExportError("publishedFolderInvalid")
        with fs_path(manifest).open("r", encoding=encoding, newline="") as handle:
            rows = list(csv.DictReader(handle))
        if [row["Filename"] for row in rows] != expected_names:
            raise ExportError("publishedFolderInvalid")
        for row in rows:
            artifact = path / "artifacts" / row["Filename"]
            if not fs_path(artifact).is_file():
                raise ExportError("publishedFolderInvalid")
            if fs_path(artifact).stat().st_size != int(row["File Size"]):
                raise ExportError("publishedFolderInvalid")
            if md5_file(artifact) != row["Hash"]:
                raise ExportError("publishedFolderInvalid")
    except (OSError, KeyError, ValueError) as error:
        raise ExportError("publishedFolderUnreadable", {"path": str(path)}) from error


def _replace_with_retry(source: Path, target: Path, attempts: int = 5) -> None:
    """os.replace with a short retry on PermissionError.

    Renaming a directory on Windows fails while any file under it is open, and
    an antivirus scan of a freshly copied TIFF is enough. The handle is released
    within milliseconds, so retrying keeps a verified package from being thrown
    away by the caller's staging cleanup.
    """
    for attempt in range(attempts):
        try:
            os.replace(fs_path(source), fs_path(target))
            return
        except PermissionError:
            if attempt == attempts - 1:
                raise
            time.sleep(0.5)


def upload_ledger_path(config: ExportRuntimeConfig) -> Path:
    """Where the upload sweep keeps its per-package state.

    Duplicated deliberately rather than imported from `upload.py`: that module
    imports boto3 lazily and owns the sweep, and the export has no business
    pulling it in just to invalidate one row. Same path both sides compute -
    keep them together if it ever moves.
    """
    return config.temp_dir / ".lwcam-export" / "uploads.json"


def clear_upload_ledger_entry(config: ExportRuntimeConfig, package_name: str) -> bool:
    """Forget that [package_name] was uploaded, so the sweep sends it again.

    Best effort on purpose: the package is published either way, and a ledger
    that cannot be written must not fail an export that has already succeeded.
    The cost of failing to clear is that the correction waits for someone to
    retry the upload, not that anything is lost.
    """
    path = upload_ledger_path(config)
    ledger = JsonLedger(path)
    data = ledger.load()
    if package_name not in data:
        return False
    data.pop(package_name, None)
    ledger.save(data, best_effort=True)
    return True


def _remove_published(path: Path) -> None:
    """Delete a published package so a rework can take its name.

    Only ever called with `replace`, which only a client rework sets: the
    package under that name is the version the client rejected, and the
    corrected one has to land under the SAME Group ID.
    """
    if fs_path(path).is_dir():
        shutil.rmtree(fs_path(path), ignore_errors=True)
    else:
        fs_path(path).unlink(missing_ok=True)


def publish_folder(
    exported: ExportedZip,
    group_id: str,
    config: ExportRuntimeConfig,
    artifact_count: int,
    *,
    replace: bool = False,
) -> Path:
    """Publishes an unzipped package by renaming a fully-built directory.

    Same shape as publish_zip and for the same reason: the copy into staging may
    cross volumes, the rename that makes the package VISIBLE never does, so a
    consumer watching the output folder cannot see a half-copied group. A
    directory rename is atomic within a volume too, but unlike a file it will not
    overwrite - which suits us, since an existing group is a conflict either way.
    """
    staging_dir = config.output_dir / ".staging"
    fs_path(staging_dir).mkdir(parents=True, exist_ok=True)
    final_path = config.output_dir / group_id
    partial_path = staging_dir / group_id
    if fs_path(final_path).exists() and replace:
        # A client rework republishes under the SAME Group ID, so the package
        # already there is the version the client rejected. Refusing would
        # strand the correction; leaving it would ship the old pages.
        _remove_published(final_path)
    if fs_path(final_path).exists():
        raise ExportError("folderConflict", {"filename": final_path.name})
    try:
        if fs_path(partial_path).exists():
            shutil.rmtree(fs_path(partial_path))
        shutil.copytree(fs_path(exported.path), fs_path(partial_path))
        verify_published_folder(
            partial_path, group_id, artifact_count, config.encoding
        )
        _replace_with_retry(partial_path, final_path)
    finally:
        shutil.rmtree(fs_path(partial_path), ignore_errors=True)
        try:
            if not any(fs_path(staging_dir).iterdir()):
                fs_path(staging_dir).rmdir()
        except OSError:
            pass
    return final_path


def publish_package(
    exported: ExportedZip,
    group_id: str,
    config: ExportRuntimeConfig,
    artifact_count: int,
    *,
    replace: bool = False,
) -> Path:
    """Publishes the built package in whichever form the project takes.

    The single place the output format is branched on, so every caller - the
    normal run, the resume path and the tests - agrees about what a published
    package is.
    """
    if fs_path(exported.path).is_dir():
        return publish_folder(exported, group_id, config, artifact_count, replace=replace)
    return publish_zip(exported, group_id, config, replace=replace)


def verify_published_package(
    path: Path, group_id: str, artifact_count: int, config: ExportRuntimeConfig
) -> None:
    if settings.export_zip_output:
        verify_published_zip(path, group_id, artifact_count)
    else:
        verify_published_folder(path, group_id, artifact_count, config.encoding)


def publish_zip(
    exported: ExportedZip,
    group_id: str,
    config: ExportRuntimeConfig,
    *,
    replace: bool = False,
) -> Path:
    """Copies the built ZIP to the output folder and publishes it by rename.

    Staging lives INSIDE the output folder deliberately, because os.replace is
    only atomic within one volume - that is what stops the ingest team ever
    seeing a partial package. Keeping it here is also what lets 1.Images,
    2.Batches and 3.Export sit on three DIFFERENT drives: the copy above crosses
    volumes happily, and the rename below never has to. Moving staging under the
    work root would make the same-drive rule a hard requirement instead of the
    convention Station Setup currently enforces.

    The directory is removed again when it empties, so 3.Export holds nothing but
    finished ZIPs at rest - it only exists for the seconds a publish is in
    flight.
    """
    staging_dir = config.output_dir / ".staging"
    fs_path(staging_dir).mkdir(parents=True, exist_ok=True)
    final_path = config.output_dir / f"{group_id}.zip"
    partial_path = staging_dir / f"{group_id}.zip.partial"
    if fs_path(final_path).is_file() and replace:
        # See publish_folder: the package under this name is the one the client
        # sent back.
        _remove_published(final_path)
    if fs_path(final_path).is_file():
        same_size = fs_path(final_path).stat().st_size == exported.size
        if same_size and sha256_file(final_path) == exported.sha256:
            return final_path
        raise ExportError("zipConflict", {"filename": final_path.name})
    try:
        shutil.copyfile(fs_path(exported.path), fs_path(partial_path))
        with fs_path(partial_path).open("rb+") as output:
            output.flush()
            os.fsync(output.fileno())
        if (
            fs_path(partial_path).stat().st_size != exported.size
            or sha256_file(partial_path) != exported.sha256
        ):
            raise ExportError("zipCopyValidationFailed")
        os.replace(fs_path(partial_path), fs_path(final_path))
    finally:
        fs_path(partial_path).unlink(missing_ok=True)
        # Only when empty: a concurrent publish of another folder may still have
        # its own partial in here.
        try:
            if not any(fs_path(staging_dir).iterdir()):
                fs_path(staging_dir).rmdir()
        except OSError:
            pass
    return final_path


def finalize_folder(folder_id: int, group_id: str) -> None:
    with SessionLocal() as db:
        folder = db.scalar(
            select(CaptureFolder)
            .options(lazyload("*"))
            .where(CaptureFolder.id == folder_id)
            .with_for_update(of=CaptureFolder)
        )
        if folder is None or folder.is_deleted:
            raise ExportError("folderMissingAtFinalize")
        if folder.is_exported:
            if folder.group_id != group_id:
                raise ExportError("folderGroupConflict")
            return
        if folder.qc_status.lower() != "pass":
            raise ExportError("folderNotPassAtFinalize")
        folder.group_id = group_id
        folder.is_tif_converted = True
        folder.is_exported = True
        folder.exported_time = utc_now()
        db.commit()


def eligible_folder_ids(db: Session) -> list[int]:
    return list(
        db.scalars(
            select(CaptureFolder.id)
            .where(
                func.lower(CaptureFolder.qc_status) == "pass",
                CaptureFolder.is_exported.is_not(True),
                CaptureFolder.is_deleted.is_not(True),
            )
            .order_by(CaptureFolder.source_created_at.asc().nullslast(), CaptureFolder.id.asc())
        ).all()
    )


def list_export_folders(
    db: Session,
    export_status: str = "all",
    *,
    page: int = 1,
    size: int = 20,
) -> tuple[list[dict[str, Any]], int]:
    conditions = [
        CaptureFolder.is_deleted.is_not(True),
        func.lower(CaptureFolder.qc_status) != "rework",
    ]
    if export_status == "exported":
        conditions.append(CaptureFolder.is_exported.is_(True))
    elif export_status == "unexported":
        conditions.append(CaptureFolder.is_exported.is_not(True))

    folder_scope = (
        select(CaptureFolder.id)
        .join(CaptureBox, CaptureFolder.box_id == CaptureBox.box_id)
        .join(Project, CaptureBox.project_id == Project.id)
        .where(*conditions)
    )
    total = int(
        db.scalar(
            select(func.count()).select_from(folder_scope.order_by(None).subquery())
        )
        or 0
    )
    rows = db.execute(
        select(
            CaptureFolder.id.label("folder_id"),
            CaptureFolder.folder_name,
            CaptureFolder.folder_seq,
            CaptureFolder.qc_status,
            CaptureFolder.is_exported,
            CaptureFolder.exported_time,
            CaptureFolder.group_id,
            CaptureBox.box_name,
            Project.project_id,
            Project.project_name,
            func.count(CaptureImage.id).label("image_count"),
        )
        .join(CaptureBox, CaptureFolder.box_id == CaptureBox.box_id)
        .join(Project, CaptureBox.project_id == Project.id)
        .outerjoin(CaptureImage, CaptureImage.folder_id == CaptureFolder.id)
        .where(*conditions)
        .group_by(
            CaptureFolder.id,
            CaptureFolder.folder_name,
            CaptureFolder.folder_seq,
            CaptureFolder.qc_status,
            CaptureFolder.is_exported,
            CaptureFolder.exported_time,
            CaptureFolder.group_id,
            CaptureBox.box_name,
            Project.project_id,
            Project.project_name,
            CaptureFolder.source_created_at,
        )
        .order_by(CaptureFolder.source_created_at.asc().nullslast(), CaptureFolder.id.asc())
        .offset((page - 1) * size)
        .limit(size)
    ).all()
    records = [
        {
            "folderId": row.folder_id,
            "folderName": row.folder_name,
            "folderSeq": row.folder_seq,
            "qcStatus": row.qc_status,
            "isExported": bool(row.is_exported),
            "exportedTime": row.exported_time,
            "groupId": row.group_id,
            "exportable": row.qc_status.lower() == "pass" and not bool(row.is_exported),
            "boxName": row.box_name,
            "projectId": row.project_id,
            "projectName": row.project_name,
            "imageCount": row.image_count,
        }
        for row in rows
    ]
    return records, total


class ExportCoordinator:
    def __init__(self) -> None:
        self._state_lock = threading.RLock()
        self._start_lock = threading.Lock()
        self._thread: threading.Thread | None = None
        self._state: dict[str, Any] | None = None

    def _state_root(self, config: ExportRuntimeConfig) -> Path:
        root = config.temp_dir / ".lwcam-export"
        fs_path(root).mkdir(parents=True, exist_ok=True)
        legacy_runs = root / "runs"
        if fs_path(legacy_runs).is_dir():
            try:
                shutil.rmtree(fs_path(legacy_runs))
            except OSError:
                pass
        return root

    def _failures(self, config: ExportRuntimeConfig) -> JsonLedger:
        return JsonLedger(self._failures_path(config))

    def _failures_path(self, config: ExportRuntimeConfig) -> Path:
        """Where unresolved export failures are kept.

        Separate from active.json, which holds ONE run and is overwritten by the
        next - a failure recorded only there stops being reviewable the moment
        anybody exports again. This file is keyed by folder and an entry is
        removed once that folder finally exports, so it answers "what is still
        broken" rather than "what happened last time".

        Safe from the retention sweep: _cleanup_workspaces only touches
        .lwcam-export/work/*, never the root.
        """
        return self._state_root(config) / "failures.json"

    def read_failures(self, config: ExportRuntimeConfig | None = None) -> list[dict[str, Any]]:
        """Unresolved failures, newest first.

        Never raises: a missing or corrupt ledger reports nothing rather than
        breaking the screen whose whole job is to show what went wrong.
        """
        try:
            config = config or runtime_config()
        except ExportError:
            return []
        entries = self._failures(config).entries()
        entries.sort(key=lambda item: str(item.get("failedAt") or ""), reverse=True)
        return entries

    def _load_failures(self, config: ExportRuntimeConfig) -> dict[str, Any]:
        return self._failures(config).load()

    def _write_failures(self, config: ExportRuntimeConfig, data: dict[str, Any]) -> None:
        # Best effort: a ledger write must never take down an export that
        # otherwise succeeded; the run's own state still records what happened.
        self._failures(config).save(data, best_effort=True)

    def _record_failure(self, config: ExportRuntimeConfig, item: dict[str, Any]) -> None:
        data = self._load_failures(config)
        key = str(item.get("folderId"))
        previous = data.get(key) if isinstance(data.get(key), dict) else {}
        with self._state_lock:
            run_id = (self._state or {}).get("runId")
        data[key] = {
            "folderId": item.get("folderId"),
            "error": item.get("error"),
            "errorKey": item.get("errorKey"),
            "errorParams": item.get("errorParams"),
            "failedAt": utc_now().isoformat(),
            # Counts attempts, so a folder failing the same way repeatedly is
            # visibly different from one that failed once.
            "attempts": int(previous.get("attempts") or 0) + 1,
            "lastRunId": run_id,
            # What the failed run had already published, if anything, so a
            # retry adopts that package instead of allocating a new group id
            # and publishing a second one beside it.
            "groupId": item.get("groupId"),
            "zipPath": item.get("zipPath"),
        }
        self._write_failures(config, data)

    def clear_failure(
        self, folder_id: Any, config: ExportRuntimeConfig | None = None
    ) -> None:
        """Drops a folder's entry once it exports, or once it can no longer be
        exported - what makes this ledger "unresolved failures" rather than a
        log that only grows."""
        config = config or runtime_config()
        data = self._load_failures(config)
        if data.pop(str(folder_id), None) is None:
            return
        self._write_failures(config, data)

    def _persist(self, config: ExportRuntimeConfig) -> None:
        with self._state_lock:
            if self._state is None:
                return
            payload = json.loads(json.dumps(self._state, ensure_ascii=False, default=str))
        root = self._state_root(config)
        atomic_json(root / "active.json", payload)

    def _cleanup_workspaces(self, config: ExportRuntimeConfig) -> None:
        work_root = self._state_root(config) / "work"
        if not fs_path(work_root).is_dir():
            return
        cutoff = utc_now() - timedelta(hours=settings.export_temp_retention_hours)
        # Walked from the prefixed root, so `path` is already extended-form for
        # every syscall below - no need to re-wrap it.
        for path in fs_path(work_root).iterdir():
            try:
                modified = datetime.fromtimestamp(path.stat().st_mtime, timezone.utc)
                if path.is_dir() and modified < cutoff:
                    shutil.rmtree(path)
            except OSError:
                continue

    def current(self) -> dict[str, Any] | None:
        with self._state_lock:
            if self._state is not None:
                return json.loads(json.dumps(self._state, ensure_ascii=False, default=str))
        try:
            config = runtime_config()
        except ExportError:
            return None
        path = config.temp_dir / ".lwcam-export" / "active.json"
        if not fs_path(path).is_file():
            return None
        try:
            return json.loads(fs_path(path).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return None

    def preflight(self, db: Session) -> dict[str, Any]:
        errors: list[dict[str, Any]] = []
        config: ExportRuntimeConfig | None = None
        try:
            config = runtime_config()
            validate_runtime_paths(config)
        except ExportError as error:
            errors.append(error.to_dict())
        eligible_conditions = [
            func.lower(CaptureFolder.qc_status) == "pass",
            CaptureFolder.is_exported.is_not(True),
            CaptureFolder.is_deleted.is_not(True),
        ]
        eligible_count = int(
            db.scalar(
                select(func.count(CaptureFolder.id)).where(*eligible_conditions)
            )
            or 0
        )
        exported_count = int(
            db.scalar(
                select(func.count(CaptureFolder.id)).where(
                    CaptureFolder.is_exported.is_(True),
                    CaptureFolder.is_deleted.is_not(True),
                    func.lower(CaptureFolder.qc_status) != "rework",
                )
            )
            or 0
        )
        invalid_projects: list[dict[str, Any]] = []
        if eligible_count:
            project_ids = db.scalars(
                select(CaptureBox.project_id)
                .join(CaptureFolder, CaptureFolder.box_id == CaptureBox.box_id)
                .where(*eligible_conditions)
                .distinct()
            ).all()
            projects = db.scalars(
                select(Project).where(
                    Project.id.in_(project_ids),
                    Project.is_deleted.is_not(True),
                )
            ).all()
            for project in projects:
                try:
                    project_ingest_id(project)
                except ExportError:
                    invalid_projects.append(
                        {
                            "id": project.id,
                            "projectId": project.project_id,
                            "projectName": project.project_name,
                        }
                    )
        if invalid_projects:
            errors.append(ExportError("invalidProjects").to_dict())
        return {
            "ready": not errors,
            "errors": errors,
            "eligibleCount": eligible_count,
            "exportedCount": exported_count,
            "invalidProjects": invalid_projects,
            "config": config.to_json() if config else None,
            "activeRun": self.current(),
        }

    def start(
        self,
        admin_user_id: str,
        folder_ids: list[int] | None = None,
    ) -> dict[str, Any]:
        config = runtime_config()
        validate_runtime_paths(config)
        self._cleanup_workspaces(config)
        with self._start_lock:
            if self._thread is not None and self._thread.is_alive():
                raise ExportError("taskAlreadyRunning")
            with SessionLocal() as db:
                selected = folder_ids if folder_ids is not None else eligible_folder_ids(db)
                if not selected:
                    raise ExportError("noEligibleFolders")
            state = {
                "runId": uuid.uuid4().hex,
                "status": "QUEUED",
                "createdBy": admin_user_id,
                "createdAt": utc_now().isoformat(),
                "startedAt": None,
                "completedAt": None,
                "settings": config.to_json(),
                "total": len(selected),
                "succeeded": 0,
                "failed": 0,
                "skipped": 0,
                "currentFolderId": None,
                "items": [
                    {
                        "folderId": folder_id,
                        "status": "PENDING",
                        "groupId": None,
                        "zipPath": None,
                        "zipSize": None,
                        "zipSha256": None,
                        "error": None,
                        "errorKey": None,
                        "errorParams": None,
                    }
                    for folder_id in selected
                ],
            }
            with self._state_lock:
                self._state = state
            self._persist(config)
            self._thread = threading.Thread(
                target=self._run,
                args=(config,),
                name=f"lwcam-export-{state['runId']}",
                daemon=True,
            )
            self._thread.start()
            return self.current() or state

    def resume_if_needed(self) -> None:
        try:
            config = runtime_config()
        except ExportError:
            return
        active_path = config.temp_dir / ".lwcam-export" / "active.json"
        if not fs_path(active_path).is_file():
            return
        try:
            state = json.loads(fs_path(active_path).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            # Unreadable state means an interrupted run cannot be resumed, and
            # its folders simply stay un-exported. Say so: returning in silence
            # made the one case worth investigating look identical to the normal
            # "nothing was running" path.
            logger.warning(
                "Export resume skipped; the run state could not be read. "
                "path=%s error_type=%s",
                active_path,
                type(error).__name__,
            )
            return
        if state.get("status") not in {"QUEUED", "RUNNING"}:
            return
        for item in state.get("items", []):
            if item.get("status") == "RUNNING":
                item["status"] = "PENDING"
                error = ExportError("serviceRestarted")
                item["error"] = str(error)
                item.update(error.to_dict())
        state["status"] = "QUEUED"
        with self._state_lock:
            self._state = state
        with self._start_lock:
            if self._thread is None or not self._thread.is_alive():
                self._thread = threading.Thread(
                    target=self._run,
                    args=(config,),
                    name=f"lwcam-export-{state['runId']}",
                    daemon=True,
                )
                self._thread.start()

    def _discard_workspace(
        self,
        config: ExportRuntimeConfig,
        run_id: str | None,
        folder_id: Any,
    ) -> None:
        """Removes one folder's export workspace.

        Best effort on purpose: the folder IS exported by the time this runs, so
        a workspace that cannot be deleted - an antivirus scanner still holding a
        TIFF is the usual reason - must not turn a finished export into a
        failure. Whatever survives is aged out by _cleanup_workspaces.
        """
        if run_id is None or folder_id is None:
            return
        workspace = (
            self._state_root(config) / "work" / str(run_id) / str(folder_id)
        )
        try:
            if fs_path(workspace).is_dir():
                shutil.rmtree(fs_path(workspace))
            # Drop the run's directory too once its last folder is gone, so the
            # sweep is not left walking empty shells.
            parent = workspace.parent
            if fs_path(parent).is_dir() and not any(fs_path(parent).iterdir()):
                fs_path(parent).rmdir()
        except OSError as error:
            logger.warning(
                "Export workspace could not be removed; it will be swept later. "
                "path=%s error_type=%s",
                workspace,
                type(error).__name__,
            )

    def _set_item(self, config: ExportRuntimeConfig, item: dict[str, Any], **values: Any) -> None:
        run_id: str | None = None
        with self._state_lock:
            item.update(values)
            if self._state:
                run_id = self._state.get("runId")
                self._state["succeeded"] = sum(
                    candidate.get("status") == "SUCCEEDED"
                    for candidate in self._state["items"]
                )
                self._state["failed"] = sum(
                    candidate.get("status") == "FAILED"
                    for candidate in self._state["items"]
                )
                self._state["skipped"] = sum(
                    candidate.get("status") == "SKIPPED_BUSY"
                    for candidate in self._state["items"]
                )
        self._persist(config)
        # Every failure path funnels through here - ExportError, an unexpected
        # exception, and folderBusy - so the ledger is maintained in one place
        # rather than at each raise site. SKIPPED_BUSY is deliberately NOT a
        # failure: that folder was locked, not broken, and the next run picks it
        # up on its own.
        status = values.get("status")
        if status == "FAILED":
            self._record_failure(config, item)
        elif status == "SUCCEEDED":
            self.clear_failure(item.get("folderId"), config)
            # The workspace has no reader once the ZIP is published, verified and
            # hashed: build_export_zip rmtree's and rebuilds it, and a resumed
            # run re-does the folder from scratch, so nothing ever picks it back
            # up. Left behind it is roughly TEN TIMES the source in TIFFs - 8
            # pages measured at 424 MB - per run, inside the install tree, until
            # some later run's retention sweep happens to catch it. A FAILED
            # folder's workspace is kept: that is the one somebody may want to
            # look at, and _cleanup_workspaces ages it out.
            self._discard_workspace(config, run_id, item.get("folderId"))

    def _run(self, config: ExportRuntimeConfig) -> None:
        with self._state_lock:
            if not self._state:
                return
            self._state["status"] = "RUNNING"
            self._state["startedAt"] = self._state.get("startedAt") or utc_now().isoformat()
            items = self._state["items"]
            run_id = self._state["runId"]
        self._persist(config)
        for item in items:
            if item.get("status") in {"SUCCEEDED", "SKIPPED_BUSY"}:
                continue
            folder_id = int(item["folderId"])
            with self._state_lock:
                if self._state:
                    self._state["currentFolderId"] = folder_id
            self._set_item(
                config,
                item,
                status="RUNNING",
                error=None,
                errorKey=None,
                errorParams=None,
            )
            try:
                self._export_one(folder_id, run_id, config, item)
            except ExportError as error:
                self._set_item(
                    config,
                    item,
                    status="FAILED",
                    error=str(error),
                    **error.to_dict(),
                )
            except Exception as error:
                export_error = ExportError("unexpected")
                self._set_item(
                    config,
                    item,
                    status="FAILED",
                    error=str(error) or str(export_error),
                    **export_error.to_dict(),
                )
        with self._state_lock:
            if self._state:
                succeeded = int(self._state["succeeded"])
                failed = int(self._state["failed"])
                self._state["status"] = (
                    "SUCCEEDED"
                    if failed == 0
                    else ("FAILED" if succeeded == 0 else "PARTIAL_FAILED")
                )
                self._state["currentFolderId"] = None
                self._state["completedAt"] = utc_now().isoformat()
        self._persist(config)

    def _export_one(
        self,
        folder_id: int,
        run_id: str,
        config: ExportRuntimeConfig,
        item: dict[str, Any],
    ) -> None:
        with engine.connect() as folder_lock:
            acquired = bool(
                folder_lock.scalar(
                    text(
                        "SELECT pg_try_advisory_lock("
                        "hashtextextended(:resource, 0))"
                    ),
                    {"resource": f"lwcam-export-folder:{folder_id}"},
                )
            )
            if not acquired:
                error = ExportError("folderBusy")
                self._set_item(
                    config,
                    item,
                    status="SKIPPED_BUSY",
                    error=str(error),
                    **error.to_dict(),
                )
                return
            # Bound before the session block so the adopt guard below can never
            # read it unbound on a path that returns early.
            is_rework = False
            try:
                with SessionLocal() as db:
                    folder = db.get(CaptureFolder, folder_id)
                    if folder is not None and folder.is_exported:
                        self._set_item(
                            config,
                            item,
                            status="SUCCEEDED",
                            groupId=folder.group_id,
                            zipPath=str(published_package_path(folder.group_id, config)),
                        )
                        return
                    snapshot = load_folder_snapshot(db, folder_id)
                    # A folder the client sent back keeps the Group ID it was
                    # delivered under: FamilySearch want the corrected package to
                    # REPLACE the original, not arrive beside it as a second one.
                    # So no new sequence is allocated and the id does not move.
                    # Keyed on `client_rework` alone, NOT on group_id being set:
                    # a run that published and then failed at finalize leaves
                    # group_id NULL, and a revert after that would otherwise
                    # take the non-rework path, pick the old id up from the
                    # failure ledger and ADOPT the package the client rejected.
                    is_rework = bool(folder is not None and folder.client_rework)
                    group_id = str(item.get("groupId") or "")
                    if not group_id and folder is not None and folder.group_id:
                        group_id = str(folder.group_id)
                    if not group_id:
                        # A previous run may have published this folder and then
                        # failed at finalize. Reuse its group id so the branch
                        # below adopts that package rather than publishing a
                        # second one under a fresh sequence number.
                        previous = self._load_failures(config).get(str(folder_id))
                        if isinstance(previous, dict) and previous.get("zipPath"):
                            group_id = str(previous.get("groupId") or "")
                    if not group_id:
                        sequence = allocate_sequence(db, snapshot.project_id)
                        group_id = build_group_id(snapshot, sequence)
                    db.commit()
                self._set_item(config, item, groupId=group_id)
                final_candidate = published_package_path(group_id, config)
                # NOT for a rework. This branch adopts a package already sitting
                # in the output folder instead of rebuilding - which is right
                # after a crash between publish and finalize, and catastrophic
                # here: the package under that name is the OLD one the client
                # rejected, so adopting it would ship the uncorrected pages back
                # to them, stamped Rework=TRUE.
                if fs_path(final_candidate).exists() and not item.get("zipPath") and not is_rework:
                    verify_published_package(
                        final_candidate,
                        group_id,
                        len(snapshot.images),
                        config,
                    )
                    self._set_item(
                        config,
                        item,
                        zipPath=str(final_candidate),
                        zipSize=package_size(final_candidate),
                        zipSha256=package_digest(final_candidate),
                    )
                    finalize_folder(folder_id, group_id)
                    self._set_item(config, item, status="SUCCEEDED")
                    return
                existing_path_value = item.get("zipPath")
                existing_path = (
                    Path(str(existing_path_value)) if existing_path_value else None
                )
                expected_size = item.get("zipSize")
                expected_sha256 = item.get("zipSha256")
                resumable = (
                    existing_path is not None
                    and fs_path(existing_path).exists()
                    and expected_size == package_size(existing_path)
                    and expected_sha256 == package_digest(existing_path)
                )
                if resumable and fs_path(existing_path).is_dir():
                    # package_digest is empty for a folder, so only the byte
                    # total was compared above; re-check it per file the way
                    # the first publish did.
                    verify_published_package(
                        existing_path, group_id, len(snapshot.images), config
                    )
                if resumable:
                    finalize_folder(folder_id, group_id)
                    self._set_item(config, item, status="SUCCEEDED")
                    return
                exported = build_export_zip(snapshot, group_id, run_id, config)
                final_path = publish_package(
                    exported, group_id, config, len(snapshot.images), replace=is_rework
                )
                if is_rework:
                    # The upload sweep is keyed by package NAME and skips
                    # anything its ledger already calls UPLOADED - so without
                    # this the corrected package would be silently "moved"
                    # instead of sent, and the client would keep the version
                    # they rejected. Clearing the row makes the sweep treat it
                    # as new and PUT it over the same S3 key, which is the
                    # in-place replacement FamilySearch asked for.
                    clear_upload_ledger_entry(config, final_path.name)
                self._set_item(
                    config,
                    item,
                    zipPath=str(final_path),
                    zipSize=package_size(final_path),
                    zipSha256=package_digest(final_path),
                )
                finalize_folder(folder_id, group_id)
                self._set_item(
                    config,
                    item,
                    status="SUCCEEDED",
                )
            finally:
                folder_lock.execute(
                    text(
                        "SELECT pg_advisory_unlock("
                        "hashtextextended(:resource, 0))"
                    ),
                    {"resource": f"lwcam-export-folder:{folder_id}"},
                )



class ExportAutoScheduler(PeriodicSweep):
    """Exports approved folders without anyone asking.

    WHY A SWEEP, not a call from the approve handler. Two structural reasons:

    1. Approve is done by a QcUser, and every export route is AdminUser-gated,
       so the client cannot start one on the operator's behalf.
    2. ExportCoordinator.start raises taskAlreadyRunning while a run is alive.
       Firing on approve would lose the second of two near-simultaneous
       approvals - and lose it silently, leaving a PASS folder unexported with
       nothing recording that it should have been.

    A sweep has neither problem: it runs as the server, one run at a time, and a
    folder approved mid-run is simply picked up by the next pass. Same shape as
    AiPreanalysisScheduler, which is this backend's established pattern for a
    background worker.
    """

    def __init__(self) -> None:
        super().__init__(
            "lwcam-export-auto",
            tick=self.scan_once,
            interval=lambda: settings.export_auto_interval_seconds,
            enabled=lambda: bool(settings.export_auto_enabled),
        )

    def scan_once(self) -> int:
        """Starts a run for everything eligible. Returns how many were queued."""
        if self._busy():
            return 0
        backing_off = self._backing_off()
        with SessionLocal() as db:
            pending = [f for f in eligible_folder_ids(db) if f not in backing_off]
            if not pending:
                return 0
            # preflight guards the things a run cannot recover from - an
            # unconfigured output root, a missing sequence - and reports them
            # per-issue. Starting anyway would just fail every folder and fill
            # the ledger with noise that is really one configuration problem.
            readiness = export_coordinator.preflight(db)
            if not readiness.get("ready"):
                return 0
            try:
                export_coordinator.start("auto", pending)
            except ExportError:
                # taskAlreadyRunning between the check and the call, or nothing
                # eligible after all. Either way the next tick retries.
                return 0
        return len(pending)

    def _backing_off(self) -> set[int]:
        """Folder ids whose last failure is too recent to retry.

        FAILED never touches the database, so a folder that fails the same way
        every time stays eligible; without this the sweep would rebuild it every
        tick forever, burning a sequence number each time. The wait doubles per
        attempt and caps at an hour; the Exports screen's Retry is the way past
        it sooner.
        """
        now = utc_now()
        interval = float(settings.export_auto_interval_seconds)
        blocked: set[int] = set()
        for entry in export_coordinator.read_failures():
            try:
                folder_id = int(entry["folderId"])
                failed_at = datetime.fromisoformat(str(entry.get("failedAt")))
            except (KeyError, TypeError, ValueError):
                continue
            if failed_at.tzinfo is None:
                failed_at = failed_at.replace(tzinfo=timezone.utc)
            attempts = max(int(entry.get("attempts") or 1), 1)
            wait = min(interval * 2 ** (attempts - 1), 3600.0)
            if now < failed_at + timedelta(seconds=wait):
                blocked.add(folder_id)
        return blocked

    def _busy(self) -> bool:
        current = export_coordinator.current()
        return bool(current and current.get("status") in {"QUEUED", "RUNNING"})


export_auto_scheduler = ExportAutoScheduler()

export_coordinator = ExportCoordinator()


__all__ = [
    "ARTIFACT_CSV_HEADERS",
    "GROUP_CSV_FIELD_IDS",
    "GROUP_CSV_HEADERS",
    "group_csv_headers",
    "disabled_template_fields",
    "ExportCoordinator",
    "ExportError",
    "ExportRuntimeConfig",
    "FolderExportSnapshot",
    "allocate_sequence",
    "atomic_json",
    "build_export_zip",
    "build_group_id",
    "conversion_pool",
    "convert_all",
    "export_auto_scheduler",
    "export_coordinator",
    "shutdown_conversion_pool",
    "parse_source_identity",
    "runtime_config",
]

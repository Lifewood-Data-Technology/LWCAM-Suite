"""Configuration for LWIP (the deskew/crop stage), loaded from a JSON file.

load_config() reads config/deskew_crop_config.json into the frozen ToolConfig
dataclass and validates it. The installer writes this file once and it is not
overwritten on upgrade. Relative paths resolve against the install directory.
Things to know: input_root/output_root/work_root must not overlap; database
settings are only required when cloud_report is true; the DB password may be
stored encrypted (see lwcam_secrets); the new ToolConfig fields are defaulted
so older callers and tests that build one by keyword keep working.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from . import lwcam_secrets
from .image_ops import DEFAULT_DESKEW_MIN_DEGREES


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONFIG_PATH = PROJECT_ROOT / "config" / "deskew_crop_config.json"
DEFAULT_EXTENSIONS = (".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp", ".jxl")

# Pixels kept on EACH side of the detected content rect before cropping.
# The real value comes from the config file Station Setup writes; this is only
# the fallback when the key is absent, and the one place any Python default
# lives (benchmark_lwip.py imports it rather than pinning its own).
#
# Keep in step with NodeConfig.processingCropPadding on the Dart side --
# two languages cannot share a literal.
DEFAULT_CROP_PADDING = 200


def db_sslmode(host: str, use_ssl: bool = False) -> str:
    """TLS is required for every non-local database host (encrypted, certificate
    not verified - the server's is self-signed). Only loopback may fall back to
    plain text, and only when dbUseSsl is not true."""
    local = str(host).strip().strip("[]").lower() in ("localhost", "127.0.0.1", "::1")
    return "require" if use_ssl or not local else "prefer"


@dataclass(frozen=True)
class ToolConfig:
    input_root: Path
    output_root: Path
    work_root: Path
    state_file: Path
    log_file: Path
    workers: int
    poll_interval_seconds: float
    stable_seconds: float
    minimum_file_age_seconds: float
    presence_check_interval_seconds: float
    checksum_check_interval_seconds: float
    crop_padding: int
    jpeg_quality: int
    completion_marker: str | None
    recursive: bool
    extensions: tuple[str, ...]
    folder_depth: int
    thumbnail_width: int
    thumbnail_quality: int
    thumbnail_dirname: str
    # Defaulted, unlike every field above: this is the newest addition and
    # existing callers (tests, benchmark_lwip) construct ToolConfig
    # by keyword without it. False is also the correct default
    # on its own terms - a config that does not ask for reporting must not
    # get it.
    cloud_report: bool = False
    rework_settle_seconds: float = 30.0
    # Defaulted for the same reason as cloud_report above. The value that
    # matters is in image_ops (DEFAULT_DESKEW_MIN_DEGREES); this carries a
    # station's override to it.
    deskew_min_degrees: float = DEFAULT_DESKEW_MIN_DEGREES
    # Keep full padding on a tilted page and let QC paint the rotation void
    # (a trailing matfill op) instead of trimming the padding away.
    mat_fill: bool = True
    # LWIP's own database login, since the standalone install has no LWCAM
    # node config to borrow it from. Defaulted blank/false like the two
    # fields above; load_config is what makes them mandatory, and only when
    # cloud_report is true.
    db_host: str = ""
    db_port: int = 5432
    db_name: str = "lwcam"
    db_user: str = ""
    # Not stripped: unlike every other string field here, a password's
    # leading/trailing characters may be significant.
    db_password: str = ""
    db_use_ssl: bool = False
    # Console (deskew_crop_tool.service). The supervisor reads these two
    # LENIENTLY itself (plain json.loads, defaulting if the file is
    # unreadable or the value is bad) because it must be able to start and
    # show an error even when the stricter validation below would reject the
    # rest of the file.
    ui_port: int = 8090
    ui_bind: str = "0.0.0.0"
    # https for the console: both set = serve https (tls.py); blank = http.
    tls_cert_file: str = ""
    tls_key_file: str = ""


def load_config(path: Path | str = DEFAULT_CONFIG_PATH) -> ToolConfig:
    config_path = Path(path).expanduser().resolve()
    if not config_path.is_file():
        raise FileNotFoundError(f"Configuration file does not exist: {config_path}")
    raw = json.loads(config_path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise ValueError("configuration root must be a JSON object")
    base = config_path.parent

    input_root = _required_path(raw, "input_root", base)
    output_root = _required_path(raw, "output_root", base)
    work_root = _path(raw.get("work_root", "runtime/deskew_crop/work"), base)
    state_file = _path(
        raw.get("state_file", "runtime/deskew_crop/state.json"), base
    )
    log_file = _path(
        raw.get("log_file", "runtime/logs/deskew_crop.log"), base
    )

    workers = int(raw.get("workers", 0))
    if workers == 0:
        workers = min(61, max(1, (os.cpu_count() or 2) - 1))
    elif workers < 0:
        raise ValueError("workers cannot be negative; use zero for automatic sizing")
    if os.name == "nt" and workers > 61:
        raise ValueError("workers cannot exceed 61 on Windows")
    poll_interval = float(raw.get("poll_interval_seconds", 5))
    stable_seconds = float(raw.get("stable_seconds", 60))
    minimum_age = float(raw.get("minimum_file_age_seconds", 30))
    rework_settle = float(raw.get("rework_settle_seconds", 30))
    presence_interval = float(raw.get("presence_check_interval_seconds", 300))
    checksum_interval = float(raw.get("checksum_check_interval_seconds", 86400))
    padding = int(raw.get("crop_padding", DEFAULT_CROP_PADDING))
    # 100 with 4:4:4 chroma reproduces the camera's own quantization tables
    # exactly. Anything lower is a visibly coarser second compression than the
    # capture, which is what FamilySearch rejected the first delivery for.
    quality = int(raw.get("jpeg_quality", 100))
    deskew_min_degrees = float(
        raw.get("deskew_min_degrees", DEFAULT_DESKEW_MIN_DEGREES)
    )
    mat_fill = raw.get("mat_fill", True)
    if not isinstance(mat_fill, bool):
        raise ValueError("mat_fill must be true or false")
    # Off by default, like completion_marker and thumbnail_width: a bare
    # START_DESKEW_CROP.bat run must never reach for a database. Station Setup
    # writes true, so every managed station reports.
    cloud_report = bool(raw.get("cloud_report", False))
    db_host = str(raw.get("db_host", "")).strip()
    db_port = int(raw.get("db_port", 5432))
    db_name = str(raw.get("db_name", "lwcam")).strip() or "lwcam"
    db_user = str(raw.get("db_user", "")).strip()
    # Stored as dpapi:... (lwcam_secrets); a plain value is still accepted.
    # An undecryptable one raises SecretError, shown as the config problem.
    db_password = lwcam_secrets.unprotect(str(raw.get("db_password", "")), "db_password")
    db_use_ssl = raw.get("db_use_ssl", False)
    if not isinstance(db_use_ssl, bool):
        raise ValueError("db_use_ssl must be true or false")
    ui_port = int(raw.get("ui_port", 8090))
    ui_bind = str(raw.get("ui_bind", "0.0.0.0")).strip() or "0.0.0.0"
    tls_cert_file = str(raw.get("tls_cert_file", "")).strip()
    tls_key_file = str(raw.get("tls_key_file", "")).strip()
    if bool(tls_cert_file) != bool(tls_key_file):
        raise ValueError("tls_cert_file and tls_key_file must be set together")
    marker = str(raw.get("completion_marker", "")).strip() or None
    # Depth 1 (default) = each child dir of input_root is a job — the tool's
    # original contract. Depth 2 = each grandchild (e.g. YYYYMMDD/<folder>),
    # for watching LWCAM's <dest>/YYYYMMDD/<folder> layout directly.
    folder_depth = int(raw.get("folder_depth", 1))
    # 0 disables the thumbnail stage entirely (original behaviour).
    thumbnail_width = int(raw.get("thumbnail_width", 0))
    thumbnail_quality = int(raw.get("thumbnail_quality", 85))
    thumbnail_dirname = str(raw.get("thumbnail_dirname", "thumbs")).strip() or "thumbs"
    recursive_value = raw.get("recursive", True)
    if not isinstance(recursive_value, bool):
        raise ValueError("recursive must be true or false")
    recursive = recursive_value
    extension_values = raw.get("extensions", DEFAULT_EXTENSIONS)
    if isinstance(extension_values, str) or not isinstance(
        extension_values, (list, tuple)
    ):
        raise ValueError("extensions must be a JSON array")
    extensions = tuple(
        sorted(
            {
                _normalise_extension(value)
                for value in extension_values
            }
        )
    )

    if poll_interval <= 0:
        raise ValueError("poll_interval_seconds must be greater than zero")
    if stable_seconds < 0 or minimum_age < 0:
        raise ValueError("stability durations cannot be negative")
    if presence_interval < 0 or checksum_interval < 0:
        raise ValueError("integrity check intervals cannot be negative")
    if padding < 0:
        raise ValueError("crop_padding cannot be negative")
    if not 1 <= quality <= 100:
        raise ValueError("jpeg_quality must be between 1 and 100")
    if not 0 <= deskew_min_degrees <= 10:
        raise ValueError("deskew_min_degrees must be between 0 and 10")
    if not extensions:
        raise ValueError("extensions must contain at least one image extension")
    if marker and Path(marker).name != marker:
        raise ValueError("completion_marker must be a file name, not a path")
    if folder_depth not in (1, 2):
        raise ValueError("folder_depth must be 1 or 2")
    if not 0 <= thumbnail_width <= 4096:
        raise ValueError("thumbnail_width must be between 0 and 4096 (0 disables thumbnails)")
    if not isinstance(cloud_report, bool):
        raise ValueError("cloud_report must be true or false")
    if not 1 <= db_port <= 65535:
        raise ValueError("db_port must be between 1 and 65535")
    if not 1 <= ui_port <= 65535:
        raise ValueError("ui_port must be between 1 and 65535")
    if cloud_report:
        missing = [
            name
            for name, value in (
                ("db_host", db_host),
                ("db_user", db_user),
                ("db_password", db_password),
            )
            if not value.strip()
        ]
        if missing:
            raise ValueError(
                "cloud_report is true but missing database settings: "
                + ", ".join(missing)
            )
    if not 1 <= thumbnail_quality <= 100:
        raise ValueError("thumbnail_quality must be between 1 and 100")
    if Path(thumbnail_dirname).name != thumbnail_dirname or thumbnail_dirname in (".", ".."):
        raise ValueError("thumbnail_dirname must be a bare directory name, not a path")

    _validate_roots(input_root, output_root, work_root)
    return ToolConfig(
        input_root=input_root,
        output_root=output_root,
        work_root=work_root,
        state_file=state_file,
        log_file=log_file,
        workers=workers,
        poll_interval_seconds=poll_interval,
        stable_seconds=stable_seconds,
        minimum_file_age_seconds=minimum_age,
        presence_check_interval_seconds=presence_interval,
        checksum_check_interval_seconds=checksum_interval,
        crop_padding=padding,
        jpeg_quality=quality,
        completion_marker=marker,
        recursive=recursive,
        extensions=extensions,
        folder_depth=folder_depth,
        thumbnail_width=thumbnail_width,
        thumbnail_quality=thumbnail_quality,
        thumbnail_dirname=thumbnail_dirname,
        cloud_report=cloud_report,
        rework_settle_seconds=rework_settle,
        deskew_min_degrees=deskew_min_degrees,
        mat_fill=mat_fill,
        db_host=db_host,
        db_port=db_port,
        db_name=db_name,
        db_user=db_user,
        db_password=db_password,
        db_use_ssl=db_use_ssl,
        ui_port=ui_port,
        ui_bind=ui_bind,
        tls_cert_file=tls_cert_file,
        tls_key_file=tls_key_file,
    )


def _required_path(raw: dict[str, Any], key: str, base: Path) -> Path:
    value = str(raw.get(key, "")).strip()
    if not value:
        raise ValueError(f"{key} must be configured")
    return _path(value, base)


def _path(value: object, base: Path) -> Path:
    path = Path(str(value)).expanduser()
    if not path.is_absolute():
        # Configuration lives in <root>/config, while runtime paths are rooted
        # at the installed application directory.
        path = base.parent / path
    return path.resolve()


def _normalise_extension(value: object) -> str:
    extension = str(value).strip().lower()
    if not extension:
        raise ValueError("image extensions cannot be empty")
    return extension if extension.startswith(".") else f".{extension}"


def _validate_roots(input_root: Path, output_root: Path, work_root: Path) -> None:
    if input_root == output_root:
        raise ValueError("input_root and output_root must be different")
    if output_root.is_relative_to(input_root):
        raise ValueError("output_root cannot be inside input_root")
    if work_root.is_relative_to(input_root):
        raise ValueError("work_root cannot be inside input_root")

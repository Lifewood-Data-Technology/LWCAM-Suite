"""Reports the folder settings in force, and where each came from.

Read-only by design. LWCam Admin's Station Setup is the suite's single
configuration authority: it writes `lwcam_node_config.json`, which this backend
loads at import (`app/core/node_config.py`). The QC console displays these values so
an operator can see what the server is actually using — and probe the folders — but
it cannot change them. An editable copy here would mean two writers for one setting,
and which one won would depend on load order.

An earlier build stored per-station overrides in `%LOCALAPPDATA%\\LWCam\\QC\\
qc_paths.json`. That file is obsolete: it is neither read nor written now, and a
leftover copy has no effect.
"""

from __future__ import annotations

from typing import Any

from app.core.config import settings


# The image pair mirrors `capture_image_host_path` / `capture_image_container_path`:
# the prefix LWCAM wrote into `capture_folders.folder_path`, and the local root to
# read it from. Both blank keeps `to_local()` an identity mapping.
CAPTURE_STORED_PREFIX = "captureImageStoredPrefix"
CAPTURE_LOCAL_ROOT = "captureImageLocalRoot"
EXPORT_TEMP_DIR = "exportTempDir"
EXPORT_OUTPUT_DIR = "exportOutputDir"

PATH_KEYS = (
    CAPTURE_STORED_PREFIX,
    CAPTURE_LOCAL_ROOT,
    EXPORT_TEMP_DIR,
    EXPORT_OUTPUT_DIR,
)

# Which `Settings` field backs each reported key.
SOURCE_FIELDS = {
    CAPTURE_STORED_PREFIX: "capture_image_host_path",
    CAPTURE_LOCAL_ROOT: "capture_image_container_path",
    EXPORT_TEMP_DIR: "export_temp_dir",
    EXPORT_OUTPUT_DIR: "export_output_dir",
}


def effective_value(key: str) -> str:
    """The path in force for `key`."""
    return str(getattr(settings, SOURCE_FIELDS[key], "") or "").strip()


def value_source(key: str) -> str:
    """Where `effective_value(key)` came from, for the console to display."""
    if not effective_value(key):
        return "unset"
    # node_config.py forces app_env=production whenever a station config was loaded,
    # so it is the honest signal for "Station Setup supplied this" versus a bare .env.
    return "stationConfig" if settings.app_env == "production" else "environment"


def describe() -> dict[str, dict[str, Any]]:
    """Every reported path: what is in force and where it came from."""
    return {
        key: {"value": effective_value(key), "source": value_source(key)}
        for key in PATH_KEYS
    }

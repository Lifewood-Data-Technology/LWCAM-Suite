"""Report active path settings and whether config.txt overrides defaults.

Legacy per-station path override files are obsolete and are not read.
"""

from __future__ import annotations

from typing import Any

from app.core.config import settings
from app.core.server_settings import load_server_settings_overrides

EXPORT_TEMP_DIR = "exportTempDir"
EXPORT_OUTPUT_DIR = "exportOutputDir"

PATH_KEYS = (
    EXPORT_TEMP_DIR,
    EXPORT_OUTPUT_DIR,
)

SOURCE_FIELDS = {
    EXPORT_TEMP_DIR: "export_temp_dir",
    EXPORT_OUTPUT_DIR: "export_output_dir",
}


def effective_value(key: str) -> str:
    """The path in force for `key`."""
    return str(getattr(settings, SOURCE_FIELDS[key], "") or "").strip()


def value_source(key: str) -> str:
    """Where `effective_value(key)` came from, for the console to display."""
    field = SOURCE_FIELDS[key]
    return "console" if field in load_server_settings_overrides() else "default"


def describe() -> dict[str, dict[str, Any]]:
    """Every reported path: what is in force and where it came from."""
    return {
        key: {"value": effective_value(key), "source": value_source(key)}
        for key in PATH_KEYS
    }

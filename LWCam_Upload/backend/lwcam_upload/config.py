"""`{app}\\config\\upload_config.json`. Modelled on LWIP's own
`deskew_crop_tool/config.py` - a frozen dataclass plus one `load_config`
that reads, defaults, validates and resolves relative paths the same way:
against the config file's GRANDPARENT (its parent is `{app}\\config`, so a
relative `runtime/uploads.json` resolves to `{app}\\runtime\\uploads.json`,
alongside the rest of the install).

Every rule here is the one the shared contract's config table lists.
`load_config` raises ValueError, never returns a half-valid object - the
console reads the raised message straight into a `[CONFIG]` log line.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

DEFAULT_STATE_FILE = "runtime/uploads.json"
DEFAULT_LOG_FILE = "logs/upload.log"


@dataclass(frozen=True)
class Config:
    watch_root: Path
    done_root: Path | None
    summary_root: Path | None
    enabled: bool
    s3_path: str
    s3_region: str
    s3_access_key: str
    s3_secret_key: str
    interval_seconds: int
    state_file: Path
    log_file: Path
    db_host: str
    db_port: int
    db_name: str
    db_user: str
    db_password: str
    db_use_ssl: bool
    ui_port: int
    ui_bind: str


def parse_s3_path(value: str) -> tuple[str, str]:
    """`s3://bucket/optional/prefix` -> (bucket, prefix). Prefix may be empty."""
    text = (value or "").strip()
    if not text.lower().startswith("s3://"):
        raise ValueError("s3_path must start with s3://")
    bucket, _, prefix = text[5:].strip("/").partition("/")
    if not bucket:
        raise ValueError("s3_path names no bucket")
    return bucket, prefix.strip("/")


def load_config(path: Path | str) -> Config:
    config_path = Path(path).expanduser().resolve()
    if not config_path.is_file():
        raise FileNotFoundError(f"Configuration file does not exist: {config_path}")
    raw = json.loads(config_path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise ValueError("configuration root must be a JSON object")
    base = config_path.parent

    watch_root = _required_path(raw, "watch_root", base)
    done_root = _optional_path(raw.get("done_root", ""), base)
    summary_root = _optional_path(raw.get("summary_root", ""), base)
    state_file = _path(raw.get("state_file", DEFAULT_STATE_FILE), base)
    log_file = _path(raw.get("log_file", DEFAULT_LOG_FILE), base)

    enabled = raw.get("enabled", True)
    if not isinstance(enabled, bool):
        raise ValueError("enabled must be true or false")

    s3_path = str(raw.get("s3_path", "")).strip()
    s3_region = str(raw.get("s3_region", "")).strip()
    s3_access_key = str(raw.get("s3_access_key", "")).strip()
    # Not stripped: like a database password, a secret's leading/trailing
    # characters may be significant.
    s3_secret_key = str(raw.get("s3_secret_key", ""))
    if enabled:
        missing = [
            name
            for name, value in (
                ("s3_path", s3_path),
                ("s3_region", s3_region),
                ("s3_access_key", s3_access_key),
                ("s3_secret_key", s3_secret_key),
            )
            if not value.strip()
        ]
        if missing:
            raise ValueError(
                "enabled is true but missing settings: " + ", ".join(missing)
            )
        parse_s3_path(s3_path)  # raises ValueError with a clear reason

    interval_seconds = int(raw.get("interval_seconds", 60))
    if interval_seconds < 5:
        raise ValueError("interval_seconds must be at least 5")

    db_host = str(raw.get("db_host", "")).strip()
    db_port = int(raw.get("db_port", 5432))
    db_name = str(raw.get("db_name", "lwcam")).strip() or "lwcam"
    db_user = str(raw.get("db_user", "")).strip()
    db_password = str(raw.get("db_password", ""))
    db_use_ssl = raw.get("db_use_ssl", False)
    if not isinstance(db_use_ssl, bool):
        raise ValueError("db_use_ssl must be true or false")
    if not 1 <= db_port <= 65535:
        raise ValueError("db_port must be between 1 and 65535")

    ui_port = int(raw.get("ui_port", 8091))
    if not 1 <= ui_port <= 65535:
        raise ValueError("ui_port must be between 1 and 65535")
    ui_bind = str(raw.get("ui_bind") or "0.0.0.0").strip() or "0.0.0.0"

    _validate_roots(watch_root, done_root, summary_root)

    return Config(
        watch_root=watch_root,
        done_root=done_root,
        summary_root=summary_root,
        enabled=enabled,
        s3_path=s3_path,
        s3_region=s3_region,
        s3_access_key=s3_access_key,
        s3_secret_key=s3_secret_key,
        interval_seconds=interval_seconds,
        state_file=state_file,
        log_file=log_file,
        db_host=db_host,
        db_port=db_port,
        db_name=db_name,
        db_user=db_user,
        db_password=db_password,
        db_use_ssl=db_use_ssl,
        ui_port=ui_port,
        ui_bind=ui_bind,
    )


def _required_path(raw: dict[str, Any], key: str, base: Path) -> Path:
    value = str(raw.get(key, "")).strip()
    if not value:
        raise ValueError(f"{key} must be configured")
    return _path(value, base)


def _optional_path(value: object, base: Path) -> Path | None:
    text = str(value or "").strip()
    return _path(text, base) if text else None


def _path(value: object, base: Path) -> Path:
    path = Path(str(value)).expanduser()
    if not path.is_absolute():
        # Configuration lives in <app>/config, while runtime paths (state_file,
        # log_file) are rooted at the installed application directory itself.
        path = base.parent / path
    return path.resolve()


def _same_or_inside(candidate: Path, root: Path) -> bool:
    # resolve() follows junctions and expands 8.3 short names, so a done or
    # summary folder aliased into watch_root is still caught.
    try:
        a, b = candidate.resolve(), root.resolve()
    except OSError:
        return False
    return a == b or a.is_relative_to(b)


def _validate_roots(watch_root: Path, done_root: Path | None, summary_root: Path | None) -> None:
    # Inside watch_root either would be listed as a package itself: done_root
    # would be re-uploaded forever, and summary_root's own db3 file would be
    # swept up as a "package".
    if done_root is not None and _same_or_inside(done_root, watch_root):
        raise ValueError("done_root must not be inside watch_root")
    if summary_root is not None and _same_or_inside(summary_root, watch_root):
        raise ValueError("summary_root must not be inside watch_root")


__all__ = ["Config", "load_config", "parse_s3_path"]

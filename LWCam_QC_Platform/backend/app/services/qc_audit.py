from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from app.core.config import settings
from app.core.paths import fs_path


BACKEND_ROOT = Path(__file__).resolve().parents[2]


def audit_root() -> Path:
    root = Path(settings.qc_audit_dir).expanduser()
    if not root.is_absolute():
        root = BACKEND_ROOT / root
    root = root.resolve()
    fs_path(root).mkdir(parents=True, exist_ok=True)
    return root


def audit_path() -> Path:
    return audit_root() / f"qc_audit_{datetime.now(timezone.utc).strftime('%Y%m%d')}.jsonl"


def write_qc_audit(
    action: str,
    user_id: str,
    folder_id: int,
    *,
    image_ids: list[int] | None = None,
    source_hash: str | None = None,
    draft_summary: dict[str, Any] | None = None,
    result: str = "success",
    note: str | None = None,
) -> None:
    record = {
        "at": datetime.now(timezone.utc).isoformat(),
        "user_id": user_id,
        "folder_id": folder_id,
        "image_ids": image_ids or [],
        "action": action,
        "source_hash": source_hash,
        "draft_summary": draft_summary or {},
        "result": result,
        "note": note,
    }
    try:
        with fs_path(audit_path()).open("a", encoding="utf-8") as file:
            file.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
    except Exception:
        # Audit is best-effort local evidence and must not break the review flow.
        return

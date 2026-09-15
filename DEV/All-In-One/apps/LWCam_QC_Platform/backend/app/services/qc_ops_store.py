"""Committed geometry ops: what QC has approved on top of LWIP's baseline.

Lives beside LWIP's own manifest, in the capture folder itself (not the
per-reviewer draft under qc_work_dir) - it has to survive across review
sessions and reviewers, because a client-rework reopens an ALREADY-APPROVED
folder and its prior committed straighten/crop must still apply. A CAPTURE
rework (LWIP rebuilding the folder from a fresh recapture) correctly wipes
this file along with everything else in the folder, which is exactly right:
a recaptured page has no history to keep.

Deliberately NOT the per-image page JPEG: geometry lands here instead of in
pixels so the delivered file never carries anything FamilySearch could call
image manipulation. See `effective_ops` for how this layers with LWIP's own
baseline and a reviewer's still-open draft.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

from app.core.paths import fs_path
from app.services.lwip_baseline import baseline_ops

QC_OPS_NAME = "qc_ops.json"


def qc_ops_path(folder_path: Path) -> Path:
    return Path(folder_path) / QC_OPS_NAME


def read_qc_ops(folder_path: Path) -> dict[str, Any]:
    """Tolerant read: `{}` for a missing, unreadable or corrupt file.

    A folder with nothing committed yet is the overwhelmingly common case
    (every folder, until its first approval that touches geometry), so this
    is not an error path - it is the default.
    """
    try:
        raw = fs_path(qc_ops_path(folder_path)).read_text(encoding="utf-8")
        data = json.loads(raw)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _image_entry(folder_path: Path, image_name: str) -> dict[str, Any]:
    images = read_qc_ops(folder_path).get("images")
    entry = (images or {}).get(image_name) if isinstance(images, dict) else None
    return entry if isinstance(entry, dict) else {}


def committed_ops(folder_path: Path, image_name: str) -> list[dict]:
    ops = _image_entry(folder_path, image_name).get("ops")
    return [op for op in ops if isinstance(op, dict)] if isinstance(ops, list) else []


def ignore_lwip(folder_path: Path, image_name: str) -> bool:
    return bool(_image_entry(folder_path, image_name).get("ignore_lwip"))


def effective_ops(
    folder_path: Path, image_name: str, pending: list[dict] | None = None
) -> list[dict]:
    """The full chain for one image: LWIP's baseline, committed rounds, and
    whatever the current reviewer still has pending. Order is the contract -
    see geometry_ops.replay_pending_ops - so these concatenate, never merge.
    """
    baseline = [] if ignore_lwip(folder_path, image_name) else baseline_ops(folder_path, image_name)
    return baseline + committed_ops(folder_path, image_name) + list(pending or [])


def write_image_ops(folder_path: Path, image_name: str, ops: list[dict], ignore_lwip_flag: bool) -> None:
    """Replace one image's committed entry. Atomic: temp file + os.replace."""
    path = qc_ops_path(folder_path)
    data = read_qc_ops(folder_path)
    data.setdefault("version", 1)
    images = data.get("images")
    if not isinstance(images, dict):
        images = {}
        data["images"] = images
    images[image_name] = {"ops": list(ops), "ignore_lwip": bool(ignore_lwip_flag)}
    _write_atomic(path, data)


def drop_image_ops(folder_path: Path, image_name: str) -> None:
    """Remove one image's committed entry entirely - a deleted page has
    nothing left to carry ops for."""
    path = qc_ops_path(folder_path)
    data = read_qc_ops(folder_path)
    images = data.get("images")
    if not isinstance(images, dict) or image_name not in images:
        return
    images.pop(image_name, None)
    _write_atomic(path, data)


def _write_atomic(path: Path, data: dict[str, Any]) -> None:
    fs_path(path.parent).mkdir(parents=True, exist_ok=True)
    temp_path = path.with_name(f".{path.name}.tmp")
    fs_path(temp_path).write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(fs_path(temp_path), fs_path(path))

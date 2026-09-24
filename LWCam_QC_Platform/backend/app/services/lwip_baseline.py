"""LWIP's own straighten/crop, read from its per-folder manifest.

LWIP no longer bakes its measured deskew (or the tight crop to the page's own
edges) into the page JPEG - both would be exactly the "image enhancement"
FamilySearch rejected the pipeline for. Instead it writes them as a deferred
op list, in the SAME schema a reviewer's own pending_ops use, into each file
entry of its manifest (`.deskew_crop_manifest.json`, in the capture folder
LWCAM points `folder_path` at). This module is the QC engine's read side of
that contract; see `services/qc_ops_store.effective_ops` for how it layers
under a reviewer's own committed/pending ops.

A missing manifest, a missing entry, or a manifest that fails to parse all
mean the same thing: no baseline for this image, `[]`. LWIP not having run
yet (or a folder from before this contract existed) must never be an error.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from app.core.paths import fs_path

MANIFEST_NAME = ".deskew_crop_manifest.json"

# One entry per (path, mtime_ns) actually seen. A capture rework republishes
# the whole folder under a fresh mtime, so a stale entry is never served - it
# just stops being looked up. Capped rather than left to grow across a
# station's whole uptime.
# ponytail: global dict, no LRU. Bump the cap or switch to functools.lru_cache
# if a station ever keeps enough distinct folders open to make this measurable.
_MAX_CACHED_MANIFESTS = 64
_manifest_cache: dict[tuple[str, int], dict[str, Any] | None] = {}


def _load_manifest(folder_path: Path) -> dict[str, Any] | None:
    manifest_path = fs_path(Path(folder_path) / MANIFEST_NAME)
    try:
        mtime_ns = manifest_path.stat().st_mtime_ns
    except OSError:
        return None
    key = (str(manifest_path), mtime_ns)
    if key in _manifest_cache:
        return _manifest_cache[key]
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        manifest = None
    if not isinstance(manifest, dict):
        manifest = None
    if len(_manifest_cache) >= _MAX_CACHED_MANIFESTS:
        _manifest_cache.clear()
    _manifest_cache[key] = manifest
    return manifest


def baseline_ops(folder_path: Path, image_name: str) -> list[dict]:
    """LWIP's deferred ops for [image_name] in [folder_path]'s manifest.

    [image_name] is matched against each file entry's `relative_path`, which
    is `capture_images.image_name` for a page (LWIP's own contract - the
    manifest lives beside the very files it describes, so there is no folder
    id or path prefix to strip).
    """
    manifest = _load_manifest(folder_path)
    if not manifest:
        return []
    for entry in manifest.get("files") or []:
        if not isinstance(entry, dict):
            continue
        if entry.get("relative_path") != image_name:
            continue
        ops = entry.get("qc_ops") or []
        return [op for op in ops if isinstance(op, dict)]
    return []

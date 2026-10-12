"""Per-reviewer QC draft storage: the manifest, work copies and undo history.

Used by routers/qc.py in the QC Platform review step (after LWIP, before
export). While a reviewer edits a folder nothing official is touched. Every
change is recorded in a manifest.json under qc_work_dir/<user>/<folder>/ and
page files are copied into that folder's images/ directory. The router later
commits the draft to the official files (commit_current_draft).

Ideas to know before editing:
- The manifest holds: per-image items keyed by image id, the page order,
  separation markers, metadata values, and undo/redo stacks.
- Image ids below zero are draft-only pages (inserted ones); real pages use
  their database id.
- Rotate, crop and deskew are not applied on click. They are stored as an
  ordered list of pending ops per image and baked into pixels once, later.
- Every mutation calls push_history first (snapshot files plus manifest) so
  undo and redo can restore both state and pixels.
"""
from __future__ import annotations

import json
import os
import shutil
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from app.core.config import settings
from app.core.paths import fs_path


BACKEND_ROOT = Path(__file__).resolve().parents[2]
MANIFEST_NAME = "manifest.json"


# --- Draft folder layout and manifest file ------------------------------------
def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def safe_part(value: str) -> str:
    return "".join(char if char.isalnum() or char in {"-", "_", "."} else "_" for char in value)


def qc_work_root() -> Path:
    """The configured QC working directory (created if missing); drafts live under it."""
    root = Path(settings.qc_work_dir).expanduser()
    if not root.is_absolute():
        root = BACKEND_ROOT / root
    root = root.resolve()
    fs_path(root).mkdir(parents=True, exist_ok=True)
    return root


def draft_dir(folder_id: int, user_id: str) -> Path:
    """This reviewer's draft folder for one QC folder; refuses paths that escape the work root."""
    path = (qc_work_root() / safe_part(user_id) / str(folder_id)).resolve()
    path.relative_to(qc_work_root())
    return path


def manifest_path(folder_id: int, user_id: str) -> Path:
    return draft_dir(folder_id, user_id) / MANIFEST_NAME


def image_key(image_id: int) -> str:
    return str(int(image_id))


def empty_manifest(folder_id: int, user_id: str) -> dict:
    """A new manifest with every key present and nothing edited."""
    now = utc_now_iso()
    return {
        "folder_id": folder_id,
        "user_id": user_id,
        "created_at": now,
        "updated_at": now,
        "images": {},
        "metadata": {"dirty": False, "values": {}},
        "order": [],
        "separation_markers": [],
        "next_temp_id": -1,
        "operations": [],
        "undo_stack": [],
        "redo_stack": [],
    }


def normalize_manifest(manifest: dict | None, folder_id: int | None = None, user_id: str | None = None) -> dict | None:
    """Add any missing keys in place, so manifests written by older versions still load."""
    if manifest is None:
        return None
    if folder_id is not None:
        manifest.setdefault("folder_id", folder_id)
    if user_id is not None:
        manifest.setdefault("user_id", user_id)
    manifest.setdefault("images", {})
    manifest.setdefault("metadata", {"dirty": False, "values": {}})
    manifest.setdefault("order", [])
    manifest.setdefault("separation_markers", [])
    manifest.setdefault("next_temp_id", -1)
    manifest.setdefault("operations", [])
    manifest.setdefault("undo_stack", [])
    manifest.setdefault("redo_stack", [])
    return manifest


def read_manifest(folder_id: int, user_id: str) -> dict | None:
    path = manifest_path(folder_id, user_id)
    if not fs_path(path).is_file():
        return None
    return normalize_manifest(json.loads(fs_path(path).read_text(encoding="utf-8")), folder_id, user_id)


def write_manifest(folder_id: int, user_id: str, manifest: dict) -> None:
    """Save the manifest atomically (temp file, then replace) and bump updated_at."""
    directory = draft_dir(folder_id, user_id)
    fs_path(directory).mkdir(parents=True, exist_ok=True)
    normalize_manifest(manifest, folder_id, user_id)
    manifest["updated_at"] = utc_now_iso()
    path = directory / MANIFEST_NAME
    temp_path = directory / f".{MANIFEST_NAME}.tmp"
    fs_path(temp_path).write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(fs_path(temp_path), fs_path(path))


def manifest_has_changes(manifest: dict | None) -> bool:
    """True if the manifest holds any edit worth keeping (pages, metadata, order or split marks)."""
    if not manifest:
        return False
    return bool(
        dirty_image_ids_from_manifest(manifest)
        or metadata_dirty_from_manifest(manifest)
        or manifest.get("separation_markers")
        or any((item or {}).get("status") in {"inserted", "deleted"} for item in manifest.get("images", {}).values())
        or manifest.get("order")
    )


def has_draft(folder_id: int, user_id: str) -> bool:
    return manifest_has_changes(read_manifest(folder_id, user_id))


# --- Undo / redo history ------------------------------------------------------
def _copy_file_into_history(source: str | None, target_dir: Path, key: str) -> str | None:
    if not source:
        return None
    source_path = Path(source)
    if not fs_path(source_path).is_file():
        return None
    target = target_dir / f"{safe_part(key)}{source_path.suffix}"
    shutil.copy2(fs_path(source_path), fs_path(target))
    return str(target.resolve())


def push_history(manifest: dict, folder_id: int, user_id: str) -> None:
    """Snapshot the current state (and copies of the work files) onto the undo stack, and clear redo.

    Call this before changing the manifest. It does not write the manifest itself.
    """
    normalize_manifest(manifest, folder_id, user_id)
    history_dir = draft_dir(folder_id, user_id) / "history" / str(len(manifest["undo_stack"]) + 1)
    fs_path(history_dir).mkdir(parents=True, exist_ok=True)
    snapshot = {
        "images": deepcopy(manifest.get("images", {})),
        "metadata": deepcopy(manifest.get("metadata", {})),
        "order": deepcopy(manifest.get("order", [])),
        "separation_markers": deepcopy(manifest.get("separation_markers", [])),
        "next_temp_id": manifest.get("next_temp_id", -1),
        "files": {},
    }
    for key, item in snapshot["images"].items():
        copied = _copy_file_into_history(item.get("work_path"), history_dir, key)
        if copied:
            snapshot["files"][key] = copied
    manifest["undo_stack"].append(snapshot)
    manifest["redo_stack"] = []


def _restore_snapshot_files(folder_id: int, user_id: str, snapshot: dict) -> None:
    base = draft_dir(folder_id, user_id).resolve()
    images = snapshot.get("images") or {}
    for key, item in images.items():
        work_path_value = item.get("work_path")
        if not work_path_value:
            continue
        work_path = Path(work_path_value).resolve()
        work_path.relative_to(base)
        history_file = snapshot.get("files", {}).get(str(key))
        if history_file and fs_path(Path(history_file)).is_file():
            fs_path(work_path.parent).mkdir(parents=True, exist_ok=True)
            shutil.copy2(fs_path(Path(history_file)), fs_path(work_path))


def _state_snapshot(manifest: dict) -> dict:
    snapshot = {
        "images": deepcopy(manifest.get("images", {})),
        "metadata": deepcopy(manifest.get("metadata", {})),
        "order": deepcopy(manifest.get("order", [])),
        "separation_markers": deepcopy(manifest.get("separation_markers", [])),
        "next_temp_id": manifest.get("next_temp_id", -1),
        "files": {},
    }
    return snapshot


def undo_manifest(folder_id: int, user_id: str) -> bool:
    """Step back one edit: restore the last snapshot and its files, keeping the current state for redo."""
    manifest = read_manifest(folder_id, user_id)
    if not manifest or not manifest.get("undo_stack"):
        return False
    redo = _state_snapshot(manifest)
    redo_dir = draft_dir(folder_id, user_id) / "history" / f"redo_{len(manifest['redo_stack']) + 1}"
    fs_path(redo_dir).mkdir(parents=True, exist_ok=True)
    for key, item in redo["images"].items():
        copied = _copy_file_into_history(item.get("work_path"), redo_dir, key)
        if copied:
            redo["files"][key] = copied
    snapshot = manifest["undo_stack"].pop()
    manifest["redo_stack"].append(redo)
    manifest["images"] = deepcopy(snapshot.get("images", {}))
    manifest["metadata"] = deepcopy(snapshot.get("metadata", {}))
    manifest["order"] = deepcopy(snapshot.get("order", []))
    manifest["separation_markers"] = deepcopy(snapshot.get("separation_markers", []))
    manifest["next_temp_id"] = snapshot.get("next_temp_id", -1)
    _restore_snapshot_files(folder_id, user_id, snapshot)
    manifest.setdefault("operations", []).append({"operation": "undo", "at": utc_now_iso()})
    write_manifest(folder_id, user_id, manifest)
    return True


def redo_manifest(folder_id: int, user_id: str) -> bool:
    """Re-apply the edit that was last undone."""
    manifest = read_manifest(folder_id, user_id)
    if not manifest or not manifest.get("redo_stack"):
        return False
    snapshot = manifest["redo_stack"].pop()
    undo = _state_snapshot(manifest)
    undo_dir = draft_dir(folder_id, user_id) / "history" / f"redo_undo_{len(manifest['undo_stack']) + 1}"
    fs_path(undo_dir).mkdir(parents=True, exist_ok=True)
    for key, item in undo["images"].items():
        copied = _copy_file_into_history(item.get("work_path"), undo_dir, key)
        if copied:
            undo["files"][key] = copied
    manifest["undo_stack"].append(undo)
    manifest["images"] = deepcopy(snapshot.get("images", {}))
    manifest["metadata"] = deepcopy(snapshot.get("metadata", {}))
    manifest["order"] = deepcopy(snapshot.get("order", []))
    manifest["separation_markers"] = deepcopy(snapshot.get("separation_markers", []))
    manifest["next_temp_id"] = snapshot.get("next_temp_id", -1)
    _restore_snapshot_files(folder_id, user_id, snapshot)
    manifest.setdefault("operations", []).append({"operation": "redo", "at": utc_now_iso()})
    write_manifest(folder_id, user_id, manifest)
    return True


# --- Reading draft state ------------------------------------------------------
def metadata_dirty_from_manifest(manifest: dict | None) -> bool:
    if not manifest:
        return False
    metadata = manifest.get("metadata") or {}
    return bool(metadata.get("dirty"))


def metadata_values_from_manifest(manifest: dict | None) -> dict[str, Any]:
    if not manifest:
        return {}
    metadata = manifest.get("metadata") or {}
    if not metadata.get("dirty"):
        return {}
    values = metadata.get("values")
    return values if isinstance(values, dict) else {}


def dirty_image_ids_from_manifest(manifest: dict | None) -> list[int]:
    if not manifest:
        return []
    result: list[int] = []
    for raw_id, item in manifest.get("images", {}).items():
        if (
            item.get("dirty")
            or item.get("status") in {"inserted", "deleted", "replaced"}
            # A plain restore carries neither: {"restored": True} is the
            # whole item. It still has to survive at approval (see
            # commit_current_draft), so it counts as a draft change.
            or item.get("restored")
        ):
            result.append(int(raw_id))
    return sorted(result)


def draft_summary(manifest: dict | None) -> dict[str, Any]:
    """A small description of the draft, used in audit log entries."""
    return {
        "dirty_image_ids": dirty_image_ids_from_manifest(manifest),
        "metadata_dirty": metadata_dirty_from_manifest(manifest),
        "operations": len((manifest or {}).get("operations", [])),
        "separation_markers": list((manifest or {}).get("separation_markers", [])),
    }


def draft_version(folder_id: int, user_id: str) -> int | None:
    """The manifest's last-update time in milliseconds, or None if there is no draft."""
    manifest = read_manifest(folder_id, user_id)
    if not manifest:
        return None
    try:
        return int(datetime.fromisoformat(manifest["updated_at"]).timestamp() * 1000)
    except Exception:
        return None


def draft_image_item(manifest: dict | None, image_id: int) -> dict | None:
    if not manifest:
        return None
    item = manifest.get("images", {}).get(image_key(image_id))
    return item if isinstance(item, dict) else None


def draft_image_path(folder_id: int, user_id: str, image_id: int) -> Path | None:
    """The draft work copy of an image, or None if it has none, is deleted, or the file is gone."""
    manifest = read_manifest(folder_id, user_id)
    item = draft_image_item(manifest, image_id)
    if not item or item.get("status") == "deleted":
        return None
    path_value = item.get("work_path")
    if not path_value:
        return None
    path = Path(path_value).resolve()
    try:
        path.relative_to(draft_dir(folder_id, user_id).resolve())
    except ValueError:
        return None
    return path if fs_path(path).is_file() else None


def ensure_order(manifest: dict, official_ids: list[int]) -> list[int]:
    """Bring the manifest's page order up to date: add new official ids, drop unknown ones."""
    order = [int(item) for item in manifest.get("order") or []]
    seen = set(order)
    for image_id in official_ids:
        if image_id not in seen:
            order.append(image_id)
    valid_ids = set(official_ids) | {int(raw_id) for raw_id in manifest.get("images", {}) if int(raw_id) < 0}
    order = [image_id for image_id in order if image_id in valid_ids]
    manifest["order"] = order
    return order


def visible_order(manifest: dict | None, official_ids: list[int]) -> list[int]:
    """The page order the reviewer sees: draft order minus deleted pages (official order if no draft)."""
    if not manifest:
        return official_ids
    order = ensure_order(manifest, official_ids)
    deleted = {int(raw_id) for raw_id, item in manifest.get("images", {}).items() if item.get("status") == "deleted"}
    return [image_id for image_id in order if image_id not in deleted]


def ensure_work_copy(
    folder_id: int,
    user_id: str,
    image_id: int,
    image_name: str,
    source_path: Path,
    *,
    official_ids: list[int] | None = None,
) -> Path:
    """Copy an official page into the draft (once) so it can be edited without touching the original."""
    manifest = read_manifest(folder_id, user_id) or empty_manifest(folder_id, user_id)
    if official_ids is not None:
        ensure_order(manifest, official_ids)
    images = manifest.setdefault("images", {})
    key = image_key(image_id)
    item = images.get(key)
    if item and item.get("work_path") and fs_path(Path(item["work_path"])).is_file():
        return Path(item["work_path"]).resolve()

    images_dir = draft_dir(folder_id, user_id) / "images"
    fs_path(images_dir).mkdir(parents=True, exist_ok=True)
    work_path = (images_dir / f"{image_id}_{safe_part(image_name)}").resolve()
    work_path.relative_to(draft_dir(folder_id, user_id).resolve())
    shutil.copy2(fs_path(source_path), fs_path(work_path))
    # Update the EXISTING item in place rather than assigning a fresh dict -
    # ensure_editable_work_path calls this to rebuild a work copy an AV scan or
    # %LOCALAPPDATA% cleanup deleted out from under a pending edit, and a fresh
    # dict here dropped pending_ops/dirty/version, silently discarding the edit
    # (it got recreated with dirty=False and was never committed).
    if item is None:
        item = {"dirty": False, "status": "existing"}
        images[key] = item
    item["image_name"] = image_name
    item["official_path"] = str(source_path.resolve())
    item["work_path"] = str(work_path)
    write_manifest(folder_id, user_id, manifest)
    return work_path


# --- Pending (deferred) edits: rotate, crop, deskew ---------------------------
# A deskew is DEFERRED, not applied when the reviewer clicks.
#
# Straightening a page used to resample the full 18MP working copy and re-encode
# it on every click: ~1.5s each, and a 5 degree correction is several clicks, so
# the operator waited about eight seconds to do one thing. It also compounded -
# five clicks meant five resamples and five JPEG re-encodes, each on the output
# of the last, so the page got softer the more carefully it was straightened.
#
# The angle now accumulates here and the PREVIEW is rotated instead (~130ms at
# 1600px). The full-resolution resample happens exactly once, when the pixels
# are actually needed: before any other image operation, and at approval. One
# resample from the original is both faster and sharper than N compounded ones.
MAX_PENDING_DESKEW = 45.0


def pending_ops_of(manifest: dict | None, image_id: int) -> list[dict]:
    """This image's deferred edits, in the order the reviewer made them.

    Order is the whole contract: cropping then rotating is not the same picture
    as rotating then cropping, so the list is replayed exactly as recorded.

    A crop rect is stored NORMALISED (0..1 of the frame it was drawn on), which
    is what lets the same list drive both the 1600px preview and the full
    resolution flush. It is denormalised against whatever the frame measures at
    that point in the replay, so a crop after a rotate uses the rotated size.

    Reads the older `pending_deskew` field as a trailing deskew, so a draft left
    open across the upgrade that introduced this list is not silently dropped.
    """
    item = draft_image_item(manifest, image_id)
    if not item:
        return []
    ops = [op for op in (item.get("pending_ops") or []) if isinstance(op, dict)]
    legacy = item.get("pending_deskew")
    if legacy:
        try:
            if float(legacy):
                ops = ops + [{"op": "deskew", "degrees": float(legacy)}]
        except (TypeError, ValueError):
            pass
    return ops


def pending_deskew_of(manifest: dict | None, image_id: int) -> float:
    """Total deferred straightening, for the callers that only care about that."""
    total = 0.0
    for op in pending_ops_of(manifest, image_id):
        if op.get("op") == "deskew":
            try:
                total += float(op.get("degrees") or 0.0)
            except (TypeError, ValueError):
                continue
    return total


def add_pending_op(folder_id: int, user_id: str, image_id: int, op: dict) -> list[dict]:
    """Append a deferred edit. Returns the image's resulting op list.

    Consecutive edits of the SAME rotational kind are merged rather than
    appended - five 1-degree nudges are one 5-degree resample, and two 90 degree
    turns are one 180. Crops are never merged: a crop of a crop is a different
    rectangle, and composing them is not worth getting subtly wrong.

    Raises ValueError past MAX_PENDING_DESKEW: the canvas grows with the angle,
    so a runaway total would balloon the page rather than straighten it.
    """
    manifest = read_manifest(folder_id, user_id) or empty_manifest(folder_id, user_id)
    push_history(manifest, folder_id, user_id)
    item = manifest.setdefault("images", {}).setdefault(image_key(image_id), {})

    ops = [entry for entry in (item.get("pending_ops") or []) if isinstance(entry, dict)]
    legacy = item.get("pending_deskew")
    if legacy:
        try:
            if float(legacy):
                ops.append({"op": "deskew", "degrees": float(legacy)})
        except (TypeError, ValueError):
            pass
        item["pending_deskew"] = 0.0

    kind = op.get("op")
    if kind in {"deskew", "rotate"} and ops and ops[-1].get("op") == kind:
        merged = float(ops[-1].get("degrees") or 0.0) + float(op.get("degrees") or 0.0)
        if kind == "rotate":
            merged = merged % 360.0
        if kind == "deskew" and abs(merged) > MAX_PENDING_DESKEW:
            raise ValueError(
                f"Total straightening is limited to {MAX_PENDING_DESKEW:g} degrees; "
                f"this would reach {merged:.1f}."
            )
        if merged:
            ops[-1] = {"op": kind, "degrees": merged}
        else:
            ops.pop()  # nudged back to straight, or turned full circle
    else:
        if kind == "deskew" and abs(float(op.get("degrees") or 0.0)) > MAX_PENDING_DESKEW:
            raise ValueError(
                f"Total straightening is limited to {MAX_PENDING_DESKEW:g} degrees."
            )
        ops.append(op)

    item["pending_ops"] = ops
    item["dirty"] = True
    item["version"] = image_version_stamp()
    if item.get("status") == "existing":
        item["status"] = "edited"
    manifest.setdefault("operations", []).append(
        {"image_id": image_id, "operation": kind, "at": utc_now_iso()}
    )
    write_manifest(folder_id, user_id, manifest)
    return ops


def add_pending_deskew(folder_id: int, user_id: str, image_id: int, degrees: float) -> float:
    """Straightening, as a deferred op. Returns the resulting total angle."""
    add_pending_op(folder_id, user_id, image_id, {"op": "deskew", "degrees": float(degrees)})
    return pending_deskew_of(read_manifest(folder_id, user_id), image_id)


def clear_pending_ops(folder_id: int, user_id: str, image_id: int) -> None:
    """Drop the deferred edits once they are baked into the working copy."""
    manifest = read_manifest(folder_id, user_id)
    if not manifest:
        return
    item = draft_image_item(manifest, image_id)
    if not item:
        return
    if not item.get("pending_ops") and not item.get("pending_deskew"):
        return
    item["pending_ops"] = []
    item["pending_deskew"] = 0.0
    item["version"] = image_version_stamp()
    write_manifest(folder_id, user_id, manifest)


# Kept as the name the deskew-only callers read better with.
clear_pending_deskew = clear_pending_ops


def images_with_pending_ops(folder_id: int, user_id: str) -> list[int]:
    """Image ids still carrying deferred edits, for the flush before commit."""
    manifest = read_manifest(folder_id, user_id)
    if not manifest:
        return []
    pending = []
    for key, item in (manifest.get("images") or {}).items():
        if not isinstance(item, dict):
            continue
        if item.get("pending_ops") or item.get("pending_deskew"):
            try:
                pending.append(int(key))
            except (TypeError, ValueError):
                continue
    return pending


images_with_pending_deskew = images_with_pending_ops


def image_version_stamp() -> int:
    """Cache-buster for ONE image's preview URL.

    Stamped per image rather than per folder. The preview URL used to carry the
    manifest's `updated_at`, which every write bumps - so editing page 12 changed
    the URL of pages 1-11 as well and the rail re-fetched every page it had ever
    touched, at roughly 300ms of rendering each. The longer a reviewer worked on
    a folder, the slower each further edit became.

    Snapshotted and restored by push_history with the image item, so an undo
    reverts the stamp along with the pixels it belongs to and a browser cache
    entry for that stamp is still correct.
    """
    return int(datetime.now(timezone.utc).timestamp() * 1000)


# --- Page-level draft operations ----------------------------------------------
def mark_dirty(folder_id: int, user_id: str, image_id: int, operation: str) -> None:
    """Record that a page was changed (with an undo snapshot) so it is committed later."""
    manifest = read_manifest(folder_id, user_id) or empty_manifest(folder_id, user_id)
    push_history(manifest, folder_id, user_id)
    item = manifest.setdefault("images", {}).setdefault(image_key(image_id), {})
    item["dirty"] = True
    item["version"] = image_version_stamp()
    if item.get("status") == "existing":
        item["status"] = "edited"
    manifest.setdefault("operations", []).append({"image_id": image_id, "operation": operation, "at": utc_now_iso()})
    write_manifest(folder_id, user_id, manifest)


def mark_dirty_no_history(folder_id: int, user_id: str, image_id: int, operation: str) -> None:
    """Same as mark_dirty but without taking an undo snapshot first."""
    manifest = read_manifest(folder_id, user_id) or empty_manifest(folder_id, user_id)
    item = manifest.setdefault("images", {}).setdefault(image_key(image_id), {})
    item["dirty"] = True
    item["version"] = image_version_stamp()
    if item.get("status") == "existing":
        item["status"] = "edited"
    manifest.setdefault("operations", []).append({"image_id": image_id, "operation": operation, "at": utc_now_iso()})
    write_manifest(folder_id, user_id, manifest)


def create_inserted_image(folder_id: int, user_id: str, image_name: str, source_path: Path, before_image_id: int, official_ids: list[int]) -> int:
    """Add an uploaded file as a new draft-only page before another page. Returns its negative temp id."""
    manifest = read_manifest(folder_id, user_id) or empty_manifest(folder_id, user_id)
    push_history(manifest, folder_id, user_id)
    order = ensure_order(manifest, official_ids)
    temp_id = int(manifest.get("next_temp_id", -1))
    manifest["next_temp_id"] = temp_id - 1
    images_dir = draft_dir(folder_id, user_id) / "images"
    fs_path(images_dir).mkdir(parents=True, exist_ok=True)
    work_path = (images_dir / f"{temp_id}_{safe_part(image_name)}").resolve()
    shutil.copy2(fs_path(source_path), fs_path(work_path))
    manifest["images"][image_key(temp_id)] = {
        "image_name": image_name,
        "official_path": None,
        "work_path": str(work_path),
        "dirty": True,
        "status": "inserted",
    }
    try:
        index = order.index(before_image_id)
    except ValueError:
        index = len(order)
    order.insert(index, temp_id)
    manifest["order"] = order
    manifest["operations"].append({"image_id": temp_id, "operation": "insert_before", "at": utc_now_iso()})
    write_manifest(folder_id, user_id, manifest)
    return temp_id


def replace_image(folder_id: int, user_id: str, image_id: int, image_name: str, source_path: Path, official_ids: list[int]) -> Path:
    """Overwrite a page's draft work copy with an uploaded file. Returns the work copy path."""
    manifest = read_manifest(folder_id, user_id) or empty_manifest(folder_id, user_id)
    push_history(manifest, folder_id, user_id)
    ensure_order(manifest, official_ids)
    images_dir = draft_dir(folder_id, user_id) / "images"
    fs_path(images_dir).mkdir(parents=True, exist_ok=True)
    item = manifest.setdefault("images", {}).setdefault(image_key(image_id), {})
    work_path = Path(item.get("work_path") or images_dir / f"{image_id}_{safe_part(image_name)}").resolve()
    shutil.copy2(fs_path(source_path), fs_path(work_path))
    item.update({
        "image_name": image_name,
        "work_path": str(work_path),
        "dirty": True,
        "status": "inserted" if image_id < 0 else "replaced",
    })
    manifest["operations"].append({"image_id": image_id, "operation": "replace", "at": utc_now_iso()})
    write_manifest(folder_id, user_id, manifest)
    return work_path


def delete_image(folder_id: int, user_id: str, image_id: int, official_ids: list[int]) -> None:
    """Mark a page deleted in the draft (a draft-only page is simply dropped) and remove it from the order."""
    manifest = read_manifest(folder_id, user_id) or empty_manifest(folder_id, user_id)
    push_history(manifest, folder_id, user_id)
    order = ensure_order(manifest, official_ids)
    if image_id < 0:
        manifest["images"].pop(image_key(image_id), None)
    else:
        item = manifest.setdefault("images", {}).setdefault(image_key(image_id), {})
        item["dirty"] = True
        item["status"] = "deleted"
    manifest["order"] = [item for item in order if item != image_id]
    manifest["separation_markers"] = [item for item in manifest.get("separation_markers", []) if item != image_id]
    manifest["operations"].append({"image_id": image_id, "operation": "delete", "at": utc_now_iso()})
    write_manifest(folder_id, user_id, manifest)


def set_order(folder_id: int, user_id: str, image_ids: list[int], official_ids: list[int]) -> None:
    """Store a new page order in the draft."""
    manifest = read_manifest(folder_id, user_id) or empty_manifest(folder_id, user_id)
    push_history(manifest, folder_id, user_id)
    ensure_order(manifest, official_ids)
    manifest["order"] = list(image_ids)
    manifest["operations"].append({"image_ids": image_ids, "operation": "reorder", "at": utc_now_iso()})
    write_manifest(folder_id, user_id, manifest)


def set_separation_markers(folder_id: int, user_id: str, first_page_image_ids: list[int], official_ids: list[int]) -> None:
    """Store which pages start a new folder when the draft is saved (separation)."""
    manifest = read_manifest(folder_id, user_id) or empty_manifest(folder_id, user_id)
    push_history(manifest, folder_id, user_id)
    ensure_order(manifest, official_ids)
    manifest["separation_markers"] = list(dict.fromkeys(first_page_image_ids))
    manifest["operations"].append({"image_ids": first_page_image_ids, "operation": "separation_markers", "at": utc_now_iso()})
    write_manifest(folder_id, user_id, manifest)


def save_metadata_draft(folder_id: int, user_id: str, values: dict[str, Any], operation: str = "metadata") -> None:
    """Store edited metadata values in the draft; they reach the folder row only on commit."""
    def serialize(value: Any) -> Any:
        if isinstance(value, datetime):
            return value.isoformat()
        return value

    manifest = read_manifest(folder_id, user_id) or empty_manifest(folder_id, user_id)
    push_history(manifest, folder_id, user_id)
    manifest["metadata"] = {
        "dirty": True,
        "values": {key: serialize(value) for key, value in values.items()},
    }
    manifest.setdefault("operations", []).append({"operation": operation, "at": utc_now_iso()})
    write_manifest(folder_id, user_id, manifest)


def restore_original(folder_id: int, user_id: str, image_id: int, official_ids: list[int]) -> None:
    """Drop this image's draft edits and, at the next approval, its committed
    geometry too - "original" now means LWIP's straightened baseline, not
    whatever qc_ops.json has accumulated across earlier approval rounds.

    A negative id (an uncommitted insert) has no baseline to fall back to, so
    it is removed outright, exactly as before. A real page instead gets a
    minimal marker, `{"restored": True}`: no work copy, nothing pending -
    commit_current_draft reads that flag to write committed=[]/ignore_lwip
    reset at approval (see its docstring). Popping the entry outright, as this
    used to do, left a PRIOR round's committed ops untouched - restoring only
    ever undid edits made in the CURRENT session.
    """
    manifest = read_manifest(folder_id, user_id)
    if not manifest:
        return
    push_history(manifest, folder_id, user_id)
    if image_id < 0:
        manifest["images"].pop(image_key(image_id), None)
        manifest["order"] = [item for item in manifest.get("order", []) if item != image_id]
    else:
        manifest["images"][image_key(image_id)] = {"restored": True}
        ensure_order(manifest, official_ids)
    manifest["separation_markers"] = [item for item in manifest.get("separation_markers", []) if item != image_id]
    manifest["operations"].append({"image_id": image_id, "operation": "restore_original", "at": utc_now_iso()})
    write_manifest(folder_id, user_id, manifest)


def mark_baked(folder_id: int, user_id: str, image_id: int) -> None:
    """Flag that this image's work copy now holds the FULL effective chain -
    LWIP's baseline, every earlier committed round, and whatever was pending -
    baked in by a flush (see qc.py's ops_to_bake, luminance's pre-step).

    commit_current_draft reads this to commit the work copy as a real pixel
    replacement and reset qc_ops.json instead of layering more entries onto
    it - the pixels already contain everything qc_ops.json would otherwise
    have to describe.
    """
    manifest = read_manifest(folder_id, user_id)
    if not manifest:
        return
    item = draft_image_item(manifest, image_id)
    if not item:
        return
    item["baked"] = True
    write_manifest(folder_id, user_id, manifest)


def discard_draft(folder_id: int, user_id: str) -> None:
    """Delete the whole draft folder (manifest, work copies and history)."""
    path = draft_dir(folder_id, user_id)
    if fs_path(path).exists():
        shutil.rmtree(fs_path(path))

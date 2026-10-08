"""Pages and edits QC owns, kept through a capture rework.

A capture rework makes LWIP rebuild the whole output folder: it builds a fresh
directory and swaps it in, so everything QC added to the old one - inserted
pages, replacement files, their thumbnails, qc_ops.json - is gone, while the
capture_images rows (which LWIP never touches) live on. LWIP is not changed
for this; QC keeps its own copy outside LWIP's tree and puts it back.

Store: `<qc_work_root>/qc_kept/<folder_id>/`
  kept.json     the publish marker + per-file sha256 of LWIP's manifest at
                snapshot time, a copy of qc_ops.json, and the kept pages
  pages/<name>  a byte copy of every inserted/replaced page

`snapshot_folder` runs after every commit (Save changes, Approve).
`restore_after_republish` runs at claim time. LWIP's `source_fingerprint` only
describes its INPUT and can stay the same across a rebuild, so a republish is
recognised by the manifest's publish marker (`created_at`, rewritten on every
publish) OR by the folder visibly missing what the store holds. Neither may
ever raise: a snapshot that fails costs a later restore, and a restore that
fails must not stop a reviewer opening the folder.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
from datetime import datetime, timedelta, timezone
from hashlib import sha256
from pathlib import Path
from typing import Any

from sqlalchemy import select

from app.core.paths import fs_path, to_local
from app.models.capture import CaptureFolder
from app.models.qc_session import ReworkLog
from app.services.lwip_baseline import _load_manifest, baseline_ops
from app.services.previews import generate_thumbnail_file
from app.services.qc_drafts import qc_work_root
from app.services.qc_ops_store import qc_ops_path, read_qc_ops, write_qc_ops

logger = logging.getLogger(__name__)

KEPT_NAME = "kept.json"
QC_REWORK_TYPE = "QC Rework"


def store_dir(folder_id: int) -> Path:
    return qc_work_root() / "qc_kept" / str(folder_id)


def _safe_name(name: Any) -> bool:
    """A bare file name. Names reach this module from qc_ops.json and kept.json,
    which live on shares anyone with write access can edit, and end up in paths
    this process moves and overwrites as SYSTEM."""
    return (
        isinstance(name, str)
        and name not in {"", ".", ".."}
        and Path(name).name == name
        and "/" not in name
        and "\\" not in name
    )


def _read_store(folder_id: int) -> dict[str, Any] | None:
    try:
        data = json.loads(fs_path(store_dir(folder_id) / KEPT_NAME).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _file_sha(path: Path) -> str:
    digest = sha256()
    with fs_path(path).open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _copy_atomic(source: Path, target: Path) -> None:
    """Temp file beside [target], then replace: an interrupted copy never
    leaves a truncated file under the real name."""
    temp = target.with_name(f".{target.name}.kept_tmp")
    try:
        shutil.copy2(fs_path(source), fs_path(temp))
        os.replace(fs_path(temp), fs_path(target))
    except BaseException:
        fs_path(temp).unlink(missing_ok=True)
        raise


def _manifest_state(folder_path: Path) -> tuple[str | None, dict[str, str]]:
    """(publish marker, {relative_path: sha256}) of LWIP's current manifest.

    The marker is None when there is no manifest at all."""
    manifest = _load_manifest(folder_path)
    if manifest is None:
        return None, {}
    shas = {
        str(entry["relative_path"]): str(entry.get("sha256") or "")
        for entry in manifest.get("files") or []
        if isinstance(entry, dict) and entry.get("relative_path")
    }
    return f"{manifest.get('created_at')}|{manifest.get('source_fingerprint')}", shas


def _listed_names(shas: dict[str, str]) -> set[str]:
    return {os.path.normcase(name) for name in shas}


def _kept_kind(entry: Any, name: str, manifest_names: set[str]) -> str | None:
    """"inserted"/"replaced" for a page QC owns, else None.

    Entries written before the `kept` tag existed carry only ignore_lwip - which
    a luminance-baked LWIP page has too - so those are recognised by LWIP's
    manifest instead: a page it never listed was added in QC."""
    if isinstance(entry, dict) and entry.get("kept"):
        return str(entry["kept"])
    if manifest_names and os.path.normcase(name) not in manifest_names:
        return "inserted"
    return None


def is_kept_page(folder_id: int, folder_path: Path | None, image_name: str) -> bool:
    """True for a page QC added or replaced - the reject guard's question."""
    if folder_path is not None:
        entry = (read_qc_ops(folder_path).get("images") or {}).get(image_name)
        if _kept_kind(entry, image_name, _listed_names(_manifest_state(folder_path)[1])):
            return True
    return image_name in ((_read_store(folder_id) or {}).get("pages") or {})


def drop_store(folder_id: int) -> None:
    """Nothing left to restore: the folder was split."""
    shutil.rmtree(fs_path(store_dir(folder_id)), ignore_errors=True)


def snapshot_folder(folder: CaptureFolder, db=None, recaptured=()) -> None:
    """[recaptured]: names of pages being sent back for recapture right now.
    They are recorded as such and their edits are left out of the copy - no
    clock comparison involved, unlike the rework-log check."""
    try:
        _snapshot(folder, db, set(recaptured))
    except Exception:
        logger.exception("QC kept-pages snapshot failed; folder=%s", folder.id)


def _republished(folder: CaptureFolder, folder_path: Path, stored: dict, marker: str | None) -> bool:
    if marker is not None and stored.get("manifest_marker") != marker:
        return True
    row_names = {image.image_name for image in folder.images}
    for name in stored.get("pages") or {}:
        if name in row_names and _safe_name(name) and not fs_path(folder_path / name).is_file():
            return True
    stored_ops = (stored.get("qc_ops") or {}).get("images")
    return bool(stored_ops) and not fs_path(qc_ops_path(folder_path)).is_file()


def _snapshot(folder: CaptureFolder, db, recaptured: set[str] = frozenset(), clear_recaptured: bool = False) -> None:
    if not folder.folder_path:
        return
    folder_path = to_local(folder.folder_path)
    if not fs_path(folder_path).is_dir():
        return
    marker, shas = _manifest_state(folder_path)
    old = _read_store(folder.id) or {}
    if old and _republished(folder, folder_path, old, marker):
        clear_recaptured = clear_recaptured or (marker is not None and old.get("manifest_marker") != marker)
        # The folder was rebuilt and not yet put back (a restore that failed,
        # or a republish during review): snapshotting NOW would overwrite the
        # only good copy with the rebuilt state. Restore first.
        if db is None:
            return
        _restore(folder, db)
        old = _read_store(folder.id) or {}
    # Pages already sent back and not yet republished stay marked until a
    # genuine republish has been restored (then a later cycle starts clean).
    recaptured = set(recaptured) | (set() if clear_recaptured else set(old.get("recaptured") or []))
    qc_ops = read_qc_ops(folder_path)
    ops_images = qc_ops.get("images") if isinstance(qc_ops.get("images"), dict) else {}
    old_pages = old.get("pages") or {}
    store = store_dir(folder.id)
    pages_dir = store / "pages"
    manifest_names = _listed_names(shas)

    pages: dict[str, dict] = {}
    for image in folder.images:
        name = image.image_name
        entry = ops_images.get(name)
        kind = _kept_kind(entry, name, manifest_names)
        if kind is None or not _safe_name(name):
            continue
        lwip_name = entry.get("lwip_name") if isinstance(entry, dict) else None
        record = {"kind": kind, "image_id": image.id, "lwip_name": lwip_name if _safe_name(lwip_name) else None}
        source = folder_path / name
        target = pages_dir / name
        if fs_path(source).is_file():
            stat = fs_path(source).stat()
            record["size"], record["mtime_ns"] = stat.st_size, stat.st_mtime_ns
            previous = old_pages.get(name, {})
            if (
                previous.get("sha256")
                and (previous.get("size"), previous.get("mtime_ns")) == (stat.st_size, stat.st_mtime_ns)
                and fs_path(target).is_file()
            ):
                # Same size and mtime as the copy on record: not re-read (a
                # slow share, and the row lock is held).
                record["sha256"] = previous["sha256"]
            else:
                digest = _file_sha(source)
                if previous.get("sha256") != digest or not fs_path(target).is_file():
                    fs_path(pages_dir).mkdir(parents=True, exist_ok=True)
                    _copy_atomic(source, target)
                record["sha256"] = digest
        elif name in old_pages and fs_path(target).is_file():
            # Already lost from the folder: the stored copy is all that is
            # left, so it stays.
            record["sha256"] = old_pages[name].get("sha256")
        else:
            continue
        pages[name] = record

    stored_images = {name: entry for name, entry in ops_images.items() if name not in recaptured}
    qc_ops = {**qc_ops, "images": stored_images}
    if not pages and not stored_images and not recaptured:
        drop_store(folder.id)
        return
    if fs_path(pages_dir).is_dir():
        for stale in fs_path(pages_dir).iterdir():
            if stale.name not in pages:
                stale.unlink(missing_ok=True)

    fs_path(store).mkdir(parents=True, exist_ok=True)
    data = {
        "manifest_marker": marker,
        "manifest_sha": shas,
        "snapshot_at": datetime.now(timezone.utc).isoformat(),
        "qc_ops": qc_ops,
        "recaptured": sorted(recaptured),
        "pages": pages,
    }
    temp = store / f".{KEPT_NAME}.tmp"
    fs_path(temp).write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(fs_path(temp), fs_path(store / KEPT_NAME))


def restore_after_republish(folder: CaptureFolder, db) -> None:
    try:
        stored = _read_store(folder.id) or {}
        marker = _manifest_state(to_local(folder.folder_path))[0] if folder.folder_path else None
        genuine = marker is not None and stored.get("manifest_marker") != marker
        if _restore(folder, db):
            _snapshot(folder, db, clear_recaptured=genuine)
        elif stored.get("recaptured"):
            # Pending again with no republish (a metadata-only return): LWIP
            # sets PENDING only after publishing, so none is coming for that
            # reject - the pages are not "being recaptured" any more.
            _snapshot(folder, db, clear_recaptured=True)
    except Exception:
        logger.exception("QC kept-pages restore failed; folder=%s", folder.id)


def _recaptured_names(folder: CaptureFolder, db, stored: dict, shas: dict[str, str], kept: set[str]) -> set[str]:
    """Pages whose own edits cannot be trusted any more: LWIP's file for them
    changed, or QC sent them back for recapture after the snapshot. When
    unsure the edits are dropped - a page without QC's crop just opens
    uncropped, while a stale crop on a new photo ships wrong."""
    old_shas = stored.get("manifest_sha") or {}
    names = {
        image.image_name
        for image in folder.images
        if image.image_name not in kept and shas.get(image.image_name) != old_shas.get(image.image_name)
    }
    # Named outright when the reject snapshot was taken - no clocks involved.
    names |= {name for name in stored.get("recaptured") or [] if isinstance(name, str)}
    try:
        # The log column keeps milliseconds and the snapshot microseconds, so
        # compare from a millisecond before the snapshot's own millisecond.
        snapshot_at = datetime.fromisoformat(stored["snapshot_at"])
        snapshot_at = snapshot_at.replace(microsecond=snapshot_at.microsecond // 1000 * 1000) - timedelta(milliseconds=1)
        # A savepoint: a database error here must not leave the claim's own
        # transaction aborted.
        with db.begin_nested():
            reworked = set(db.scalars(
                select(ReworkLog.image_id).where(
                    ReworkLog.folder_id == folder.id,
                    ReworkLog.rework_type == QC_REWORK_TYPE,
                    ReworkLog.created_at >= snapshot_at,
                )
            ).all())
        names |= {image.image_name for image in folder.images if image.id in reworked}
    except Exception:
        logger.exception("QC kept-pages could not read rework logs; folder=%s", folder.id)
        names |= {image.image_name for image in folder.images if image.image_name not in kept}
    return names


def _restore(folder: CaptureFolder, db) -> bool:
    stored = _read_store(folder.id)
    if not stored or not folder.folder_path:
        return False
    folder_path = to_local(folder.folder_path)
    if not fs_path(folder_path).is_dir():
        return False
    marker, shas = _manifest_state(folder_path)
    if not _republished(folder, folder_path, stored, marker):
        return False

    pages: dict[str, dict] = {n: r for n, r in (stored.get("pages") or {}).items() if _safe_name(n)}
    # A genuine republish changed the publish marker; anything else (a file
    # lost to a scan, a failed step) must not overwrite what is on disk now.
    genuine = marker is not None and stored.get("manifest_marker") != marker
    row_names = {image.image_name for image in folder.images}
    existing_ops = read_qc_ops(folder_path).get("images")
    existing_ops = existing_ops if isinstance(existing_ops, dict) else {}
    recaptured = _recaptured_names(folder, db, stored, shas, set(pages))
    thumb_dir = to_local(folder.thumbnail_path) if folder.thumbnail_path else None
    if thumb_dir is not None:
        fs_path(thumb_dir).mkdir(parents=True, exist_ok=True)
    stored_ops = (stored.get("qc_ops") or {}).get("images") or {}
    restored_ops: dict[str, dict] = {}

    for name, record in pages.items():
        if name not in row_names:
            continue
        copy = store_dir(folder.id) / "pages" / name
        if not fs_path(copy).is_file():
            continue
        if record.get("sha256") and _file_sha(copy) != record["sha256"]:
            logger.error("QC kept page copy is damaged, not restored; folder=%s page=%s", folder.id, name)
            continue
        target = folder_path / name
        copied = not fs_path(target).is_file() or (genuine and _file_sha(target) != record.get("sha256"))
        if copied:
            _copy_atomic(copy, target)
        lwip_name = record.get("lwip_name")
        if _safe_name(lwip_name) and lwip_name != name and lwip_name not in row_names:
            _retire_stray(folder, folder_path, thumb_dir, lwip_name)
        # Only FILL what is missing: an entry already in qc_ops.json is newer
        # than the snapshot (a Save just wrote it).
        filled = name in stored_ops and name not in existing_ops
        if filled:
            restored_ops[name] = stored_ops[name]
        if copied or filled:
            _rebuild_thumbnail(folder_path, thumb_dir, name, stored_ops.get(name), ignore_lwip=True)

    for name, entry in stored_ops.items():
        if name in pages or name in recaptured or name not in row_names or not isinstance(entry, dict):
            continue
        if name in existing_ops:
            continue
        restored_ops[name] = entry
        _rebuild_thumbnail(folder_path, thumb_dir, name, entry, ignore_lwip=bool(entry.get("ignore_lwip")))

    data = read_qc_ops(folder_path)
    data.setdefault("version", 1)
    images = data.get("images") if isinstance(data.get("images"), dict) else {}
    for name, entry in restored_ops.items():
        images.setdefault(name, entry)
    data["images"] = images
    write_qc_ops(folder_path, data)
    logger.info(
        "QC kept pages restored after a republish; folder=%s kept=%s edits=%s dropped=%s",
        folder.id, sorted(pages), sorted(set(restored_ops) - set(pages)), sorted(recaptured & set(stored_ops)),
    )
    return True


def _rebuild_thumbnail(folder_path: Path, thumb_dir: Path | None, name: str, entry: dict | None, ignore_lwip: bool) -> None:
    """LWIP's own thumbnail knows nothing of QC's geometry or pages."""
    if thumb_dir is None:
        return
    ops = [op for op in (entry or {}).get("ops") or [] if isinstance(op, dict)]
    if not ignore_lwip:
        ops = baseline_ops(folder_path, name) + ops
    try:
        generate_thumbnail_file(folder_path / name, thumb_dir / name, ops)
    except Exception:
        logger.exception("QC kept-pages thumbnail failed; page=%s", name)


def _retire_stray(folder: CaptureFolder, folder_path: Path, thumb_dir: Path | None, name: str) -> None:
    """The file LWIP produced under a replaced page's OLD name has no row any
    more: archive it beside QC's other deleted files rather than leave a stray."""
    archive = qc_work_root() / "qc_deleted" / str(folder.id) / f"republish-{int(datetime.now().timestamp() * 1000)}"
    for path, target_dir in ((folder_path / name, archive), (thumb_dir / name if thumb_dir else None, archive / "thumbs")):
        if path is not None and fs_path(path).is_file():
            fs_path(target_dir).mkdir(parents=True, exist_ok=True)
            shutil.move(str(fs_path(path)), str(fs_path(target_dir / name)))

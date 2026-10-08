r"""Give already-split QC child folders their LWIP manifest back.

Why: before this fix a separation moved the pages into `<name>_001`, `<name>_002`
... but left LWIP's `.deskew_crop_manifest.json` (the deskew/crop baseline) in
the parent folder. The children then had no baseline, so their preview,
re-rendered thumbnails and EXPORT lacked LWIP's deskew/crop. This copies the
parent's manifest into each such child, narrowed to the child's own pages, and
re-renders the child's thumbnails with the full ops chain. It writes nothing
when a child already has a manifest, so running it twice is safe.

Dry run by default: prints what it would do. `--yes` writes.

On the QC repo (development), from `backend\`:

    C:\Python314\python.exe repair_split_manifests.py [--yes]

On an INSTALLED QC PC (the installer ships this file in `<install>\backend\`),
from an ELEVATED prompt (config\ is admin-only):

    cd /d "C:\Program Files\LWCam QC Platform\backend"
    set LWCAM_QC_SERVER_CONFIG=C:\Program Files\LWCam QC Platform\config\config.txt
    ..\runtime\python\python.exe repair_split_manifests.py          (dry run)
    ..\runtime\python\python.exe repair_split_manifests.py --yes    (write)

Network shares: an admin prompt does not have the saved network logins the
SYSTEM service uses, so main() connects them first (netlogin.connect_all). A
child whose folder still cannot be read prints "failed - <error>", counts as a
failure and the run goes on.

A child is reported, not repaired, when no ancestor folder with a manifest is
left (the parent folder was removed, or LWIP never made a manifest). When the
manifest comes from further up (a child that was split again) only pages whose
sha256 equals the file on disk are kept. Thumbnails are re-rendered only if the
child has a thumbnail_path; if anything fails after the manifest was written,
that manifest is removed again so a rerun retries. A child that is already
exported is flagged: it was delivered without deskew/crop and needs a revert
(client rework) to re-deliver. Repairing a child that already has a kept-pages
store makes the next claim log "restored after a republish"; harmless, it only
fills missing entries.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

_here = Path(__file__).resolve().parent
sys.path.insert(0, str(_here))  # lives in backend\, next to app\
from app.core.paths import fs_path  # noqa: E402
from app.services.lwip_baseline import MANIFEST_NAME  # noqa: E402
from app.services.qc_separation import child_manifest  # noqa: E402

_SPLIT_NAME = re.compile(r"^(?P<stem>.*)_\d{3}(?P<tail>_path)?$")


def parent_dir_name(name: str) -> str | None:
    """Inverse of qc_separation.child_directory_path (one level up)."""
    m = _SPLIT_NAME.match(name)
    if not m:
        return None
    return m.group("stem") + (m.group("tail") or "")


def _read(path: Path) -> dict | None:
    try:
        data = json.loads(fs_path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with fs_path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def repair_child_dir(child_dir: Path, thumb_dir: Path | None = None, write: bool = False) -> tuple[str, str]:
    """(status, detail). status: has-manifest | repaired | would-repair | unrepairable."""
    child_dir = Path(child_dir)
    if fs_path(child_dir / MANIFEST_NAME).is_file():
        return "has-manifest", "already has a manifest"
    if not fs_path(child_dir).is_dir():
        return "unrepairable", f"folder missing: {child_dir}"
    names = [p.name for p in fs_path(child_dir).iterdir() if p.is_file()]
    # A child that was split again has no manifest-bearing parent; walk up.
    name, source, hops = child_dir.name, None, 0
    while (name := parent_dir_name(name)) is not None:
        candidate = child_dir.with_name(name)
        manifest = _read(candidate / MANIFEST_NAME)
        if manifest is not None:
            source = (candidate, manifest)
            break
        hops += 1
    if source is None:
        return "unrepairable", "no ancestor folder with a manifest"
    parent_manifest = source[1]
    if hops:  # a manifest passed down through a parent that lost its own: names alone are not proof
        parent_manifest = dict(parent_manifest, files=[
            e for e in parent_manifest.get("files") or []
            if isinstance(e, dict) and e.get("relative_path") in names
            and e.get("sha256") == _sha256(child_dir / e["relative_path"])
        ])
    narrowed = child_manifest(parent_manifest, names)
    if narrowed is None:
        return "unrepairable", f"{source[0].name} manifest lists none of this folder's pages"
    detail = f"{len(narrowed['files'])} page(s) from {source[0].name}"
    if not write:
        return "would-repair", detail
    target = fs_path(child_dir / MANIFEST_NAME)
    temp = target.with_name(f".{MANIFEST_NAME}.tmp")
    temp.write_text(json.dumps(narrowed, ensure_ascii=False, indent=2), encoding="utf-8")
    temp.replace(target)
    try:
        if thumb_dir is not None and fs_path(thumb_dir).is_dir():
            from app.services.geometry_ops import replay_pending_ops
            from app.services.previews import generate_thumbnail_file, set_pending_op_replay
            from app.services.qc_ops_store import effective_ops

            # Only importing the router sets this; a script must do it itself.
            set_pending_op_replay(replay_pending_ops)
            for page in names:
                if fs_path(thumb_dir / page).is_file():
                    generate_thumbnail_file(child_dir / page, thumb_dir / page, effective_ops(child_dir, page))
    except Exception as error:
        target.unlink(missing_ok=True)  # resumable: a rerun starts again
        return "unrepairable", f"thumbnails failed, manifest removed: {error}"
    return "repaired", detail


def main() -> int:
    from sqlalchemy import text

    from app.core.paths import to_local
    from app.db.session import SessionLocal

    parser = argparse.ArgumentParser(description="Restore LWIP manifests in split QC child folders.")
    parser.add_argument("--yes", action="store_true", help="write (default is a dry run)")
    args = parser.parse_args()

    from app.core import netlogin

    netlogin.connect_all()
    with SessionLocal() as db:
        rows = db.execute(
            text(
                "SELECT id, folder_name, folder_path, thumbnail_path, qc_status, is_exported FROM capture_folders "
                "WHERE separated_from_folder_id IS NOT NULL AND is_deleted = false ORDER BY id"
            )
        ).all()
    bad = 0
    for row in rows:
        if not row.folder_path:
            print(f"folder {row.id} {row.folder_name}: unrepairable - no folder_path")
            bad += 1
            continue
        try:
            thumb = to_local(row.thumbnail_path) if row.thumbnail_path else None
            status, detail = repair_child_dir(to_local(row.folder_path), thumb, write=args.yes)
        except OSError as error:
            print(f"folder {row.id} {row.folder_name}: failed - {error}")
            bad += 1
            continue
        bad += status == "unrepairable"
        print(f"folder {row.id} {row.folder_name}: {status} - {detail}")
        if row.is_exported and status in ("repaired", "would-repair"):
            print("  already exported without deskew/crop - revert (client rework) to re-deliver")
    if not args.yes:
        print("Dry run. Re-run with --yes to write.")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

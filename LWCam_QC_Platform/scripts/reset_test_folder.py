r"""Put a finished QC folder back to PENDING, as if it had just been captured.

Why this exists: testing QC needs a pending folder, and the only other way to
get one is to photograph something. After approval a folder is PASS and
exported, its pages carry committed ops, and some may have been replaced or
inserted. Re-running LWIP alone does NOT bring it back, for a reason that is
easy to lose an hour to:

    LWIP only ever UPDATEs capture_folders. cloud_report.py's
    "SELECT id FROM capture_folders WHERE box_id = ... AND folder_seq = ..."
    returns NOT_YET when the row is missing, and the row is created by LWCAM's
    capture app (pg_sync_sink), not by LWIP. Delete the row, re-run LWIP, and
    you get images on disk that QC cannot see, with no error anywhere.

So this rebuilds the row itself, from LWCAM's own local SQLite, which still
holds the folder and every field the operator keyed. Nothing is invented: only
the QC state is reset - PENDING, not exported, no group id, no lock.

One subtlety worth keeping: capture_images.image_name in PostgreSQL holds the
TRANSFERRED name (SAX01_..._001.jpg), not the capture name. QC resolves every
page as folder_path / image_name, and the transfer renamed the files. The
SQLite row keeps both, so this reads `transferred_name`.

Run it from the platform root, with the shipped runtime and its own
config.txt beside backend\ (or LWCAM_QC_SERVER_CONFIG pointed at it):

    C:\Python314\python.exe scripts\reset_test_folder.py 11

It deletes the batch output and the folder's DB rows, so it asks first unless
--yes is passed. It never touches 1.Images, which holds the only copy of the
capture.

Where 1.Images and the LWIP install are gone but the batch output survives,
--skip-lwip rebuilds the rows alone and leaves the pages on disk untouched;
--batch-dir points at them when the capture tree has moved since the row was
written. The station is then answerable for that folder holding the pages the
capture recorded, and the `names == on_disk` line at the end says whether it does.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))

from sqlalchemy import text  # noqa: E402 - must follow the sys.path fix above

from app.db.session import SessionLocal  # noqa: E402

LWIP_ROOT = Path(r"C:\Program Files\LWCam LWIP")
LWIP_CONFIG = LWIP_ROOT / "config" / "deskew_crop_config.json"
LWCAM_DBS = Path.home() / "LWCAM_DBs"

# The metadata LWCAM owns and QC only displays. Copied as a block rather than
# field by field, because a hand-written column list is exactly how Record Type
# got lost three times before - see the root AGENTS.md, "Traps that cost time here".
CARRIED_COLUMNS = (
    "folder_name", "folder_seq", "cover_tag", "image_tags", "title", "volume",
    "start_date", "end_date", "archival_ref_no", "record_type", "place", "language",
    "record_custodian", "capture_operator_id", "capture_operator_name",
    "digitizing_entity", "source_created_at", "source_updated_at",
)

INSERT_FOLDER = text(
    """
    INSERT INTO capture_folders (
        folder_name, box_id, device_id, folder_seq, cover_tag, image_tags, title, volume,
        start_date, end_date, archival_ref_no, record_type, place, language,
        record_custodian, capture_operator_id, capture_operator_name, digitizing_entity,
        source_created_at, source_updated_at, updated_at, is_deleted, client_rework,
        is_deskewed, is_cropped, is_created_thumbnail, folder_path, thumbnail_path,
        qc_status, is_tif_converted, is_exported, is_ingested)
    VALUES (
        :folder_name, :box_id, :device_id, :folder_seq, :cover_tag, :image_tags, :title, :volume,
        :start_date, :end_date, :archival_ref_no, :record_type, :place, :language,
        :record_custodian, :capture_operator_id, :capture_operator_name, :digitizing_entity,
        :source_created_at, :source_updated_at, now(), false, false,
        true, true, true, :folder_path, :thumbnail_path,
        'PENDING', false, false, false)
    RETURNING id
    """
)


def local_sqlite_row(folder_name: str, folder_seq: int) -> dict:
    """The capture app's own record of this folder, across its per-device files."""
    for db_path in sorted(LWCAM_DBS.glob("lwcam_stats_*.db")):
        connection = sqlite3.connect(db_path)
        connection.row_factory = sqlite3.Row
        try:
            folder = connection.execute(
                "SELECT * FROM capture_folders WHERE folder_name = ? AND folder_seq = ?",
                (folder_name, folder_seq),
            ).fetchone()
        except sqlite3.OperationalError:
            continue  # an older stats file, without the capture tables
        if folder is None:
            continue
        images = connection.execute(
            "SELECT * FROM capture_images WHERE folder_id = ? ORDER BY image_name",
            (folder["id"],),
        ).fetchall()
        return {"folder": dict(folder), "images": [dict(i) for i in images], "source": db_path}
    raise SystemExit(f"No LWCAM SQLite row for '{folder_name}' seq {folder_seq} under {LWCAM_DBS}")


def lwip_state_path() -> Path:
    """The state.json this LWIP install actually uses, per its own config.

    Mirrors deskew_crop_tool/config.py's own path resolution (a relative
    value resolves against the config file's grandparent, i.e. LWIP_ROOT) -
    the installed config writes an absolute path, but this keeps working
    against a hand-edited or older-style relative one too.
    """
    raw = json.loads(LWIP_CONFIG.read_text(encoding="utf-8"))
    value = str(raw.get("state_file", "runtime/state.json"))
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = LWIP_CONFIG.parent.parent / path
    return path.resolve()


def run_lwip() -> str:
    """One pass of the watcher, in its own runtime - it has cv2, the QC one need not."""
    code = (
        "import runpy, sys;"
        f"sys.path.insert(0, r'{LWIP_ROOT / 'backend'}');"
        f"sys.argv = ['deskew_crop_tool', '--config', r'{LWIP_CONFIG}', '--once'];"
        "runpy.run_module('deskew_crop_tool', run_name='__main__')"
    )
    result = subprocess.run(
        [str(LWIP_ROOT / "runtime" / "python" / "python.exe"), "-c", code],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise SystemExit(result.stderr[-500:])
    lines = (result.stdout or result.stderr).strip().splitlines()
    return lines[-1] if lines else "(no output)"


def main() -> None:
    parser = argparse.ArgumentParser(description="Reset a QC folder to PENDING for testing.")
    parser.add_argument("folder_id", type=int)
    parser.add_argument("--yes", action="store_true", help="skip the confirmation prompt")
    parser.add_argument("--skip-lwip", action="store_true", help="do not re-run LWIP")
    parser.add_argument(
        "--batch-dir",
        type=Path,
        help="use this folder instead of the row's folder_path, on a station where the capture tree moved",
    )
    args = parser.parse_args()

    with SessionLocal() as db:
        row = db.execute(
            text(
                """SELECT id, folder_name, folder_seq, box_id, device_id, qc_status,
                          is_exported, group_id, folder_path
                   FROM capture_folders WHERE id = :i"""
            ),
            {"i": args.folder_id},
        ).one_or_none()
    if row is None:
        raise SystemExit(f"No capture_folders row with id {args.folder_id}")

    batch_dir = args.batch_dir or Path(row.folder_path)
    # 2.Batches is LWIP's output and is rebuilt; 1.Images holds the transferred
    # capture and is the one directory this script must never write to.
    source_dir = Path(str(batch_dir).replace("2.Batches", "1.Images"))

    print(f"folder {row.id}: {row.folder_name}  ({row.qc_status}, exported={row.is_exported})")
    if args.skip_lwip:
        # ponytail: --skip-lwip trusts the batch output already on disk, so a
        # station that has lost 1.Images and the LWIP install can still make a
        # pending folder. The names == on_disk check at the end is what catches
        # a directory holding the wrong pages.
        print(f"  batch output   {batch_dir}   <- kept as it stands (--skip-lwip)")
    else:
        print(f"  batch output   {batch_dir}   <- deleted and rebuilt")
        print(f"  capture source {source_dir}   <- read only")
        if not source_dir.is_dir():
            raise SystemExit("The capture originals are gone - refusing, there is nothing to rebuild from.")
    if not args.yes and input("proceed? [y/N] ").strip().lower() != "y":
        raise SystemExit("cancelled")

    local = local_sqlite_row(row.folder_name, row.folder_seq)
    print(f"  metadata from  {local['source'].name}  ({len(local['images'])} images)")

    with SessionLocal() as db:
        images = db.execute(text("DELETE FROM capture_images WHERE folder_id = :i"), {"i": row.id}).rowcount
        folders = db.execute(text("DELETE FROM capture_folders WHERE id = :i"), {"i": row.id}).rowcount
        db.commit()
    print(f"  deleted {folders} folder row, {images} image rows")

    if not args.skip_lwip:
        if batch_dir.exists():
            shutil.rmtree(batch_dir)
        print(f"  removed batch output: {not batch_dir.exists()}")

        # LWIP skips anything recorded as completed, so the entry has to go or
        # the re-run is a silent no-op that reads exactly like success.
        lwip_state = lwip_state_path()
        state = json.loads(lwip_state.read_text(encoding="utf-8"))
        cleared = state.get("completed", {}).pop(str(source_dir), None)
        lwip_state.write_text(json.dumps(state, indent=1), encoding="utf-8")
        print(f"  cleared LWIP state entry: {cleared is not None}")

        print(f"  LWIP: {run_lwip()}")

    folder = local["folder"]
    values = {column: folder[column] for column in CARRIED_COLUMNS}
    values.update(
        box_id=row.box_id,
        device_id=row.device_id,
        folder_path=str(batch_dir),
        thumbnail_path=str(batch_dir / "thumbs"),
    )
    with SessionLocal() as db:
        new_id = db.execute(INSERT_FOLDER, values).scalar()
        for image in local["images"]:
            db.execute(
                text(
                    """INSERT INTO capture_images (image_name, device_id, folder_id, file_format,
                                                   image_created_at, image_updated_at)
                       VALUES (:name, :device, :folder, :format, :created, :updated)"""
                ),
                {
                    "name": image["transferred_name"] or image["image_name"],
                    "device": row.device_id,
                    "folder": new_id,
                    "format": image["file_format"],
                    "created": image["image_created_at"],
                    "updated": image["image_updated_at"],
                },
            )
        db.commit()
        names = [
            r[0]
            for r in db.execute(
                text("SELECT image_name FROM capture_images WHERE folder_id = :i ORDER BY image_name"),
                {"i": new_id},
            )
        ]

    on_disk = sorted(p.name for p in batch_dir.glob("*.jpg"))
    print(f"\nfolder {new_id} is PENDING with {len(names)} pages")
    print(f"every row resolves to a file: {names == on_disk}")
    if names != on_disk:
        print(f"  rows: {names}")
        print(f"  disk: {on_disk}")


if __name__ == "__main__":
    main()

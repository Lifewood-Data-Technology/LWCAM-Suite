"""The Upload Summary database: one row per package that reached the bucket.

A small SQLite file (`Upload_Summary.db3`) in the folder Station Setup names,
meant to be opened in DB Browser by a person - which is why `rework` is the
text `TRUE`/`FALSE` rather than 0/1, and sizes and times are rounded to two
decimals. The engine creates the file and table when missing and adds any
missing column to a file that already exists, so an older or hand-made file
keeps its rows. One row per `capture_id`; uploading the same package again
updates that row.

Written by the upload sweep after the package is verified in the bucket and
before it moves to the Uploaded folder (see upload.py).
"""

from __future__ import annotations

import csv
import io
import sqlite3
import zipfile
from datetime import datetime
from pathlib import Path
from typing import Any

from app.core.paths import fs_path
from app.services.export import GROUP_CSV_NAME as GROUP_CSV

SUMMARY_FILE = "Upload_Summary.db3"

# Column order is the operator's sample, with zip_size_mb renamed and rework
# added. Kept as a dict so ensure_schema can add whatever an existing file lacks.
COLUMNS: dict[str, str] = {
    "id": "INTEGER PRIMARY KEY AUTOINCREMENT",
    "capture_id": "TEXT UNIQUE",
    "title": "TEXT",
    "image_count": "INTEGER",
    "folder_size_mb": "REAL",
    "upload_speed_mb_s": "REAL",
    "upload_duration_s": "REAL",
    "upload_date": "TEXT",
    "upload_time": "TEXT",
    "rework": "TEXT",
}

SCHEMA = "CREATE TABLE IF NOT EXISTS upload_summary (\n    " + ",\n    ".join(
    f"{name} {kind}" for name, kind in COLUMNS.items()
) + "\n)"


def ensure_schema(connection: sqlite3.Connection) -> None:
    """Creates the table, then adds any column an existing file is missing.

    ALTER TABLE ADD COLUMN cannot add PRIMARY KEY or UNIQUE, so those two are
    only ever created by the CREATE; a pre-existing file already has them.
    """
    connection.execute(SCHEMA)
    present = {row[1] for row in connection.execute("PRAGMA table_info(upload_summary)")}
    for name, kind in COLUMNS.items():
        if name in present or "PRIMARY KEY" in kind or "UNIQUE" in kind:
            continue
        connection.execute(f"ALTER TABLE upload_summary ADD COLUMN {name} {kind}")


def read_group_metadata(package: Path) -> dict[str, str]:
    """The single row of GroupMetadataImage.csv, from a folder or a ZIP.

    utf-8-sig decodes both export encodings (utf-8 and utf-8-sig). A package
    without the CSV, or an empty one, yields {} and the caller falls back.
    """
    try:
        if fs_path(package).is_dir():
            text = fs_path(package / GROUP_CSV).read_text(encoding="utf-8-sig")
        else:
            with zipfile.ZipFile(fs_path(package)) as archive:
                member = next(
                    (n for n in archive.namelist() if n.rsplit("/", 1)[-1] == GROUP_CSV),
                    None,
                )
                if member is None:
                    return {}
                text = archive.read(member).decode("utf-8-sig")
    except (OSError, zipfile.BadZipFile, UnicodeDecodeError):
        return {}
    rows = list(csv.DictReader(io.StringIO(text)))
    if not rows:
        return {}
    return {str(k).strip(): str(v or "").strip() for k, v in rows[0].items() if k}


def _mb(size_bytes: int) -> float:
    return round(size_bytes / 1_000_000, 2)


def record_upload(
    db_path: Path,
    *,
    capture_id: str,
    title: str | None,
    image_count: int | None,
    rework: str | None,
    size_bytes: int,
    duration_s: float,
    at: datetime,
) -> dict[str, Any]:
    """Upserts the row for [capture_id]. Returns the values written.

    The 30 s busy timeout covers a person who has the file open in DB Browser
    with a write transaction pending; a plain read never blocks a writer.
    """
    folder_size_mb = _mb(size_bytes)
    duration = round(float(duration_s), 2)
    speed = round(folder_size_mb / duration, 2) if duration > 0 else None
    values = {
        "capture_id": capture_id,
        "title": title,
        "image_count": image_count,
        "folder_size_mb": folder_size_mb,
        "upload_speed_mb_s": speed,
        "upload_duration_s": duration,
        "upload_date": at.strftime("%Y-%m-%d"),
        "upload_time": at.strftime("%H:%M:%S"),
        "rework": rework,
    }
    fs_path(db_path.parent).mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(fs_path(db_path), timeout=30)
    try:
        ensure_schema(connection)
        columns = list(values)
        connection.execute(
            f"INSERT INTO upload_summary ({', '.join(columns)}) "
            f"VALUES ({', '.join('?' for _ in columns)}) "
            "ON CONFLICT(capture_id) DO UPDATE SET "
            + ", ".join(f"{c} = excluded.{c}" for c in columns if c != "capture_id"),
            [values[c] for c in columns],
        )
        connection.commit()
    finally:
        connection.close()
    return values


def normalize_rework(value: str | None) -> str | None:
    """`TRUE`/`FALSE` as the CSV writes them; anything else is kept as typed so a
    surprise in the export shows up in the table rather than being guessed at."""
    if value is None:
        return None
    text = value.strip()
    if not text:
        return None
    upper = text.upper()
    return upper if upper in {"TRUE", "FALSE"} else text


def image_count_from(metadata: dict[str, str], package: Path) -> int | None:
    """`Total Artifacts` from the CSV, else the number of files under artifacts/."""
    raw = metadata.get("Total Artifacts", "")
    if raw.isdigit():
        return int(raw)
    if fs_path(package).is_dir():
        artifacts = package / "artifacts"
        if fs_path(artifacts).is_dir():
            return sum(1 for p in fs_path(artifacts).iterdir() if p.is_file())
        return None
    try:
        with zipfile.ZipFile(fs_path(package)) as archive:
            return sum(
                1
                for n in archive.namelist()
                if "/artifacts/" in f"/{n}" and not n.endswith("/")
            )
    except (OSError, zipfile.BadZipFile):
        return None


__all__ = [
    "COLUMNS",
    "GROUP_CSV",
    "SCHEMA",
    "SUMMARY_FILE",
    "ensure_schema",
    "image_count_from",
    "normalize_rework",
    "read_group_metadata",
    "record_upload",
]

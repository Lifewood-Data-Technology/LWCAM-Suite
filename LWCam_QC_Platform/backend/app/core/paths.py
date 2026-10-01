"""Maps the paths LWCAM stores in `capture_folders` onto paths this process can open.

LWCAM writes an absolute **Windows** path (LWIP's output directory) into
`folder_path`/`thumbnail_path`, and it is the source of truth for those columns —
rewriting them would break LWCAM and LWIP, which read the same values. So the
translation belongs here, at the point of use.

`CAPTURE_IMAGE_HOST_PATH` / `CAPTURE_IMAGE_CONTAINER_PATH` were already declared
in `.env.example` and `docker-compose.yml`, where the host path is bind-mounted
at the container path — but nothing read them. This module is that reader.

Leave both unset (the default) when the backend runs natively on Windows and the
stored paths still resolve: every call is then an identity mapping.

The same pair is also settable from the Admin console, which takes precedence over
the configured values (see `app/core/runtime_settings.py`). That is the supported
way to re-point QC at images that have MOVED on disk: `folder_path` is LWCAM-owned
and rewriting it would break LWCAM and LWIP, so the stored prefix is remapped here
instead.
"""

import os
import re
from pathlib import Path

from app.core.config import settings


# Literal "\\?\", the Windows extended-length path prefix. Port of LWIP's own
# `fs_path` (LWIP/backend/deskew_crop_tool/image_ops.py) - this engine's own
# paths are LONGER than LWIP's (output root is `<input>_processed`, plus
# `\thumbs`), so the same 260-char MAX_PATH failure applies here, and with
# LongPathsEnabled off it shows up as a bare OSError from os.scandir/Image.open
# with nothing in the DB explaining it.
_EXTENDED_PREFIX = "\\\\?\\"
_UNC_EXTENDED_PREFIX = "\\\\?\\UNC\\"


def fs_path(path: Path | str) -> Path:
    r"""`path` in the form Windows accepts past its 260-character MAX_PATH.

    Applied ONLY at the system-call boundary (open/exists/scandir/mkdir/
    shutil/zipfile/Image.open/...), never to a path that gets stored: the
    prefixed form must not reach the DB, a JSON response, a CSV, or a zip
    member name. Use `display_path` to strip it back off first.

    Idempotent, and a no-op off Windows. See LWIP's `fs_path` for the fuller
    story (why the temp file beside the target is what actually fails first).
    """
    if os.name != "nt":
        return Path(path)
    text = os.path.abspath(str(path))
    if text.startswith(_EXTENDED_PREFIX):
        return Path(text)
    if text.startswith("\\\\"):
        # UNC: \\server\share -> \\?\UNC\server\share
        return Path(_EXTENDED_PREFIX + "UNC" + text[1:])
    return Path(_EXTENDED_PREFIX + text)


def display_path(path: Path | str) -> str:
    """Reverse of `fs_path`: strip the extended-length prefix for anything
    shown to a user or written to the DB, a JSON response, a CSV, or a zip
    member name. A path with no prefix passes through unchanged."""
    text = str(path)
    if text.startswith(_UNC_EXTENDED_PREFIX):
        return "\\\\" + text[len(_UNC_EXTENDED_PREFIX):]
    if text.startswith(_EXTENDED_PREFIX):
        return text[len(_EXTENDED_PREFIX):]
    return text


def _prefixes() -> tuple[str, str] | None:
    host = (settings.capture_image_host_path or "").strip()
    container = (settings.capture_image_container_path or "").strip()
    if not host or not container:
        return None
    return host.replace("\\", "/").rstrip("/"), container.replace("\\", "/").rstrip("/")


def resolve_with(db_value: str, host: str, container: str) -> Path:
    """`to_local` against an explicit prefix pair instead of the stored one.

    Exists so the Admin console can probe how many folders a CANDIDATE pair would
    resolve before saving it — the answer has to be computed with the exact same
    matching rules the real lookup uses, not an approximation of them.
    """
    host = (host or "").replace("\\", "/").rstrip("/")
    container = (container or "").replace("\\", "/").rstrip("/")
    if not host or not container:
        return Path(db_value).expanduser()
    return _remap(db_value, host, container)


# A capture date folder: LWIP writes <batches root>\YYYYMMDD\<folder name>, and
# the thumbnails one level deeper again. Anchoring on the date is what lets a
# single setting handle both without being told where the old root ended.
_DATE_SEGMENT = re.compile(r"^\d{8}$")


def relocate_under(db_value: str, images_root: str) -> Path | None:
    r"""The stored path re-rooted under [images_root], or None if it cannot be.

    LWCAM records an absolute path per folder - C:\...\2.Batches\20260909\<name>
    - so on a site where QC runs somewhere else there is no single "images
      folder" to point at; there are as many paths as there are folders, all
    written by another application into a column this engine does not own.

    What every one of them DOES share is its tail: the capture date folder and
    everything below it. So the rule is keep the tail, replace the head, the
    way forwarding post keeps the street and changes the city:

        C:\Program Files\...\2.Batches \ 20260909\9155 1234-5678 file no. 1234
        \\nas\LWCamCapture             \ 20260909\9155 1234-5678 file no. 1234

    Anchoring on the (last) date rather than counting segments from the right is what
    makes this work for thumbnail_path too, which carries one extra level
    (...\<folder>\thumbs) and would otherwise be re-rooted one directory short.

    Returns None when the stored value has no date segment at all. The caller
    then falls back to the value as written, so an unrecognised layout surfaces
    as the existing "directory missing" error rather than as a confidently
    wrong path pointing at a folder that happens to exist.
    """
    root = (images_root or "").strip()
    if not root:
        return None
    segments = db_value.replace("\\", "/").split("/")
    # Search from the END and need a segment after the date: a root such as
    # D:/20260101/Batches holds an 8-digit segment of its own (same rule as
    # LWCAM's rework_service).
    for index in range(len(segments) - 2, -1, -1):
        if _DATE_SEGMENT.match(segments[index]) and segments[index + 1]:
            return Path(root).joinpath(*segments[index:])
    return None


def to_local(db_value: str) -> Path:
    """`capture_folders.folder_path` as LWCAM wrote it -> a path this process can open.

    A value outside the configured mount is returned unchanged, so the caller's
    existing "directory missing" error surfaces instead of a silently wrong path.
    """
    # qc_images_root supersedes the host/container prefix pair when set: it
    # needs to be told only where the images ARE, not also what the capture PC
    # once called them, and it keeps working on a site whose stations wrote
    # different roots. The pair stays for stations already configured with it.
    relocated = relocate_under(db_value, settings.qc_images_root)
    if relocated is not None:
        return relocated
    mapping = _prefixes()
    if mapping is None:
        return Path(db_value).expanduser()
    return _remap(db_value, *mapping)


def _remap(db_value: str, host: str, container: str) -> Path:
    slashed = db_value.replace("\\", "/")
    # Windows prefix, so match case-insensitively — but slice the ORIGINAL string
    # so the remainder keeps its case for the case-sensitive container filesystem.
    if slashed.lower() == host.lower():
        return Path(container)
    if not slashed.lower().startswith(host.lower() + "/"):
        return Path(db_value).expanduser()
    return Path(container) / slashed[len(host) + 1 :]


def to_db(local: Path) -> str:
    """Reverse of `to_local`, for the one site that writes a new `folder_path`.

    Keeps the host prefix's own separator style so the value LWCAM and LWIP read
    back looks exactly like the ones they write themselves.
    """
    mapping = _prefixes()
    if mapping is None:
        return str(local)
    host, container = mapping
    slashed = str(local).replace("\\", "/")
    if slashed == container:
        remainder = ""
    elif slashed.startswith(container + "/"):
        remainder = slashed[len(container) + 1 :]
    else:
        return str(local)
    original_host = (settings.capture_image_host_path or "").strip()
    if "\\" in original_host:
        base = original_host.replace("/", "\\").rstrip("\\")
        return f"{base}\\{remainder.replace('/', chr(92))}" if remainder else base
    return f"{host}/{remainder}" if remainder else host

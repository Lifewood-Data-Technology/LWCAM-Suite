import os
import threading
import time
import json
from hashlib import sha256
from pathlib import Path
from uuid import uuid4

from PIL import Image, ImageOps

from app.core.config import settings
from app.core.paths import fs_path

BACKEND_ROOT = Path(__file__).resolve().parents[2]
PREVIEW_MAX_EDGE = 1600
PREVIEW_QUALITY = 85
PREVIEW_MIME_TYPE = "image/jpeg"
SUPPORTED_PREVIEW_EXTENSIONS = {"jpg", "jpeg", "png", "webp", "bmp", "tif", "tiff"}


def resolve_preview_cache_dir() -> Path:
    cache_dir = Path(settings.preview_cache_dir).expanduser()
    if not cache_dir.is_absolute():
        cache_dir = BACKEND_ROOT / cache_dir
    fs_path(cache_dir).mkdir(parents=True, exist_ok=True)
    return cache_dir


# Set once at import by the router, which owns the draft op model. Keeps this
# module from importing the router and creating a cycle.
_replay = None


def set_pending_op_replay(replay) -> None:
    global _replay
    _replay = replay


def preview_cache_path(source_path: Path, pending_ops: "list[dict] | None" = None) -> Path:
    stat = fs_path(source_path).stat()
    # The deferred edits are part of the key: they leave the source file
    # untouched, so without them an edited preview and an unedited one would
    # collide on the same cache entry. Serialised with sorted keys so the same
    # chain always produces the same key.
    ops_key = json.dumps(pending_ops or [], sort_keys=True, separators=(",", ":"))
    key = sha256(
        f"{source_path.resolve()}|{stat.st_size}|{stat.st_mtime_ns}|{ops_key}".encode("utf-8")
    ).hexdigest()
    return resolve_preview_cache_dir() / f"{key}.jpg"


# One lock per cache key, so two requests never render or publish the same
# preview at once.
#
# The atomic publish below stops a reader seeing a HALF-written file, but not
# this: FileResponse stats the file to set Content-Length and opens it a moment
# later, and on Windows a concurrent os.replace makes the target briefly
# unopenable. The reader's open() then fails AFTER the headers have gone out, so
# the socket closes with zero bytes delivered against a non-zero Content-Length -
# which reaches Flutter as "Connection closed while receiving data", or as
# "Invalid image data" when an empty body still decodes as a response. Inserting,
# replacing or deskewing a page restamps every preview URL at once, so the rail
# refetches them together and this fires exactly when a reviewer edits.
#
# Per key rather than one global lock: different pages must still render in
# parallel, or opening a folder would serialise the rail's four renders. The dict
# only ever grows by one small Lock per distinct preview, which is not worth
# evicting.
_render_locks: dict[Path, threading.Lock] = {}
_render_locks_guard = threading.Lock()


def render_lock(target_path: Path) -> threading.Lock:
    with _render_locks_guard:
        return _render_locks.setdefault(target_path, threading.Lock())


def normalize_preview_frame(source: Image.Image) -> Image.Image:
    frame = source.copy()
    frame = ImageOps.exif_transpose(frame)
    if frame.mode in {"RGBA", "LA"}:
        background = Image.new("RGB", frame.size, "white")
        alpha = frame.getchannel("A") if frame.mode == "RGBA" else frame.getchannel("A")
        background.paste(frame.convert("RGBA"), mask=alpha)
        return background
    if frame.mode != "RGB":
        return frame.convert("RGB")
    return frame


def save_rendered_image(frame: Image.Image, target_path: Path) -> None:
    """Publish a rendered image by rename, never by writing the live file.

    Two requests for the same uncached preview both miss the is_file() check and
    both render it. Writing straight to the shared path let the second TRUNCATE
    the file while starlette was still streaming the first - the Content-Length
    header had already gone out, so uvicorn raised "Response content shorter than
    Content-Length" and closed the socket mid-body. The client saw a dropped
    connection on an image that was otherwise fine; a batch rotate made it common
    by restamping every page's preview URL at once, so the rail refetched them
    together.

    Rendering to a private temp file and renaming means a reader always has a
    whole file. On POSIX the rename is atomic and an open reader keeps the old
    inode; on Windows it simply fails while the target is open - and the file
    already there is complete, because whoever published it finished writing
    before serving it.

    That last point holds for previews, whose path is content-addressed, but
    NOT for a thumbnail regenerated after an edit, where the file already there
    is the stale one. So the rename is retried briefly first - a reader holds a
    thumbnail open for milliseconds - and callers that must overwrite render to
    a private name and rename it themselves (see the draft commit in qc.py).
    """
    fs_path(target_path.parent).mkdir(parents=True, exist_ok=True)
    temp_path = target_path.with_name(f"{target_path.name}.{uuid4().hex}.tmp")
    try:
        frame.save(fs_path(temp_path), format="JPEG", quality=PREVIEW_QUALITY, optimize=True)
        for attempt in range(5):
            try:
                os.replace(fs_path(temp_path), fs_path(target_path))
                break
            except PermissionError:
                if attempt == 4:
                    raise
                time.sleep(0.05)
    except OSError:
        fs_path(temp_path).unlink(missing_ok=True)
        # Losing the race is not a failure: the file another request published is
        # the same render. Only re-raise when nothing usable is there.
        if not fs_path(target_path).is_file():
            raise


def generate_preview_image(
    source_path: Path, pending_ops: "list[dict] | None" = None
) -> Path | None:
    """The preview for [source_path] with any deferred edits applied.

    The edits are replayed on the PREVIEW, not the source: ~130ms at 1600px
    against ~1500ms for a full 18MP resample, and a crop or rotate costs a
    decode and a re-encode of the whole page even though its own pixel work is
    milliseconds. That is what lets an edit click be instant, with the real work
    deferred until the pixels are needed - see qc_drafts.add_pending_op.

    The replay itself lives in the router (`replay_pending_ops`) so preview and
    flush cannot drift apart; it is injected to keep this module free of the
    draft model.
    """
    source_path = source_path.expanduser().resolve()
    if not fs_path(source_path).is_file():
        return None
    if source_path.suffix.lower().lstrip(".") not in SUPPORTED_PREVIEW_EXTENSIONS:
        return None

    preview_path = preview_cache_path(source_path, pending_ops)
    if fs_path(preview_path).is_file():
        return preview_path

    with render_lock(preview_path):
        # Re-check inside the lock: whoever held it has just published the file,
        # and this is what turns N concurrent requests into ONE render instead of
        # N identical ones racing to replace each other.
        if fs_path(preview_path).is_file():
            return preview_path

        with Image.open(fs_path(source_path)) as source:
            if getattr(source, "n_frames", 1) > 1:
                source.seek(0)
            # Ask the JPEG decoder for a smaller image instead of decoding all
            # 18 MP and throwing most of it away: draft() scales by a power of
            # two DURING decode, so a 3566x5206 page comes out of libjpeg at
            # 1783x2603 and LANCZOS finishes the last step to 1600. Measured
            # 454ms -> 284ms per preview, with no visible difference at this
            # size. A no-op for formats that cannot do it (PNG, TIFF), and it
            # never scales BELOW the requested box, so the result is identical.
            source.draft("RGB", (PREVIEW_MAX_EDGE, PREVIEW_MAX_EDGE))
            frame = normalize_preview_frame(source)

        frame.thumbnail((PREVIEW_MAX_EDGE, PREVIEW_MAX_EDGE), Image.Resampling.LANCZOS)
        if pending_ops and _replay is not None:
            # The SAME replay the flush uses, so the preview is an honest
            # picture of what approval will produce.
            frame = _replay(frame, pending_ops)
        save_rendered_image(frame, preview_path)
    return preview_path


def generate_thumbnail_file(
    source_path: Path, target_path: Path, ops: "list[dict] | None" = None
) -> Path | None:
    source_path = source_path.expanduser().resolve()
    target_path = target_path.expanduser().resolve()
    if not fs_path(source_path).is_file():
        return None
    if source_path.suffix.lower().lstrip(".") not in SUPPORTED_PREVIEW_EXTENSIONS:
        return None

    # Locked like the preview path, since it shares save_rendered_image and can
    # race the same way. Deliberately NO is_file() short circuit: callers
    # regenerate a thumbnail after an edit, so an existing file is exactly what
    # has to be overwritten - the lock serialises that, it does not skip it.
    with render_lock(target_path):
        with Image.open(fs_path(source_path)) as source:
            if getattr(source, "n_frames", 1) > 1:
                source.seek(0)
            # Ask the JPEG decoder for a smaller image instead of decoding all
            # 18 MP and throwing most of it away: draft() scales by a power of
            # two DURING decode, so a 3566x5206 page comes out of libjpeg at
            # 1783x2603 and LANCZOS finishes the last step to 1600. Measured
            # 454ms -> 284ms per preview, with no visible difference at this
            # size. A no-op for formats that cannot do it (PNG, TIFF), and it
            # never scales BELOW the requested box, so the result is identical.
            source.draft("RGB", (PREVIEW_MAX_EDGE, PREVIEW_MAX_EDGE))
            frame = normalize_preview_frame(source)

        frame.thumbnail((PREVIEW_MAX_EDGE, PREVIEW_MAX_EDGE), Image.Resampling.LANCZOS)
        if ops and _replay is not None:
            # A page's committed geometry can change (a rework's re-approval)
            # without its own bytes changing at all - LWIP's baseline and a
            # reviewer's ops both live outside the page JPEG now. Regenerating
            # from [source_path] with the current chain is what keeps this
            # thumbnail honest; see commit_current_draft's geometry-only path.
            frame = _replay(frame, ops)
        save_rendered_image(frame, target_path)
    return target_path


__all__ = [
    "PREVIEW_MAX_EDGE",
    "PREVIEW_MIME_TYPE",
    "generate_preview_image",
    "generate_thumbnail_file",
    "render_lock",
    "save_rendered_image",
]

"""Preview and thumbnail rendering for QC review, with an on-disk cache.

QC Platform stage. The console shows a downscaled JPEG (max 1600 px) of each
page. Edits (crop, rotate, deskew, ...) are deferred "pending ops"; they are
replayed on the small preview rather than on the full page, so an edit click is
instant. Ideas to know before editing:
- the cache key covers the source file's path/size/mtime and the ops chain, so
  stale entries are never served, only left behind and swept by size;
- files are published by rename under a per-key lock, so a concurrent reader
  never sees a half-written or briefly missing file (this matters on Windows);
- the op replay function is injected by the router (set_pending_op_replay) to
  avoid a circular import.
"""
import logging
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

logger = logging.getLogger(__name__)

BACKEND_ROOT = Path(__file__).resolve().parents[2]
PREVIEW_MAX_EDGE = 1600
PREVIEW_QUALITY = 85
PREVIEW_MIME_TYPE = "image/jpeg"
SUPPORTED_PREVIEW_EXTENSIONS = {"jpg", "jpeg", "png", "webp", "bmp", "tif", "tiff"}
try:  # optional JPEG XL decoder; without it .jxl stays unsupported
    import pillow_jxl  # noqa: F401 - registers the Pillow plugin

    SUPPORTED_PREVIEW_EXTENSIONS = SUPPORTED_PREVIEW_EXTENSIONS | {"jxl"}
except ImportError:
    pass

# The cap is soft and the sweep brings the cache down to 80% of it, not
# exactly to it, so a station sitting right on the boundary does not sweep on
# every single render.
PREVIEW_CACHE_SWEEP_TARGET_RATIO = 0.8

# A file this new might still be the render a concurrent request is about to
# serve. render_lock's own comment above explains why a Windows FileResponse
# on a file that goes missing between its stat and its open is worse than a
# cache that is briefly over cap: it drops the connection mid-response rather
# than failing cleanly. Nothing younger than this is ever evicted.
PREVIEW_CACHE_MIN_AGE_SECONDS = 300

# Sweeping is an iterdir + stat of the whole cache directory - fine as an
# occasional check, not as something every render pays for. One preview
# render is already ~130-450ms of real work, so a sweep every 25 renders is
# a few seconds of station use between checks: fast enough that the cache
# never gets far past the cap, rare enough that it is noise next to the
# renders themselves.
PREVIEW_CACHE_SWEEP_INTERVAL = 25

_sweep_state_lock = threading.Lock()
_writes_since_sweep = 0
_swept_once = False


def _note_preview_written() -> None:
    """Sweep the preview cache every PREVIEW_CACHE_SWEEP_INTERVAL writes.

    The first write in the process sweeps immediately rather than waiting for
    the counter to fill, so a long-lived process that inherited an
    already-oversized cache does not carry it for another 25 renders before
    doing anything about it.

    Never allowed to raise into the caller: a cache that cannot be tidied is
    a logging matter, not a failed preview.
    """
    global _writes_since_sweep, _swept_once
    with _sweep_state_lock:
        _writes_since_sweep += 1
        if _swept_once and _writes_since_sweep < PREVIEW_CACHE_SWEEP_INTERVAL:
            return
        _writes_since_sweep = 0
        _swept_once = True
    try:
        sweep_preview_cache()
    except Exception:
        logger.exception("Preview cache sweep failed")


def sweep_preview_cache() -> None:
    """Evict the oldest preview cache entries until the cache is back under
    ~80% of `settings.preview_cache_max_mb`.

    The cache key is `sha256(source path | size | mtime_ns | pending-ops
    chain)` (see `preview_cache_path`), so it self-invalidates: editing a page
    again makes its previous preview entries unreachable garbage, not a
    reusable file. Most of what piles up here is already dead shortly after
    it was written, which is exactly what makes evicting by `mtime` sound -
    entries are write-once, so mtime is also their birth time - and necessary,
    since NTFS disables atime updates by default and this ships on NTFS.

    Oldest-first by mtime, skipping anything younger than
    PREVIEW_CACHE_MIN_AGE_SECONDS regardless of size, and skipping (not
    raising on) anything that is not a plain file or that disappears mid-walk
    - a concurrent render publishing or another sweep racing this one.
    """
    cache_dir = resolve_preview_cache_dir()
    cap_bytes = settings.preview_cache_max_mb * 1024 * 1024
    target_bytes = int(cap_bytes * PREVIEW_CACHE_SWEEP_TARGET_RATIO)
    now = time.time()

    entries: list[tuple[float, int, str]] = []
    total_bytes = 0
    with os.scandir(fs_path(cache_dir)) as it:
        for entry in it:
            try:
                if not entry.is_file():
                    continue
                stat = entry.stat()
            except OSError:
                # Gone, or not stat-able (e.g. a permissions oddity) - not
                # this sweep's problem, skip it.
                continue
            total_bytes += stat.st_size
            entries.append((stat.st_mtime, stat.st_size, entry.path))

    if total_bytes <= cap_bytes:
        return

    entries.sort(key=lambda item: item[0])
    for mtime, size, path in entries:
        if total_bytes <= target_bytes:
            break
        if now - mtime < PREVIEW_CACHE_MIN_AGE_SECONDS:
            continue
        try:
            os.remove(path)
        except OSError:
            # Already gone, or briefly locked by a reader - either way,
            # nothing this sweep should fail over.
            continue
        total_bytes -= size


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
    # Outside the render lock: sweeping the cache directory is unrelated to
    # publishing THIS entry, and there is no reason to hold other requests
    # for this key up while it runs.
    _note_preview_written()
    return preview_path


def generate_thumbnail_file(
    source_path: Path, target_path: Path, ops: "list[dict] | None" = None
) -> Path | None:
    """Render a page's thumbnail to [target_path], overwriting any existing one.

    Unlike generate_preview_image this is not cached by content: it writes the
    real thumbnail file the pipeline keeps next to the page."""
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
    "PREVIEW_CACHE_MIN_AGE_SECONDS",
    "PREVIEW_CACHE_SWEEP_INTERVAL",
    "generate_preview_image",
    "generate_thumbnail_file",
    "render_lock",
    "save_rendered_image",
    "sweep_preview_cache",
]

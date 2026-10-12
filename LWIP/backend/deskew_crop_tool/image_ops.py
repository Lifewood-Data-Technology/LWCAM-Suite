"""Per-image work for LWIP: find the page, measure its tilt, crop, and write the result.

Pipeline position: called by orchestrator.py once per image, inside worker
processes (deskew_crop_file is the entry point). The output feeds the QC Platform.
Ideas to know before editing:
- LWIP never rotates pixels. It MEASURES the page's skew and records the
  correction as `qc_ops` (deskew, crop, optional matfill) that QC replays once
  at preview/export time. Rotating here would add a resample that image-quality
  checks on delivered files have flagged as "enhancement".
- Where possible the crop is lossless: a JPEG is cut on its block grid with
  `jpegtran`, and a file with no page found is copied byte for byte.
- Page detection works on a downscaled grey copy (DETECTION_MAX_DIMENSION);
  the crop geometry is then scaled back to the full frame.
- Windows long paths: use fs_path() at every filesystem call, never on a path
  that is stored.
"""
from __future__ import annotations

import logging
import math
import os
import shutil
import struct
import subprocess
from io import BytesIO
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

try:  # JPEG XL decode for Pillow; cv2 cannot read .jxl. Optional.
    import pillow_jxl  # noqa: F401
except ImportError:
    pillow_jxl = None

# The op replay is shared byte-for-byte with the QC engine (geometry_replay.py
# in both trees). Verification scripts load this file standalone, outside the
# package, so fall back to loading the sibling file by path.
try:
    from . import geometry_replay
except ImportError:
    import importlib.util as _importlib_util

    _spec = _importlib_util.spec_from_file_location(
        "geometry_replay", Path(__file__).with_name("geometry_replay.py")
    )
    geometry_replay = _importlib_util.module_from_spec(_spec)
    _spec.loader.exec_module(geometry_replay)


# Literal "\\?\", the Windows extended-length path prefix.
_EXTENDED_PREFIX = "\\\\?\\"


def fs_path(path: Path) -> Path:
    r"""`path` in the form Windows accepts past its 260-character MAX_PATH.

    LWIP's own layout is what overruns the limit. An operator-typed folder name
    is reproduced under the output root, and publishing adds a
    `.<folder>-<hash>.publishing` staging directory plus a `.<file>.<pid>.tmp`
    write target on top of it — about 36 characters MORE than the output path it
    is building. So the first thing to fail is never the delivered file, it is
    the temp file being written beside it, and the error is a bare
    FileNotFoundError naming that temp path. It reads like a missing file rather
    than a name that is too long, which is why this cost a whole batch once.

    The \\?\ prefix lifts the cap to ~32767 characters with no registry change
    and no elevation, so it holds on a station where the LongPathsEnabled
    policy is locked off. Verified on this suite's own runtime against Pillow,
    cv2.imread/imwrite and os.replace — cv2 matters because it does not use
    Python's file IO.

    Applied ONLY at the system-call boundary, never to a path that gets stored.
    Prefixed text must not reach `state.json`'s keys, the manifest's
    `source_folder`, or the rows cloud_report writes — QC resolves those as
    `folder_path / image_name`.
    """
    if os.name != "nt":
        return path
    # abspath also normalises separators and strips `.`/`..`, both of which the
    # extended-length form requires.
    text = os.path.abspath(str(path))
    if text.startswith(_EXTENDED_PREFIX):
        return path
    if text.startswith("\\\\"):
        # UNC: \\server\share -> \\?\UNC\server\share
        return Path(_EXTENDED_PREFIX + "UNC" + text[1:])
    return Path(_EXTENDED_PREFIX + text)


# --- Tuning constants ---------------------------------------------------------
DETECTION_MAX_DIMENSION = 1600

# Below this the page is straight enough that recording a straightening op
# is not worth the resample QC would pay to replay it. At 0.01 degrees — the
# old threshold — a handheld capture is never square enough to skip, so
# almost every page carried a deskew op for a tilt no reader could see.
# Raised 0.2 -> 0.5 on 2026-09-10, the same day LWIP itself stopped rotating
# pixels at all (see deskew_crop_file): every page, tilted or not, is now
# cropped losslessly from the camera file when it can be; the ONLY cost a
# tilted page still pays here is a qc_ops entry QC resamples once, at preview
# and export time. On the 99 Control pages 0.2 let 27 through untouched and
# 0.5 lets 49; a 0.5 degree lean is ~2.6 mm across an A4 long edge. Callers
# override it from config; this is the fallback.
DEFAULT_DESKEW_MIN_DEGREES = 0.5

# A page tilted further than this is not skew, it is a page photographed the
# wrong way round. Deskew declines it and leaves it for QC's rotate.
SKEW_MAX_DEGREES = 10.0
# How far off horizontal/vertical an edge may sit and still be read as a page
# edge rather than as content.
SKEW_EDGE_TOLERANCE_DEGREES = 12.0
# Fewer sides than this, or sides that disagree by more than the spread, and the
# estimate is not trustworthy enough to resample a page over.
SKEW_MIN_SIDES = 2
SKEW_MAX_EDGE_SPREAD_DEGREES = 2.0
# Outline points needed along one side before it is worth fitting a line to.
SKEW_MIN_SIDE_POINTS = 8
# Fraction of the outline's width/height treated as "along this side".
SKEW_SIDE_BAND = 0.08

# `_estimate_skew`'s self-consistency loop. On bound-register spreads a single
# `_page_angle` read over-estimates the tilt by ~50% (measured on the 99
# Control pages): rotating by the raw estimate and re-measuring leaves a
# residual of median 0.31 deg, p90 0.60. One correction pass (measure, rotate,
# measure the leftover) brings that to median 0.064, p90 0.41 - most of the
# gain is the FIRST re-measurement, which is why this caps at 3 rather than
# iterating to a tighter fit.
SKEW_ESTIMATE_MAX_ITERATIONS = 3
# A re-measurement below this means the last correction already landed;
# stop rather than chase noise in the detection frame.
SKEW_ESTIMATE_CONVERGED_DEGREES = 0.05
# On the Control pages, 3 of 50 tilted pages never settle: the residual
# flips sign between measurements (e.g. +1.087 -> -0.658 -> +0.551) instead of
# shrinking, meaning no candidate angle from that sequence is trustworthy.
# FamilySearch's standard is no manipulation, so an untouched page with a real
# 1 degree lean beats a confidently wrong 0.5 degree resample: above this
# residual the page is left as captured (angle 0.0, qc_ops []).
SKEW_ESTIMATE_MAX_RESIDUAL_DEGREES = 0.3
# Fraction trimmed off each end of a side, to keep rounded corners out of the fit.
SKEW_SIDE_CORNER_INSET = 0.15

# EXIF tags handled specially when metadata is carried across.
_EXIF_GPS_IFD = 0x8825
_EXIF_ORIENTATION = 0x0112

LOGGER = logging.getLogger(__name__)

# A lossless JPEG crop moves whole coded blocks, so its edges must sit on the
# iMCU grid: 16 px for the 4:2:0 chroma the capture phone writes, 8 px for
# 4:4:4. One snap to 16 serves both.
LOSSLESS_CROP_GRID = 16
# Pixels kept clear of rotation fill because QC's Lanczos4 resample reads 4 px
# beyond each kept pixel, plus rounding; measured on real captures, a 1 px gap
# left 70-93 fill-blended pixels, 5 px left 19, 8 px left 0.
RESAMPLE_REACH = 8
# A page counts as running OFF the frame on a side only when its outline lies
# along that frame edge for at least this fraction of the page's extent.
OFF_FRAME_MIN_FRACTION = 0.25
# Override for a station whose tools folder is elsewhere; the default is the
# LWIP\tools folder the installer ships.
JPEGTRAN_ENV = "LWIP_JPEGTRAN"
_jpegtran_warned = False


# --- Lossless JPEG crop (jpegtran) and atomic writes --------------------------
def jpegtran_path() -> Path | None:
    """The libjpeg-turbo `jpegtran` shipped beside this package, or None."""
    candidates: list[Path] = []
    override = os.environ.get(JPEGTRAN_ENV)
    if override:
        candidates.append(Path(override))
    candidates.append(Path(__file__).resolve().parents[2] / "tools" / "jpegtran.exe")
    found = shutil.which("jpegtran")
    if found:
        candidates.append(Path(found))
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return None


def _source_orientation(source_bytes: bytes) -> int:
    """The camera's EXIF Orientation as written; 0 (Xiaomi's illegal value) and
    a missing tag both mean the pixels are stored upright."""
    try:
        with Image.open(BytesIO(source_bytes)) as opened:
            return int(opened.getexif().get(_EXIF_ORIENTATION, 1) or 1)
    except Exception:
        return 1


def snap_crop_box(
    left: int, top: int, right: int, bottom: int, width: int, height: int
) -> tuple[int, int, int, int]:
    """Grows the box outward to the lossless-crop grid, clamped to the frame.

    Outward, never inward: the padding around the page may shrink by up to 15
    px on the far edges relative to the resampled path, but never below what
    was asked for on the near ones, and nothing of the page is cut.
    """
    grid = LOSSLESS_CROP_GRID
    left -= left % grid
    top -= top % grid
    right = min(width, -(-right // grid) * grid)
    bottom = min(height, -(-bottom // grid) * grid)
    return left, top, right, bottom


def _app_segment(marker: int, payload: bytes) -> bytes:
    if len(payload) + 2 > 0xFFFF:
        raise ValueError("JPEG APP segment payload too long")
    return bytes([0xFF, marker]) + struct.pack(">H", len(payload) + 2) + payload


def _insert_app_segments(jpeg: bytes, metadata: dict[str, bytes]) -> bytes:
    """Splices the sanitised EXIF (APP1) and ICC (APP2) into a JPEG that
    jpegtran wrote with `-copy none`, after SOI and any JFIF APP0 so readers
    find Exif where they expect it. No pixel data is touched."""
    segments: list[bytes] = []
    exif = metadata.get("exif")
    if exif:
        if not exif.startswith(b"Exif\x00\x00"):
            exif = b"Exif\x00\x00" + exif
        try:
            segments.append(_app_segment(0xE1, exif))
        except ValueError:
            LOGGER.warning("EXIF too long for one APP1 segment; page ships without it")
    icc = metadata.get("icc_profile")
    if icc:
        # ICC_PROFILE chunks carry a 1-based sequence number and the count.
        header = b"ICC_PROFILE\x00"
        room = 0xFFFF - 2 - len(header) - 2
        parts = [icc[i : i + room] for i in range(0, len(icc), room)]
        for index, part in enumerate(parts, 1):
            segments.append(
                _app_segment(0xE2, header + bytes([index, len(parts)]) + part)
            )
    if not segments:
        return jpeg
    position = 2
    while (
        position + 4 <= len(jpeg)
        and jpeg[position] == 0xFF
        and jpeg[position + 1] == 0xE0
    ):
        position += 2 + struct.unpack(">H", jpeg[position + 2 : position + 4])[0]
    return jpeg[:position] + b"".join(segments) + jpeg[position:]


def crop_jpeg_lossless(
    source_bytes: bytes,
    box: tuple[int, int, int, int],
    metadata: dict[str, bytes],
) -> bytes | None:
    """The camera file cropped to [box] without decoding it, or None when the
    tool is missing or fails - the caller then takes the resampling path.

    `-copy none` drops every marker the camera wrote (an XMP block can carry
    GPS just as EXIF can); the EXIF and ICC that _source_metadata already
    sanitised are spliced back in. Bytes go through stdin/stdout so a path past
    MAX_PATH never reaches the tool's C runtime.
    """
    global _jpegtran_warned
    tool = jpegtran_path()
    if tool is None:
        if not _jpegtran_warned:
            LOGGER.warning(
                "jpegtran not found (LWIP\\tools or %s); straight pages will be "
                "re-encoded instead of cropped losslessly",
                JPEGTRAN_ENV,
            )
            _jpegtran_warned = True
        return None
    left, top, right, bottom = box
    command = [
        str(tool),
        "-copy",
        "none",
        "-crop",
        f"{right - left}x{bottom - top}+{left}+{top}",
    ]
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0) if os.name == "nt" else 0
    try:
        completed = subprocess.run(
            command,
            input=source_bytes,
            capture_output=True,
            creationflags=flags,
            timeout=300,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        LOGGER.warning("jpegtran failed to run: %s", exc)
        return None
    output = completed.stdout
    if completed.returncode != 0 or not output.startswith(b"\xff\xd8"):
        LOGGER.warning(
            "jpegtran exited %d: %s",
            completed.returncode,
            completed.stderr.decode("utf-8", "replace").strip()[:200],
        )
        return None
    return _insert_app_segments(output, metadata)


def _write_bytes_atomic(destination: Path, data: bytes) -> None:
    fs_path(destination.parent).mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(
        f".{destination.stem}.{os.getpid()}.tmp{destination.suffix}"
    )
    try:
        fs_path(temporary).write_bytes(data)
        os.replace(fs_path(temporary), fs_path(destination))
    finally:
        fs_path(temporary).unlink(missing_ok=True)


def initialise_worker() -> None:
    # Each process handles one image at a time. Prevent OpenCV from creating a
    # second, nested thread pool that would oversubscribe the host.
    cv2.setNumThreads(1)


# --- Per-image entry point ----------------------------------------------------
def deskew_crop_file(
    source_value: str,
    destination_value: str,
    padding: int,
    jpeg_quality: int,
    thumbnail_destination_value: str | None = None,
    thumbnail_width: int = 0,
    thumbnail_quality: int = 85,
    deskew_min_degrees: float = DEFAULT_DESKEW_MIN_DEGREES,
    mat_fill: bool = True,
) -> dict[str, object]:
    """Process one image: write the cropped file (and thumbnail) and return a
    result dict (angle, crop box, qc_ops, lossless flag, ...) that the
    orchestrator stores in the folder manifest. Raises OSError if unreadable."""
    source = Path(source_value)
    destination = Path(destination_value)
    is_jxl = source.suffix.lower() == ".jxl"
    try:
        source_bytes = fs_path(source).read_bytes()
        with Image.open(BytesIO(source_bytes)) as opened:
            opened.verify()
    except Exception as exc:
        if is_jxl:
            state = "installed" if pillow_jxl else "NOT installed on this PC"
            raise OSError(
                f"Unreadable image: {source}: JPEG XL needs the pillow-jxl-plugin "
                f"package ({state}): {exc}"
            ) from exc
        raise OSError(f"Unreadable image: {source}: {exc}") from exc
    # verify() consumes the file object, so the metadata read needs its own open.
    metadata = _source_metadata(source_bytes)
    if is_jxl:
        # cv2 cannot read JPEG XL; Pillow (with the plugin) can.
        try:
            with Image.open(BytesIO(source_bytes)) as opened:
                image = cv2.cvtColor(np.array(opened.convert("RGB")), cv2.COLOR_RGB2BGR)
        except Exception as exc:
            raise OSError(f"Unreadable image: {source}: {exc}") from exc
    else:
        image = cv2.imdecode(np.frombuffer(source_bytes, dtype=np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        raise OSError(f"Unreadable image: {source}")
    full_height, full_width = image.shape[:2]
    is_jpeg = source_bytes[:2] == b"\xff\xd8"
    # Orientation 2..8 means cv2 rotated the frame on decode, so the stored
    # bytes and the decoded frame disagree: those files take the old
    # decode-and-re-encode path and are never byte-copied or trim-cropped.
    upright = _source_orientation(source_bytes) == 1

    prepared = _detection_frame(image)
    contour = _largest_content_contour(image, prepared)
    # Measurement only, always. LWIP used to straighten the page itself with
    # cv2.warpAffine (INTER_LANCZOS4, BORDER_CONSTANT black) right here; that
    # resample is exactly what FamilySearch flagged as "image enhancement" on
    # this project's first delivery. The page is now never rotated at LWIP's
    # hands: `angle` is a measurement QC replays later (qc_ops, below), on the
    # one file that is ever going to be resampled.
    angle = 0.0
    angle_source = "none"
    off_frame: set[str] = set()
    crop_source: tuple[int, int, int, int] | None = None
    if contour is not None:
        measured = _estimate_skew(image, contour, deskew_min_degrees)
        if abs(measured) >= deskew_min_degrees:
            angle = measured
        # Keep enough of the camera frame for the final, straightened crop.
        # A tilted page's padded output rectangle maps back to a larger
        # quadrilateral; cropping only the unrotated contour's bbox would
        # leave rotation-fill wedges inside that requested margin.
        box = _source_crop_box(contour, angle, padding, full_width, full_height)
        if box[2] > box[0] and box[3] > box[1]:
            crop_source = box
            off_frame = _off_frame_sides(contour, full_width, full_height)
            angle_source = (
                "sides" if _contour_edge_angle(contour) is not None else "min_area_rect"
            )
    page_found = crop_source is not None

    # Encode once: a non-JPEG file, and a JPEG with no page to crop, ship the
    # camera's bytes untouched. Their geometry (when there is any) is data.
    copy_source = upright and (not is_jpeg or not page_found)

    lossless_bytes: bytes | None = None
    crop_box: tuple[int, int, int, int] | None = None
    qc_ops: list[dict[str, object]] = []
    if page_found and copy_source:
        qc_ops = _build_qc_ops(
            angle,
            full_width,
            full_height,
            contour.reshape(-1, 2).astype(np.float64),
            padding,
            off_frame,
            mat_fill,
        )
    elif page_found:
        left, top, right, bottom = crop_source
        # No decode, no encode: the delivered pixels ARE the camera's.
        # This no longer depends on `angle` - a tilted page is cropped
        # losslessly exactly like a straight one, since neither is ever
        # rotated here.
        if destination.suffix.lower() in {".jpg", ".jpeg"} and is_jpeg and upright:
            snapped = snap_crop_box(left, top, right, bottom, full_width, full_height)
            lossless_bytes = crop_jpeg_lossless(source_bytes, snapped, metadata)
            if lossless_bytes is not None:
                left, top, right, bottom = snapped
        crop_box = (left, top, right, bottom)
        cropped = image[top:bottom, left:right]
        if angle != 0.0:
            shifted_contour = contour.reshape(-1, 2).astype(np.float64) - (left, top)
            qc_ops = _build_qc_ops(
                angle,
                cropped.shape[1],
                cropped.shape[0],
                shifted_contour,
                padding,
                off_frame,
                mat_fill,
            )
        image = cropped

    if copy_source:
        _write_bytes_atomic(destination, source_bytes)
    elif lossless_bytes is not None:
        _write_bytes_atomic(destination, lossless_bytes)
    else:
        _write_image_atomic(
            destination, image, jpeg_quality=jpeg_quality, metadata=metadata
        )
    thumbnail_created = False
    if thumbnail_destination_value and thumbnail_width > 0:
        try:
            _write_thumbnail_atomic(
                Path(thumbnail_destination_value),
                image,
                max_width=thumbnail_width,
                quality=thumbnail_quality,
                qc_ops=qc_ops,
            )
            thumbnail_created = True
        except Exception:
            # Thumbnails are best effort. The orchestrator removes the whole
            # folder's thumbnail tree if any image reports failure.
            thumbnail_created = False
    return {
        "source": str(source),
        "angle": round(angle, 4),
        "width": int(image.shape[1]),
        "height": int(image.shape[0]),
        "thumbnail_created": thumbnail_created,
        "lossless": lossless_bytes is not None,
        "crop": list(crop_box) if crop_box else None,
        "qc_ops": qc_ops,
        "angle_source": angle_source,
        "page_found": page_found,
        "off_frame": sorted(off_frame),
        "mat_fill": any(op.get("op") == "matfill" for op in qc_ops),
    }


# --- Crop geometry and the qc_ops QC replays ----------------------------------
def _build_qc_ops(
    angle: float,
    width: int,
    height: int,
    contour_xy: np.ndarray,
    padding: int,
    off_frame: set[str] | None = None,
    mat_fill: bool = False,
) -> list[dict[str, object]]:
    """The deskew+crop QC replays against the OUTPUT frame, in order.

    `angle` is cv2's `getRotationMatrix2D` convention (positive = the amount
    that would straighten the page if warped). QC uses Pillow, whose
    `Image.rotate` is also positive-counter-clockwise but is not the same
    axis convention once you work through `rotate`'s own inverse-affine
    matrix (see its source) - empirically (an asymmetric fixture, checked
    both ways) the degrees QC must pass to `rotate(-degrees, expand=True)` to
    straighten the page is `-angle`, not `angle`. Do not "simplify" this back
    to `angle` without re-running that check.

    The crop rect is computed by replicating exactly what
    `Image.rotate(angle, expand=True)` (== the engine's `rotate(-degrees,
    expand=True)`) does to the frame: rotate the frame's own corners about
    its centre, take their bounding box for the expanded W/H, shift so its
    top-left is (0, 0), apply the same transform to the (already
    output-frame-shifted) contour, then pad and clamp to the real rotated
    source polygon. No pixel is touched; this is pure geometry so QC's later
    resample lands on the same box LWIP would have cropped to itself.

    Rotation void (the black wedges at the corners of the expanded canvas):
    - `mat_fill` False: every side is clamped clear of it, losing padding.
    - `mat_fill` True: only the sides in `off_frame` (the page itself runs off
      the photo there, so there is no background to fill from) are clamped;
      every other side keeps its full padding, and if the rect still holds
      void a trailing `{"op": "matfill"}` tells QC to paint it with the
      surrounding mat. `angle == 0` has no rotation, so no void and no op.
    A zero angle emits no deskew op (a straight page on an uncropped source).
    """
    # -angle, not angle. `degrees` above is what QC PASSES to rotate(); the
    # direction the pixels then MOVE under it is the opposite one, and this
    # model has to follow the pixels. Both signs produce the same expanded
    # canvas (it is symmetric), which is how the mirrored one survived: only
    # the contour landed in the wrong place, and the padding hid it. Measured
    # against Pillow's own output on a real capture at 3.9 degrees, this sign
    # lands the page within 3px, the other one is out by ~300.
    phi = math.radians(-angle)
    cos_phi, sin_phi = math.cos(phi), math.sin(phi)
    cx, cy = width / 2.0, height / 2.0

    def rotate(x: float, y: float) -> tuple[float, float]:
        dx, dy = x - cx, y - cy
        return (
            cx + dx * cos_phi - dy * sin_phi,
            cy + dx * sin_phi + dy * cos_phi,
        )

    corners = [rotate(px, py) for px, py in ((0, 0), (width, 0), (width, height), (0, height))]
    min_x = math.floor(min(p[0] for p in corners))
    max_x = math.ceil(max(p[0] for p in corners))
    min_y = math.floor(min(p[1] for p in corners))
    max_y = math.ceil(max(p[1] for p in corners))
    new_width = max_x - min_x
    new_height = max_y - min_y

    rotated_points = [rotate(float(px), float(py)) for px, py in contour_xy]
    xs = [px - min_x for px, _py in rotated_points]
    ys = [py - min_y for _px, py in rotated_points]
    x0 = max(0.0, min(xs) - padding)
    y0 = max(0.0, min(ys) - padding)
    x1 = min(float(new_width), max(xs) + padding)
    y1 = min(float(new_height), max(ys) + padding)
    frame = dict(
        centre=(width / 2.0 - min_x, height / 2.0 - min_y),
        half_width=width / 2.0,
        half_height=height / 2.0,
        cos_phi=cos_phi,
        sin_phi=sin_phi,
    )
    x0, y0, x1, y1 = _clamp_to_rotated_frame(
        x0,
        y0,
        x1,
        y1,
        sides=set(off_frame or ()) if mat_fill else None,
        **frame,
    )

    ops: list[dict[str, object]] = []
    if angle != 0.0:
        ops.append({"op": "deskew", "degrees": round(-angle, 4)})
    ops.append(
        {
            "op": "crop",
            "rect": [
                x0 / new_width,
                y0 / new_height,
                x1 / new_width,
                y1 / new_height,
            ],
        }
    )
    if mat_fill and angle != 0.0 and _rect_violation(x0, y0, x1, y1, **frame) is not None:
        ops.append({"op": "matfill"})
    return ops


def _rect_violation(
    x0: float,
    y0: float,
    x1: float,
    y1: float,
    *,
    centre: tuple[float, float],
    half_width: float,
    half_height: float,
    cos_phi: float,
    sin_phi: float,
) -> tuple[float, float, float, float] | None:
    """The first half-plane (a, b, limit, worst value) the rect's corners cross,
    or None when the rect is clear of rotation void by `RESAMPLE_REACH`.

    A point p is inside the rotated source frame iff |u.(p - c)| <= W/2 and
    |v.(p - c)| <= H/2, for the rotated axes u = (cos, sin), v = (-sin, cos).
    """
    violations = _rect_violations(
        x0, y0, x1, y1,
        centre=centre, half_width=half_width, half_height=half_height,
        cos_phi=cos_phi, sin_phi=sin_phi,
    )
    return violations[0] if violations else None


def _rect_violations(
    x0: float,
    y0: float,
    x1: float,
    y1: float,
    *,
    centre: tuple[float, float],
    half_width: float,
    half_height: float,
    cos_phi: float,
    sin_phi: float,
) -> list[tuple[float, float, float, float]]:
    """Every half-plane (a, b, limit, worst value) the rect's corners cross."""
    cx, cy = centre
    planes = (
        (cos_phi, sin_phi, half_width - RESAMPLE_REACH),
        (-cos_phi, -sin_phi, half_width - RESAMPLE_REACH),
        (-sin_phi, cos_phi, half_height - RESAMPLE_REACH),
        (sin_phi, -cos_phi, half_height - RESAMPLE_REACH),
    )
    corners = ((x0, y0), (x1, y0), (x1, y1), (x0, y1))
    found = []
    for a, b, limit in planes:
        maximum = max(a * (x - cx) + b * (y - cy) for x, y in corners)
        if maximum > limit:
            found.append((a, b, limit, maximum))
    return found


def _clamp_to_rotated_frame(
    x0: float,
    y0: float,
    x1: float,
    y1: float,
    *,
    centre: tuple[float, float],
    half_width: float,
    half_height: float,
    cos_phi: float,
    sin_phi: float,
    sides: set[str] | None = None,
) -> tuple[float, float, float, float]:
    """Trim only the sides of a padded crop that run into rotation fill.

    `Image.rotate(expand=True)` leaves black wedges at the corners of the
    expanded canvas, and QC's replay fills them the same way (geometry_ops
    passes borderValue 0 deliberately, to match Pillow). Clamping the padded
    rect to the canvas alone does not exclude them: the wedge is shallower
    than the padding -- measured on a delivered page, 60px deep at 1.07
    degrees against 200px of padding -- so the crop keeps a pure-black edge
    against the grey capture backdrop.

    A corner failing a half-plane of the rotated source frame (see
    `_rect_violation`) moves an offending edge inward only as far as that
    plane requires. Keep `RESAMPLE_REACH` pixels clear so QC's Lanczos4
    resample, including its rounding, cannot blend rotation fill into a kept
    pixel. Recheck all corners after each trim because an edge can participate
    in more than one plane.

    No fill is allowed into the delivery. If the page itself reaches the
    capture edge, only the margin on that side is reduced; a uniform shrink
    would needlessly take the same amount from all four sides.

    `sides` (None = all four) limits which edges may move: with mat_fill only
    the sides the page runs off may be trimmed, and whatever void is left on
    the others is the matfill op's to paint.
    """
    cx, cy = centre
    for _ in range(32):
        violations = _rect_violations(
            x0, y0, x1, y1,
            centre=centre, half_width=half_width, half_height=half_height,
            cos_phi=cos_phi, sin_phi=sin_phi,
        )
        if not violations:
            return x0, y0, x1, y1

        corners = ((x0, y0), (x1, y0), (x1, y1), (x0, y1))
        # The first plane an ALLOWED edge can fix. With `sides` limited, the
        # first violated plane may belong to a side matfill will paint; it
        # must not stop the trim of an off-frame side further down the list.
        candidates = []
        for a, b, limit, _maximum in violations:
            for edge, indices, coefficient in (
                ("left", (0, 3), -a),
                ("right", (1, 2), a),
                ("top", (0, 1), -b),
                ("bottom", (2, 3), b),
            ):
                if sides is not None and edge not in sides:
                    continue
                edge_max = max(
                    a * (corners[i][0] - cx) + b * (corners[i][1] - cy)
                    for i in indices
                )
                if coefficient > 1e-9 and edge_max > limit:
                    candidates.append((coefficient, edge, edge_max - limit))
            if candidates:
                break
        if not candidates:
            break
        coefficient, edge, edge_excess = max(candidates)
        movement = edge_excess / coefficient + 1e-6
        if edge == "left":
            x0 += movement
        elif edge == "right":
            x1 -= movement
        elif edge == "top":
            y0 += movement
        else:
            y1 -= movement
        if x0 >= x1 or y0 >= y1:
            break
    return x0, y0, x1, y1


def _source_crop_box(
    contour_xy: np.ndarray,
    angle: float,
    padding: int,
    width: int,
    height: int,
) -> tuple[int, int, int, int]:
    """Keep the inverse-rotated final padded crop available to QC.

    The final crop is axis-aligned after deskew. Its four corners, mapped back
    through the inverse deskew, define the source-space bounds needed to hold
    all requested photo pixels. Clipping those bounds to the camera frame is
    the only place padding is lost due to lack of source image.

    A straight page keeps the exact box it always had: cv2.boundingRect's
    exclusive right/bottom edge sits one pixel past the contour's last
    point, and the float path below (ceil of that point) would be a pixel
    short, which after snap_crop_box can land a whole 16 px block smaller.
    """
    if angle == 0.0:
        x, y, box_width, box_height = cv2.boundingRect(contour_xy)
        return (
            max(0, x - padding),
            max(0, y - padding),
            min(width, x + box_width + padding),
            min(height, y + box_height + padding),
        )
    phi = math.radians(-angle)
    cos_phi, sin_phi = math.cos(phi), math.sin(phi)
    cx, cy = width / 2.0, height / 2.0
    points = contour_xy.reshape(-1, 2).astype(np.float64)
    dx, dy = points[:, 0] - cx, points[:, 1] - cy
    rotated_x = cx + dx * cos_phi - dy * sin_phi
    rotated_y = cy + dx * sin_phi + dy * cos_phi
    x0, x1 = float(rotated_x.min()) - padding, float(rotated_x.max()) + padding
    y0, y1 = float(rotated_y.min()) - padding, float(rotated_y.max()) + padding
    corners = ((x0, y0), (x1, y0), (x1, y1), (x0, y1))
    source_x = [cx + (x - cx) * cos_phi + (y - cy) * sin_phi for x, y in corners]
    source_y = [cy - (x - cx) * sin_phi + (y - cy) * cos_phi for x, y in corners]
    left = max(0, math.floor(min(source_x)) - RESAMPLE_REACH)
    top = max(0, math.floor(min(source_y)) - RESAMPLE_REACH)
    right = min(width, math.ceil(max(source_x)) + RESAMPLE_REACH)
    bottom = min(height, math.ceil(max(source_y)) + RESAMPLE_REACH)
    return left, top, right, bottom


# --- Replay, metadata and thumbnails ------------------------------------------
def apply_qc_ops(image: Image.Image, qc_ops: list[dict[str, object]]) -> Image.Image:
    """Replays LWIP's deferred straightening ops on an already-written output
    frame, exactly as the QC engine does at preview/export time.

    LWIP itself only calls this for the 512px thumbnail (so the review rail
    shows a straight page at zero cost to the full-resolution file, which is
    never rotated). It also backs the regression tests here and the
    `lossless_replay.py` verification script.

    It IS the QC engine's replay (`geometry_replay.py`, byte-identical in both
    trees): deskew, quarter-turn rotate, crop and matfill, so the thumbnail
    can never drift from the preview and the export again.
    """
    return geometry_replay.replay_pending_ops(image, qc_ops)


def _source_metadata(source_bytes: bytes) -> dict[str, bytes]:
    """EXIF and ICC from the camera file, ready to hand to Pillow's saver.

    The capture is the archival record, so its provenance — camera, lens,
    exposure, capture time — has to survive processing. OpenCV cannot write
    either block, which is why every image LWIP has ever produced arrived at the
    client stripped bare.

    Two deliberate edits on the way through:

    - **GPS is removed.** It pins the building the records were photographed in,
      it travels to the client inside every page, and nothing downstream wants
      it. The rest of the EXIF, MakerNote included, is carried verbatim.
    - **Orientation 0 is corrected to 1.** Xiaomi writes a literal 0 here, which
      is not a legal value; readers that validate it reject the tag, and some
      reject the whole block.

    Returns the kwargs Pillow's `save` accepts, so a failure to parse degrades to
    "no metadata" rather than failing the page.
    """
    result: dict[str, bytes] = {}
    try:
        with Image.open(BytesIO(source_bytes)) as opened:
            icc = opened.info.get("icc_profile")
            if icc:
                result["icc_profile"] = icc
            exif = opened.getexif()
            if not exif:
                return result
            # Materialise the nested IFDs before serialising: Exif.tobytes()
            # only emits the sub-IFDs it has already been asked for.
            for ifd in (0x8769, 0xA005):
                try:
                    exif.get_ifd(ifd)
                except Exception:
                    pass
            if _EXIF_GPS_IFD in exif:
                del exif[_EXIF_GPS_IFD]
            # cv2.IMREAD_COLOR already applies EXIF Orientation to the pixels,
            # so the output is upright. Any value but 1 (including the illegal 0)
            # would make every viewer rotate it a second time.
            if _EXIF_ORIENTATION in exif and exif[_EXIF_ORIENTATION] != 1:
                exif[_EXIF_ORIENTATION] = 1
            encoded = exif.tobytes()
            if encoded:
                result["exif"] = encoded
    except Exception as exc:
        # Metadata is worth carrying, never worth failing a folder over - but a
        # page shipping bare must at least leave a line saying so.
        logging.getLogger(__name__).warning("EXIF/ICC not carried: %s", exc)
        return {}
    return result


def _write_thumbnail_atomic(
    destination: Path,
    image: np.ndarray,
    *,
    max_width: int,
    quality: int,
    qc_ops: list[dict[str, object]] | None = None,
) -> None:
    """The rail shows LWIP's thumbnail, so it must look straight even though
    the delivered file never is. Downscale FIRST, then replay the same
    deskew+crop QC will apply to the full-resolution output — the resample
    this pays for is bounded by `max_width`, never by the capture's own
    resolution. Quality is irrelevant at ~512px; this thumbnail is never
    delivered.
    """
    rgb = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
    thumbnail = Image.fromarray(rgb)
    if thumbnail.width > max_width:
        new_height = max(1, round(thumbnail.height * max_width / thumbnail.width))
        thumbnail = thumbnail.resize((max_width, new_height), Image.LANCZOS)
    if qc_ops:
        thumbnail = apply_qc_ops(thumbnail, qc_ops)
    fs_path(destination.parent).mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(
        f".{destination.stem}.{os.getpid()}.tmp{destination.suffix}"
    )
    try:
        with fs_path(temporary).open("wb") as stream:
            thumbnail.save(stream, format="JPEG", quality=quality)
            stream.flush()
        os.replace(fs_path(temporary), fs_path(destination))
    finally:
        fs_path(temporary).unlink(missing_ok=True)


# --- Page detection and skew measurement --------------------------------------
def _detection_frame(image: np.ndarray) -> tuple[np.ndarray, float]:
    """Downscaled greyscale used by both detectors, plus the scale applied."""
    height, width = image.shape[:2]
    scale = min(1.0, DETECTION_MAX_DIMENSION / max(height, width))
    if scale < 1.0:
        image = cv2.resize(
            image,
            (max(1, round(width * scale)), max(1, round(height * scale))),
            interpolation=cv2.INTER_AREA,
        )
    if image.ndim == 2:
        return image, scale
    if image.shape[2] == 4:
        return cv2.cvtColor(image, cv2.COLOR_BGRA2GRAY), scale
    return cv2.cvtColor(image, cv2.COLOR_BGR2GRAY), scale


def _contour_edge_angle(contour) -> float | None:
    """Skew read off the long straight sides of the detected outline.

    This exists because `minAreaRect` is only a skew estimator for a shape with
    crisp corners. On the Taiping confirmation registers — bound books, rounded
    corners, a bowed spine — the minimum-area rectangle of the threshold blob IS
    the axis-aligned bounding box, so it reported exactly 0.000 or 90.000 on page
    after page: for a rounded outline it cannot report a tilt at all, whatever
    the tilt is. Loose sheets have crisp corners and are unaffected, which is why
    this survived so long. On the batch that exposed it the real tilt happened to
    be small (contour-to-bounding-box fill was already at the rounded-corner
    ceiling of 0.97 before and after), so nothing shipped visibly crooked — this
    is insurance against a bound volume that IS tilted, not a fix for a visible
    fault.

    Measuring the outline's own sides, rather than every straight line in the
    frame, is what makes this stable. An earlier attempt ran Hough over the whole
    image and locked onto the marbled cover texture and the pasted label, giving
    an estimate that did not converge — feeding its own output back in produced a
    residual as large as the original tilt, sometimes with the sign flipped. The
    sides of the contour are the same geometry the crop already trusts.

    Beware measuring skew from printed content: on at least one sheet here the
    printed form sits ~2 degrees askew relative to the paper, so text-based and
    edge-based estimates legitimately disagree. This aligns the PAPER, which is
    what the previous implementation did too.

    Rounded corners contribute many short segments and long sides contribute few
    long ones, so segments are weighted by length and the median is taken. Short
    segments are dropped outright.
    """
    points = np.asarray(contour, dtype=np.float64).reshape(-1, 2)
    if len(points) < SKEW_MIN_SIDE_POINTS:
        return None
    x0, y0 = points.min(axis=0)
    x1, y1 = points.max(axis=0)
    width, height = x1 - x0, y1 - y0
    if width <= 0 or height <= 0:
        return None

    xs, ys = points[:, 0], points[:, 1]
    # Each side is fitted from the points lying along it, with the corner
    # regions excluded — corners are where a bound volume rounds off, and they
    # are exactly what defeats minAreaRect.
    inset_x = x0 + SKEW_SIDE_CORNER_INSET * width
    inset_x_far = x1 - SKEW_SIDE_CORNER_INSET * width
    inset_y = y0 + SKEW_SIDE_CORNER_INSET * height
    inset_y_far = y1 - SKEW_SIDE_CORNER_INSET * height
    middle_x = (xs > inset_x) & (xs < inset_x_far)
    middle_y = (ys > inset_y) & (ys < inset_y_far)
    bands = (
        (xs <= x0 + SKEW_SIDE_BAND * width) & middle_y,   # left
        (xs >= x1 - SKEW_SIDE_BAND * width) & middle_y,   # right
        (ys <= y0 + SKEW_SIDE_BAND * height) & middle_x,  # top
        (ys >= y1 - SKEW_SIDE_BAND * height) & middle_x,  # bottom
    )

    angles: list[float] = []
    for band in bands:
        if int(band.sum()) < SKEW_MIN_SIDE_POINTS:
            continue
        vx, vy, _cx, _cy = cv2.fitLine(
            points[band].astype(np.float32), cv2.DIST_HUBER, 0, 0.01, 0.01
        ).ravel()
        angle = float(np.degrees(np.arctan2(float(vy), float(vx))))
        # Fold to [-45, 45): all four sides of a rectangle report the same tilt.
        angle = (angle + 45.0) % 90.0 - 45.0
        if abs(angle) <= SKEW_EDGE_TOLERANCE_DEGREES:
            angles.append(angle)

    if len(angles) < SKEW_MIN_SIDES:
        return None
    values = np.array(angles, dtype=np.float64)
    median = float(np.median(values))
    # Sides that disagree mean the outline is not a rectangle — a torn page, or
    # two objects merged by the morphological close. Refuse rather than guess.
    if float(np.max(np.abs(values - median))) > SKEW_MAX_EDGE_SPREAD_DEGREES:
        return None
    return median


def _off_frame_sides(contour, width: int, height: int) -> set[str]:
    """Frame sides the page itself runs off - not merely comes close to.

    Capturing a spread wider than the frame with one side cut by the frame
    edge is correct practice. A page that only nears the edge, or touches it
    with one torn corner, does not count: its outline must lie along the frame
    edge for OFF_FRAME_MIN_FRACTION of the page's extent on that side.
    """
    points = np.asarray(contour, dtype=np.float64).reshape(-1, 2)
    xs, ys = points[:, 0], points[:, 1]
    # Two detection-frame pixels, expressed at full resolution.
    tolerance = 2.0 * max(1.0, max(width, height) / DETECTION_MAX_DIMENSION)
    page_width = max(1.0, float(np.ptp(xs)))
    page_height = max(1.0, float(np.ptp(ys)))
    runs = {
        "left": (xs <= tolerance, ys, page_height),
        "right": (xs >= width - 1 - tolerance, ys, page_height),
        "top": (ys <= tolerance, xs, page_width),
        "bottom": (ys >= height - 1 - tolerance, xs, page_width),
    }
    sides: set[str] = set()
    for side, (on_edge, along, extent) in runs.items():
        if int(on_edge.sum()) >= 2 and np.ptp(along[on_edge]) / extent >= OFF_FRAME_MIN_FRACTION:
            sides.add(side)
    return sides


def _page_angle(contour) -> float:
    """The page's measured tilt in degrees (cv2 `getRotationMatrix2D`
    convention), preferring measured sides over the bounding rect. LWIP
    never rotates a pixel with this value itself — deskew_crop_file turns it
    into a `qc_ops` entry QC replays later."""
    angle = _contour_edge_angle(contour)
    if angle is None:
        angle = _normalise_angle(float(cv2.minAreaRect(contour)[2]))
    if abs(angle) > SKEW_MAX_DEGREES:
        return 0.0
    return angle


def _estimate_skew(image: np.ndarray, contour, deskew_min_degrees: float) -> float:
    """A self-consistent skew estimate: measure, rotate by the estimate,
    re-measure, and trust the reading whose own re-measurement came back
    smallest — never a single `_page_angle` call taken on faith.

    Runs entirely on the small DETECTION frame (`_detection_frame`, capped at
    ~1600px), never the full-resolution image the caller will crop from: this
    only needs an angle, and three small warps cost tens of ms where three
    full-resolution ones would not. `contour` is the caller's already-detected
    full-frame contour, scaled back down for the first measurement so that
    one is free; every later measurement re-detects the content on the
    frame this function has itself rotated, since the caller's contour no
    longer applies once the frame underneath it has moved.

    Returns 0.0 - "leave the page as captured" - whenever no reading can be
    trusted: the contour disappears on a rotated frame (the estimate pushed
    it somewhere the simple threshold no longer finds it), or the best
    candidate's own re-measurement is still >= SKEW_ESTIMATE_MAX_RESIDUAL_DEGREES.
    Both are real outcomes on bound registers, not just theoretical - see the
    constants above. `deskew_min_degrees` is not applied here; the caller
    thresholds the returned value exactly as it did the old single reading.
    """
    gray, scale = _detection_frame(image)
    height, width = gray.shape[:2]
    center = (width / 2.0, height / 2.0)
    threshold, _binary = cv2.threshold(
        cv2.GaussianBlur(gray, (3, 3), 0), 0, 255, cv2.THRESH_BINARY + cv2.THRESH_TRIANGLE
    )

    # The caller's contour is in full-frame coordinates; bring it down to this
    # frame's scale so the first measurement reuses it instead of re-detecting.
    current_contour = contour if scale == 1.0 else np.asarray(contour, dtype=np.float32) * scale

    candidates: list[tuple[float, float]] = []
    total = 0.0
    previous_total: float | None = None
    vanished = False
    for _ in range(SKEW_ESTIMATE_MAX_ITERATIONS):
        if current_contour is None:
            vanished = True
            break
        theta = _page_angle(current_contour)
        if previous_total is not None:
            candidates.append((previous_total, abs(theta)))
        total += theta
        previous_total = total
        if abs(theta) < SKEW_ESTIMATE_CONVERGED_DEGREES:
            break
        matrix = cv2.getRotationMatrix2D(center, total, 1.0)
        rotated = cv2.warpAffine(
            gray,
            matrix,
            (width, height),
            flags=cv2.INTER_LINEAR,
            borderMode=cv2.BORDER_CONSTANT,
            borderValue=0,
        )
        current_contour = _largest_contour_in_frame(rotated, threshold)

    if vanished:
        LOGGER.info(
            "skew estimate unstable (contour vanished on a rotated frame; "
            "candidates so far %s); page left as captured",
            [(round(t, 3), round(r, 3)) for t, r in candidates],
        )
        return 0.0

    if not candidates:
        # Converged on the very first measurement (already under the noise
        # floor we bother correcting for) - nothing left to validate.
        return total

    best_total, best_residual = min(candidates, key=lambda pair: pair[1])
    if best_residual >= SKEW_ESTIMATE_MAX_RESIDUAL_DEGREES:
        LOGGER.info(
            "skew estimate unstable (candidates %s); page left as captured",
            [(round(t, 3), round(r, 3)) for t, r in candidates],
        )
        return 0.0
    return best_total


def _largest_contour_in_frame(gray: np.ndarray, threshold: float | None = None):
    """The threshold/contour pipeline `_largest_content_contour` runs, minus
    the scale bookkeeping — factored out so `_estimate_skew` can re-run it on
    a small, already-detection-sized frame it has itself rotated, without
    paying for another downscale each time.

    `threshold` None picks the TRIANGLE threshold from this frame. A frame the
    caller has rotated carries black corner wedges: they form a second large
    histogram peak, and TRIANGLE (which walks from the biggest peak toward the
    longer tail) can then flip and file the whole backdrop with the page. So
    `_estimate_skew` measures the threshold once on the unrotated frame and
    passes it in for every re-detection."""
    blurred = cv2.GaussianBlur(gray, (3, 3), 0)
    # TRIANGLE, not OTSU. Otsu is a two-class split, and a bound volume has
    # three classes on the mat: black backdrop, dark cover board, paper. Otsu
    # lands between board and paper and files the board with the backdrop, so
    # the outline traces the inner sheet only and the board eats the padding on
    # whichever side it protrudes (~230 px measured). TRIANGLE finds the foot of
    # the dominant background peak, so the board lands on the object side.
    # Loose sheets are unaffected - there is no middle class to misfile.
    if threshold is None:
        _value, binary = cv2.threshold(
            blurred, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_TRIANGLE
        )
    else:
        _value, binary = cv2.threshold(blurred, threshold, 255, cv2.THRESH_BINARY)
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (5, 5))
    closed = cv2.morphologyEx(binary, cv2.MORPH_CLOSE, kernel)
    contours, _hierarchy = cv2.findContours(
        closed, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE
    )
    if not contours:
        return None
    return max(contours, key=cv2.contourArea)


def _largest_content_contour(image: np.ndarray, prepared=None):
    gray, scale = _detection_frame(image) if prepared is None else prepared
    contour = _largest_contour_in_frame(gray)
    if contour is None:
        return None
    return contour if scale == 1.0 else contour.astype(np.float32) / scale


def _normalise_angle(angle: float) -> float:
    """Fold a minAreaRect angle into [-45, 45] so a near-90 reading means ~0 tilt."""
    if angle < -45:
        return angle + 90
    if angle > 45:
        return angle - 90
    return angle


# --- Full re-encode output (when a lossless crop is not possible) -------------
def _write_image_atomic(
    destination: Path,
    image: np.ndarray,
    *,
    jpeg_quality: int,
    metadata: dict[str, bytes] | None = None,
) -> None:
    """Write the processed page, preserving the camera's encoding fidelity.

    Written through Pillow rather than `cv2.imencode` for one reason: OpenCV
    cannot emit EXIF or ICC, so this was where the capture's provenance was being
    destroyed.

    At quality 100 with 4:4:4 chroma, libjpeg emits quantization tables of all
    1s — byte-for-byte the tables the Xiaomi writes itself. That matters more
    than it sounds: FamilySearch rejected this project's first delivery for
    "evidence of image enhancement", and the cause was this function encoding at
    q90, whose tables (max 24/20) are visibly coarser than the camera's. At q100
    the output cannot be called more compressed than the original — measured max
    error 3 DN against 21 at q90, with 88% of pixels bit-identical.

    `optimize` recomputes the Huffman tables only. It is lossless, and saves
    about 5%.
    """
    fs_path(destination.parent).mkdir(parents=True, exist_ok=True)
    suffix = destination.suffix.lower()
    frame = Image.fromarray(cv2.cvtColor(image, cv2.COLOR_BGR2RGB))

    save_kwargs: dict[str, object] = dict(metadata or {})
    if suffix in {".jpg", ".jpeg"}:
        save_kwargs.update(
            format="JPEG", quality=jpeg_quality, subsampling=0, optimize=True
        )
    elif suffix == ".png":
        save_kwargs.update(format="PNG", compress_level=6)
    elif suffix in {".tif", ".tiff"}:
        # Pillow expands an exif= blob into a nested ExifIFD that libtiff refuses
        # ("Bad LONG8 or IFD8 value for EXIFIFDOffset"); the ICC profile is fine.
        save_kwargs.pop("exif", None)
        save_kwargs.update(format="TIFF", compression="tiff_adobe_deflate")
    else:
        raise OSError(f"Unsupported output format: {destination}")

    temporary = destination.with_name(
        f".{destination.stem}.{os.getpid()}.tmp{destination.suffix}"
    )
    try:
        with fs_path(temporary).open("wb") as stream:
            frame.save(stream, **save_kwargs)
            stream.flush()
        os.replace(fs_path(temporary), fs_path(destination))
    finally:
        fs_path(temporary).unlink(missing_ok=True)

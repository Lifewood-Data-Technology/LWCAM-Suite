"""Replays a deferred geometry chain onto a decoded frame.

Pulled out of routers/qc.py so services/export.py can share it too, without
either of them importing the router (previews.py still gets it by injection -
see set_pending_op_replay - to keep it free of the draft model; export.py has
no such constraint and can import this module directly).

Used at THREE sizes now: the ~1600px preview, the one-time full-resolution
bake (luminance's pre-step - see qc.py's apply_pending_ops), and the export
TIFF. Same function, same order semantics, so none of the three can drift
from what the others produce.

A non-quarter-turn deskew/rotate is resampled with OpenCV's LANCZOS4, not
Pillow's rotate(): Pillow's own transform() hard-refuses LANCZOS for an
AFFINE method (raises from C, any Pillow version - see the fallback below),
and the project's own interpolator comparison (CLAUDE.md) measured BICUBIC
well below LANCZOS4 on detail retention (0.48 vs 0.94 high-frequency
retention). The export TIFF is the delivered artifact, so this is not a
cosmetic choice. An exact quarter turn (0/90/180/270) still goes through
Pillow's own rotate(): Pillow fast-paths it as a pure transpose - no
interpolation at all, strictly better than either filter - so there is
nothing for OpenCV to improve there.
"""

from __future__ import annotations

import logging
import math

from PIL import Image

logger = logging.getLogger(__name__)

try:
    import cv2
    import numpy as np
except ImportError:  # pragma: no cover - exercised via a monkeypatched import
    cv2 = None
    np = None

_cv2_unavailable_logged = False


def _pillow_expanded_size(size: tuple[int, int], degrees: float) -> tuple[int, int]:
    """(width, height) Pillow's own rotate(-degrees, expand=True) would
    produce for an image of [size].

    LWIP's manifest crop rects, and a reviewer's own, are normalised against
    exactly this expanded frame (see routers/qc.py's replay_pending_ops
    contract), so OpenCV's output canvas has to match it exactly - not
    approximately. Getting that from a throwaway 1-bit dummy image, rather
    than hand-reimplementing Pillow's ceil/floor-of-rotated-corners math, is
    what makes it exact by construction instead of by careful arithmetic:
    there is no formula here to drift from Pillow's own if a future Pillow
    version changes its rounding. Measured ~34ms on a 4000x6000 dummy -
    negligible next to the LANCZOS4 warp itself.
    """
    dummy = Image.new("1", size)
    return dummy.rotate(-degrees, expand=True, resample=Image.Resampling.NEAREST).size


def _rotate_cv2_lanczos(frame: "Image.Image", degrees: float) -> "Image.Image | None":
    """OpenCV LANCZOS4 rotation, geometrically identical to Pillow's
    rotate(-degrees, expand=True) (size AND placement), but with a sharper
    filter. Returns None if cv2/numpy failed to import, so the caller falls
    back to Pillow's BICUBIC.
    """
    if cv2 is None or np is None:
        return None
    original_mode = frame.mode
    work_mode = original_mode if original_mode in ("RGB", "L") else "RGB"
    work_frame = frame if work_mode == original_mode else frame.convert("RGB")
    width, height = work_frame.size
    new_width, new_height = _pillow_expanded_size((width, height), degrees)

    # A = -degrees: the counter-clockwise angle cv2.getRotationMatrix2D needs
    # to land on the SAME pixels as Pillow's rotate(-degrees) - proved
    # empirically (an asymmetric marker's centroid matched Pillow's own
    # output to a fraction of a pixel across a range of sizes/angles; see
    # tests/test_deferred_geometry.py), not derived from the two libraries'
    # stated sign conventions, which do not obviously agree or disagree.
    matrix = cv2.getRotationMatrix2D((width / 2.0, height / 2.0), -degrees, 1.0)
    matrix[0, 2] += (new_width - width) / 2.0
    matrix[1, 2] += (new_height - height) / 2.0

    # Pillow's own rotate() fills the expanded margin with black (0) when no
    # fillcolor is given, which is what every existing call here relies on.
    border_value = 0 if work_mode == "L" else (0, 0, 0)
    rotated = cv2.warpAffine(
        np.asarray(work_frame),
        matrix,
        (new_width, new_height),
        flags=cv2.INTER_LANCZOS4,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=border_value,
    )
    result = Image.fromarray(rotated, mode=work_mode)
    if original_mode != work_mode:
        result = result.convert(original_mode)
    return result


def _rotate(frame: "Image.Image", degrees: float) -> "Image.Image":
    # Pillow fast-paths an exact quarter turn as a pure transpose regardless
    # of the resample filter passed - no interpolation at all, which beats
    # either BICUBIC or LANCZOS4 - so those go through Pillow unconditionally.
    if degrees % 90.0 == 0.0:
        return frame.rotate(-degrees, expand=True, resample=Image.Resampling.BICUBIC)
    rotated = _rotate_cv2_lanczos(frame, degrees)
    if rotated is not None:
        return rotated
    global _cv2_unavailable_logged
    if not _cv2_unavailable_logged:
        logger.warning(
            "cv2 is not importable; falling back to Pillow BICUBIC for non-quarter-turn "
            "geometry ops. Detail retention will be measurably worse - see "
            "geometry_ops.py's module docstring."
        )
        _cv2_unavailable_logged = True
    return frame.rotate(-degrees, expand=True, resample=Image.Resampling.BICUBIC)


def replay_pending_ops(frame: "Image.Image", ops: list[dict]) -> "Image.Image":
    """Apply deferred edits to [frame], in order.

    Crop rects are normalised, so they denormalise against whatever the frame
    measures at that point in the replay - a crop recorded after a rotate is
    applied to the rotated frame, exactly as the reviewer saw it.
    """
    for op in ops:
        kind = op.get("op")
        if kind in {"deskew", "rotate"}:
            try:
                degrees = float(op.get("degrees") or 0.0)
            except (TypeError, ValueError):
                continue
            if not degrees:
                continue
            frame = _rotate(frame, degrees)
        elif kind == "crop":
            rect = op.get("rect") or []
            if len(rect) != 4:
                continue
            try:
                x0, y0, x1, y1 = (float(value) for value in rect)
            except (TypeError, ValueError):
                continue
            left = max(0, min(frame.width - 1, round(x0 * frame.width)))
            top = max(0, min(frame.height - 1, round(y0 * frame.height)))
            right = max(left + 1, min(frame.width, round(x1 * frame.width)))
            bottom = max(top + 1, min(frame.height, round(y1 * frame.height)))
            frame = frame.crop((left, top, right, bottom))
    return frame

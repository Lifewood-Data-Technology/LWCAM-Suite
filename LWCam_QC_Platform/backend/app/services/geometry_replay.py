"""Replays a deferred geometry chain onto a decoded frame.

SHARED MODULE: this file ships BYTE-IDENTICAL in QC (app/services/) and LWIP
(deskew_crop_tool/); tests/test_geometry_replay.py fails if the copies drift.
It therefore imports nothing from either package: stdlib + numpy + Pillow +
(optional) cv2 only.

Pulled out of routers/qc.py so services/export.py can share it too.
Used at THREE sizes: the ~1600px preview, the one-time full-resolution
bake, and the export TIFF. Same function, same order semantics, so none of
the three can drift from what the others produce.

Ops (strict list order, unknown ops/keys skipped silently):
  {"op":"deskew"|"rotate","degrees":D}  rotate about the centre, expand=True
  {"op":"crop","rect":[x0,y0,x1,y1]}    normalised against the CURRENT frame
  {"op":"matfill"}                      fill the rotation wedges with mat

A non-quarter-turn deskew/rotate is resampled with OpenCV's LANCZOS4, not
Pillow's rotate() (Pillow refuses LANCZOS for AFFINE; BICUBIC measured 0.48
vs 0.94 high-frequency retention). An exact quarter turn goes through
Pillow's own rotate(): a pure transpose, no interpolation.

MATFILL. Producers place it after the crop: [deskew, crop, matfill]. The
rotation exposes black wedges where the frame had no pixels; they stand in
for mat that fell outside the capture. While replaying, a validity mask
(255 = real source pixel) is carried through exactly the same rotate/crop
steps (nearest neighbour, border 0, identical expand geometry), so at
matfill the void is known exactly: not-valid, eroded by the Lanczos reach
(4 px: pixels that close to a wedge were blended with the black fill). Only
void pixels are written; a real pixel is never modified. The algorithm is
ported from the reference script lwip_deskew_crop_v2.py: brightness plane
fitted to the mat (outlier refit), mirror-tiled dust-clipped texture patch,
per-side "mirror from beside" in bands, Gaussian per-row match across the
join. Page mask = what must never be sampled as mat: the page re-detected in
the CURRENT frame as v2 does (grey, Gaussian 3x3, THRESH_TRIANGLE - not Otsu
- 5x5 close, largest external contour, filled).

SCALING. v2's pixel constants were tuned on ~4000x5500 captures. Every one is
multiplied by s = longest_edge / MAT_REFERENCE_EDGE (5500), so a 1600px
preview, a 512px thumbnail and a full-size export fill alike. The Lanczos
reach is NOT scaled: it is the real warp kernel radius in the frame the
rotation was done in. Without cv2 the fill is skipped (wedges stay black)
with one warning; replay never raises for it.
"""

from __future__ import annotations

import logging

import numpy as np
from PIL import Image

logger = logging.getLogger(__name__)

try:
    import cv2
except ImportError:  # pragma: no cover - exercised via a monkeypatched import
    cv2 = None

# Registers JPEG XL with Pillow. Here, not in a caller, because every path that
# opens a page for replay imports this module - including the export's worker
# processes, which never import previews.py. Optional: without it .jxl is
# simply unreadable.
try:
    import pillow_jxl  # noqa: F401
except ImportError:
    pillow_jxl = None

_cv2_unavailable_logged = False
_matfill_unavailable_logged = False

# Longest edge the mat-fill constants below were tuned at (v2: ~4000x5500).
MAT_REFERENCE_EDGE = 5500
LANCZOS_RADIUS = 4
DETECTION_MAX_DIMENSION = 1600
# v2 constants at the reference size (px).
MAT_PATCH = 256
MAT_FIT_RADIUS = 600
MAT_PAGE_MARGIN = 40
MAT_GRID_CELL = 8
MAT_BAND = 64
MAT_MATCH_WIDTH = 12
MAT_MATCH_SIGMA = 32


def _pillow_expanded_size(size: tuple[int, int], degrees: float) -> tuple[int, int]:
    """(width, height) Pillow's own rotate(-degrees, expand=True) would
    produce for an image of [size].

    LWIP's manifest crop rects, and a reviewer's own, are normalised against
    exactly this expanded frame, so OpenCV's output canvas has to match it
    exactly. Asking a throwaway 1-bit dummy image makes that exact by
    construction rather than by re-derived ceil/floor arithmetic.
    """
    dummy = Image.new("1", size)
    return dummy.rotate(-degrees, expand=True, resample=Image.Resampling.NEAREST).size


def _rotation_matrix(size: tuple[int, int], degrees: float):
    """(2x3 matrix, new_width, new_height) matching Pillow's
    rotate(-degrees, expand=True) in size AND placement.

    A = -degrees: the counter-clockwise angle cv2.getRotationMatrix2D needs to
    land on the SAME pixels as Pillow's rotate(-degrees) - proved empirically
    (tests/test_deferred_geometry.py), not derived from the two libraries'
    stated sign conventions.
    """
    width, height = size
    new_width, new_height = _pillow_expanded_size((width, height), degrees)
    matrix = cv2.getRotationMatrix2D((width / 2.0, height / 2.0), -degrees, 1.0)
    matrix[0, 2] += (new_width - width) / 2.0
    matrix[1, 2] += (new_height - height) / 2.0
    return matrix, new_width, new_height


def _rotate_cv2_lanczos(frame: "Image.Image", degrees: float) -> "Image.Image | None":
    """OpenCV LANCZOS4 rotation, geometrically identical to Pillow's
    rotate(-degrees, expand=True), with a sharper filter. Returns None if
    cv2 failed to import, so the caller falls back to Pillow's BICUBIC.
    """
    if cv2 is None:
        return None
    original_mode = frame.mode
    work_mode = original_mode if original_mode in ("RGB", "L") else "RGB"
    work_frame = frame if work_mode == original_mode else frame.convert("RGB")
    matrix, new_width, new_height = _rotation_matrix(work_frame.size, degrees)
    # Pillow's own rotate() fills the expanded margin with black (0).
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
    # of the resample filter passed, so those go through Pillow unconditionally.
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
            "geometry_replay.py's module docstring."
        )
        _cv2_unavailable_logged = True
    return frame.rotate(-degrees, expand=True, resample=Image.Resampling.BICUBIC)


def _crop_box(rect, width: int, height: int):
    """Pixel box for a normalised [rect] on a width x height frame, or None."""
    rect = rect or []
    if len(rect) != 4:
        return None
    try:
        x0, y0, x1, y1 = (float(value) for value in rect)
    except (TypeError, ValueError):
        return None
    left = max(0, min(width - 1, round(x0 * width)))
    top = max(0, min(height - 1, round(y0 * height)))
    right = max(left + 1, min(width, round(x1 * width)))
    bottom = max(top + 1, min(height, round(y1 * height)))
    return left, top, right, bottom


def _rotate_mask(mask: np.ndarray, degrees: float) -> np.ndarray:
    """The frame's rotation applied to the validity mask: nearest neighbour,
    border 0, same expand geometry; then eroded by the Lanczos reach."""
    if degrees % 90.0 == 0.0:
        rotated = np.asarray(
            Image.fromarray(mask).rotate(-degrees, expand=True, resample=Image.Resampling.NEAREST)
        )
        return np.ascontiguousarray(rotated)
    matrix, new_width, new_height = _rotation_matrix((mask.shape[1], mask.shape[0]), degrees)
    rotated = cv2.warpAffine(
        mask, matrix, (new_width, new_height),
        flags=cv2.INTER_NEAREST, borderMode=cv2.BORDER_CONSTANT, borderValue=0,
    )
    side = 2 * LANCZOS_RADIUS + 1
    return cv2.erode(
        rotated, cv2.getStructuringElement(cv2.MORPH_RECT, (side, side)),
        borderType=cv2.BORDER_CONSTANT, borderValue=255,
    )


def replay_pending_ops(frame: "Image.Image", ops: list[dict]) -> "Image.Image":
    """Apply deferred edits to [frame], in order.

    Crop rects are normalised, so they denormalise against whatever the frame
    measures at that point in the replay - a crop recorded after a rotate is
    applied to the rotated frame, exactly as the reviewer saw it.
    """
    # The mask costs a full-frame plane per step; only pay for it when a
    # matfill op is actually in the list (and can run).
    wants_fill = any(op.get("op") == "matfill" for op in ops)
    if wants_fill and cv2 is None:
        global _matfill_unavailable_logged
        if not _matfill_unavailable_logged:
            logger.warning("cv2 is not importable; matfill skipped, rotation wedges stay black.")
            _matfill_unavailable_logged = True
        wants_fill = False
    mask = np.full((frame.height, frame.width), 255, dtype=np.uint8) if wants_fill else None
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
            if mask is not None:
                mask = _rotate_mask(mask, degrees)
        elif kind == "crop":
            box = _crop_box(op.get("rect"), frame.width, frame.height)
            if box is None:
                continue
            frame = frame.crop(box)
            if mask is not None:
                mask = mask[box[1]:box[3], box[0]:box[2]]
        elif kind == "matfill" and mask is not None:
            frame = _matfill(frame, mask)
            # Filled pixels are mat now; a later rotate exposes new void only.
            mask = np.full(mask.shape, 255, dtype=np.uint8)
    return frame


# ---------------------------------------------------------------------------
# Mat fill (ported from lwip_deskew_crop_v2.py; see module docstring)
# ---------------------------------------------------------------------------

class _Params:
    """v2's pixel constants scaled to this frame's size."""

    def __init__(self, width: int, height: int) -> None:
        s = max(width, height) / MAT_REFERENCE_EDGE
        self.cell = max(2, round(MAT_GRID_CELL * s))
        self.patch = max(4 * self.cell, round(MAT_PATCH * s))
        self.fit_radius = max(8 * self.cell, round(MAT_FIT_RADIUS * s))
        self.page_margin = max(3, round(MAT_PAGE_MARGIN * s))
        self.band = max(4, round(MAT_BAND * s))
        self.match_width = max(3, round(MAT_MATCH_WIDTH * s))
        self.match_sigma = max(4, round(MAT_MATCH_SIGMA * s))
        self.min_mat = max(50, round(1000 * s * s))
        self.beside_kernel = max(3, round(7 * s) | 1)


def _matfill(frame: "Image.Image", valid: np.ndarray) -> "Image.Image":
    if frame.mode not in ("RGB", "L") or valid.shape != (frame.height, frame.width):
        return frame
    void = valid == 0
    if not void.any():
        return frame
    rgb = frame if frame.mode == "RGB" else frame.convert("RGB")
    arr = np.array(rgb)  # writable copy
    try:
        _fill_void(arr, void, _Params(frame.width, frame.height))
    except Exception:  # never let a cosmetic fill break an export
        logger.exception("matfill failed; leaving the wedges black")
        return frame
    result = Image.fromarray(arr, mode="RGB")
    return result if frame.mode == "RGB" else result.convert("L")


def _page_mask(arr: np.ndarray) -> np.ndarray:
    """Page outline in the current frame, filled (255 = page), as v2 detects
    it. TRIANGLE, not Otsu: see v2's note on the cover board."""
    height, width = arr.shape[:2]
    gray = cv2.cvtColor(arr, cv2.COLOR_RGB2GRAY)
    scale = min(1.0, DETECTION_MAX_DIMENSION / max(height, width))
    if scale < 1.0:
        gray = cv2.resize(
            gray, (max(1, round(width * scale)), max(1, round(height * scale))),
            interpolation=cv2.INTER_AREA,
        )
    blurred = cv2.GaussianBlur(gray, (3, 3), 0)
    _value, threshold = cv2.threshold(blurred, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_TRIANGLE)
    closed = cv2.morphologyEx(
        threshold, cv2.MORPH_CLOSE, cv2.getStructuringElement(cv2.MORPH_RECT, (5, 5))
    )
    contours, _h = cv2.findContours(closed, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    page = np.zeros((height, width), dtype=np.uint8)
    if not contours:
        return page
    contour = max(contours, key=cv2.contourArea).astype(np.float32) / scale
    cv2.fillPoly(page, [np.round(contour).astype(np.int32)], 255)
    return page


def _void_sides(valid: np.ndarray, ys: np.ndarray, xs: np.ndarray) -> np.ndarray:
    """Which frame edge each void pixel fell off, in np.rot90 order
    (0 left, 1 top, 2 right, 3 bottom: k rotations bring that side to the
    left). A void pixel belongs to the side whose valid pixels are nearest
    along an axis: a wedge under the top edge has valid pixels just below it.
    """
    height, width = valid.shape
    big = 1 << 30

    def forward(v: np.ndarray) -> np.ndarray:
        # distance along axis 1 to the next valid pixel (self included)
        cols = np.arange(v.shape[1], dtype=np.int32)[None, :]
        nxt = np.where(v, cols, np.int32(big))
        nxt = np.minimum.accumulate(nxt[:, ::-1], axis=1)[:, ::-1]
        return nxt - cols

    distances = [
        forward(valid)[ys, xs],                          # valid to the right -> wedge on the left
        forward(valid.T)[xs, ys],                        # valid below        -> wedge on top
        forward(valid[:, ::-1])[ys, width - 1 - xs],     # valid to the left  -> wedge on the right
        forward(valid.T[:, ::-1])[xs, height - 1 - ys],  # valid above        -> wedge at the bottom
    ]
    return np.argmin(np.stack(distances, axis=1), axis=1)


def _fill_void(crop: np.ndarray, invalid: np.ndarray, p: _Params) -> None:
    """Fill [invalid] pixels of [crop] (HxWx3 uint8) in place with mat."""
    page = _page_mask(crop)
    # Mat = real pixels clear of the page, with a margin so the paper edge and
    # its shadow stay out of both the patch and the brightness estimate.
    near_page = cv2.dilate(
        page, cv2.getStructuringElement(cv2.MORPH_RECT, (2 * p.page_margin + 1,) * 2)
    )
    mat = (~invalid) & (near_page == 0)
    if int(mat.sum()) < p.min_mat:
        return  # no mat to sample; leave the wedge black
    height, width = crop.shape[:2]
    cell = p.cell
    small_size = (max(1, width // cell), max(1, height // cell))
    mat_small = cv2.resize(mat.astype(np.float32), small_size, interpolation=cv2.INTER_AREA)
    crop_small = cv2.resize(
        crop.astype(np.float32) * mat[..., None], small_size, interpolation=cv2.INTER_AREA
    )
    invalid_small = cv2.resize(
        invalid.astype(np.float32), small_size, interpolation=cv2.INTER_AREA
    ) > 0

    full_cells = (mat_small >= 0.999).astype(np.uint8)
    distance = cv2.distanceTransform((~invalid_small).astype(np.uint8), cv2.DIST_L2, 5)
    ys, xs = np.nonzero(invalid)

    # Brightness: a plane fitted to the mat cells around the wedge; outliers
    # (shadow, dust) rejected and the plane refitted once.
    fit_cells = (full_cells > 0) & (distance <= p.fit_radius / cell)
    if int(fit_cells.sum()) < 20:
        fit_cells = full_cells > 0
    cy_fit, cx_fit = np.nonzero(fit_cells)
    if not len(cy_fit):
        return
    design = np.column_stack([
        np.ones(len(cx_fit)), (cx_fit + 0.5) * cell, (cy_fit + 0.5) * cell
    ])
    values = crop_small[cy_fit, cx_fit].astype(np.float64)
    keep = np.ones(len(values), dtype=bool)
    for _ in range(2):
        coefficients, *_unused = np.linalg.lstsq(design[keep], values[keep], rcond=None)
        residual = np.abs(values - design @ coefficients).max(axis=1)
        spread = 1.4826 * np.median(residual[keep]) + 1e-6
        keep = residual <= 2.5 * spread
        if int(keep.sum()) < 10:
            break
    fill = np.column_stack([np.ones(len(xs)), xs, ys]) @ coefficients

    # Texture: the patch nearest the wedge whose every pixel is mat.
    candidates = np.empty((0, 2), dtype=np.int64)
    patch_cells = 0
    for patch_cells in (p.patch // cell, p.patch // cell // 2, p.patch // cell // 4):
        if patch_cells < 2:
            break
        fits = cv2.erode(
            full_cells, np.ones((patch_cells, patch_cells), np.uint8),
            anchor=(0, 0), borderType=cv2.BORDER_CONSTANT, borderValue=0,
        )
        candidates = np.argwhere(fits > 0)
        if len(candidates):
            break
    if len(candidates):
        centres = candidates + patch_cells // 2
        cy, cx = candidates[int(np.argmin(distance[centres[:, 0], centres[:, 1]]))]
        size = patch_cells * cell
        patch = crop[cy * cell: cy * cell + size, cx * cell: cx * cell + size].astype(np.float32)
        patch -= np.median(patch.reshape(-1, patch.shape[2]), axis=0)
        # Keep the weave, drop the dust.
        spread = 1.4826 * np.median(np.abs(patch)) + 1e-6
        np.clip(patch, -3 * spread, 3 * spread, out=patch)
        # Mirror tiling: every tile edge meets its own reflection, no seams.
        tile = np.concatenate([patch, patch[:, ::-1]], axis=1)
        tile = np.concatenate([tile, tile[::-1]], axis=0)
        fill += tile[ys % tile.shape[0], xs % tile.shape[1]]

    crop[ys, xs] = np.clip(np.round(fill), 0, 255).astype(crop.dtype)
    # Where real mat lies right beside the wedge, mirror it in instead.
    _fill_from_beside(crop, invalid, mat, coefficients, page, p)


def _source_coordinates(k: int, height: int, width: int):
    """Map (row, col) in np.rot90(crop, k) back to (y, x) in the crop."""
    if k == 0:
        return lambda r, c: (r, c)
    if k == 1:
        return lambda r, c: (c, width - 1 - r)
    if k == 2:
        return lambda r, c: (height - 1 - r, width - 1 - c)
    return lambda r, c: (height - 1 - c, r)


def _fill_from_beside(crop, invalid, mat, coefficients, page, p: _Params) -> None:
    """Fill each wedge from the real mat directly beside it, in place.

    Rotating each wedge's side to the left makes every case the same: the
    wedge occupies the start of each row, and the real pixels just past it,
    mirrored about the wedge's edge, continue the mat across the join.
    """
    height, width = crop.shape[:2]
    ys, xs = np.nonzero(invalid)
    if not len(ys):
        return
    # Real pixels the fill must match across the join: anything but the paper
    # itself (its anti-aliased rim included) - shadowed mat counts.
    beside = (~invalid) & (
        cv2.dilate(page, np.ones((p.beside_kernel,) * 2, np.uint8)) == 0
    )
    side = _void_sides(~invalid, ys, xs)
    for k in np.unique(side):
        wedge = np.zeros_like(invalid)
        wedge[ys[side == k], xs[side == k]] = True
        rotated = (np.rot90(crop, k), np.rot90(wedge, k))
        _fill_left_wedge(
            *rotated, np.rot90(mat, k),
            _source_coordinates(int(k), height, width), coefficients, p,
        )
        _match_across_join(*rotated, np.rot90(beside, k), p)


def _match_across_join(image, wedge, beside, p: _Params) -> None:
    """Shift each row of a filled left-side wedge to its real neighbour's level.

    Per row, compare the real pixels just past the join with the filled pixels
    just inside it, smooth that difference over neighbouring rows (a notch in a
    torn edge must not make the fill jump) and add it to the row's fill, per
    channel. Rows with no real pixel beside them take their neighbours'
    correction.
    """
    rows_h, cols_w = wedge.shape
    has_wedge = wedge.any(axis=1)
    if not has_wedge.any():
        return
    depth = np.where(has_wedge, cols_w - np.argmax(wedge[:, ::-1], axis=1), 0)
    rows = np.arange(rows_h)[:, None]
    steps = np.arange(p.match_width)

    outside = depth[:, None] + steps
    outside_ok = (outside < cols_w) & has_wedge[:, None]
    outside = np.minimum(outside, cols_w - 1)
    outside_ok &= beside[rows, outside]
    inside = depth[:, None] - 1 - steps
    inside_ok = (inside >= 0) & has_wedge[:, None]
    inside = np.maximum(inside, 0)
    inside_ok &= wedge[rows, inside]
    if not inside_ok.any():
        return
    # Anything far brighter than the fill is paper poking past the outline.
    fill_level = float(np.median(image[rows, inside][inside_ok]))
    outside_ok &= image[rows, outside].max(axis=2) <= 3 * fill_level + 20

    def row_level(columns, ok):
        values = image[rows, columns].astype(np.float64) * ok[..., None]
        return values.sum(axis=1), ok.sum(axis=1).astype(np.float64)

    def smooth(values):
        radius = 3 * p.match_sigma
        kernel = np.exp(-0.5 * (np.arange(-radius, radius + 1) / p.match_sigma) ** 2)
        if values.ndim == 1:
            return np.convolve(values, kernel, mode="same")
        return np.stack(
            [np.convolve(values[:, c], kernel, mode="same") for c in range(values.shape[1])],
            axis=1,
        )

    out_sum, out_n = row_level(outside, outside_ok)
    in_sum, in_n = row_level(inside, inside_ok)
    out_w, in_w = smooth(out_n), smooth(in_n)
    reached = (out_w > 1e-3) & (in_w > 1e-3)
    offset = np.zeros((rows_h, image.shape[2]))
    offset[reached] = (
        smooth(out_sum)[reached] / out_w[reached, None]
        - smooth(in_sum)[reached] / in_w[reached, None]
    )
    # Rows with paper against the join have no neighbour to measure: carry on
    # the correction of the nearest rows that do.
    if reached.any() and not reached.all():
        known = np.flatnonzero(reached)
        for c in range(offset.shape[1]):
            offset[:, c] = np.interp(np.arange(rows_h), known, offset[known, c])
    wedge_r, wedge_c = np.nonzero(wedge)
    image[wedge_r, wedge_c] = np.clip(
        np.round(image[wedge_r, wedge_c].astype(np.float64) + offset[wedge_r]), 0, 255
    ).astype(image.dtype)


def _fill_left_wedge(image, wedge, mat, to_crop, coefficients, p: _Params) -> None:
    """Fill a wedge at the start of each row from the mat just past it.

    `image` is a rotated view, so writes land in the crop. Rows go in bands of
    p.band. A band whose own rows have enough mat past the wedge mirrors it
    straight across; one blocked by the page borrows the same arrangement from
    the nearest rows that have it, shifted by the brightness plane. A band with
    no such rows anywhere keeps the tiled-patch fill.
    """
    rows_h, cols_w = wedge.shape
    has_wedge = wedge.any(axis=1)
    depth = np.where(has_wedge, cols_w - np.argmax(wedge[:, ::-1], axis=1), 0)
    limit = int(depth.max())
    if limit == 0:
        return
    columns = depth[:, None] + np.arange(limit)
    window = mat[np.arange(rows_h)[:, None], np.minimum(columns, cols_w - 1)]
    window &= columns < cols_w
    run = np.where(window.all(axis=1), limit, np.argmin(window, axis=1))

    previous_shift = None
    for start in range(0, rows_h, p.band):
        rows = np.arange(start, min(start + p.band, rows_h))
        rows = rows[depth[rows] > 0]
        if not len(rows):
            previous_shift = None
            continue
        need = depth[rows]
        span = int(rows[-1] - rows[0] + 1)
        good = np.concatenate([[0], np.cumsum(run >= need.max())])
        starts = np.arange(0, rows_h - span + 1)
        usable = starts[good[starts + span] - good[starts] == span]
        if not len(usable):
            previous_shift = None
            continue
        if previous_shift is not None and np.any(usable == rows[0] + previous_shift):
            shift = previous_shift
        else:
            shift = int(usable[np.argmin(np.abs(usable - rows[0]))] - rows[0])
        previous_shift = shift

        target_r = np.repeat(rows, need)
        target_c = np.arange(int(need.sum())) - np.repeat(np.cumsum(need) - need, need)
        keep = wedge[target_r, target_c]
        target_r, target_c = target_r[keep], target_c[keep]
        source_r = target_r + shift
        # Mirror about each row's own wedge edge.
        source_c = depth[source_r] + (depth[target_r] - 1 - target_c)

        values = image[source_r, source_c].astype(np.float64)
        target_y, target_x = to_crop(target_r, target_c)
        source_y, source_x = to_crop(source_r, source_c)
        values += (
            (target_x - source_x)[:, None] * coefficients[1]
            + (target_y - source_y)[:, None] * coefficients[2]
        )
        image[target_r, target_c] = np.clip(np.round(values), 0, 255).astype(image.dtype)

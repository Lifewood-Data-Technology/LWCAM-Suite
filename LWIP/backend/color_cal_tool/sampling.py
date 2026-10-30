"""Median-samples the 48 patches of a rectified chart frame.

`snap_patch_centres` exists because the physical card's hinge gap does not
match the reference-dot frame the geometry constants were measured from: on
a real photo the nominal grid position is off by tens of pixels for some
columns (see AGENTS.md WP-P0 report), so a fixed inset cannot fix it -- each
patch needs its own small local search for the flattest window nearby.
"""

from __future__ import annotations

from typing import NamedTuple

import numpy as np

from .color_math import srgb_decode
from .reference_data import PATCH_RADIUS, PATCHES


class PatchSamples(NamedTuple):
    median_rgb8: np.ndarray  # (48,3) float64, 0-255
    linear: np.ndarray  # (48,3) float64, linear light 0-1
    std_rgb8: np.ndarray  # (48,3) float64
    pixel_count: np.ndarray  # (48,) int64
    clipped: np.ndarray  # (48,) bool


class SnapResult(NamedTuple):
    centres: np.ndarray  # (48,2) float64, px (x,y) in rect_rgb
    offsets: np.ndarray  # (48,2) float64, px (dx,dy) chosen relative to nominal


def snap_patch_centres(
    rect_rgb: np.ndarray, radius: float = PATCH_RADIUS, search: float = 0.035, step: int = 4
) -> SnapResult:
    """For each patch, search a small grid of offsets around its nominal
    centre and keep the one whose sample window has the lowest total
    per-channel std (a patch is flat; the search jumps at the black gaps
    between patches). Vectorised via integral images -- O(1) per candidate
    window regardless of window size -- so 48 patches x ~500 candidates
    stays well under a second."""
    height, width = rect_rgb.shape[:2]
    half = radius * height * 0.5  # same half-side sample_patches uses by default

    img = rect_rgb.astype(np.float64)
    sum_ii = np.zeros((height + 1, width + 1, 3), dtype=np.float64)
    sumsq_ii = np.zeros((height + 1, width + 1, 3), dtype=np.float64)
    sum_ii[1:, 1:] = np.cumsum(np.cumsum(img, axis=0), axis=1)
    sumsq_ii[1:, 1:] = np.cumsum(np.cumsum(img * img, axis=0), axis=1)

    n_x = max(1, int(round((search * width) / step)))
    n_y = max(1, int(round((search * height) / step)))
    grid_dx, grid_dy = np.meshgrid(
        np.arange(-n_x, n_x + 1) * step, np.arange(-n_y, n_y + 1) * step, indexing="xy"
    )
    grid_dx = grid_dx.ravel().astype(np.float64)
    grid_dy = grid_dy.ravel().astype(np.float64)
    offset_mag = grid_dx**2 + grid_dy**2

    centres = np.zeros((48, 2), dtype=np.float64)
    offsets = np.zeros((48, 2), dtype=np.float64)

    for i, patch in enumerate(PATCHES):
        cx0, cy0 = patch.x * width, patch.y * height
        x0 = np.clip(np.round(cx0 + grid_dx - half).astype(np.int64), 0, width)
        x1 = np.clip(np.round(cx0 + grid_dx + half).astype(np.int64), 0, width)
        y0 = np.clip(np.round(cy0 + grid_dy - half).astype(np.int64), 0, height)
        y1 = np.clip(np.round(cy0 + grid_dy + half).astype(np.int64), 0, height)
        count = np.maximum((x1 - x0) * (y1 - y0), 1).astype(np.float64)

        box_sum = sum_ii[y1, x1] - sum_ii[y0, x1] - sum_ii[y1, x0] + sum_ii[y0, x0]
        box_sumsq = sumsq_ii[y1, x1] - sumsq_ii[y0, x1] - sumsq_ii[y1, x0] + sumsq_ii[y0, x0]
        mean = box_sum / count[:, None]
        variance = np.maximum(box_sumsq / count[:, None] - mean**2, 0.0)
        total_std = np.sqrt(variance).sum(axis=1)  # (K,)

        order = np.lexsort((offset_mag, total_std))  # primary std, tie -> smallest offset
        best = order[0]
        offsets[i] = [grid_dx[best], grid_dy[best]]
        centres[i] = [cx0 + grid_dx[best], cy0 + grid_dy[best]]

    return SnapResult(centres=centres, offsets=offsets)


def sample_patches(
    rect_rgb: np.ndarray, radius: float = PATCH_RADIUS, inset_fraction: float = 0.5, centres=None
) -> PatchSamples:
    height, width = rect_rgb.shape[:2]
    half = radius * height * inset_fraction

    median_rgb8 = np.zeros((48, 3), dtype=np.float64)
    linear = np.zeros((48, 3), dtype=np.float64)
    std_rgb8 = np.zeros((48, 3), dtype=np.float64)
    pixel_count = np.zeros((48,), dtype=np.int64)
    clipped = np.zeros((48,), dtype=bool)

    for i, patch in enumerate(PATCHES):
        cx, cy = (centres[i][0], centres[i][1]) if centres is not None else (patch.x * width, patch.y * height)
        x0 = max(0, int(round(cx - half)))
        x1 = min(width, int(round(cx + half)))
        y0 = max(0, int(round(cy - half)))
        y1 = min(height, int(round(cy + half)))
        window = rect_rgb[y0:y1, x0:x1].reshape(-1, 3).astype(np.float64)
        if window.size == 0:
            raise ValueError(f"patch window off canvas: {patch.name}")

        median = np.median(window, axis=0)
        median_rgb8[i] = median
        std_rgb8[i] = np.std(window, axis=0)
        pixel_count[i] = window.shape[0]
        linear[i] = srgb_decode(median / 255.0)
        clipped[i] = bool(np.any(median >= 250) or np.any(median <= 5))

    return PatchSamples(
        median_rgb8=median_rgb8,
        linear=linear,
        std_rgb8=std_rgb8,
        pixel_count=pixel_count,
        clipped=clipped,
    )

"""Finds a SpyderCheckr Photo card and rectifies it to the reference-dot frame.

The contour detector is the frozen local implementation in detection.py,
extracted from the source edition. It never imports an installed LWIP service.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import cv2
import numpy as np

from .detection import _detection_frame, _largest_content_contour

from .reference_data import COLUMN_X, FRAME_RATIO, GREY_INDICES, PATCH_RADIUS, ROW_Y

CANONICAL_WIDTH = 1500
CANONICAL_HEIGHT = round(1500 * FRAME_RATIO)  # 1060

# ponytail: kept at zero, deliberately -- WP-P0 found the offset between the
# card edge and the reference-dot frame is not a fixed fraction of the edge
# (the physical case's hinge gap puts the left panel ~45px off in a 1500px
# frame while the right panel is aligned), so a single inset cannot fix it.
# `sampling.snap_patch_centres` does a per-patch local search instead.
DEFAULT_INSET = {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}

CARD_ASPECT = 0.68  # measured 1800/2650 from a real Xiaomi Pro-Mode photo's detected quad
CARD_ASPECT_TOL = 0.15
MIN_AREA_FRACTION = 0.05
ACCEPT_CONFIDENCE = 0.6

_APPROX_EPSILON_FRACTIONS = (0.01, 0.02, 0.03, 0.05, 0.08)


@dataclass(frozen=True)
class QuadResult:
    quad: np.ndarray  # (4,2) float32 TL,TR,BR,BL, full-image pixels
    confidence: float
    needs_review: bool
    method: str  # approx_poly | min_area_rect | manual
    reasons: tuple[str, ...] = field(default_factory=tuple)


def detect_chart_quad(image_bgr: np.ndarray) -> QuadResult | None:
    gray, scale = _detection_frame(image_bgr)
    contour = _largest_content_contour(image_bgr, prepared=(gray, scale))
    if contour is None:
        return None
    # Contour dtype is float32 when the detection frame was downscaled, or
    # int32 when the image was already small enough (image_ops.py:800).
    contour = np.asarray(contour, dtype=np.float32).reshape(-1, 2)

    height, width = image_bgr.shape[:2]
    full_area = float(height) * float(width)
    contour_area = float(cv2.contourArea(contour))
    if full_area <= 0 or contour_area / full_area < MIN_AREA_FRACTION:
        return None

    reasons: list[str] = []
    perimeter = cv2.arcLength(contour, True)
    quad = None
    method = None
    for eps_fraction in _APPROX_EPSILON_FRACTIONS:
        approx = cv2.approxPolyDP(contour, eps_fraction * perimeter, True)
        if len(approx) == 4 and cv2.isContourConvex(approx):
            quad = approx.reshape(4, 2).astype(np.float32)
            method = "approx_poly"
            break

    if quad is None:
        rect = cv2.minAreaRect(contour)
        quad = cv2.boxPoints(rect).astype(np.float32)
        method = "min_area_rect"
        reasons.append("approxPolyDP did not converge to a convex quadrilateral")

    ordered = order_corners(quad)
    confidence, penalty_reasons = _confidence(ordered, contour_area, full_area, method)
    reasons.extend(penalty_reasons)
    needs_review = confidence < ACCEPT_CONFIDENCE

    return QuadResult(
        quad=ordered,
        confidence=confidence,
        needs_review=needs_review,
        method=method,
        reasons=tuple(reasons),
    )


def order_corners(pts) -> np.ndarray:
    """Orders 4 points as TL, TR, BR, BL, then rotates the labelling by one
    step if the result is portrait -- the card's long side is always meant
    to read horizontal."""
    pts = np.asarray(pts, dtype=np.float32).reshape(-1, 2)
    s = pts.sum(axis=1)
    d = (pts[:, 1] - pts[:, 0])
    tl = pts[np.argmin(s)]
    br = pts[np.argmax(s)]
    tr = pts[np.argmin(d)]
    bl = pts[np.argmax(d)]
    ordered = np.array([tl, tr, br, bl], dtype=np.float32)

    width = float(np.linalg.norm(ordered[1] - ordered[0]))
    height = float(np.linalg.norm(ordered[3] - ordered[0]))
    if height > width:
        # 90-degree rotation ambiguity: relabel so the long side is on top.
        ordered = np.array([ordered[1], ordered[2], ordered[3], ordered[0]], dtype=np.float32)
    return ordered


def _confidence(
    quad: np.ndarray, contour_area: float, full_area: float, method: str
) -> tuple[float, list[str]]:
    reasons: list[str] = []
    penalty = 0.0

    tl, tr, br, bl = quad
    top = float(np.linalg.norm(tr - tl))
    bottom = float(np.linalg.norm(br - bl))
    left = float(np.linalg.norm(bl - tl))
    right = float(np.linalg.norm(br - tr))

    avg_width = (top + bottom) / 2.0
    avg_height = (left + right) / 2.0
    aspect = avg_height / avg_width if avg_width > 0 else 0.0
    aspect_penalty = min(0.4, abs(aspect - CARD_ASPECT) / CARD_ASPECT_TOL * 0.4)
    if aspect_penalty > 0:
        penalty += aspect_penalty
        reasons.append(f"aspect ratio {aspect:.3f} vs expected {CARD_ASPECT}")

    if not cv2.isContourConvex(quad.reshape(-1, 1, 2).astype(np.float32)):
        penalty += 0.5
        reasons.append("quad is not convex")

    area_fraction = contour_area / full_area if full_area else 0.0
    if area_fraction < 0.10:
        penalty += 0.2
        reasons.append(f"detected area only {area_fraction:.1%} of frame")

    if max(top, bottom) > 0 and abs(top - bottom) / max(top, bottom) > 0.15:
        penalty += 0.2
        reasons.append("top/bottom side length asymmetry")
    if max(left, right) > 0 and abs(left - right) / max(left, right) > 0.15:
        penalty += 0.2
        reasons.append("left/right side length asymmetry")

    confidence = 1.0 - penalty
    if method == "min_area_rect":
        confidence *= 0.5
        reasons.append("fell back to minAreaRect")
    return max(0.0, min(1.0, confidence)), reasons


def rectify(image_bgr: np.ndarray, quad: np.ndarray, inset: dict) -> np.ndarray:
    """Perspective-warps the quad to the canonical (1060, 1500, 3) uint8 RGB
    reference-dot frame. This is the ONLY BGR->RGB conversion in the tool;
    nothing downstream touches cv2 colour ordering."""
    tl, tr, br, bl = (np.asarray(p, dtype=np.float64) for p in quad)
    left = float(inset.get("left", 0.0))
    top = float(inset.get("top", 0.0))
    right = float(inset.get("right", 0.0))
    bottom = float(inset.get("bottom", 0.0))

    tl_adj = tl + left * (tr - tl) + top * (bl - tl)
    tr_adj = tr + right * (tl - tr) + top * (br - tr)
    br_adj = br + right * (bl - br) + bottom * (tr - br)
    bl_adj = bl + left * (br - bl) + bottom * (tl - bl)

    src = np.array([tl_adj, tr_adj, br_adj, bl_adj], dtype=np.float32)
    dst = np.array(
        [
            [0, 0],
            [CANONICAL_WIDTH - 1, 0],
            [CANONICAL_WIDTH - 1, CANONICAL_HEIGHT - 1],
            [0, CANONICAL_HEIGHT - 1],
        ],
        dtype=np.float32,
    )
    matrix = cv2.getPerspectiveTransform(src, dst)
    warped = cv2.warpPerspective(
        image_bgr, matrix, (CANONICAL_WIDTH, CANONICAL_HEIGHT), flags=cv2.INTER_AREA
    )
    return cv2.cvtColor(warped, cv2.COLOR_BGR2RGB)


def _grey_medians(rect_rgb: np.ndarray) -> np.ndarray:
    """Median RGB of each of the 12 D/E grey patches, in D1..D6,E1..E6
    order -- the same geometry `sampling.sample_patches` uses, kept local so
    orientation resolution has no dependency on the sampling module."""
    height, width = rect_rgb.shape[:2]
    half = PATCH_RADIUS * height * 0.5
    medians = []
    for idx in GREY_INDICES:
        col, row = divmod(idx, 6)
        cx = COLUMN_X[col] * width
        cy = ROW_Y[row] * height
        x0 = max(0, int(round(cx - half)))
        x1 = int(round(cx + half))
        y0 = max(0, int(round(cy - half)))
        y1 = int(round(cy + half))
        window = rect_rgb[y0:y1, x0:x1].reshape(-1, 3)
        medians.append(np.median(window, axis=0))
    return np.array(medians, dtype=np.float64)


def _orientation_score(rect_rgb: np.ndarray) -> float:
    medians = _grey_medians(rect_rgb)
    channel_spread = (medians.max(axis=1) - medians.min(axis=1)) / np.clip(
        medians.mean(axis=1), 1.0, None
    )
    score = float(np.mean(channel_spread))

    lum = medians.mean(axis=1)
    d_lum, e_lum = lum[0:6], lum[6:12]
    non_decreasing_steps = int(np.sum(np.diff(d_lum) >= 0)) + int(np.sum(np.diff(e_lum) >= 0))
    score += 0.5 * non_decreasing_steps

    if int(np.argmax(lum)) != 6:  # index 6 = E1, the first of the E ramp
        score += 1.0

    return score


def resolve_orientation(rect_rgb: np.ndarray) -> tuple[np.ndarray, int]:
    """0 or 180 -- the only ambiguity `order_corners` cannot resolve on its
    own, since a landscape rectangle looks the same rotated a half turn."""
    rotated = np.rot90(rect_rgb, 2)
    if _orientation_score(rotated) < _orientation_score(rect_rgb):
        return np.ascontiguousarray(rotated), 180
    return rect_rgb, 0


# ponytail: if the card has printed corner dots, a detect_reference_dots(rect)
# refinement replaces the inset. V2.

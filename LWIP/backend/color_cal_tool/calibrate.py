"""Orchestrates one calibration run: load image -> find/rectify the chart ->
sample patches -> fit WB + matrix -> build the profile dict. Never writes
the profile to disk itself (no `out` path in the signature) -- `__main__.py`
does that once it has decided the run is `ok`, so a caller that only wants
the numbers (the Dart side's `runCalibration`, tests) can call this without
touching the filesystem beyond the source image and optional debug PNGs.
"""

from __future__ import annotations

import hashlib
import io
import logging
from datetime import datetime
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageOps

from .detection import _detection_frame

from . import reference_data
from .chart_detect import DEFAULT_INSET, QuadResult, detect_chart_quad, order_corners, rectify, resolve_orientation
from .color_math import delta_e00, linear_srgb_to_lab_d50
from .fit import (
    apply_panel_gains,
    apply_tone,
    estimate_anchor_gain,
    estimate_panel_gains,
    estimate_white_balance,
    evaluate,
    fit_matrix,
    fit_tone,
)
from .profile import build_profile, gamut_hint
from .reference_data import GREY_INDICES, LAB_REFERENCE, PATCH_RADIUS, PATCHES, WHITE_INDEX
from .sampling import PatchSamples, sample_patches, snap_patch_centres

LOGGER = logging.getLogger(__name__)


def calibrate(
    image_path,
    *,
    corners=None,
    inset: dict | None = None,
    device_id: str | None = None,
    operator: str | None = None,
    debug_dir=None,
    force: bool = False,
) -> dict:
    reference_data.verify()
    inset = dict(DEFAULT_INSET if inset is None else inset)
    image_path = Path(image_path)

    pil_image = ImageOps.exif_transpose(Image.open(image_path))
    rgb_image = pil_image if pil_image.mode == "RGB" else pil_image.convert("RGB")
    bgr_array = cv2.cvtColor(np.asarray(rgb_image), cv2.COLOR_RGB2BGR)

    warnings: list[str] = []
    debug_paths: dict[str, str] = {}

    if corners is not None:
        quad = order_corners(np.asarray(corners, dtype=np.float32).reshape(4, 2))
        quad_result = QuadResult(quad=quad, confidence=1.0, needs_review=False, method="manual", reasons=())
        inset = {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
    else:
        quad_result = detect_chart_quad(bgr_array)
        if quad_result is None:
            return {
                "ok": False,
                "error": {
                    "code": "no_chart_found",
                    "message": "no chart-sized contour was found in the image",
                },
            }

    detection_info = {
        "quad": quad_result.quad.tolist(),
        "rotation_deg": 0,
        "confidence": quad_result.confidence,
        "method": quad_result.method,
        "manual": quad_result.method == "manual",
        "inset": dict(inset),
    }

    if debug_dir:
        debug_paths["detected_png"] = _write_detected_debug(bgr_array, quad_result, debug_dir)

    if quad_result.needs_review and not force:
        result = {
            "ok": False,
            "error": {
                "code": "low_confidence",
                "message": f"chart detection confidence {quad_result.confidence:.2f} is below "
                f"the acceptance threshold; retry, pass --corners, or --force",
            },
            "detection": detection_info,
        }
        if debug_paths:
            result["debug"] = debug_paths
        return result

    rect_rgb = rectify(bgr_array, quad_result.quad, inset)
    rect_rgb, rotation_deg = resolve_orientation(rect_rgb)
    detection_info["rotation_deg"] = rotation_deg

    snap = snap_patch_centres(rect_rgb)
    samples = sample_patches(rect_rgb, centres=snap.centres)
    snap_max_px = float(np.max(np.hypot(snap.offsets[:, 0], snap.offsets[:, 1])))
    detection_info["snap_offsets_px"] = [[round(float(dx), 1), round(float(dy), 1)] for dx, dy in snap.offsets]
    detection_info["snap_max_px"] = round(snap_max_px, 1)

    if debug_dir:
        debug_paths["rectified_png"] = _write_rectified_debug(rect_rgb, debug_dir, centres=snap.centres)

    plausible, neutral_count = _chart_plausibility(samples)
    if not plausible:
        result = {
            "ok": False,
            "error": {
                "code": "chart_mismatch",
                "message": (
                    "The photo does not look like the SpyderCheckr Photo 48-patch card "
                    f"(found {neutral_count} neutral patches, expected 12)"
                ),
            },
            "detection": detection_info,
        }
        if debug_paths:
            result["debug"] = debug_paths
        return result

    non_white_grey_indices = [i for i in GREY_INDICES if i != WHITE_INDEX]
    total_clipped = int(np.sum(samples.clipped))
    non_white_grey_clipped = bool(np.any(samples.clipped[non_white_grey_indices]))
    if total_clipped > 12 or non_white_grey_clipped:
        result = {
            "ok": False,
            "error": {
                "code": "clipped_patches",
                "message": f"{total_clipped} of 48 patches are clipped ({'a non-white grey patch is clipped' if non_white_grey_clipped else 'too many overall'})",
            },
            "detection": detection_info,
        }
        if debug_paths:
            result["debug"] = debug_paths
        return result

    try:
        white_balance = estimate_white_balance(samples.linear, samples.clipped)
        linear_wb = samples.linear * white_balance

        # Per-panel exposure gain, fit-only (D10 corrective pass): a
        # row-paired ratio of the two ramps' own implied gain, which
        # cancels the (not yet fitted) tone curve's shape without a
        # bootstrap tone stage -- see fit.py::estimate_panel_gains.
        panel_gains = estimate_panel_gains(linear_wb, samples.clipped)
        linear_gained = apply_panel_gains(linear_wb, panel_gains)

        # Tone from the grey ramps ONLY (D10) -- never folds in the matrix
        # or the 36 chromatic patches, which is what previously let them
        # bend a white-anchored LUT away from mapping every grey onto its
        # reference luminance by construction.
        tone = fit_tone(linear_gained, samples.clipped)
        linear_toned = apply_tone(linear_gained, tone)

        # Anchored gain, fit-only: exactly pins E1 to its reference
        # luminance (median unclipped-grey ratio if E1 is itself clipped).
        # Never baked into any array, never stored in the profile.
        anchor_gain = estimate_anchor_gain(linear_toned, samples.clipped)
        matrix, fit_info = fit_matrix(linear_toned, samples.clipped, anchor_gain)

        # Reported only (stats.tone.mean_de00_without_tone) -- never chosen
        # over the tone-based fit. With the tone fitted from greys alone it
        # cannot hurt them, and the matrix is white-preserving so it cannot
        # either; if this full chain still comes out worse than skipping
        # the tone stage, that is a warning, not a reason to switch.
        anchor_gain_no_tone = estimate_anchor_gain(linear_gained, samples.clipped)
        matrix_no_tone, _ = fit_matrix(linear_gained, samples.clipped, anchor_gain_no_tone)
    except Exception as exc:  # noqa: BLE001 - turned into a structured result, not swallowed
        result = {
            "ok": False,
            "error": {"code": "fit_failed", "message": str(exc)},
            "detection": detection_info,
        }
        if debug_paths:
            result["debug"] = debug_paths
        return result

    after_de00 = evaluate(linear_toned, matrix, anchor_gain)
    before_de00 = evaluate(linear_wb, np.eye(3), anchor_gain)
    no_tone_de00 = evaluate(linear_gained, matrix_no_tone, anchor_gain_no_tone)

    mean_de00 = float(np.mean(after_de00))
    mean_de00_without_tone = float(np.mean(no_tone_de00))
    if mean_de00 > mean_de00_without_tone:
        LOGGER.warning(
            "tone stage made the full chain worse on this photo (kept anyway -- "
            "greys-only fit, D10): with_tone mean dE00=%.3f vs without_tone=%.3f",
            mean_de00, mean_de00_without_tone,
        )

    stats = {
        "mean_de00": mean_de00,
        "median_de00": float(np.median(after_de00)),
        "max_de00": float(np.max(after_de00)),
        "exposure_gain_fit_only": {**panel_gains, "anchor": anchor_gain},
        "before": {
            "mean_de00": float(np.mean(before_de00)),
            "median_de00": float(np.median(before_de00)),
            "max_de00": float(np.max(before_de00)),
        },
        "tone": {
            **tone,
            "mean_de00_without_tone": mean_de00_without_tone,
        },
        "greys": _grey_diagnostics(linear_toned, matrix, anchor_gain, samples.clipped),
        "per_patch": [
            {"name": patch.name, "de00": float(after_de00[i]), "clipped": bool(samples.clipped[i])}
            for i, patch in enumerate(PATCHES)
        ],
    }

    camera_make, camera_model = _read_exif_make_model(pil_image)
    icc_description = _read_icc_description(pil_image)
    hint = gamut_hint(icc_description)
    if hint == "display_p3":
        warnings.append(
            f"Source ICC is '{icc_description}' (P3 gamut). The fitted matrix maps "
            "camera-linear P3 to linear sRGB; output is sRGB and carries no ICC."
        )
    elif hint == "unknown" and icc_description:
        warnings.append(
            f"Source ICC is '{icc_description}' (gamut unrecognised). The fitted "
            "matrix assumes camera-linear sRGB; verify colour accuracy before use."
        )

    profile = build_profile(
        created_at=datetime.now().astimezone(),
        device_id=device_id,
        camera_make=camera_make,
        camera_model=camera_model,
        operator=operator,
        white_balance=white_balance,
        matrix=matrix,
        tone=tone,
        stats=stats,
        detection=detection_info,
        source_image={
            "path": str(image_path),
            "sha256": _sha256_file(image_path),
            "icc_description": icc_description or "",
            "gamut_hint": hint,
        },
    )

    result = {
        "ok": True,
        "profile": profile,
        "detection": detection_info,
        "warnings": warnings,
    }
    if debug_paths:
        result["debug"] = debug_paths
    return result


_NON_GREY_INDICES = [i for i in range(48) if i not in GREY_INDICES]

# ponytail: 0.25 (the plan's own starting figure) rejects the REAL colour
# chart -- the Xiaomi's raw, pre-white-balance grey patches carry a warm
# cast strong enough to put 4 of 12 over that line (measured up to 0.274 on
# the real photo). Widened to 0.30 against that photo (WP-P0); the actual
# discriminator against the grey-only target is the chroma-ratio check
# below (2.25 vs 1.21 measured), not this one -- both real fixtures land at
# 8-10/12 neutral by THIS test alone.
_GREY_SPREAD_THRESHOLD = 0.30


def _chart_plausibility(samples: PatchSamples) -> tuple[bool, int]:
    """Is this plausibly a photo of the 48-patch colour card, not e.g. the
    grey-scale-only target that ships in the same case? Three cheap checks
    on the snapped samples: the 12 designated grey patches actually read as
    neutral, the two grey ramps are (near) monotonic, and the 36 colour
    patches are meaningfully more saturated than the greys -- a grey-only
    target fails only the last one, since its 48 patches are all neutral."""
    grey_indices = list(GREY_INDICES)
    median = samples.median_rgb8

    grey_median = median[grey_indices]
    spread = (grey_median.max(axis=1) - grey_median.min(axis=1)) / np.clip(grey_median.mean(axis=1), 1.0, None)
    neutral_count = int(np.sum(spread < _GREY_SPREAD_THRESHOLD))

    luminance = median.mean(axis=1)
    d_violations = int(np.sum(np.diff(luminance[18:24]) >= 0))
    e_violations = int(np.sum(np.diff(luminance[24:30]) >= 0))

    chroma = samples.linear.max(axis=1) - samples.linear.min(axis=1)
    mean_chroma_grey = float(np.mean(chroma[grey_indices]))
    mean_chroma_non_grey = float(np.mean(chroma[_NON_GREY_INDICES]))
    chroma_ok = mean_chroma_non_grey > 2.0 * mean_chroma_grey

    ok = neutral_count >= 9 and d_violations <= 1 and e_violations <= 1 and chroma_ok
    return ok, neutral_count


def _grey_diagnostics(linear_toned: np.ndarray, matrix: np.ndarray, gain: float, clipped: np.ndarray) -> list[dict]:
    """Per-grey-patch (the 12 D+E ramp patches) diagnostic after the full
    chain, so a human can see whether the remaining error is L (tone
    shape still off) or a/b (a colour cast the matrix left behind) rather
    than only a single aggregate number."""
    grey_indices = list(GREY_INDICES)
    out = gain * (linear_toned[grey_indices] @ matrix.T)
    lab_meas = linear_srgb_to_lab_d50(out)
    lab_ref = LAB_REFERENCE[grey_indices]
    de00 = delta_e00(lab_meas, lab_ref)
    return [
        {
            "name": PATCHES[i].name,
            "L_ref": round(float(lab_ref[j, 0]), 2),
            "L_meas": round(float(lab_meas[j, 0]), 2),
            "a_ref": round(float(lab_ref[j, 1]), 2),
            "a_meas": round(float(lab_meas[j, 1]), 2),
            "b_ref": round(float(lab_ref[j, 2]), 2),
            "b_meas": round(float(lab_meas[j, 2]), 2),
            "de00": round(float(de00[j]), 3),
            "clipped": bool(clipped[i]),
        }
        for j, i in enumerate(grey_indices)
    ]


def _write_detected_debug(image_bgr: np.ndarray, quad_result: QuadResult, debug_dir) -> str:
    """Detection-frame-sized (not full-res) -- this is a human sanity check,
    not archival output."""
    out_dir = Path(debug_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    gray, scale = _detection_frame(image_bgr)
    if scale < 1.0:
        height, width = image_bgr.shape[:2]
        frame = cv2.resize(
            image_bgr,
            (max(1, round(width * scale)), max(1, round(height * scale))),
            interpolation=cv2.INTER_AREA,
        )
    else:
        frame = image_bgr.copy()

    quad_scaled = (quad_result.quad * scale).astype(np.int32)
    annotated = frame.copy()
    cv2.polylines(annotated, [quad_scaled.reshape(-1, 1, 2)], isClosed=True, color=(0, 255, 0), thickness=2)
    for label, point in zip(("TL", "TR", "BR", "BL"), quad_scaled):
        cv2.putText(
            annotated, label, (int(point[0]) + 4, int(point[1]) - 4),
            cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2, cv2.LINE_AA,
        )

    path = out_dir / "detected.png"
    cv2.imwrite(str(path), annotated)
    return str(path)


def _write_rectified_debug(rect_rgb: np.ndarray, debug_dir, centres=None) -> str:
    """`centres` (48,2), when given, are the SNAPPED per-patch centres --
    draw those, not the nominal grid, so this image is an honest picture of
    where the tool actually sampled."""
    out_dir = Path(debug_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    height, width = rect_rgb.shape[:2]
    half = PATCH_RADIUS * height * 0.5
    annotated = rect_rgb.copy()
    for i, patch in enumerate(PATCHES):
        cx, cy = (centres[i][0], centres[i][1]) if centres is not None else (patch.x * width, patch.y * height)
        x0, x1 = int(round(cx - half)), int(round(cx + half))
        y0, y1 = int(round(cy - half)), int(round(cy + half))
        cv2.rectangle(annotated, (x0, y0), (x1, y1), (255, 0, 0), 1)
        cv2.putText(
            annotated, patch.name, (x0, max(0, y0 - 3)),
            cv2.FONT_HERSHEY_SIMPLEX, 0.35, (255, 0, 0), 1, cv2.LINE_AA,
        )

    path = out_dir / "rectified.png"
    Image.fromarray(annotated).save(path)
    return str(path)


def _read_exif_make_model(pil_image: Image.Image) -> tuple[str | None, str | None]:
    exif = pil_image.getexif()
    make = exif.get(271)
    model = exif.get(272)
    make = str(make).strip() if make else None
    model = str(model).strip() if model else None
    return (make or None, model or None)


def _read_icc_description(pil_image: Image.Image) -> str | None:
    icc_bytes = pil_image.info.get("icc_profile")
    if not icc_bytes:
        return None
    try:
        from PIL import ImageCms

        cms_profile = ImageCms.ImageCmsProfile(io.BytesIO(icc_bytes))
        description = ImageCms.getProfileDescription(cms_profile)
        return description.strip() if description else None
    except Exception:
        return None


def _sha256_file(path) -> str:
    hasher = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            hasher.update(chunk)
    return hasher.hexdigest()

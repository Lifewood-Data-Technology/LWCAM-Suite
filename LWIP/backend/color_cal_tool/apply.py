"""Apply white balance, a 3x3 matrix and optional tone correction to RGB8.

Byte-identical consumer copies live under LWIP/backend/color_cal_tool and
LWCam_QC_Platform/backend/color_cal_tool. Edit this canonical copy, copy it
and run the parity test. Each installation imports only its own package.
"""

from __future__ import annotations

import functools
import hashlib
import json

import numpy as np
from PIL import Image


class UnsupportedCorrection(ValueError):
    """Raised on a `correction.type` other than `matrix3x3` (see profile.py's
    identical class -- duplicated here for the same self-containment reason
    as everything else in this module)."""


def _srgb_decode(v):
    v = np.clip(v, 0.0, 1.0)
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)


def _srgb_encode(v):
    v = np.clip(v, 0.0, 1.0)
    return np.where(v <= 0.0031308, 12.92 * v, 1.055 * v ** (1 / 2.4) - 0.055)


# A 65536-entry encode LUT: 4096 entries (one per 4-bit linear step) gave
# ~0.8 code error near black, where the sRGB curve is steepest. The full
# 16-bit domain costs well under 1 MB and removes the error entirely.
_DECODE_LUT = _srgb_decode(np.arange(256, dtype=np.float64) / 255.0).astype(np.float32)
_ENCODE_LUT = np.round(_srgb_encode(np.arange(65536, dtype=np.float64) / 65535.0) * 255.0).astype(np.uint8)


@functools.lru_cache(maxsize=8)
def _tone_lut_gamma(gamma: float, white: float) -> np.ndarray:
    """65536-entry float32 LUT for the white-anchored gamma tone stage
    (`tone(x) = W*(x/W)**g` below W, identity at/above it). Built once per
    (gamma, white) pair -- a station applies one profile at a time."""
    x = np.arange(65536, dtype=np.float64) / 65535.0
    ratio = x / white
    toned = white * ratio ** gamma
    return np.where(x < white, toned, x).astype(np.float32)


@functools.lru_cache(maxsize=8)
def _tone_lut_1d(white: float, x_knots: tuple, y_knots: tuple) -> np.ndarray:
    """65536-entry float32 LUT for the 'lut1d_white_anchored' tone stage
    (`tone(x) = W*interp(x/W, xs, ys)` below W, identity at/above it)."""
    x = np.arange(65536, dtype=np.float64) / 65535.0
    ratio = x / white
    toned = white * np.interp(ratio, np.asarray(x_knots, dtype=np.float64), np.asarray(y_knots, dtype=np.float64))
    return np.where(x < white, toned, x).astype(np.float32)


@functools.lru_cache(maxsize=8)
def _tone_lut_1d_rgb(white: tuple, white_out: tuple, x_knots: tuple, y_knots: tuple) -> tuple:
    """Three 65536-entry float32 LUTs, one per channel, for the
    'lut1d_rgb_white_anchored' tone stage (`tone_c(v) = W_out_c*interp(v/W_c,
    xs_c, ys_c)` below W_c, `W_out_c*(v/W_c)` -- continuing the same end
    slope -- at/above it) -- absorbs a colour cast that varies with
    luminance, which the single shared-luminance LUT above cannot (every
    unclipped grey maps to `k * rref_i` for one shared scalar k, by
    construction, because each channel is fit independently and `white_out`
    replaces the anchor's own measured chromaticity with the reference's,
    luminance preserved -- see fit.py::fit_tone_rgb). `white_out` equal to
    `white` (the fallback `_tone_lut_rgb` uses for a profile written before
    `white_out` existed) collapses this to the old identity-at-white
    behaviour exactly."""
    x = np.arange(65536, dtype=np.float64) / 65535.0
    luts = []
    for c in range(3):
        w = white[c]
        w_out = white_out[c]
        ratio = x / w
        interp_below = np.interp(ratio, np.asarray(x_knots[c], dtype=np.float64), np.asarray(y_knots[c], dtype=np.float64))
        toned = w_out * np.where(ratio < 1.0, interp_below, ratio)
        luts.append(toned.astype(np.float32))
    return tuple(luts)


def _tone_lut(tone: dict) -> np.ndarray:
    """Dispatches on `tone["type"]` -- absent means the original
    gamma-only shape, kept for callers still passing `{"gamma", "white"}`
    with no `type` key. Not used for 'lut1d_rgb_white_anchored' -- see
    `_tone_lut_rgb`, which builds three LUTs instead of one."""
    white = round(float(tone["white"]), 6)
    if tone.get("type") == "lut1d_white_anchored":
        x_knots = tuple(round(float(v), 6) for v in tone["x"])
        y_knots = tuple(round(float(v), 6) for v in tone["y"])
        return _tone_lut_1d(white, x_knots, y_knots)
    return _tone_lut_gamma(round(float(tone["gamma"]), 6), white)


def _tone_lut_rgb(tone: dict) -> tuple:
    """Builds (or fetches, cache keyed on the rounded tuple of all knots)
    the three per-channel LUTs for 'lut1d_rgb_white_anchored'. `white_out`
    falls back to `white` when absent (a profile written before D11)."""
    white = tuple(round(float(w), 6) for w in tone["white"])
    white_out = tuple(round(float(w), 6) for w in tone.get("white_out", tone["white"]))
    x_knots = tuple(tuple(round(float(v), 6) for v in xs) for xs in tone["x"])
    y_knots = tuple(tuple(round(float(v), 6) for v in ys) for ys in tone["y"])
    return _tone_lut_1d_rgb(white, white_out, x_knots, y_knots)


def apply_matrix_rgb8(rgb_uint8: np.ndarray, white_balance, matrix, tone: dict | None = None) -> np.ndarray:
    """`rgb_uint8` is any array shaped `(..., 3)`, RGB order. Returns a NEW
    array; the input is never mutated. `tone`, when given, is
    `{"type": "gamma_white_anchored", "gamma": g, "white": W}`,
    `{"type": "lut1d_white_anchored", "white": W, "x": [...], "y": [...]}`,
    or `{"type": "lut1d_rgb_white_anchored", "white": [Wr,Wg,Wb],
    "x": [[...],[...],[...]], "y": [[...],[...],[...]]}` (independent
    per-channel curves, for a cast that varies with luminance) -- applied
    after the white-balance multiply, before the matrix (pipeline order in
    AGENTS.md)."""
    wb = np.asarray(white_balance, dtype=np.float32)
    m = np.asarray(matrix, dtype=np.float32)
    shape = rgb_uint8.shape
    lin = _DECODE_LUT[rgb_uint8]
    out = lin.reshape(-1, 3) * wb
    if tone:
        np.clip(out, 0.0, 1.0, out=out)
        idx = (out * 65535.0 + 0.5).astype(np.uint16)
        if tone.get("type") == "lut1d_rgb_white_anchored":
            luts = _tone_lut_rgb(tone)
            out = np.stack([luts[c][idx[:, c]] for c in range(3)], axis=1)
        else:
            lut = _tone_lut(tone)
            out = lut[idx]
    out = out @ m.T
    np.clip(out, 0.0, 1.0, out=out)
    encoded = _ENCODE_LUT[(out * 65535.0 + 0.5).astype(np.uint16)]
    return encoded.reshape(shape)


def apply_profile_to_pil(image: Image.Image, color_profile: dict) -> Image.Image:
    """Accepts either a marker fragment or a full profile dict -- both carry
    `white_balance` and `correction` at the top level. Non-RGB images are
    converted to RGB first."""
    if not isinstance(color_profile, dict):
        raise ValueError("color_profile must be a dict")
    white_balance = color_profile.get("white_balance")
    correction = color_profile.get("correction")
    if not isinstance(white_balance, (list, tuple)) or len(white_balance) != 3:
        raise ValueError("color_profile.white_balance must have 3 components")
    if not isinstance(correction, dict):
        raise ValueError("color_profile.correction must be an object")
    if correction.get("type") != "matrix3x3":
        raise UnsupportedCorrection(f"unsupported correction type: {correction.get('type')!r}")
    matrix = correction.get("matrix")
    if not isinstance(matrix, (list, tuple)) or len(matrix) != 3:
        raise ValueError("color_profile.correction.matrix must be 3x3")
    tone = correction.get("tone")

    rgb_image = image if image.mode == "RGB" else image.convert("RGB")
    array = np.asarray(rgb_image, dtype=np.uint8)
    corrected = apply_matrix_rgb8(array, white_balance, matrix, tone=tone)
    return Image.fromarray(corrected)


def color_profile_component(profile: dict | None) -> int:
    """A short int derived from the correction values, for cache-key
    invalidation. 0 means "no profile", so an absent profile can never
    collide with a real one that happens to hash to 0."""
    if not profile:
        return 0
    correction = profile.get("correction") or {}
    payload = {"wb": profile.get("white_balance"), "m": correction.get("matrix"), "t": correction.get("tone")}
    digest = hashlib.sha256(json.dumps(payload, sort_keys=True).encode("utf-8")).hexdigest()
    return int(digest[:8], 16)

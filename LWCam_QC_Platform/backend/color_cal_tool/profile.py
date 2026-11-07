"""Versioned calibration profile: build, atomic write, read, validate, and
the marker fragment that goes into `lwcam_capture_marker.json` (AGENTS.md's
Cross-package contracts section)."""

from __future__ import annotations

import json
import math
import os
import tempfile
from datetime import datetime
from pathlib import Path

from . import reference_data

SCHEMA_VERSION = 1


class UnsupportedCorrection(ValueError):
    """Raised by `validate_profile` (and so by any reader that calls it) on
    a `correction.type` this build does not know how to apply. V2 slots a
    3D LUT type in beside `matrix3x3`; unknown types must fail loudly rather
    than silently pass pixels through uncorrected."""


def _profile_id(created_at: datetime, device_id: str | None) -> str:
    return created_at.strftime("%Y%m%dT%H%M%S%z") + "-" + (device_id or "nodev")


def gamut_hint(icc_description: str | None) -> str:
    """Heuristic-only gamut guess from an ICC profile's description string
    -- good enough to decide whether to warn, not a colour-managed
    decision. `working_space` in the profile always describes the OUTPUT
    (linear_srgb_d65); this describes the SOURCE image's likely gamut."""
    if not icc_description:
        return "unknown"
    lowered = icc_description.lower()
    if "p3" in lowered or "dci" in lowered:
        return "display_p3"
    if "srgb" in lowered:
        return "srgb"
    return "unknown"


def build_profile(
    *,
    created_at: datetime,
    device_id: str | None,
    camera_make: str | None,
    camera_model: str | None,
    operator: str | None,
    white_balance,
    matrix,
    tone: dict | None = None,
    stats: dict,
    detection: dict,
    source_image: dict,
) -> dict:
    correction = {
        "type": "matrix3x3",
        "matrix": [[float(v) for v in row] for row in matrix],
        "applied_after_white_balance": True,
    }
    if tone is not None:
        correction["tone"] = tone
    return {
        "schema_version": SCHEMA_VERSION,
        "profile_id": _profile_id(created_at, device_id),
        "created_at": created_at.isoformat(),
        "target": reference_data.TARGET_ID,
        "working_space": "linear_srgb_d65",
        "camera": {"make": camera_make, "model": camera_model, "device_id": device_id},
        "operator": operator,
        "white_balance": [float(v) for v in white_balance],
        "correction": correction,
        "stats": stats,
        "detection": detection,
        "source_image": source_image,
    }


def write_profile(path, data: dict) -> None:
    """Tmp file + `os.replace`, like every other atomic write in this
    suite -- a reader never sees a half-written profile."""
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=str(target.parent), prefix=".profile-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2)
        os.replace(tmp_name, target)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def read_profile(path) -> dict:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def validate_profile(profile: dict) -> None:
    """Raises on a malformed or unsupported profile. Never returns a
    truthy/falsy verdict -- callers that need to know without an exception
    should catch."""
    if profile.get("schema_version") != SCHEMA_VERSION:
        raise ValueError(f"unsupported schema_version: {profile.get('schema_version')!r}")

    white_balance = profile.get("white_balance")
    if not isinstance(white_balance, (list, tuple)) or len(white_balance) != 3:
        raise ValueError("white_balance must have exactly 3 components")
    for value in white_balance:
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value):
            raise ValueError(f"white_balance component is not a finite number: {value!r}")
        if not (0.2 <= value <= 5.0):
            raise ValueError(f"white_balance component out of range [0.2, 5]: {value!r}")

    correction = profile.get("correction")
    if not isinstance(correction, dict) or correction.get("type") != "matrix3x3":
        bad_type = correction.get("type") if isinstance(correction, dict) else correction
        raise UnsupportedCorrection(f"unsupported correction type: {bad_type!r}")

    matrix = correction.get("matrix")
    if not isinstance(matrix, (list, tuple)) or len(matrix) != 3:
        raise ValueError("correction.matrix must be 3x3")
    for row in matrix:
        if not isinstance(row, (list, tuple)) or len(row) != 3:
            raise ValueError("correction.matrix must be 3x3")
        for value in row:
            if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value):
                raise ValueError(f"correction.matrix contains a non-finite value: {value!r}")

    tone = correction.get("tone")
    if tone is not None:
        _TONE_TYPES = ("gamma_white_anchored", "lut1d_white_anchored", "lut1d_rgb_white_anchored")
        if not isinstance(tone, dict) or tone.get("type") not in _TONE_TYPES:
            bad_tone_type = tone.get("type") if isinstance(tone, dict) else tone
            raise ValueError(f"unsupported tone type: {bad_tone_type!r}")

        if tone["type"] == "lut1d_rgb_white_anchored":
            white = tone.get("white")
            if not isinstance(white, (list, tuple)) or len(white) != 3:
                raise ValueError("tone.white must have exactly 3 components for lut1d_rgb_white_anchored")
            for value in white:
                if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value):
                    raise ValueError(f"tone.white component is not a finite number: {value!r}")
                if not (0 < value <= 2):
                    raise ValueError(f"tone.white component out of range (0, 2]: {value!r}")

            white_out = tone.get("white_out")
            if white_out is not None:
                if not isinstance(white_out, (list, tuple)) or len(white_out) != 3:
                    raise ValueError("tone.white_out must have exactly 3 components for lut1d_rgb_white_anchored")
                for value in white_out:
                    if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value):
                        raise ValueError(f"tone.white_out component is not a finite number: {value!r}")
                    if not (0 < value <= 2):
                        raise ValueError(f"tone.white_out component out of range (0, 2]: {value!r}")

            xs_all, ys_all = tone.get("x"), tone.get("y")
            if not isinstance(xs_all, (list, tuple)) or not isinstance(ys_all, (list, tuple)):
                raise ValueError("tone.x and tone.y must be lists of 3 per-channel knot lists")
            if len(xs_all) != 3 or len(ys_all) != 3:
                raise ValueError("tone.x and tone.y must each have exactly 3 channel knot lists")
            for xs, ys in zip(xs_all, ys_all):
                if not isinstance(xs, (list, tuple)) or not isinstance(ys, (list, tuple)) or len(xs) != len(ys):
                    raise ValueError("each tone.x/tone.y channel must be equal-length lists")
                if len(xs) < 2:
                    raise ValueError("each tone.x/tone.y channel needs at least 2 knots")
                for values, label in ((xs, "x"), (ys, "y")):
                    for value in values:
                        if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value):
                            raise ValueError(f"tone.{label} contains a non-finite value: {value!r}")
                        if not (0.0 <= value <= 1.0):
                            raise ValueError(f"tone.{label} value out of range [0, 1]: {value!r}")
                if any(b < a for a, b in zip(xs, xs[1:])) or any(b < a for a, b in zip(ys, ys[1:])):
                    raise ValueError("tone.x and tone.y must be non-decreasing per channel")
            return

        white = tone.get("white")
        if not isinstance(white, (int, float)) or isinstance(white, bool) or not math.isfinite(white):
            raise ValueError(f"tone.white is not a finite number: {white!r}")
        if not (0 < white <= 2):
            raise ValueError(f"tone.white out of range (0, 2]: {white!r}")

        if tone["type"] == "gamma_white_anchored":
            gamma = tone.get("gamma")
            if not isinstance(gamma, (int, float)) or isinstance(gamma, bool) or not math.isfinite(gamma):
                raise ValueError(f"tone.gamma is not a finite number: {gamma!r}")
            if not (0.3 <= gamma <= 3.0):
                raise ValueError(f"tone.gamma out of range [0.3, 3.0]: {gamma!r}")
        else:  # lut1d_white_anchored
            xs, ys = tone.get("x"), tone.get("y")
            if not isinstance(xs, (list, tuple)) or not isinstance(ys, (list, tuple)) or len(xs) != len(ys):
                raise ValueError("tone.x and tone.y must be equal-length lists")
            if len(xs) < 2:
                raise ValueError("tone.x/tone.y need at least 2 knots")
            for values, label in ((xs, "x"), (ys, "y")):
                for value in values:
                    if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value):
                        raise ValueError(f"tone.{label} contains a non-finite value: {value!r}")
                    if not (0.0 <= value <= 1.0):
                        raise ValueError(f"tone.{label} value out of range [0, 1]: {value!r}")
            if any(b < a for a, b in zip(xs, xs[1:])) or any(b < a for a, b in zip(ys, ys[1:])):
                raise ValueError("tone.x and tone.y must be non-decreasing")


def marker_fragment(profile: dict) -> dict:
    """The `color_profile` object as it goes into the marker/manifest --
    everything the profile carries EXCEPT `calibrated_today`, which only
    LWCAM (with a clock and "today" to compare against) can add."""
    return {
        "profile_id": profile["profile_id"],
        "calibrated_at": profile["created_at"],
        "working_space": profile["working_space"],
        "white_balance": profile["white_balance"],
        "correction": profile["correction"],
    }

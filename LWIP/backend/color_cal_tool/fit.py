"""White balance + white-preserving 3x3 matrix fit, on mean CIEDE2000.

No scipy (LWIP's wheelhouse is air-gapped, numpy/opencv/Pillow only), so the
matrix step uses a small hand-rolled Nelder-Mead simplex, seeded from a
least-squares solve. See AGENTS.md D10.
"""

from __future__ import annotations

import numpy as np

from .color_math import (
    LINEAR_SRGB_TO_XYZ_D65,
    delta_e00,
    lab_d50_to_linear_srgb,
    lab_to_xyz_d50,
    linear_srgb_to_lab_d50,
)
from .reference_data import GREY_INDICES, LAB_REFERENCE, WHITE_INDEX

_GREY_INDEX_ARRAY = np.array(list(GREY_INDICES), dtype=np.int64)
_Y_REF = lab_to_xyz_d50(LAB_REFERENCE)[:, 1]
# Per-channel reference target for the RGB tone fit (D11): each grey's OWN
# linear-sRGB triple, not just its luminance -- see fit_tone_rgb.
_RREF = lab_d50_to_linear_srgb(LAB_REFERENCE)
# Column index (0=A .. 7=H) per patch, column-major layout (reference_data.py).
_LEFT_COLUMNS = (np.arange(48) // 6) < 4  # True for A-D, False for E-H

# Nelder-Mead coefficients (standard).
_ALPHA, _GAMMA, _RHO, _SIGMA = 1.0, 2.0, 0.5, 0.5
_MAX_ITERATIONS = 2000
_F_TOL = 1e-4
_X_TOL = 1e-6
_INITIAL_STEP = 0.05

_GAMMA_GRID = np.round(np.arange(0.5, 2.0 + 1e-9, 0.02), 2)
_GOLDEN_RATIO = (np.sqrt(5.0) - 1.0) / 2.0


def estimate_white_balance(linear: np.ndarray, clipped: np.ndarray) -> np.ndarray:
    """Grey-column WB gain, green held at 1.0."""
    usable = _GREY_INDEX_ARRAY[~clipped[_GREY_INDEX_ARRAY]]
    if len(usable) < 4:
        raise ValueError("too few unclipped grey patches")
    r = linear[usable, 0]
    g = linear[usable, 1]
    b = linear[usable, 2]
    gain_r = float(np.median(g / r))
    gain_b = float(np.median(g / b))
    return np.array([gain_r, 1.0, gain_b], dtype=np.float64)


def estimate_panel_gains(linear_wb: np.ndarray, clipped: np.ndarray) -> dict:
    """Fit-only per-panel exposure gain: the physical card's two panels
    (A-D / E-H) can be lit unevenly -- a single scalar exposure gain
    cannot correct both sides at once. Estimated WITHOUT tone confounding
    (D10 corrective pass): for each ROW-PAIRED grey k (D_k vs E_k -- same
    row, roughly the same tone-curve position), take the ratio of the two
    ramps' own implied per-patch gain, `(Y_ref(D_k)/Y_meas(D_k)) /
    (Y_ref(E_k)/Y_meas(E_k))`, and median that ratio over the unclipped
    rows. The (unknown) tone curve's shape mostly cancels in the ratio,
    unlike a bare per-ramp median of `Y_ref/Y_meas` (a six-fold spread
    patch-to-patch along one ramp on the real fixture, almost entirely a
    function of brightness, not panel lighting) -- so this needs no
    bootstrap tone stage first. `right` is fixed at 1.0 by construction:
    the shared absolute exposure is handled separately by the anchored
    gain (`estimate_anchor_gain`), fit-only in the same D10 sense --
    applied transiently to the working array used for tone/matrix fitting,
    never stored in the profile."""
    ratios = []
    for row in range(6):
        d_idx, e_idx = 18 + row, 24 + row
        if clipped[d_idx] or clipped[e_idx]:
            continue
        y_d = float(linear_wb[d_idx] @ LINEAR_SRGB_TO_XYZ_D65[1])
        y_e = float(linear_wb[e_idx] @ LINEAR_SRGB_TO_XYZ_D65[1])
        gain_d = _Y_REF[d_idx] / y_d
        gain_e = _Y_REF[e_idx] / y_e
        ratios.append(gain_d / gain_e)
    if not ratios:
        raise ValueError("too few unclipped paired grey rows for panel gain")
    return {"left": float(np.median(ratios)), "right": 1.0}


def apply_panel_gains(linear: np.ndarray, panel_gains: dict) -> np.ndarray:
    """Multiplies each patch by its panel's gain (A-D -> left, E-H ->
    right). Returns a new array."""
    factor = np.where(_LEFT_COLUMNS, panel_gains["left"], panel_gains["right"])
    return linear * factor[:, None]


def _anchor_index(linear_wb: np.ndarray, clipped: np.ndarray) -> int:
    """Which grey patch anchors the tone stage: E1 (`WHITE_INDEX`) when it
    survived clipping, else the brightest unclipped grey -- the same
    selection `_measure_white`/`_measure_white_channels` use to build the
    measured white LEVEL, returned here as an INDEX so `fit_tone_rgb` can
    look up that same patch's own reference Lab (`_RREF[anchor]`, D11's
    `rref_a`)."""
    anchor = WHITE_INDEX
    if not clipped[anchor]:
        return anchor
    usable_grey = _GREY_INDEX_ARRAY[~clipped[_GREY_INDEX_ARRAY]]
    if len(usable_grey) == 0:
        return anchor
    means = linear_wb[usable_grey].mean(axis=1)
    brightest_local = int(np.argmax(means))
    return int(usable_grey[brightest_local])


def _measure_white(linear_wb: np.ndarray, clipped: np.ndarray) -> float:
    """The measured white level after WB: mean over channels of the E1
    anchor patch, or -- if E1 is clipped -- the brightest unclipped grey's
    value EXTRAPOLATED to where E1 would have measured, assuming local
    linearity near the top of the range (`Y_ref(E1)/Y_ref(that patch)`).
    NOT that patch's own raw value: doing so makes its own x-ratio land at
    exactly 1.0 in the tone fit, landing it in apply_tone's "identity
    at/above white" branch under the silent assumption that ITS target is
    Y_ref(E1) rather than its own (smaller) Y_ref -- a multi-DN L overshoot
    confirmed on the synthetic fixtures (E1 renders marginally clipped in
    all of them) and a latent defect on any real capture with a touch of
    glare on the white patch, previously masked only by the old alternation's
    full-chain gamma/LUT competition (D10 corrective pass)."""
    anchor = WHITE_INDEX
    if not clipped[anchor]:
        return float(np.mean(linear_wb[anchor]))
    usable_grey = _GREY_INDEX_ARRAY[~clipped[_GREY_INDEX_ARRAY]]
    if len(usable_grey) == 0:
        return float(np.mean(linear_wb[anchor]))
    means = linear_wb[usable_grey].mean(axis=1)
    brightest_local = int(np.argmax(means))
    brightest_idx = int(usable_grey[brightest_local])
    brightest_mean = float(means[brightest_local])
    return brightest_mean * _Y_REF[anchor] / _Y_REF[brightest_idx]


def _measure_white_channels(linear_wb: np.ndarray, clipped: np.ndarray) -> np.ndarray:
    """Per-channel counterpart of `_measure_white`: the measured white
    level after WB, PER CHANNEL (not averaged across channels) -- E1's own
    channel values, or -- if E1 is clipped -- the brightest unclipped
    grey's channel values extrapolated to where E1 would have measured,
    same linearity assumption as `_measure_white`. This is the per-channel
    anchor `fit_tone_rgb` needs: a shared scalar white level cannot absorb
    a cast that varies with luminance, since it forces every channel to
    hit "identity" at the same input value."""
    anchor = WHITE_INDEX
    if not clipped[anchor]:
        return linear_wb[anchor].astype(np.float64)
    usable_grey = _GREY_INDEX_ARRAY[~clipped[_GREY_INDEX_ARRAY]]
    if len(usable_grey) == 0:
        return linear_wb[anchor].astype(np.float64)
    means = linear_wb[usable_grey].mean(axis=1)
    brightest_local = int(np.argmax(means))
    brightest_idx = int(usable_grey[brightest_local])
    return linear_wb[brightest_idx].astype(np.float64) * _Y_REF[anchor] / _Y_REF[brightest_idx]


def _anchor_gain(y_toned: np.ndarray, y_ref: np.ndarray, anchor_local_idx: int | None) -> float:
    """Shared core of step 4 (`estimate_anchor_gain`) and the gamma tone
    fit's per-candidate objective: anchors on E1 when it survived clipping
    (`anchor_local_idx` is its position within the caller's grey subset),
    else falls back to the median `Y_ref/Y_meas` ratio over whatever greys
    are left."""
    if anchor_local_idx is not None:
        return float(y_ref[anchor_local_idx] / y_toned[anchor_local_idx])
    return float(np.median(y_ref / y_toned))


def estimate_anchor_gain(linear_after_tone: np.ndarray, clipped: np.ndarray) -> float:
    """Anchored gain, fit-only (D10, step 4): `Y_ref(E1) / Y(tone(x_E1))`
    -- exactly pins the white patch to its reference luminance. Falls back
    to the median ratio over unclipped greys if E1 itself is clipped.
    Never baked into any array, never stored in the profile -- passed
    transiently into `fit_matrix`/`evaluate`."""
    usable = _GREY_INDEX_ARRAY[~clipped[_GREY_INDEX_ARRAY]]
    if len(usable) == 0:
        raise ValueError("no unclipped grey patches for anchor gain")
    y_toned = linear_after_tone[usable] @ LINEAR_SRGB_TO_XYZ_D65[1]
    y_ref = _Y_REF[usable]
    anchor_pos = np.where(usable == WHITE_INDEX)[0]
    anchor_local_idx = int(anchor_pos[0]) if len(anchor_pos) else None
    return _anchor_gain(y_toned, y_ref, anchor_local_idx)


def apply_tone_gamma(x: np.ndarray, gamma: float, white: float) -> np.ndarray:
    """White-anchored gamma tone stage: `tone(x) = W*(x/W)**g` below W,
    identity at/above it (continuous at W, never moves exposure -- D10).
    Mirrors apply.py's LUT-based runtime version; see AGENTS.md Tone model."""
    ratio = np.clip(x, 0.0, None) / white
    toned = white * ratio ** gamma
    return np.where(x < white, toned, x)


def apply_tone_lut1d(x: np.ndarray, tone: dict) -> np.ndarray:
    """`tone(x) = W*interp(x/W, xs, ys)` below W, identity at/above it --
    the fit-side counterpart of apply.py's LUT-based runtime version for
    the 'lut1d_white_anchored' tone type."""
    white = tone["white"]
    xs = np.asarray(tone["x"], dtype=np.float64)
    ys = np.asarray(tone["y"], dtype=np.float64)
    ratio = np.clip(x, 0.0, None) / white
    toned = white * np.interp(ratio, xs, ys)
    return np.where(x < white, toned, x)


def apply_tone_lut1d_rgb(x: np.ndarray, tone: dict) -> np.ndarray:
    """`tone_c(v) = W_out_c*interp(v/W_c, xs_c, ys_c)` below W_c,
    `W_out_c*(v/W_c)` (continuing the same end slope) at/above it, per
    channel -- the fit-side counterpart of apply.py's per-channel LUT for
    the 'lut1d_rgb_white_anchored' tone type. `white_out` (D11) is the
    anchor's REFERENCE chromaticity with its measured LUMINANCE preserved,
    replacing the pre-D11 identity-at-white behaviour that left every grey
    converging on the anchor's own residual cast instead of the reference;
    falls back to `white` for a profile written before `white_out` existed,
    which reproduces that old behaviour exactly (`w_out == w` collapses
    this to `where(ratio<1, w*interp(ratio), w*ratio) == where(x<w, ..., x)`)."""
    white = tone["white"]
    white_out = tone.get("white_out", white)
    out = np.empty_like(x, dtype=np.float64)
    for c in range(3):
        w = white[c]
        w_out = white_out[c]
        xs = np.asarray(tone["x"][c], dtype=np.float64)
        ys = np.asarray(tone["y"][c], dtype=np.float64)
        ratio = np.clip(x[..., c], 0.0, None) / w
        interp_below = np.interp(ratio, xs, ys)
        out[..., c] = w_out * np.where(ratio < 1.0, interp_below, ratio)
    return out


def apply_tone(linear: np.ndarray, tone: dict) -> np.ndarray:
    """Dispatches on `tone["type"]` between the three tone stages."""
    if tone.get("type") == "lut1d_rgb_white_anchored":
        return apply_tone_lut1d_rgb(linear, tone)
    if tone.get("type") == "lut1d_white_anchored":
        return apply_tone_lut1d(linear, tone)
    return apply_tone_gamma(linear, tone["gamma"], tone["white"])


def _pool_adjacent_violators(y: np.ndarray) -> np.ndarray:
    """Isotonic regression (non-decreasing), pool-adjacent-violators,
    stack-based. `y` must already be sorted by the x it corresponds to."""
    values: list[float] = []
    weights: list[float] = []
    for v in y:
        values.append(float(v))
        weights.append(1.0)
        while len(values) > 1 and values[-2] > values[-1]:
            v2, w2 = values.pop(), weights.pop()
            v1, w1 = values.pop(), weights.pop()
            merged_w = w1 + w2
            values.append((v1 * w1 + v2 * w2) / merged_w)
            weights.append(merged_w)
    out = np.empty(len(y), dtype=np.float64)
    i = 0
    for v, w in zip(values, weights):
        count = int(round(w))
        out[i : i + count] = v
        i += count
    return out


def _golden_section_min(f, lo: float, hi: float, tol: float = 1e-3) -> float:
    a, b = lo, hi
    c = b - _GOLDEN_RATIO * (b - a)
    d = a + _GOLDEN_RATIO * (b - a)
    fc, fd = f(c), f(d)
    while abs(b - a) > tol:
        if fc < fd:
            b, d, fd = d, c, fc
            c = b - _GOLDEN_RATIO * (b - a)
            fc = f(c)
        else:
            a, c, fc = c, d, fd
            d = a + _GOLDEN_RATIO * (b - a)
            fd = f(d)
    return (a + b) / 2.0


def fit_tone_gamma(linear_gained: np.ndarray, clipped: np.ndarray) -> tuple[float, float]:
    """`(gamma, white)` for the white-anchored gamma tone stage, fit by
    directly minimising mean CIEDE2000 (not a closed-form log-log LS --
    that systematically undershot on the real fixture, see AGENTS.md
    report): coarse grid over [0.5, 2.0] step 0.02, then golden-section
    refine on the best bracket to 1e-3. GREYS ONLY (D10 corrective pass --
    never folds in the matrix or the 36 chromatic patches, which is what
    previously let them bend the tone curve away from a correct grey
    mapping). Uses ALL unclipped grey patches (18-29, anchor included --
    no `0<m<1` filter; a grey brighter than the anchor still participates,
    through apply_tone_gamma's `x>=W -> identity` branch). Each gamma
    candidate is scored with `M=I` and its OWN anchored gain (step 4,
    `_anchor_gain`) rather than a fixed one, since the anchor depends on
    the candidate's own toned white value. `white` is the measured white
    level after WB+panel-gain (mean over channels of the E1 anchor patch,
    or the brightest unclipped grey if E1 is clipped)."""
    white = _measure_white(linear_gained, clipped)

    usable = _GREY_INDEX_ARRAY[~clipped[_GREY_INDEX_ARRAY]]
    if len(usable) < 3:
        return 1.0, white

    linear_grey = linear_gained[usable]
    lab_grey = LAB_REFERENCE[usable]
    y_ref_grey = _Y_REF[usable]
    anchor_pos = np.where(usable == WHITE_INDEX)[0]
    anchor_local_idx = int(anchor_pos[0]) if len(anchor_pos) else None

    def objective(gamma: float) -> float:
        toned = apply_tone_gamma(linear_grey, gamma, white)
        y_toned = toned @ LINEAR_SRGB_TO_XYZ_D65[1]
        gain = _anchor_gain(y_toned, y_ref_grey, anchor_local_idx)
        out = gain * toned
        lab_pred = linear_srgb_to_lab_d50(out)
        return float(np.mean(delta_e00(lab_pred, lab_grey)))

    grid_vals = np.array([objective(float(g)) for g in _GAMMA_GRID])
    best_i = int(np.argmin(grid_vals))
    lo = float(_GAMMA_GRID[max(best_i - 1, 0)])
    hi = float(_GAMMA_GRID[min(best_i + 1, len(_GAMMA_GRID) - 1)])
    gamma = _golden_section_min(objective, lo, hi, tol=1e-3)
    return float(gamma), white


def _dedupe_with_tolerance(x: np.ndarray, y: np.ndarray, tol: float) -> tuple[np.ndarray, np.ndarray]:
    """Merge adjacent (already sorted) x-values within `tol` of each other
    into one knot, keeping the pooled MEAN of both x and y -- not just the
    first member, which is what a plain `np.unique` dedupe (the pre-D10
    behaviour) would do and silently drop real signal from a knot that
    lost a near-tie."""
    if len(x) == 0:
        return x, y
    out_x = [float(x[0])]
    sums = [float(y[0])]
    counts = [1]
    for xv, yv in zip(x[1:], y[1:]):
        if xv - out_x[-1] <= tol:
            n = counts[-1]
            out_x[-1] = (out_x[-1] * n + xv) / (n + 1)
            sums[-1] += yv
            counts[-1] += 1
        else:
            out_x.append(float(xv))
            sums.append(float(yv))
            counts.append(1)
    y_mean = [s / c for s, c in zip(sums, counts)]
    return np.array(out_x, dtype=np.float64), np.array(y_mean, dtype=np.float64)


_LUT1D_KNOT_TOL = 1e-4


def _lut1d_candidate_knots(linear_gained: np.ndarray, clipped: np.ndarray) -> tuple[float, np.ndarray, np.ndarray]:
    """The interior knots (excluding the synthetic (0,0)/(1,1) anchors) a
    LUT1D tone fit would use: `x_i = mean_channels(x_i)/W`, `y_i =
    Y_ref_i/Y_ref_E1` for unclipped greys, sorted by x, made monotone by
    isotonic regression (PAVA), tolerance-deduped. A grey measuring at or
    above the anchor (x >= 1 -- e.g. glare/uneven lighting; the real
    fixture's D1/D2) is DROPPED, not clamped -- apply_tone_lut1d only ever
    interpolates below white (identity at/above it, same as the gamma
    stage), so a clamped x=1 knot would collide with and silently replace
    the real (1,1) anchor with that glare patch's own wrong y. Shared by
    `fit_tone_lut1d` (builds the profile dict) and `fit_tone` (decides
    gamma vs lut1d by how many knots survive)."""
    white = _measure_white(linear_gained, clipped)
    anchor = WHITE_INDEX
    usable = _GREY_INDEX_ARRAY[~clipped[_GREY_INDEX_ARRAY]]

    means = linear_gained[usable].mean(axis=1)
    x = means / white
    y = _Y_REF[usable] / _Y_REF[anchor]

    below_white = x < 1.0
    x, y = x[below_white], y[below_white]
    if len(x) == 0:
        return white, x, y

    order = np.argsort(x)
    x_sorted = np.clip(x[order], 0.0, 1.0)
    y_sorted = np.clip(_pool_adjacent_violators(y[order]), 0.0, 1.0)
    x_dedup, y_dedup = _dedupe_with_tolerance(x_sorted, y_sorted, _LUT1D_KNOT_TOL)
    return white, x_dedup, y_dedup


def fit_tone_lut1d(linear_gained: np.ndarray, clipped: np.ndarray) -> dict:
    """`{"type": "lut1d_white_anchored", "white": W, "x": [...], "y": [...]}`
    -- a monotone lookup built from the grey ramps (D10: greys only, see
    `_lut1d_candidate_knots`) instead of a single power curve, so an
    S-shaped response (measured on the real fixture: both ramps compress
    highlights and expand mid-shadows, a shape no single gamma can fit) is
    captured directly. Anchored at (0,0) and (1,1); a knot landing within
    `_LUT1D_KNOT_TOL` of either endpoint (or of another knot) is pooled
    into it rather than left as a separate near-duplicate."""
    white, x_dedup, y_dedup = _lut1d_candidate_knots(linear_gained, clipped)
    if len(x_dedup) == 0:
        return {"type": "lut1d_white_anchored", "white": round(float(white), 6), "x": [0.0, 1.0], "y": [0.0, 1.0]}

    xs = np.concatenate(([0.0], x_dedup, [1.0]))
    ys = np.clip(np.concatenate(([0.0], y_dedup, [1.0])), 0.0, 1.0)
    xs_final, ys_final = _dedupe_with_tolerance(xs, ys, _LUT1D_KNOT_TOL)

    return {
        "type": "lut1d_white_anchored",
        "white": round(float(white), 6),
        "x": [round(float(v), 6) for v in xs_final],
        "y": [round(float(v), 6) for v in ys_final],
    }


_LUT1D_MIN_KNOTS = 6
_LUT1D_RGB_MIN_KNOTS = 6  # per channel


def _lut1d_rgb_candidate_knots(linear_gained: np.ndarray, clipped: np.ndarray) -> tuple[np.ndarray, list, list]:
    """Per-channel counterpart of `_lut1d_candidate_knots`: three
    independent knot sets, one per RGB channel, each anchored on that
    CHANNEL's own white value (`_measure_white_channels`) rather than the
    channel-averaged anchor the single-LUT fit uses. `y_i^c = rref_i^c /
    rref_anchor^c` (D11: each grey's own REFERENCE linear-sRGB channel
    value, ratioed to the anchor's -- NOT a shared luminance ratio) is the
    per-channel target; `x_i` (and so the recovered curve) also differs per
    channel, which is what lets three independent curves absorb a cast
    that varies with luminance where one shared curve cannot. The knots
    alone still land every interior grey on the anchor's own measured
    chromaticity at x=1 (interp is anchored (1,1)) -- `fit_tone_rgb`'s
    `white_out` output scale is what actually redirects that endpoint onto
    the reference chromaticity; see its docstring. Same glare exclusion
    (x_i < 1, dropped not clamped) and PAVA isotonic step as the
    single-LUT fit, per channel."""
    white = _measure_white_channels(linear_gained, clipped)
    anchor = _anchor_index(linear_gained, clipped)
    rref_anchor = _RREF[anchor]
    usable = _GREY_INDEX_ARRAY[~clipped[_GREY_INDEX_ARRAY]]

    xs_channels, ys_channels = [], []
    for c in range(3):
        x = linear_gained[usable, c] / white[c]
        y = _RREF[usable, c] / rref_anchor[c]
        below_white = x < 1.0
        x, y = x[below_white], y[below_white]
        if len(x) == 0:
            xs_channels.append(x)
            ys_channels.append(y)
            continue
        # 'stable' (not the default 'quicksort'): a channel can genuinely
        # tie two greys at the same measured ratio (seen on the real
        # fixture -- two D-ramp patches landing on an identical raw value
        # for one channel only). An unstable sort leaves the tie order,
        # and so which values PAVA pools together, to chance.
        order = np.argsort(x, kind="stable")
        x_sorted = np.clip(x[order], 0.0, 1.0)
        y_sorted = np.clip(_pool_adjacent_violators(y[order]), 0.0, 1.0)
        x_dedup, y_dedup = _dedupe_with_tolerance(x_sorted, y_sorted, _LUT1D_KNOT_TOL)
        xs_channels.append(x_dedup)
        ys_channels.append(y_dedup)
    return white, xs_channels, ys_channels


def fit_tone_rgb(linear_gained: np.ndarray, clipped: np.ndarray) -> dict:
    """`{"type": "lut1d_rgb_white_anchored", "white": [Wr,Wg,Wb],
    "white_out": [Wr_out,Wg_out,Wb_out], "x": [[...],[...],[...]], "y":
    [[...],[...],[...]]}` -- three independent white-anchored LUTs, one
    per channel, each anchored (0,0)/(1,1) on its own measured white `white`.
    Grey a/b did not fully neutralise under a single shared-luminance curve
    because the cast varies with luminance (measured on the real fixture:
    D1 dE00 15.2, D2 11.9, E1 10.4); mapping each channel onto its own
    reference RATIO (`_lut1d_rgb_candidate_knots`'s `rref_i/rref_anchor`)
    fixes the SHAPE of the curve.

    That alone still anchors every channel's own measured white value to
    itself (the synthetic (1,1) endpoint), so the anchor patch keeps
    whatever residual cast it measured -- every grey converges onto THAT
    cast, not onto the reference (the structural defect this D11 pass
    fixes). `white_out` corrects this at the OUTPUT: `W_out_c =
    mean_c(W_c) * rref_anchor^c / mean_c(rref_anchor^c)` preserves the
    anchor's measured LUMINANCE (`mean_c(W_c)`, exposure untouched, D10)
    while replacing its CHROMATICITY with the reference's. Applied by
    `apply_tone_lut1d_rgb`/apply.py's `_tone_lut_1d_rgb` as an output
    multiplier on the whole per-channel LUT (below AND above white, same
    end slope), which makes every unclipped, non-excluded grey map to
    `k * rref_i` for one shared scalar k -- exactly the reference Lab
    after the fit-only anchored gain. A profile written before `white_out`
    existed has none; `apply_tone_lut1d_rgb`/apply.py fall back to `white`,
    reproducing the pre-D11 (self-anchored) behaviour exactly."""
    white, xs_channels, ys_channels = _lut1d_rgb_candidate_knots(linear_gained, clipped)
    xs_final, ys_final = [], []
    for x_dedup, y_dedup in zip(xs_channels, ys_channels):
        if len(x_dedup) == 0:
            xs_final.append([0.0, 1.0])
            ys_final.append([0.0, 1.0])
            continue
        xs = np.concatenate(([0.0], x_dedup, [1.0]))
        ys = np.clip(np.concatenate(([0.0], y_dedup, [1.0])), 0.0, 1.0)
        xs_c, ys_c = _dedupe_with_tolerance(xs, ys, _LUT1D_KNOT_TOL)
        xs_final.append([round(float(v), 6) for v in xs_c])
        ys_final.append([round(float(v), 6) for v in ys_c])

    anchor = _anchor_index(linear_gained, clipped)
    rref_anchor = _RREF[anchor]
    mean_white = float(np.mean(white))
    mean_rref_anchor = float(np.mean(rref_anchor))
    white_out = mean_white * rref_anchor / mean_rref_anchor

    return {
        "type": "lut1d_rgb_white_anchored",
        "white": [round(float(w), 6) for w in white],
        "white_out": [round(float(w), 6) for w in white_out],
        "x": xs_final,
        "y": ys_final,
    }


def fit_tone(linear_gained: np.ndarray, clipped: np.ndarray) -> dict:
    """Dispatcher: the per-channel RGB LUT when at least
    `_LUT1D_RGB_MIN_KNOTS` usable knots survive clipping AND the x>=1
    glare drop on EVERY channel (it recovers a luminance-varying cast the
    other two types cannot, by construction); else the single-luminance
    LUT (general monotone shape) when at least `_LUT1D_MIN_KNOTS` knots
    survive; else the ΔE00-fitted gamma curve (too few points to support
    a LUT without overfitting noise). Greys only, always (D10) -- the
    matrix and chromatic patches never enter any of the three fits."""
    _, xs_channels, _ = _lut1d_rgb_candidate_knots(linear_gained, clipped)
    if all(len(x) >= _LUT1D_RGB_MIN_KNOTS for x in xs_channels):
        return fit_tone_rgb(linear_gained, clipped)
    _, x_dedup, _ = _lut1d_candidate_knots(linear_gained, clipped)
    if len(x_dedup) >= _LUT1D_MIN_KNOTS:
        return fit_tone_lut1d(linear_gained, clipped)
    gamma, white = fit_tone_gamma(linear_gained, clipped)
    return {"type": "gamma_white_anchored", "gamma": gamma, "white": white}


def _matrix_from_params(params: np.ndarray) -> np.ndarray:
    m00, m01, m10, m11, m20, m21 = params
    return np.array(
        [
            [m00, m01, 1.0 - m00 - m01],
            [m10, m11, 1.0 - m10 - m11],
            [m20, m21, 1.0 - m20 - m21],
        ],
        dtype=np.float64,
    )


def _mean_de00(params: np.ndarray, linear_wb_usable: np.ndarray, lab_usable: np.ndarray, gain: float) -> float:
    matrix = _matrix_from_params(params)
    out = gain * (linear_wb_usable @ matrix.T)
    lab_pred = linear_srgb_to_lab_d50(out)
    return float(np.mean(delta_e00(lab_pred, lab_usable)))


def _nelder_mead(f, p0: np.ndarray):
    n = len(p0)
    simplex = np.vstack([p0] + [p0 + (_INITIAL_STEP * np.eye(n)[i]) for i in range(n)])
    fvals = np.array([f(p) for p in simplex])

    iterations = 0
    converged = False
    for iterations in range(1, _MAX_ITERATIONS + 1):
        order = np.argsort(fvals)
        simplex, fvals = simplex[order], fvals[order]

        if np.max(np.abs(fvals - fvals[0])) < _F_TOL and np.max(
            np.linalg.norm(simplex - simplex[0], axis=1)
        ) < _X_TOL:
            converged = True
            break

        centroid = simplex[:-1].mean(axis=0)
        worst_f = fvals[-1]

        xr = centroid + _ALPHA * (centroid - simplex[-1])
        fr = f(xr)
        if fvals[0] <= fr < fvals[-2]:
            simplex[-1], fvals[-1] = xr, fr
            continue
        if fr < fvals[0]:
            xe = centroid + _GAMMA * (xr - centroid)
            fe = f(xe)
            if fe < fr:
                simplex[-1], fvals[-1] = xe, fe
            else:
                simplex[-1], fvals[-1] = xr, fr
            continue

        xc = centroid + _RHO * (simplex[-1] - centroid)
        fc = f(xc)
        if fc < worst_f:
            simplex[-1], fvals[-1] = xc, fc
            continue

        best_point = simplex[0]
        for i in range(1, len(simplex)):
            simplex[i] = best_point + _SIGMA * (simplex[i] - best_point)
            fvals[i] = f(simplex[i])

    order = np.argsort(fvals)
    simplex, fvals = simplex[order], fvals[order]
    return simplex[0], float(fvals[0]), iterations, converged


def fit_matrix(linear_wb: np.ndarray, clipped: np.ndarray, gain: float) -> tuple[np.ndarray, dict]:
    usable_mask = ~clipped
    linear_wb_usable = linear_wb[usable_mask]
    lab_usable = LAB_REFERENCE[usable_mask]

    def objective(params: np.ndarray) -> float:
        return _mean_de00(params, linear_wb_usable, lab_usable, gain)

    identity_params = np.array([1.0, 0.0, 0.0, 1.0, 0.0, 0.0], dtype=np.float64)
    identity_mean_de00 = objective(identity_params)

    target_linear = np.clip(lab_d50_to_linear_srgb(lab_usable), 0.0, None)
    seed_coeffs, *_ = np.linalg.lstsq(gain * linear_wb_usable, target_linear, rcond=None)
    seed_matrix = seed_coeffs.T
    row_sums = seed_matrix.sum(axis=1, keepdims=True)
    row_sums = np.where(row_sums == 0, 1.0, row_sums)
    seed_matrix = seed_matrix / row_sums
    seed_params = np.array(
        [seed_matrix[0, 0], seed_matrix[0, 1], seed_matrix[1, 0], seed_matrix[1, 1], seed_matrix[2, 0], seed_matrix[2, 1]],
        dtype=np.float64,
    )
    seed_mean_de00 = objective(seed_params)

    # Start Nelder-Mead from whichever of {identity, seed} is already
    # better -- the lstsq seed can itself be a worse starting point than
    # doing nothing (measured on the real fixture before this fix:
    # WB+matrix landed at 7.73 mean dE00, WORSE than WB alone at 6.70).
    start_params = identity_params if identity_mean_de00 <= seed_mean_de00 else seed_params

    nm_params, nm_f, iterations, converged = _nelder_mead(objective, start_params)

    # Never lose to identity: the returned matrix is the best of all three
    # candidates the fit produced along the way, not just "NM vs seed".
    candidates = [
        (identity_mean_de00, identity_params),
        (seed_mean_de00, seed_params),
        (nm_f, nm_params),
    ]
    final_mean_de00, final_params = min(candidates, key=lambda c: c[0])

    matrix = _matrix_from_params(final_params)
    info = {
        "iterations": iterations,
        "seed_mean_de00": seed_mean_de00,
        "identity_mean_de00": identity_mean_de00,
        "converged": converged,
        "final_mean_de00": final_mean_de00,
    }
    return matrix, info


def evaluate(linear_wb: np.ndarray, matrix: np.ndarray, gain: float) -> np.ndarray:
    """Per-patch CIEDE2000 for all 48 patches (clipped patches included --
    the fit excludes them, reporting does not)."""
    out = gain * (linear_wb @ matrix.T)
    lab_pred = linear_srgb_to_lab_d50(out)
    return delta_e00(lab_pred, LAB_REFERENCE)

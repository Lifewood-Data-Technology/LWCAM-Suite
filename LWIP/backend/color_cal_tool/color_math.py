"""Colour-space maths shared by the calibration fit: sRGB <-> linear,
Lab(D50) <-> XYZ(D50) <-> linear sRGB(D65) via Bradford adaptation, and
CIEDE2000 (Sharma 2005). All functions take/return `(..., 3)` float64
arrays; nothing here touches the calibration target's pixels.
"""

from __future__ import annotations

import numpy as np

# --- sRGB transfer function --------------------------------------------

def srgb_decode(v):
    """sRGB gamma-encoded [0,1] -> linear light. Input is clipped to [0,1]
    first -- this is a transfer function, not a gamut mapper."""
    v = np.clip(np.asarray(v, dtype=np.float64), 0.0, 1.0)
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)


def srgb_encode(v):
    """Linear light -> sRGB gamma-encoded [0,1]. Input is clipped to [0,1]
    first."""
    v = np.clip(np.asarray(v, dtype=np.float64), 0.0, 1.0)
    return np.where(v <= 0.0031308, 12.92 * v, 1.055 * v ** (1 / 2.4) - 0.055)


# --- constants -----------------------------------------------------------

D50_WHITE = np.array([0.96422, 1.0, 0.82521], dtype=np.float64)
LAB_EPS = 216.0 / 24389.0
LAB_KAPPA = 24389.0 / 27.0

BRADFORD_D50_TO_D65 = np.array(
    [
        [0.9555766, -0.0230393, 0.0631636],
        [-0.0282895, 1.0099416, 0.0210077],
        [0.0122982, -0.0204830, 1.3299098],
    ],
    dtype=np.float64,
)
BRADFORD_D65_TO_D50 = np.array(
    [
        [1.0478112, 0.0228866, -0.0501270],
        [0.0295424, 0.9904844, -0.0170491],
        [-0.0092345, 0.0150436, 0.7521316],
    ],
    dtype=np.float64,
)
XYZ_D65_TO_LINEAR_SRGB = np.array(
    [
        [3.2404542, -1.5371385, -0.4985314],
        [-0.9692660, 1.8760108, 0.0415560],
        [0.0556434, -0.2040259, 1.0572252],
    ],
    dtype=np.float64,
)
LINEAR_SRGB_TO_XYZ_D65 = np.array(
    [
        [0.4124564, 0.3575761, 0.1804375],
        [0.2126729, 0.7151522, 0.0721750],
        [0.0193339, 0.1191920, 0.9503041],
    ],
    dtype=np.float64,
)


def _apply3x3(matrix: np.ndarray, values) -> np.ndarray:
    values = np.asarray(values, dtype=np.float64)
    return values @ matrix.T


# --- Lab(D50) <-> XYZ(D50) -------------------------------------------------

def lab_to_xyz_d50(lab) -> np.ndarray:
    lab = np.asarray(lab, dtype=np.float64)
    L, a, b = lab[..., 0], lab[..., 1], lab[..., 2]
    fy = (L + 16.0) / 116.0
    fx = fy + a / 500.0
    fz = fy - b / 200.0

    fx3 = fx ** 3
    fz3 = fz ** 3
    x = np.where(fx3 > LAB_EPS, fx3, (116.0 * fx - 16.0) / LAB_KAPPA)
    y = np.where(L > LAB_KAPPA * LAB_EPS, ((L + 16.0) / 116.0) ** 3, L / LAB_KAPPA)
    z = np.where(fz3 > LAB_EPS, fz3, (116.0 * fz - 16.0) / LAB_KAPPA)

    xyz = np.stack([x, y, z], axis=-1) * D50_WHITE
    return xyz


def xyz_d50_to_lab(xyz) -> np.ndarray:
    xyz = np.asarray(xyz, dtype=np.float64)
    xyz_r = xyz / D50_WHITE

    def f(t):
        return np.where(t > LAB_EPS, np.cbrt(t), (LAB_KAPPA * t + 16.0) / 116.0)

    fx = f(xyz_r[..., 0])
    fy = f(xyz_r[..., 1])
    fz = f(xyz_r[..., 2])

    L = 116.0 * fy - 16.0
    a = 500.0 * (fx - fy)
    b = 200.0 * (fy - fz)
    return np.stack([L, a, b], axis=-1)


# --- Lab(D50) <-> linear sRGB(D65), via Bradford adaptation ---------------

def lab_d50_to_linear_srgb(lab) -> np.ndarray:
    """No clipping -- an out-of-gamut Lab legitimately maps outside [0,1].
    Callers clip a seed target or the final apply output, never this."""
    xyz_d50 = lab_to_xyz_d50(lab)
    xyz_d65 = _apply3x3(BRADFORD_D50_TO_D65, xyz_d50)
    return _apply3x3(XYZ_D65_TO_LINEAR_SRGB, xyz_d65)


def linear_srgb_to_lab_d50(rgb) -> np.ndarray:
    xyz_d65 = _apply3x3(LINEAR_SRGB_TO_XYZ_D65, rgb)
    xyz_d50 = _apply3x3(BRADFORD_D65_TO_D50, xyz_d65)
    return xyz_d50_to_lab(xyz_d50)


# --- CIEDE2000 (Sharma 2005) ----------------------------------------------

def delta_e00(lab1, lab2, *, kL: float = 1.0, kC: float = 1.0, kH: float = 1.0) -> np.ndarray:
    """Vectorised CIEDE2000 colour difference, `(..., 3)` -> `(...,)`.
    Degrees throughout; handles the +-360 hue wrap and the RT rotation term.
    """
    lab1 = np.asarray(lab1, dtype=np.float64)
    lab2 = np.asarray(lab2, dtype=np.float64)
    L1, a1, b1 = lab1[..., 0], lab1[..., 1], lab1[..., 2]
    L2, a2, b2 = lab2[..., 0], lab2[..., 1], lab2[..., 2]

    C1 = np.hypot(a1, b1)
    C2 = np.hypot(a2, b2)
    Cbar = (C1 + C2) / 2.0
    Cbar7 = Cbar ** 7
    G = 0.5 * (1.0 - np.sqrt(Cbar7 / (Cbar7 + 25.0 ** 7)))

    a1p = (1.0 + G) * a1
    a2p = (1.0 + G) * a2
    C1p = np.hypot(a1p, b1)
    C2p = np.hypot(a2p, b2)

    h1p = np.degrees(np.arctan2(b1, a1p)) % 360.0
    h2p = np.degrees(np.arctan2(b2, a2p)) % 360.0

    dLp = L2 - L1
    dCp = C2p - C1p

    dhp_raw = h2p - h1p
    dhp = np.where(np.abs(dhp_raw) <= 180.0, dhp_raw, dhp_raw - np.sign(dhp_raw) * 360.0)
    dhp = np.where((C1p * C2p) == 0.0, 0.0, dhp)
    dHp = 2.0 * np.sqrt(C1p * C2p) * np.sin(np.radians(dhp / 2.0))

    Lbarp = (L1 + L2) / 2.0
    Cbarp = (C1p + C2p) / 2.0

    hsum = h1p + h2p
    habs = np.abs(h1p - h2p)
    hbarp = np.where(
        (C1p * C2p) == 0.0,
        hsum,
        np.where(habs <= 180.0, hsum / 2.0, np.where(hsum < 360.0, (hsum + 360.0) / 2.0, (hsum - 360.0) / 2.0)),
    )

    T = (
        1.0
        - 0.17 * np.cos(np.radians(hbarp - 30.0))
        + 0.24 * np.cos(np.radians(2.0 * hbarp))
        + 0.32 * np.cos(np.radians(3.0 * hbarp + 6.0))
        - 0.20 * np.cos(np.radians(4.0 * hbarp - 63.0))
    )

    dtheta = 30.0 * np.exp(-(((hbarp - 275.0) / 25.0) ** 2))
    Cbarp7 = Cbarp ** 7
    Rc = 2.0 * np.sqrt(Cbarp7 / (Cbarp7 + 25.0 ** 7))
    Sl = 1.0 + (0.015 * (Lbarp - 50.0) ** 2) / np.sqrt(20.0 + (Lbarp - 50.0) ** 2)
    Sc = 1.0 + 0.045 * Cbarp
    Sh = 1.0 + 0.015 * Cbarp * T
    Rt = -np.sin(np.radians(2.0 * dtheta)) * Rc

    termL = dLp / (kL * Sl)
    termC = dCp / (kC * Sc)
    termH = dHp / (kH * Sh)

    return np.sqrt(termL ** 2 + termC ** 2 + termH ** 2 + Rt * termC * termH)

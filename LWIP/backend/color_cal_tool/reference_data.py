"""Reference geometry and Lab values for the Datacolor SpyderCheckr Photo (48
patches). These are FACTS about the physical chart, verified against
darktable's `src/common/colorchecker.h` (`spyder_photo` entry) -- no
darktable code, comments or structure copied, only the numbers a physical
ruler and a spectrophotometer would also produce (GPL covers expression, not
facts). See AGENTS.md D7.
"""

from __future__ import annotations

from typing import NamedTuple

import numpy as np

TARGET_ID = "datacolor_spydercheckr_photo_48"

# 8 columns (A-H) x 6 rows (1-6), COLUMN-MAJOR: index = col * 6 + row.
# A1 = 0, A6 = 5, B1 = 6, ..., H6 = 47.
COLUMN_X = (0.068, 0.168, 0.268, 0.368, 0.632, 0.732, 0.832, 0.932)
ROW_Y = (0.146, 0.288, 0.429, 0.571, 0.712, 0.854)

# height / width of the reference-dot frame.
FRAME_RATIO = 106.0 / 150.0
# Half patch size, as a fraction of the canonical frame HEIGHT.
PATCH_RADIUS = 0.059

# Grey ramps. D = idx 18-23 (L 92.72 -> 25.65), E = idx 24-29 (L 96.04 ->
# 16.91). Column B (idx 6-11) is a TINTED near-neutral ramp -- not for white
# balance, only D/E are.
GREY_INDICES = range(18, 30)
WHITE_INDEX = 24  # E1
BLACK_INDEX = 29  # E6

# idx  name    L       a       b
_LAB_ROWS = (
    (61.35, 34.81, 18.38),  # 0  A1
    (75.50, 5.84, 50.42),  # 1  A2
    (66.82, -25.10, 23.47),  # 2  A3
    (60.53, -22.62, -20.40),  # 3  A4
    (59.66, -2.03, -28.46),  # 4  A5
    (59.15, 30.83, -5.72),  # 5  A6
    (82.68, 5.03, 3.02),  # 6  B1
    (82.25, -2.42, 3.78),  # 7  B2
    (82.29, 2.20, -2.04),  # 8  B3
    (24.89, 4.43, 0.78),  # 9  B4
    (25.16, -3.88, 2.13),  # 10 B5
    (26.13, 2.61, -5.03),  # 11 B6
    (85.42, 9.41, 14.49),  # 12 C1
    (74.28, 9.05, 27.21),  # 13 C2
    (64.57, 12.39, 37.24),  # 14 C3
    (44.49, 17.23, 26.24),  # 15 C4
    (25.29, 7.95, 8.87),  # 16 C5
    (22.67, 2.11, -1.10),  # 17 C6
    (92.72, 1.89, 2.76),  # 18 D1
    (88.85, 1.59, 2.27),  # 19 D2
    (73.42, 0.99, 1.89),  # 20 D3
    (57.15, 0.57, 1.19),  # 21 D4
    (41.57, 0.24, 1.45),  # 22 D5
    (25.65, 1.24, 0.05),  # 23 D6
    (96.04, 2.16, 2.60),  # 24 E1
    (80.44, 1.17, 2.05),  # 25 E2
    (65.52, 0.69, 1.86),  # 26 E3
    (49.62, 0.58, 1.56),  # 27 E4
    (33.55, 0.35, 1.40),  # 28 E5
    (16.91, 1.43, -0.81),  # 29 E6
    (47.12, -32.52, -28.75),  # 30 F1
    (50.49, 53.45, -13.55),  # 31 F2
    (83.61, 3.36, 87.02),  # 32 F3
    (41.05, 60.75, 31.17),  # 33 F4
    (54.14, -40.76, 34.75),  # 34 F5
    (24.75, 13.78, -49.48),  # 35 F6
    (60.94, 38.21, 61.31),  # 36 G1
    (37.80, 7.30, -43.04),  # 37 G2
    (49.81, 48.50, 15.76),  # 38 G3
    (28.88, 19.36, -24.48),  # 39 G4
    (72.45, -23.57, 60.47),  # 40 G5
    (71.65, 23.74, 72.28),  # 41 G6
    (70.19, -31.85, 1.98),  # 42 H1
    (54.38, 8.84, -25.71),  # 43 H2
    (42.03, -15.78, 22.93),  # 44 H3
    (48.82, -5.11, -23.08),  # 45 H4
    (65.10, 18.14, 18.68),  # 46 H5
    (36.13, 14.15, 15.78),  # 47 H6
)

LAB_REFERENCE = np.array(_LAB_ROWS, dtype=np.float64)


class Patch(NamedTuple):
    name: str
    lab: tuple[float, float, float]
    x: float
    y: float


def _patch(index: int) -> Patch:
    col, row = divmod(index, 6)
    name = "ABCDEFGH"[col] + str(row + 1)
    lab = _LAB_ROWS[index]
    return Patch(name=name, lab=lab, x=COLUMN_X[col], y=ROW_Y[row])


PATCHES: tuple[Patch, ...] = tuple(_patch(i) for i in range(48))


def verify() -> None:
    """Sanity-checks the constants above against themselves. Cheap, and run
    at the start of every calibration (`calibrate.calibrate`) so a typo in
    this module is caught before it burns a chart photo."""
    assert len(PATCHES) == 48, f"expected 48 patches, got {len(PATCHES)}"
    assert LAB_REFERENCE.shape == (48, 3)

    for i, patch in enumerate(PATCHES):
        col, row = divmod(i, 6)
        expected_name = "ABCDEFGH"[col] + str(row + 1)
        assert patch.name == expected_name, (i, patch.name, expected_name)
        assert patch.x == COLUMN_X[col]
        assert patch.y == ROW_Y[row]
        assert tuple(LAB_REFERENCE[i]) == patch.lab

    grey = LAB_REFERENCE[list(GREY_INDICES)]
    assert np.all(np.abs(grey[:, 1]) < 3.0), "grey ramp |a| exceeds 3"
    assert np.all(np.abs(grey[:, 2]) < 3.0), "grey ramp |b| exceeds 3"

    d_ramp = LAB_REFERENCE[18:24, 0]
    e_ramp = LAB_REFERENCE[24:30, 0]
    assert np.all(np.diff(d_ramp) < 0), "D ramp L is not strictly decreasing"
    assert np.all(np.diff(e_ramp) < 0), "E ramp L is not strictly decreasing"

    assert LAB_REFERENCE[24, 0] == 96.04, LAB_REFERENCE[24, 0]


if __name__ == "__main__":
    verify()
    print("reference_data: ok, 48 patches")

"""geometry_replay: copy parity, wrapper compatibility, and the matfill op."""

from __future__ import annotations

import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

import numpy as np
from PIL import Image

from app.services import geometry_ops, geometry_replay
from app.services.export import convert_to_tiff
from app.services.geometry_replay import replay_pending_ops

try:
    import cv2
except ImportError:  # pragma: no cover
    cv2 = None

DESKEW = 3.0
CROP_ALL = [0.0, 0.0, 1.0, 1.0]  # the whole expanded frame, wedges included


def _photo(width: int, height: int, seed: int = 1) -> Image.Image:
    """Mat (noisy, brighter to the right) with a bright page well inside it."""
    rng = np.random.default_rng(seed)
    xs = np.linspace(70, 110, width)[None, :, None]
    arr = np.broadcast_to(xs, (height, width, 3)) + rng.normal(0, 4, (height, width, 3))
    arr = np.clip(arr, 40, 255).astype(np.uint8)
    margin_x, margin_y = int(width * 0.12), int(height * 0.12)
    arr[margin_y:height - margin_y, margin_x:width - margin_x] = 215
    return Image.fromarray(arr, "RGB")


def _safe_valid(size: tuple[int, int], ops: list[dict]) -> np.ndarray:
    """Pixels certainly real after [ops]: a white frame replayed without
    matfill, eroded past the Lanczos reach."""
    white = Image.new("RGB", size, (255, 255, 255))
    out = np.asarray(replay_pending_ops(white, [o for o in ops if o["op"] != "matfill"]))
    return cv2.erode((out.min(axis=2) == 255).astype(np.uint8), np.ones((11, 11), np.uint8)) > 0


class CopyParityTests(unittest.TestCase):
    def test_copies_match(self) -> None:
        """The module ships inside QC and LWIP; they must not drift."""
        repo = Path(__file__).resolve().parents[3]
        mine = Path(geometry_replay.__file__).read_bytes()
        other = repo / "LWIP" / "backend" / "deskew_crop_tool" / "geometry_replay.py"
        if not other.is_file():
            self.skipTest(f"{other} is not checked out here")
        self.assertEqual(other.read_bytes(), mine, f"{other} differs")


class WrapperTests(unittest.TestCase):
    def test_wrapper_is_the_shared_module(self) -> None:
        self.assertIs(geometry_ops.replay_pending_ops, geometry_replay.replay_pending_ops)
        self.assertTrue(callable(geometry_ops._rotate_cv2_lanczos))

    def test_existing_ops(self) -> None:
        frame = _photo(200, 120)
        self.assertEqual(replay_pending_ops(frame, [{"op": "rotate", "degrees": 90}]).size, (120, 200))
        self.assertEqual(
            replay_pending_ops(frame, [{"op": "rotate", "degrees": 90}]).tobytes(),
            frame.rotate(-90, expand=True).tobytes(),
        )
        cropped = replay_pending_ops(frame, [{"op": "crop", "rect": [0.1, 0.25, 0.6, 0.75]}])
        self.assertEqual(cropped.size, (100, 60))
        skewed = replay_pending_ops(frame, [{"op": "deskew", "degrees": 2.0}])
        self.assertEqual(skewed.size, frame.rotate(-2.0, expand=True).size)
        # unknown ops / bad values are skipped silently
        junk = [{"op": "wat"}, {"op": "crop", "rect": [1]}, {"op": "rotate", "degrees": "x"}, {}]
        self.assertEqual(replay_pending_ops(frame, junk).tobytes(), frame.tobytes())


@unittest.skipIf(cv2 is None, "cv2 required")
class MatFillTests(unittest.TestCase):
    def _check(self, width: int, height: int) -> None:
        frame = _photo(width, height)
        base = [{"op": "deskew", "degrees": DESKEW}, {"op": "crop", "rect": CROP_ALL}]
        plain = np.asarray(replay_pending_ops(frame, base))
        filled = np.asarray(replay_pending_ops(frame, base + [{"op": "matfill"}]))
        self.assertEqual(plain.shape, filled.shape)
        black_before = int((plain.max(axis=2) == 0).sum())
        self.assertGreater(black_before, 100, "test image must expose wedges")
        self.assertEqual(int((filled.max(axis=2) == 0).sum()), 0, "black wedge left")
        safe = _safe_valid(frame.size, base)
        self.assertTrue(np.array_equal(filled[safe], plain[safe]), "a real pixel was modified")
        # the fill is mat-like, not page-bright
        void = ~safe & (plain.max(axis=2) == 0)
        self.assertLess(float(filled[void].mean()), 150)

    def test_preview_size(self) -> None:
        self._check(1600, 1200)

    def test_thumbnail_size(self) -> None:
        self._check(512, 384)

    def test_full_size(self) -> None:
        self._check(4000, 5500)

    def test_no_void_is_identical(self) -> None:
        frame = _photo(400, 300)
        for ops in ([{"op": "crop", "rect": [0.2, 0.2, 0.8, 0.8]}],
                    [{"op": "rotate", "degrees": 90}],
                    [{"op": "deskew", "degrees": DESKEW}, {"op": "crop", "rect": [0.2, 0.2, 0.8, 0.8]}]):
            a = replay_pending_ops(frame, ops)
            b = replay_pending_ops(frame, ops + [{"op": "matfill"}])
            self.assertEqual(a.tobytes(), b.tobytes(), ops)

    def test_matfill_without_deskew_is_noop(self) -> None:
        frame = _photo(100, 80)
        self.assertEqual(replay_pending_ops(frame, [{"op": "matfill"}]).tobytes(), frame.tobytes())

    def test_matfill_then_rotate(self) -> None:
        frame = _photo(800, 600)
        ops = [{"op": "deskew", "degrees": DESKEW}, {"op": "crop", "rect": CROP_ALL},
               {"op": "matfill"}, {"op": "rotate", "degrees": 90}]
        out = replay_pending_ops(frame, ops)
        self.assertEqual(int((np.asarray(out).max(axis=2) == 0).sum()), 0)

    def test_grayscale_frame(self) -> None:
        frame = _photo(800, 600).convert("L")
        ops = [{"op": "deskew", "degrees": DESKEW}, {"op": "crop", "rect": CROP_ALL}, {"op": "matfill"}]
        out = replay_pending_ops(frame, ops)
        self.assertEqual(out.mode, "L")
        self.assertEqual(int((np.asarray(out) == 0).sum()), 0)

    def test_without_cv2_wedges_stay_black(self) -> None:
        frame = _photo(600, 450)
        ops = [{"op": "deskew", "degrees": DESKEW}, {"op": "crop", "rect": CROP_ALL}]
        with patch.object(geometry_replay, "cv2", None), patch.object(
            geometry_replay, "_matfill_unavailable_logged", False
        ), patch.object(geometry_replay, "_cv2_unavailable_logged", False):
            with self.assertLogs(geometry_replay.logger, "WARNING"):
                plain = replay_pending_ops(frame, ops)
                out = replay_pending_ops(frame, ops + [{"op": "matfill"}])
        self.assertEqual(plain.tobytes(), out.tobytes())
        self.assertGreater(int((np.asarray(out).max(axis=2) == 0).sum()), 50)

    def test_export_tiff_has_no_wedge(self) -> None:
        with TemporaryDirectory() as tmp:
            source = Path(tmp) / "page.jpg"
            _photo(800, 600).save(source, quality=95)
            target = Path(tmp) / "page.tif"
            ops = [{"op": "deskew", "degrees": DESKEW}, {"op": "crop", "rect": CROP_ALL}, {"op": "matfill"}]
            width, height = convert_to_tiff(source, target, ops)
            with Image.open(target) as result:
                arr = np.asarray(result.convert("RGB"))
            self.assertEqual(arr.shape[:2], (height, width))
            self.assertEqual(int((arr.max(axis=2) == 0).sum()), 0)


if __name__ == "__main__":
    unittest.main()

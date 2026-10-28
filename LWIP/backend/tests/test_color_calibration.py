import hashlib
import json
import tempfile
import unittest
from pathlib import Path
import numpy as np
from PIL import Image
from color_cal_tool.apply import apply_profile_to_pil
from color_cal_tool.contract import profile_for, CalibrationError
from deskew_crop_tool.image_ops import _write_thumbnail_atomic


class CalibrationTests(unittest.TestCase):
    def test_thumbnail_changes_without_mutating_input(self):
        p = {'working_space': 'linear_srgb_d65', 'white_balance': [1.4, 1, .7],
             'correction': {'type': 'matrix3x3', 'matrix': [[1,0,0],[0,1,0],[0,0,1]]}}
        image = np.full((32, 32, 3), 120, dtype=np.uint8)
        before = image.copy()
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'thumb.jpg'
            _write_thumbnail_atomic(out, image, max_width=32, quality=100, color_profile=p)
            with Image.open(out) as thumb:
                expected = np.asarray(apply_profile_to_pil(Image.fromarray(image), p), dtype=int)
                self.assertLessEqual(np.abs(np.asarray(thumb, dtype=int) - expected).max(), 2)
        np.testing.assert_array_equal(image, before)

    def test_calibration_change_invalidates_unchanged_images(self):
        from tests.test_round2 import _config, _jpeg
        from deskew_crop_tool.orchestrator import build_snapshot
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            folder = root / 'incoming' / 'job'
            folder.mkdir(parents=True)
            _jpeg(folder / 'a.jpg')
            marker = folder / 'marker.json'
            value = {'color_calibration': {'version': 1, 'profiles': {},
                     'images': {'a.jpg': {'profile': None, 'reason': 'skipped'}}}}
            marker.write_text(json.dumps(value))
            config = _config(root, marker='marker.json')
            first = build_snapshot(folder, config)
            value['color_calibration']['images']['a.jpg']['reason'] = 'disabled'
            marker.write_text(json.dumps(value))
            second = build_snapshot(folder, config)
            self.assertEqual(first.files, second.files)
            self.assertNotEqual(first.fingerprint, second.fingerprint)
            self.assertNotEqual(first.calibration_digest, second.calibration_digest)

    def test_consumer_copies_match_capture_tool(self):
        root = Path(__file__).resolve().parents[3]
        for name in ('__init__.py', 'apply.py', 'profile.py', 'reference_data.py', 'contract.py'):
            canonical = (root / 'LWIP/backend/color_cal_tool' / name).read_bytes()
            for consumer in ('LWCam_QC_Platform',):
                self.assertEqual(canonical, (root / consumer / 'backend/color_cal_tool' / name).read_bytes())


if __name__ == '__main__':
    unittest.main()

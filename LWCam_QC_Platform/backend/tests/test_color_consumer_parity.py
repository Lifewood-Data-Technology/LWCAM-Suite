"""QC must verify its own shipped colour consumer independently of LWIP tests."""
from pathlib import Path
import unittest


class ColorConsumerParityTests(unittest.TestCase):
    def test_consumer_matches_lwip(self):
        root = Path(__file__).resolve().parents[3]
        for name in ('__init__.py', 'apply.py', 'profile.py',
                     'reference_data.py', 'contract.py'):
            with self.subTest(file=name):
                self.assertEqual(
                    (root / 'LWIP/backend/color_cal_tool' / name).read_bytes(),
                    (root / 'LWCam_QC_Platform/backend/color_cal_tool' / name).read_bytes())


if __name__ == '__main__':
    unittest.main()

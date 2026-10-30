import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np
from PIL import Image

from color_cal_tool.apply import apply_profile_to_pil
from color_cal_tool.contract import CalibrationError, profile_for, subset
from app.services.export import convert_to_jpeg, convert_to_tiff, verify_sources_unchanged, ImageSource, ExportError
from app.services.page_calibration import effective_profile
from app.services.previews import generate_preview_image, preview_cache_path
from app.services.qc_ops_store import write_qc_ops
from app.services.qc_separation import child_manifest


def profile():
    return {'schema_version': 1, 'profile_id': 'station-a',
            'working_space': 'linear_srgb_d65', 'white_balance': [1.4, 1.0, 0.7],
            'correction': {'type': 'matrix3x3', 'matrix': [[1,0,0],[0,1,0],[0,0,1]]}}


def identity():
    payload = json.dumps(profile())
    key = hashlib.sha256(payload.encode()).hexdigest()
    return {'color_calibration': {'version': 1, 'profiles': {key: payload},
            'images': {'a.jpg': {'profile': key}, 'b.jpg': {'profile': None, 'reason': 'skipped'}}}}


class CalibrationContractTests(unittest.TestCase):
    def test_per_page_and_old_folders(self):
        self.assertEqual(profile_for(identity(), 'a.jpg'), profile())
        self.assertIsNone(profile_for(identity(), 'b.jpg'))
        self.assertIsNone(profile_for({}, 'old.jpg'))

    def test_missing_reference_and_checksum_are_errors(self):
        value = identity()
        with self.assertRaises(CalibrationError):
            profile_for(value, 'missing.jpg')
        value['color_calibration']['profiles'][next(iter(value['color_calibration']['profiles']))] += ' '
        with self.assertRaises(CalibrationError):
            profile_for(value, 'a.jpg')

    def test_legacy_is_a_capture_time_decision_not_export_date(self):
        value = {'color_profile': dict(profile(), calibrated_today=True, calibrated_at='2020-01-01')}
        self.assertIsNotNone(profile_for(value, 'a.jpg'))
        value['color_profile']['calibrated_today'] = False
        self.assertIsNone(profile_for(value, 'a.jpg'))

    def test_split_keeps_only_referenced_profiles(self):
        value = identity()
        result = subset(value, {'b.jpg'})
        self.assertEqual(result['color_calibration']['profiles'], {})
        self.assertEqual(set(value['color_calibration']['images']), {'a.jpg', 'b.jpg'})
        manifest = {'source_identity': value, 'files': [{'relative_path': 'a.jpg'}, {'relative_path': 'b.jpg'}]}
        child = child_manifest(manifest, {'b.jpg'})
        self.assertEqual(child['source_identity'], result)


class CalibrationRenderingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / 'a.jpg'
        Image.new('RGB', (64, 64), (100, 120, 140)).save(self.source, quality=100, subsampling=0)
        (self.root / '.deskew_crop_manifest.json').write_text(json.dumps({'source_identity': identity()}))

    def test_tiff_corrects_once_and_keeps_source(self):
        before = self.source.read_bytes()
        output = self.root / 'out.tif'
        convert_to_tiff(self.source, output, [], profile())
        with Image.open(self.source) as original, Image.open(output) as result:
            expected = apply_profile_to_pil(original, profile())
            np.testing.assert_array_equal(np.asarray(result), np.asarray(expected))
            self.assertIn('station-a', result.tag_v2[305])
        self.assertEqual(self.source.read_bytes(), before)

    def test_jpeg_no_geometry_does_not_skip_colour(self):
        output = self.root / 'out.jpg'
        convert_to_jpeg(self.source, output, [], profile())
        self.assertNotEqual(output.read_bytes(), self.source.read_bytes())
        with Image.open(output) as result, Image.open(self.source) as original:
            expected = np.asarray(apply_profile_to_pil(original, profile()), dtype=int)
            self.assertLessEqual(np.abs(np.asarray(result, dtype=int) - expected).max(), 2)
        convert_to_jpeg(self.source, output, [])
        self.assertEqual(output.read_bytes(), self.source.read_bytes())

    def test_preview_has_same_correction_as_export(self):
        with patch('app.services.previews.resolve_preview_cache_dir', return_value=self.root):
            path = generate_preview_image(self.source, [], profile())
        with Image.open(path) as actual, Image.open(self.source) as source:
            expected = np.asarray(apply_profile_to_pil(source, profile()), dtype=int)
            self.assertLessEqual(np.abs(np.asarray(actual, dtype=int) - expected).max(), 3)

    def test_export_detects_profile_changed_after_snapshot(self):
        stat = self.source.stat()
        source = ImageSource(id=1, name='a.jpg', path=self.source, size=stat.st_size,
                             mtime_ns=stat.st_mtime_ns, color_profile=profile())
        snapshot = SimpleNamespace(images=[source])
        verify_sources_unchanged(snapshot)
        (self.root / '.deskew_crop_manifest.json').write_text('{}')
        with self.assertRaises(ExportError):
            verify_sources_unchanged(snapshot)

    def test_cache_depends_on_profile(self):
        self.assertNotEqual(preview_cache_path(self.source, []), preview_cache_path(self.source, [], profile()))

    def test_external_override_is_independent_of_geometry(self):
        self.assertIsNotNone(effective_profile(self.root, 'a.jpg'))
        write_qc_ops(self.root, {'images': {'a.jpg': {'ignore_lwip': True, 'ops': []}}})
        self.assertIsNotNone(effective_profile(self.root, 'a.jpg'))
        write_qc_ops(self.root, {'images': {'a.jpg': {'color_disabled': True}}})
        self.assertIsNone(effective_profile(self.root, 'a.jpg'))
        self.assertIsNotNone(effective_profile(self.root, 'a.jpg', {'restored': True}))
        self.assertIsNone(effective_profile(self.root, 'a.jpg', {'status': 'replaced'}))


if __name__ == '__main__':
    unittest.main()

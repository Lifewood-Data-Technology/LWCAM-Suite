"""A package is uploaded only after it has been unchanged for SETTLE_SECONDS."""

from __future__ import annotations

import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import mock

from lwcam_upload import engine
from lwcam_upload.engine import UploadCoordinator
from tests.test_upload_reupload import FakeStore, _config


class SettleTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.page = self.root / "G1" / "p.tif"
        self.page.parent.mkdir()
        self.page.write_bytes(b"page")
        self.config = _config(self.root)
        self.store = FakeStore()
        self.coordinator = UploadCoordinator(store_factory=lambda target: self.store)
        # Fake clock: sleeping advances it, so waits cost nothing.
        self.now = 1000.0
        self.sleeps = 0
        for name, fn in (("monotonic", lambda: self.now), ("sleep", self._sleep)):
            patcher = mock.patch.object(engine.time, name, fn)
            patcher.start()
            self.addCleanup(patcher.stop)

    def _sleep(self, seconds: float) -> None:
        self.sleeps += 1
        self.now += seconds

    def test_new_package_waits_then_uploads_once_unchanged(self) -> None:
        self.assertEqual(self.coordinator._scan(self.config, None), 0)
        self.assertEqual(self.store.put_calls, [], "not uploaded the instant it appears")
        self.now += 9.9
        self.assertEqual(self.coordinator._scan(self.config, None), 0)
        self.assertEqual(self.store.put_calls, [])
        self.now += 0.2
        self.assertEqual(self.coordinator._scan(self.config, None), 1)
        self.assertTrue(self.store.put_calls)

    def test_scan_once_waits_out_the_settle_itself(self) -> None:
        self.assertEqual(self.coordinator.scan_once(self.config), 1)
        self.assertGreaterEqual(self.now - 1000.0, engine.SETTLE_SECONDS)

    def test_change_during_settling_restarts_the_clock(self) -> None:
        self.coordinator._scan(self.config, None)
        self.now += 6
        self.page.write_bytes(b"page, still being written")
        self.coordinator._scan(self.config, None)  # sees the change: restart
        self.now += 6  # 12 s since first seen, only 6 since the change
        self.assertEqual(self.coordinator._scan(self.config, None), 0)
        self.assertEqual(self.store.put_calls, [])
        self.now += 5
        self.assertEqual(self.coordinator._scan(self.config, None), 1)

    def test_stop_during_the_wait_returns_without_uploading(self) -> None:
        calls = [0]

        def stop() -> bool:
            calls[0] += 1
            return calls[0] > 1  # let the first pass run, then ask to stop

        self.assertEqual(self.coordinator.scan_once(self.config, stop_check=stop), 0)
        self.assertEqual(self.store.put_calls, [])
        self.assertEqual(self.sleeps, 0, "must not sleep once stop is requested")
        self.assertFalse(self.coordinator._scanning)


if __name__ == "__main__":
    unittest.main()

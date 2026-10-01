"""Round 3: an unreachable watch folder is visible, the heartbeat carries scan
age / interval / db_pending, and the slow cross-volume move says why once."""

from __future__ import annotations

import time
import unittest
from pathlib import Path
from unittest import mock

from lwcam_upload import console, engine
from lwcam_upload.engine import UploadCoordinator, watch_state
from tests.test_round2 import TempRootCase
from tests.test_upload_reupload import FakeStore


class WatchStateTests(TempRootCase):
    def test_ok_missing_and_unreachable_are_kept_apart(self) -> None:
        self.assertEqual(watch_state(self.watch), ("ok", None))
        kind, text = watch_state(self.root / "nope")
        self.assertEqual(kind, "missing")
        self.assertIn("does not exist", text)
        with mock.patch.object(engine, "_bounded", side_effect=OSError(53, "network path")):
            kind, text = watch_state(self.watch)
        self.assertEqual(kind, "unreachable")
        self.assertIn("is unreachable", text)

    def test_a_hanging_check_times_out(self) -> None:
        with mock.patch.object(Path, "is_dir", lambda self: time.sleep(2)):
            started = time.monotonic()
            kind, _ = watch_state(self.watch, seconds=0.1)
        self.assertEqual(kind, "unreachable")
        self.assertLess(time.monotonic() - started, 1.5)


class WatchProblemReportingTests(TempRootCase):
    def test_problem_is_set_travels_in_heartbeat_and_clears(self) -> None:
        coordinator = UploadCoordinator(store_factory=lambda t: FakeStore())
        cfg = self.config()
        bad = ("unreachable", f"Watch folder {self.watch} is unreachable")
        with mock.patch.object(engine, "watch_state", return_value=bad):
            coordinator.scan_once(cfg)
            status = coordinator.status(cfg)
            self.assertEqual(status["watchKind"], "unreachable")
            self.assertEqual(status["pending"], [])
            h = mock.Mock()
            console.send_heartbeat(h, coordinator, cfg)
            self.assertIn("is unreachable", h.beat.call_args.kwargs["error"])
        self.package("G1")
        coordinator.scan_once(cfg)
        self.assertIsNone(coordinator.status(cfg)["watchProblem"])
        h = mock.Mock()
        console.send_heartbeat(h, coordinator, cfg)
        self.assertIsNone(h.beat.call_args.kwargs["error"])


class HeartbeatBacklogTests(TempRootCase):
    def test_scan_age_interval_and_db_pending(self) -> None:
        coordinator = UploadCoordinator(store_factory=lambda t: FakeStore())
        cfg = self.config(interval_seconds=120)
        self.package("G1")
        coordinator.scan_once(cfg)
        # uploaded, no database configured -> nothing pending write-back
        h = mock.Mock()
        console.send_heartbeat(h, coordinator, cfg)
        backlog = h.beat.call_args.args[0]
        self.assertEqual(backlog["scan_interval_minutes"], 2.0)
        self.assertLess(backlog["last_scan_minutes_ago"], 1)
        self.assertEqual(backlog["db_pending"], 0)
        # a running scan ages from its start; a finished one from its end
        coordinator._scanning, coordinator._scan_started_at = True, time.monotonic() - 1200
        self.assertGreaterEqual(coordinator.scan_age_minutes(), 20)
        coordinator._scanning, coordinator._scan_done_at = False, time.monotonic() - 600
        self.assertGreaterEqual(coordinator.scan_age_minutes(), 10)

    def test_db_pending_counts_unwritten_entries(self) -> None:
        coordinator = UploadCoordinator(store_factory=lambda t: FakeStore())
        coordinator.db_writer = lambda group, error: False  # database keeps refusing
        cfg = self.config(db_host="db")
        self.package("G1")
        coordinator.scan_once(cfg)
        self.assertEqual(coordinator.status(cfg)["dbPending"], 1)

    def test_disabled_service_reports_no_scan_age(self) -> None:
        coordinator = UploadCoordinator(store_factory=lambda t: FakeStore())
        cfg = self.config(enabled=False)
        h = mock.Mock()
        console.send_heartbeat(h, coordinator, cfg)
        self.assertNotIn("last_scan_minutes_ago", h.beat.call_args.args[0])


class SlowMoveNoticeTests(TempRootCase):
    def test_cross_volume_move_logs_its_reason_once(self) -> None:
        done = self.root / "done"
        engine._slow_move_logged = False
        logs = []
        with mock.patch.object(engine.os, "rename", side_effect=OSError("cross-device")), \
                mock.patch.object(engine, "log", lambda tag, msg: logs.append(msg)):
            engine.move_to_done(self.package("G1"), done)
            engine.move_to_done(self.package("G2"), done)
        self.assertEqual(len([m for m in logs if "same volume" in m]), 1)
        self.assertTrue((done / "G1" / "p.tif").exists())


if __name__ == "__main__":
    unittest.main()

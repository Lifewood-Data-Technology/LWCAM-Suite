"""Round-3: CA always permits ts.net/.local, cert refresh hook, unreachable input,
unreported backlog, rework-in-progress, bounded netlogin connects."""

from __future__ import annotations

import dataclasses
import json
import os
import tempfile
import threading
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

from cryptography import x509

from deskew_crop_tool import health, netlogin, tls
from deskew_crop_tool.orchestrator import FolderOrchestrator, build_snapshot
from tests.test_round2 import Base, _jpeg


class TlsNamesTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.dir = Path(temp.name) / "tls"
        for target, value in (("_gateway_ips", set()), ("_tailscale", (None, set()))):
            p = mock.patch.object(tls, target, return_value=value)
            p.start()
            self.addCleanup(p.stop)

    def test_ca_permits_tailnet_and_local_even_without_tailscale(self) -> None:
        tls.ensure_certificates(self.dir)
        ca = x509.load_pem_x509_certificate((self.dir / "lwcam-ca.crt").read_bytes())
        names = {n.value for n in tls._ca_constraints(ca).permitted_subtrees if isinstance(n, x509.DNSName)}
        self.assertTrue({"ts.net", "local"} <= names)
        self.assertEqual(tls._uncovered(ca, {"pc.tail1234.ts.net", "scanner.local"}, set()), [])

    def test_a_ca_without_them_is_replaced_but_one_with_them_is_kept(self) -> None:
        tls.ensure_certificates(self.dir)
        before = (self.dir / "lwcam-ca.crt").read_bytes()
        tls.ensure_certificates(self.dir)
        self.assertEqual(before, (self.dir / "lwcam-ca.crt").read_bytes())
        (self.dir / "lwcam-ca.crt").unlink()
        (self.dir / "lwcam-ca.key").unlink()
        with mock.patch.object(tls, "ALWAYS_DNS", ()):
            tls.ensure_certificates(self.dir)  # an old-style CA, without the two names
        old = (self.dir / "lwcam-ca.crt").read_bytes()
        tls.ensure_certificates(self.dir)
        self.assertNotEqual(old, (self.dir / "lwcam-ca.crt").read_bytes())

    def test_keep_fresh_calls_back_only_when_the_leaf_changed(self) -> None:
        tls.ensure_certificates(self.dir)
        seen = []

        def renewed(crt, _key):
            seen.append(crt)
            # End the keeper thread here: left running at 50 ms it races the
            # temp folder's cleanup on Windows (a locked server.crt).
            raise SystemExit

        thread = tls.keep_fresh(self.dir, renewed, interval=0.05)
        self.addCleanup(thread.join, 5)
        time.sleep(0.4)
        self.assertEqual(seen, [])
        (self.dir / "server.crt").unlink()  # forces a re-issue on the next pass
        for _ in range(50):
            if seen:
                break
            time.sleep(0.1)
        self.assertGreaterEqual(len(seen), 1)


class InputRootTests(Base):
    def test_missing_unreachable_and_recovered_input_root(self) -> None:
        o = FolderOrchestrator(self.config)
        with mock.patch.object(FolderOrchestrator, "_list_candidates", side_effect=PermissionError("denied")):
            self.assertEqual(o._candidate_folders(), [])
        self.assertIn("unreachable", o._input_error)
        with mock.patch.object(FolderOrchestrator, "_list_candidates", side_effect=FileNotFoundError()):
            o._candidate_folders()
        self.assertIn("was not found", o._input_error)
        self.assertEqual(o._candidate_folders(), [self.folder])
        self.assertIsNone(o._input_error)

    def test_a_hung_listing_times_out_and_does_not_pile_up_threads(self) -> None:
        o = FolderOrchestrator(self.config)
        o.INPUT_LIST_TIMEOUT = 0.1
        gate = threading.Event()
        self.addCleanup(gate.set)
        with mock.patch.object(FolderOrchestrator, "_list_candidates", side_effect=lambda: gate.wait(5) or []) as m:
            start = time.monotonic()
            self.assertEqual(o._candidate_folders(), [])
            self.assertEqual(o._candidate_folders(), [])
            self.assertLess(time.monotonic() - start, 1.0)
            self.assertEqual(m.call_count, 1)
        self.assertIn("unreachable", o._input_error)

    def test_status_json_carries_the_error(self) -> None:
        o = FolderOrchestrator(self.config)
        o._input_error = "Input folder X is unreachable"
        o._write_status_snapshot([])
        doc = json.loads((self.root / "status.json").read_text(encoding="utf-8"))
        self.assertEqual(doc["input_error"], "Input folder X is unreachable")


class UnreportedTests(unittest.TestCase):
    def test_count_and_oldest(self) -> None:
        old = (datetime.now(timezone.utc) - timedelta(minutes=125)).isoformat()
        new = datetime.now(timezone.utc).isoformat()
        completed = {
            "a": {"output_folder": "o", "completed_at": old},
            "b": {"output_folder": "o", "completed_at": new},
            "c": {"output_folder": "o", "completed_at": old, "reported_at": new},
            "d": {"output_folder": "o", "completed_at": old, "retry_required": True},
        }
        count, oldest = FolderOrchestrator._count_unreported(completed)
        self.assertEqual(count, 2)
        self.assertIn(oldest, (125, 126))

    def test_backlog_carries_the_status_fields(self) -> None:
        out = health.backlog_of([], [], {}, now=0.0, status={"unreported": 3, "oldest_unreported_minutes": 7})
        self.assertEqual((out["unreported"], out["oldest_unreported_minutes"]), (3, 7))


class ReworkTests(Base):
    def test_marker_flag_holds_the_folder(self) -> None:
        _jpeg(self.folder / "a.jpg")
        marker = self.folder / "marker.json"
        marker.write_text(json.dumps({"rework_in_progress": True}), encoding="utf-8")
        o = FolderOrchestrator(self.config)
        self.assertFalse(o._is_ready(build_snapshot(self.folder, self.config)))
        marker.write_text(json.dumps({"image_count": 1}), encoding="utf-8")
        self.assertTrue(o._is_ready(build_snapshot(self.folder, self.config)))

    def test_changed_completed_folder_waits_for_the_settle_time(self) -> None:
        _jpeg(self.folder / "a.jpg")
        (self.folder / "marker.json").write_text("{}", encoding="utf-8")
        config = dataclasses.replace(self.config, rework_settle_seconds=0.3)
        o = FolderOrchestrator(config)
        o.state.mark_completed(build_snapshot(self.folder, config), self.root / "out", "x")
        (self.folder / "a.jpg").write_bytes((self.folder / "a.jpg").read_bytes() + b"\0")  # reworked
        snap = build_snapshot(self.folder, config)
        self.assertFalse(o._is_ready(snap))
        time.sleep(0.4)
        self.assertTrue(o._is_ready(snap))
        (self.folder / "a.jpg").write_bytes((self.folder / "a.jpg").read_bytes() + b"\0")  # changes again
        self.assertFalse(o._is_ready(build_snapshot(self.folder, config)))

    def test_a_never_completed_folder_is_not_delayed(self) -> None:
        _jpeg(self.folder / "a.jpg")
        (self.folder / "marker.json").write_text("{}", encoding="utf-8")
        self.assertTrue(FolderOrchestrator(self.config)._is_ready(build_snapshot(self.folder, self.config)))


class BoundedNetloginTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        env = mock.patch.dict(os.environ, {netlogin.STORE_ENV: str(Path(temp.name) / "logins.json")})
        env.start()
        self.addCleanup(env.stop)
        netlogin._last_errors.clear()
        netlogin._inflight.clear()

    def test_one_dead_peer_does_not_delay_the_others(self) -> None:
        gate = threading.Event()
        self.addCleanup(gate.set)
        done = []

        def fake(host):
            if host == "DEAD":
                gate.wait(10)
            done.append(host)

        entries = {h.lower(): {"host": h} for h in ("DEAD", "ALIVE1", "ALIVE2")}
        with mock.patch.object(netlogin, "_read_store", return_value=entries), \
                mock.patch.object(netlogin, "connect", side_effect=fake):
            start = time.monotonic()
            netlogin.connect_all(timeout=0.3)
            elapsed = time.monotonic() - start
        self.assertLess(elapsed, 2.0)
        self.assertEqual(sorted(done), ["ALIVE1", "ALIVE2"])
        self.assertIn("did not answer", netlogin._last_errors["dead"])

    def test_check_all_uses_the_bounded_path(self) -> None:
        with mock.patch.object(netlogin, "connect_bounded", return_value="slow") as bounded, \
                mock.patch.object(netlogin, "list_logins", return_value=[{"host": "PC", "saved": True}]), \
                mock.patch.object(netlogin, "_check_folder_bounded", return_value=None):
            rows = netlogin.check_all([r"\\PC\share"])
        bounded.assert_called_once_with("PC")
        self.assertEqual(rows[0]["loginError"], "slow")


if __name__ == "__main__":
    unittest.main()

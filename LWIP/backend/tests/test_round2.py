"""Round-2 hardening: marker image_count, failure back-off, worker hang and
stall, links skipped, console session/limiter/cache fixes, quiet logging."""

from __future__ import annotations

import http.client
import json
import logging
import os
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from datetime import date
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock

import bcrypt
from PIL import Image

from deskew_crop_tool import orchestrator as orch
from deskew_crop_tool import service
from deskew_crop_tool.config import ToolConfig
from deskew_crop_tool.orchestrator import FolderOrchestrator, build_snapshot


def _config(root: Path, *, marker: str | None = None) -> ToolConfig:
    return ToolConfig(
        input_root=root / "incoming",
        output_root=root / "output",
        work_root=root / "work",
        state_file=root / "state.json",
        log_file=root / "tool.log",
        workers=2,
        poll_interval_seconds=0.01,
        stable_seconds=0,
        minimum_file_age_seconds=0,
        presence_check_interval_seconds=86400,
        checksum_check_interval_seconds=86400,
        crop_padding=5,
        jpeg_quality=95,
        completion_marker=marker,
        recursive=True,
        extensions=(".jpg",),
        folder_depth=1,
        thumbnail_width=0,
        thumbnail_quality=85,
        thumbnail_dirname="thumbs",
    )


def _jpeg(path: Path) -> None:
    Image.new("RGB", (64, 64), "white").save(path, "JPEG")


class Base(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.folder = self.root / "incoming" / "job"
        self.folder.mkdir(parents=True)
        self.config = _config(self.root, marker="marker.json")


class MarkerImageCountTests(Base):
    def test_folder_waits_until_the_marker_count_is_present(self) -> None:
        _jpeg(self.folder / "a.jpg")
        (self.folder / "marker.json").write_text(json.dumps({"image_count": 2}), encoding="utf-8")
        with self.assertLogs("deskew_crop", "INFO") as logs:
            self.assertEqual(FolderOrchestrator(self.config).run_once(), 0)
            self.assertEqual(FolderOrchestrator(self.config).run_once(), 0)
        self.assertEqual(sum("marker expects 2" in line for line in logs.output), 2)  # once per orchestrator
        self.assertFalse((self.root / "output" / "job").exists())
        _jpeg(self.folder / "b.jpg")
        self.assertEqual(FolderOrchestrator(self.config).run_once(), 1)

    def test_a_marker_without_the_field_or_with_junk_behaves_as_before(self) -> None:
        _jpeg(self.folder / "a.jpg")
        for text in ("{}", '{"image_count": "x"}', "not json", '{"image_count": true}'):
            (self.folder / "marker.json").write_text(text, encoding="utf-8")
            snapshot = build_snapshot(self.folder, self.config)
            self.assertTrue(FolderOrchestrator(self.config)._is_ready(snapshot), text)


class FailureBackoffTests(Base):
    def _snapshot(self):
        _jpeg(self.folder / "a.jpg")
        return build_snapshot(self.folder, self.config)

    def test_backoff_doubles_caps_and_marks_failed_after_five(self) -> None:
        state = orch.StateStore(self.root / "state.json")
        snapshot = self._snapshot()
        minutes = []
        for _ in range(8):
            before = time.time()
            item = state.record_failure(snapshot, "boom")
            minutes.append(round((item["next_retry_epoch"] - before) / 60))
        self.assertEqual(minutes, [1, 2, 4, 8, 16, 32, 60, 60])
        self.assertTrue(state.data["failures"][str(self.folder.resolve())]["failed"])
        self.assertTrue(state.retry_blocked(self.folder, snapshot.fingerprint))
        self.assertEqual(orch.StateStore(self.root / "state.json").data["failures"], state.data["failures"])  # persisted

    def test_changed_files_or_success_clear_it(self) -> None:
        state = orch.StateStore(self.root / "state.json")
        snapshot = self._snapshot()
        state.record_failure(snapshot, "boom")
        self.assertTrue(state.retry_blocked(self.folder, snapshot.fingerprint))
        self.assertFalse(state.retry_blocked(self.folder, "another-fingerprint"))
        self.assertEqual(state.data["failures"], {})
        state.record_failure(snapshot, "boom")
        state.mark_completed(snapshot, self.root / "output", "x")
        self.assertEqual(state.data["failures"], {})

    def test_failed_folders_reach_the_console_summary(self) -> None:
        state = orch.StateStore(self.root / "state.json")
        snapshot = self._snapshot()
        for _ in range(4):
            state.record_failure(snapshot, "boom")
        self.assertEqual(service.summarize_state(None, state.data, today=date.today())["queue"]["failed"], [])
        state.record_failure(snapshot, "boom")
        failed = service.summarize_state(None, state.data, today=date.today())["queue"]["failed"]
        self.assertEqual([f["folder"] for f in failed], [str(self.folder.resolve())])

    def test_a_failing_folder_is_not_retried_inside_its_backoff(self) -> None:
        (self.folder / "marker.json").write_text("{}", encoding="utf-8")
        (self.folder / "a.jpg").write_bytes(b"this is not a jpeg")
        first = FolderOrchestrator(self.config)
        self.assertEqual(first.run_once(), 0)
        key = str(self.folder.resolve())
        self.assertEqual(first.state.data["failures"][key]["count"], 1)
        second = FolderOrchestrator(self.config)  # a restarted worker reads the journal
        with mock.patch.object(orch, "deskew_crop_file") as never:
            second.run_once()
        never.assert_not_called()
        self.assertEqual(second.state.data["failures"][key]["count"], 1)
        second.state.data["failures"][key]["next_retry_epoch"] = 0
        second.run_once()
        self.assertEqual(second.state.data["failures"][key]["count"], 2)
        (self.folder / "a.jpg").write_bytes(b"still not a jpeg, but different")  # files changed
        third = FolderOrchestrator(self.config)
        third.run_once()
        self.assertEqual(third.state.data["failures"][key]["count"], 1)


class WorkerHangTests(Base):
    def test_a_job_past_its_deadline_kills_the_pool_and_stops_the_worker(self) -> None:
        _jpeg(self.folder / "a.jpg")
        orchestrator = FolderOrchestrator(self.config)
        item = types.SimpleNamespace(snapshot=build_snapshot(self.folder, self.config))
        stuck = mock.Mock(done=mock.Mock(return_value=False))
        process = mock.Mock()
        executor = mock.Mock(_processes={1: process})
        orchestrator._image_started[stuck] = time.monotonic() - orchestrator.IMAGE_DEADLINE_SECONDS - 1
        with self.assertRaises(orch.WorkerStalled):
            orchestrator._check_image_deadlines({stuck: item}, executor)
        process.kill.assert_called_once()
        executor.shutdown.assert_called_once_with(wait=False, cancel_futures=True)
        self.assertEqual(orchestrator.state.data["failures"][str(self.folder.resolve())]["count"], 1)

    def test_a_job_inside_its_deadline_is_left_alone(self) -> None:
        orchestrator = FolderOrchestrator(self.config)
        running = mock.Mock(done=mock.Mock(return_value=False))
        orchestrator._image_started[running] = time.monotonic()
        orchestrator._check_image_deadlines({running: object()}, mock.Mock())

    def test_status_carries_progress_time(self) -> None:
        orchestrator = FolderOrchestrator(self.config)
        orchestrator._write_status_snapshot([])
        status = json.loads((self.root / "status.json").read_text(encoding="utf-8"))
        self.assertAlmostEqual(status["progress_at"], time.time(), delta=5)


class SupervisorStallTests(Base):
    def _status(self, *, processing, progress_ago) -> None:
        (self.root / "status.json").write_text(
            json.dumps({"processing": processing, "waiting": [], "progress_at": time.time() - progress_ago}),
            encoding="utf-8",
        )

    def test_stalled_only_with_queued_work_and_no_recent_progress(self) -> None:
        supervisor = service.Supervisor(self.root / "cfg.json")
        long_ago = time.time() - 3 * 3600
        self._status(processing=["f"], progress_ago=service.Supervisor.STALL_SECONDS + 60)
        self.assertTrue(supervisor.worker_stalled(self.config, long_ago))
        self.assertFalse(supervisor.worker_stalled(self.config, time.time()), "a fresh worker gets a full window")
        self._status(processing=[], progress_ago=99999)
        self.assertFalse(supervisor.worker_stalled(self.config, long_ago), "idle is not stalled")
        self._status(processing=["f"], progress_ago=5)
        self.assertFalse(supervisor.worker_stalled(self.config, long_ago))

    def test_the_run_loop_restarts_a_stalled_worker_and_reports_it(self) -> None:
        config_path = self.root / "cfg.json"
        config_path.write_text(
            json.dumps({
                "input_root": str(self.root / "incoming"), "output_root": str(self.root / "output"),
                "work_root": str(self.root / "work"), "state_file": str(self.root / "state.json"),
                "workers": 1,
            }),
            encoding="utf-8",
        )
        self._status(processing=["f"], progress_ago=10)
        pids = []
        supervisor = service.Supervisor(
            config_path, backoff_seconds=0.05, restart_wait_seconds=0.3, poll_interval=0.01,
            db_probe_interval_seconds=10_000,
            child_command_factory=lambda _p: [sys.executable, "-c", "import time; time.sleep(60)"],
        )
        supervisor.STALL_SECONDS = 0.3
        supervisor.STALL_CHECK_SECONDS = 0.05
        with mock.patch.object(service, "probe_db", return_value="down"):
            thread = threading.Thread(target=supervisor.run, daemon=True)
            thread.start()
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and supervisor._stall_error is None:
                time.sleep(0.02)
            self.assertEqual(supervisor._stall_error, "worker stalled")
            while time.monotonic() < deadline and supervisor.state.snapshot().get("state") != "restarting":
                pids.append(supervisor.state.snapshot().get("pid"))
                time.sleep(0.02)
            supervisor.request_shutdown()
            thread.join(10)
        self.assertFalse(thread.is_alive())


class LinkTests(Base):
    def _junction(self, link: Path, target: Path) -> None:
        done = subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(target)], capture_output=True)
        if done.returncode != 0:
            self.skipTest("cannot create a junction here")

    def test_links_are_not_followed_when_listing_images(self) -> None:
        outside = self.root / "outside"
        outside.mkdir()
        _jpeg(outside / "secret.jpg")
        _jpeg(self.folder / "a.jpg")
        self._junction(self.folder / "linked", outside)
        snapshot = build_snapshot(self.folder, self.config)
        self.assertEqual([name for name, _, _ in snapshot.files], ["a.jpg"])

    def test_a_linked_folder_is_not_a_candidate(self) -> None:
        outside = self.root / "outside"
        outside.mkdir()
        _jpeg(outside / "a.jpg")
        self._junction(self.root / "incoming" / "linked", outside)
        names = [p.name for p in FolderOrchestrator(self.config)._candidate_folders()]
        self.assertEqual(names, ["job"])

    def test_ordinary_files_and_dirs_are_not_links(self) -> None:
        _jpeg(self.folder / "a.jpg")
        self.assertFalse(orch._path_is_link(self.folder))
        self.assertFalse(orch._path_is_link(self.folder / "a.jpg"))


class LoggingTests(Base):
    def test_no_console_handler_without_a_tty(self) -> None:
        root = logging.getLogger()
        saved, level = list(root.handlers), root.level
        self.addCleanup(lambda: (root.handlers.clear(), root.handlers.extend(saved), root.setLevel(level)))
        try:
            with mock.patch.object(sys, "stderr", mock.Mock(isatty=lambda: False)):
                orch.configure_logging(self.config)
            self.assertFalse([h for h in root.handlers if type(h) is logging.StreamHandler])
            self.assertTrue(root.handlers)  # the rotating file stays
            with mock.patch.object(sys, "stderr", mock.Mock(isatty=lambda: True)):
                orch.configure_logging(self.config)
            self.assertTrue([h for h in root.handlers if type(h) is logging.StreamHandler])
        finally:
            for handler in list(root.handlers):
                if handler not in saved:
                    handler.close()


class RateLimiterTests(unittest.TestCase):
    def test_expired_ips_are_pruned_for_everyone_and_the_table_is_capped(self) -> None:
        limiter = service.RateLimiter()
        limiter.record_failure("10.0.0.1", "a", now=0.0)
        limiter.check("10.0.0.2", "b", now=service.IP_ATTEMPT_WINDOW_SECONDS + 5)
        self.assertEqual(limiter._ip_failures, {})
        with mock.patch.object(service, "MAX_TRACKED_CLIENTS", 10):
            for n in range(50):
                limiter.record_failure(f"10.1.0.{n}", f"user{n}", now=1.0)
        self.assertLessEqual(len(limiter._ip_failures), 10)
        self.assertLessEqual(len(limiter._failures), 10)


class AdminCacheTests(unittest.TestCase):
    def test_concurrent_remembers_lose_nothing_and_leave_no_temp_files(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            config_path = Path(temp) / "config.json"
            threads = [
                threading.Thread(target=service.remember_admin, args=(config_path, f"u{n}", "h", "admin"))
                for n in range(12)
            ]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(20)
            users = {row["user_id"] for row in service.read_admin_cache(config_path)}
            self.assertEqual(users, {f"u{n}" for n in range(12)})
            self.assertEqual([p.name for p in Path(temp).glob(".*.tmp")], [])


class ConsoleServerTests(unittest.TestCase):
    def test_dropped_tls_connections_log_one_line_not_a_traceback(self) -> None:
        server = service.ConsoleServer.__new__(service.ConsoleServer)
        with self.assertLogs("deskew_crop_tool.service", "INFO") as logs:
            try:
                raise ssl.SSLError("HTTP_REQUEST")
            except ssl.SSLError:
                server.handle_error(None, ("10.0.0.9", 5555))
        self.assertEqual(len(logs.records), 1)
        self.assertIsNone(logs.records[0].exc_info)
        self.assertIn("10.0.0.9", logs.output[0])

    def test_the_handler_has_a_socket_timeout(self) -> None:
        ctx = service.ServiceContext(config_path=Path("x"), supervisor=None)  # type: ignore[arg-type]
        self.assertEqual(service.build_handler(ctx).timeout, 30)


class SessionRevalidationTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        self.config_path = root / "config.json"
        self.config_path.write_text(
            json.dumps({"input_root": str(root / "in"), "output_root": str(root / "out"), "workers": 1}),
            encoding="utf-8",
        )
        (root / "in").mkdir()
        (root / "out").mkdir()
        self.hash = bcrypt.hashpw(b"pw", bcrypt.gensalt(4)).decode("ascii")
        self.record = {"password": self.hash, "roles": "admin", "active": True, "is_deleted": False}
        self.down = False
        self.state = service.SharedState()
        self.state.update(database_reachable=True, database_checked_at="now")
        supervisor = types.SimpleNamespace(state=self.state, request_restart=lambda: None)
        self.sessions = service.SessionStore()

        def lookup(_config, _user):
            if self.down:
                raise service.DbUnavailable("down")
            return dict(self.record)

        ctx = service.ServiceContext(
            config_path=self.config_path, supervisor=supervisor, sessions=self.sessions,
            rate_limiter=service.RateLimiter(), db_lookup=lookup,
            web_dir=root / "web",
        )
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), service.build_handler(ctx))
        self.port = self.httpd.server_address[1]
        thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(lambda: (self.httpd.shutdown(), thread.join(5), self.httpd.server_close()))

    def _call(self, method, path, body=None, cookie=None, host=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        headers = {"Content-Type": "application/json", "X-Requested-With": "lwip"}
        if cookie:
            headers["Cookie"] = cookie
        if host:
            headers["Host"] = host
        try:
            conn.request(method, path, body=json.dumps(body).encode() if body is not None else None, headers=headers)
            response = conn.getresponse()
            response.read()
            return response.status, response.getheader("Set-Cookie")
        finally:
            conn.close()

    def _sign_in(self) -> str:
        status, cookie = self._call("POST", "/api/login", {"username": "admin", "password": "pw"})
        self.assertEqual(status, 200)
        return cookie.split(";")[0]

    def test_a_demoted_or_disabled_account_is_signed_out_within_a_minute(self) -> None:
        for change in ({"active": False}, {"roles": "qc"}, {"is_deleted": True}):
            self.record = {"password": self.hash, "roles": "admin", "active": True, "is_deleted": False}
            cookie = self._sign_in()
            self.record.update(change)
            self.assertEqual(self._call("GET", "/api/settings", cookie=cookie)[0], 200, "not checked yet")
            self.sessions._checked_at[cookie.split("=", 1)[1]] -= 61
            self.assertEqual(self._call("GET", "/api/settings", cookie=cookie)[0], 401, change)
            self.assertEqual(self._call("GET", "/api/settings", cookie=cookie)[0], 401)

    def test_an_unreachable_database_keeps_the_session(self) -> None:
        cookie = self._sign_in()
        self.down = True
        self.sessions._checked_at[cookie.split("=", 1)[1]] -= 61
        self.assertEqual(self._call("GET", "/api/settings", cookie=cookie)[0], 200)  # lookup failed: kept
        self.state.update(database_reachable=False)  # and none is attempted while the probe says down
        self.sessions._checked_at[cookie.split("=", 1)[1]] -= 61
        self.assertEqual(self._call("GET", "/api/settings", cookie=cookie)[0], 200)

    def test_database_down_remote_gets_the_sign_in_form_only_local_gets_view(self) -> None:
        self.state.update(database_reachable=False)
        self.assertEqual(self._call("GET", "/api/status", host="localhost")[0], 200)
        self.assertEqual(self._call("GET", "/api/status", host="192.168.0.5:8090")[0], 401)


if __name__ == "__main__":
    unittest.main()

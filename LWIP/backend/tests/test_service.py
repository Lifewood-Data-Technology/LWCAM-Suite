"""Tests for the LWIP console/supervisor (deskew_crop_tool.service).

Most of this needs neither a database nor a subprocess: role parsing, the
access-level matrix, the rate limiter, settings merge/validate and the
status.json/state.json summary are all pure functions. The one HTTP test
starts a real ThreadingHTTPServer on port 0 with a fake user-lookup callable;
the two supervisor tests spawn real (tiny, fast-exiting) child processes with
an injected backoff so they do not slow the suite down.
"""

from __future__ import annotations

import http.client
import json
import tempfile
import threading
import time
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path

import bcrypt

from deskew_crop_tool import service


class RoleParsingTests(unittest.TestCase):
    def test_single_role(self) -> None:
        self.assertEqual(service.role_set("admin"), {"admin"})

    def test_comma_joined_roles(self) -> None:
        self.assertEqual(service.role_set("qc,admin"), {"qc", "admin"})

    def test_stray_brackets_and_quotes_are_stripped(self) -> None:
        self.assertEqual(service.role_set('{"admin","superadmin"}'), {"admin", "super_admin"})

    def test_semicolon_and_pipe_separators_and_hyphen(self) -> None:
        self.assertEqual(
            service.role_set("Admin;QC|super-admin"), {"admin", "qc", "super_admin"}
        )

    def test_blank_is_empty(self) -> None:
        self.assertEqual(service.role_set(""), set())
        self.assertEqual(service.role_set(None), set())  # type: ignore[arg-type]


class AccessLevelTests(unittest.TestCase):
    def test_matrix(self) -> None:
        cases = [
            (True, True, False, ("full", False)),
            (True, False, True, ("full", False)),
            (True, False, False, ("full", False)),
            (False, True, True, ("none", False)),
            (False, True, False, ("none", False)),
            (False, False, True, ("full", True)),
            (False, False, False, ("view", False)),
        ]
        for signed_in, db_reachable, client_is_local, expected in cases:
            with self.subTest(
                signed_in=signed_in, db_reachable=db_reachable, client_is_local=client_is_local
            ):
                self.assertEqual(
                    service.compute_access_level(
                        signed_in=signed_in,
                        db_reachable=db_reachable,
                        client_is_local=client_is_local,
                    ),
                    expected,
                )


class RateLimiterTests(unittest.TestCase):
    def test_locks_out_after_five_failures_and_resets_on_success(self) -> None:
        limiter = service.RateLimiter()
        for _ in range(service.LOGIN_ATTEMPT_LIMIT):
            self.assertTrue(limiter.check("1.2.3.4", "bob", now=1000.0))
            limiter.record_failure("1.2.3.4", "bob", now=1000.0)
        self.assertFalse(limiter.check("1.2.3.4", "bob", now=1000.0))
        limiter.reset("1.2.3.4", "bob")
        self.assertTrue(limiter.check("1.2.3.4", "bob", now=1000.0))

    def test_only_wrong_password_counts_a_key_apart_by_ip_and_username(self) -> None:
        limiter = service.RateLimiter()
        for _ in range(service.LOGIN_ATTEMPT_LIMIT):
            limiter.record_failure("1.2.3.4", "bob", now=1000.0)
        # A different username from the same IP is unaffected.
        self.assertTrue(limiter.check("1.2.3.4", "alice", now=1000.0))
        # The same username from a different IP is unaffected.
        self.assertTrue(limiter.check("9.9.9.9", "bob", now=1000.0))

    def test_failures_expire_after_the_window(self) -> None:
        limiter = service.RateLimiter()
        for _ in range(service.LOGIN_ATTEMPT_LIMIT):
            limiter.record_failure("1.2.3.4", "bob", now=0.0)
        self.assertFalse(limiter.check("1.2.3.4", "bob", now=1.0))
        self.assertTrue(
            limiter.check("1.2.3.4", "bob", now=service.LOGIN_ATTEMPT_WINDOW_SECONDS + 1.0)
        )


class SettingsMergeTests(unittest.TestCase):
    def test_keeps_keys_outside_the_allowed_list(self) -> None:
        current = {"input_root": "in", "output_root": "out", "poll_interval_seconds": 5}
        merged = service.merge_settings(current, {"crop_padding": 250})
        self.assertEqual(merged["poll_interval_seconds"], 5)
        self.assertEqual(merged["crop_padding"], 250)

    def test_blank_password_keeps_the_current_one(self) -> None:
        current = {"db_password": "secret"}
        merged = service.merge_settings(current, {"db_password": ""})
        self.assertEqual(merged["db_password"], "secret")

    def test_missing_password_keeps_the_current_one(self) -> None:
        current = {"db_password": "secret"}
        merged = service.merge_settings(current, {"workers": 2})
        self.assertEqual(merged["db_password"], "secret")

    def test_a_real_new_password_replaces_the_old_one(self) -> None:
        current = {"db_password": "secret"}
        merged = service.merge_settings(current, {"db_password": "new-secret"})
        self.assertEqual(merged["db_password"], "new-secret")

    def test_unknown_keys_in_the_update_are_ignored(self) -> None:
        merged = service.merge_settings({"input_root": "in"}, {"not_a_setting": "x"})
        self.assertNotIn("not_a_setting", merged)


class ApplySettingsUpdateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "in").mkdir()
        (self.root / "out").mkdir()
        self.config_path = self.root / "config.json"
        self.original = {
            "input_root": str(self.root / "in"),
            "output_root": str(self.root / "out"),
            "workers": 4,
            "crop_padding": 200,
        }
        self.config_path.write_text(json.dumps(self.original), encoding="utf-8")

    def test_accepted_update_replaces_the_file_and_keeps_other_keys(self) -> None:
        status, payload = service.apply_settings_update(self.config_path, {"workers": 2})
        self.assertEqual(status, 200)
        self.assertEqual(payload, {"restarting": True})
        on_disk = json.loads(self.config_path.read_text(encoding="utf-8"))
        self.assertEqual(on_disk["workers"], 2)
        self.assertEqual(on_disk["crop_padding"], 200)

    def test_invalid_update_is_rejected_and_leaves_the_file_untouched(self) -> None:
        before = self.config_path.read_bytes()
        status, payload = service.apply_settings_update(self.config_path, {"crop_padding": -5})
        self.assertEqual(status, 400)
        self.assertIn("error", payload)
        self.assertEqual(self.config_path.read_bytes(), before)
        # No temp file left behind either.
        leftovers = [p for p in self.root.iterdir() if p.name != self.config_path.name
                     and p.name not in ("in", "out")]
        self.assertEqual(leftovers, [])


class SummarizeStateTests(unittest.TestCase):
    def test_sample_state_and_status(self) -> None:
        status_doc = {
            "updated_at": "2026-09-25T00:00:00+00:00",
            "waiting": ["/a/waiting1"],
            "processing": ["/a/processing1", "/a/processing2"],
        }
        today = __import__("datetime").date(2026, 9, 25)
        state_doc = {
            "completed": {
                "/a/done-today": {
                    "completed_at": "2026-09-25T05:00:00+00:00",
                    "reported_at": "2026-09-25T05:01:00+00:00",
                    "retry_required": False,
                },
                "/a/done-yesterday": {
                    "completed_at": "2026-09-24T05:00:00+00:00",
                    "reported_at": "2026-09-24T05:01:00+00:00",
                    "retry_required": False,
                },
                "/a/failed": {
                    "completed_at": "2026-09-24T06:00:00+00:00",
                    "retry_required": True,
                },
            }
        }
        summary = service.summarize_state(status_doc, state_doc, today=today)
        self.assertEqual(summary["queue"]["waiting"], 1)
        self.assertEqual(summary["queue"]["processing"], 2)
        self.assertEqual(summary["queue"]["done_today"], 1)
        self.assertEqual(summary["queue"]["failed"], [{"folder": "/a/failed"}])
        self.assertEqual(summary["queue"]["updated_at"], "2026-09-25T00:00:00+00:00")
        self.assertEqual(summary["last_report_at"], "2026-09-25T05:01:00+00:00")

    def test_missing_documents_summarise_to_empty(self) -> None:
        today = __import__("datetime").date(2026, 9, 25)
        summary = service.summarize_state(None, None, today=today)
        self.assertEqual(
            summary["queue"],
            {"waiting": 0, "processing": 0, "done_today": 0, "failed": [], "updated_at": None},
        )
        self.assertIsNone(summary["last_report_at"])


class UiSettingsTests(unittest.TestCase):
    def test_defaults_when_absent(self) -> None:
        self.assertEqual(service.parse_ui_settings({}), (8090, "0.0.0.0"))

    def test_out_of_range_port_falls_back_to_default(self) -> None:
        self.assertEqual(service.parse_ui_settings({"ui_port": 99999}), (8090, "0.0.0.0"))

    def test_non_numeric_port_falls_back_to_default(self) -> None:
        self.assertEqual(service.parse_ui_settings({"ui_port": "not-a-number"}), (8090, "0.0.0.0"))

    def test_custom_values_are_honoured(self) -> None:
        self.assertEqual(
            service.parse_ui_settings({"ui_port": 9001, "ui_bind": "127.0.0.1"}),
            (9001, "127.0.0.1"),
        )


class StubSupervisor:
    """Everything the HTTP handler touches on a Supervisor, without spawning
    a process - the state object and request_restart()."""

    def __init__(self) -> None:
        self.state = service.SharedState()
        self.restart_calls = 0

    def request_restart(self) -> None:
        self.restart_calls += 1


class HttpApiTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        (root / "in").mkdir()
        (root / "out").mkdir()
        self.config_path = root / "config.json"
        self.config_path.write_text(
            json.dumps(
                {
                    "input_root": str(root / "in"),
                    "output_root": str(root / "out"),
                    "workers": 1,
                }
            ),
            encoding="utf-8",
        )

        self.password_hash = bcrypt.hashpw(b"correct horse battery", bcrypt.gensalt()).decode(
            "ascii"
        )

        def fake_lookup(config, username):  # noqa: ANN001
            if username == "admin":
                return {
                    "password": self.password_hash,
                    "roles": "admin",
                    "active": True,
                    "is_deleted": False,
                }
            return None

        self.supervisor = StubSupervisor()
        self.supervisor.state.update(database_reachable=True, database_checked_at="now")

        ctx = service.ServiceContext(
            config_path=self.config_path,
            supervisor=self.supervisor,  # type: ignore[arg-type]
            sessions=service.SessionStore(),
            rate_limiter=service.RateLimiter(),
            db_lookup=fake_lookup,
            web_dir=root / "web",
        )
        handler_cls = service.build_handler(ctx)
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler_cls)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.httpd.shutdown)
        self.addCleanup(self.thread.join, 5)

    def _connection(self) -> http.client.HTTPConnection:
        return http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)

    def test_unauthenticated_status_is_401_when_db_reachable(self) -> None:
        conn = self._connection()
        try:
            conn.request("GET", "/api/status")
            resp = conn.getresponse()
            self.assertEqual(resp.status, 401)
            resp.read()
        finally:
            conn.close()

    def test_post_without_csrf_header_is_forbidden(self) -> None:
        conn = self._connection()
        try:
            conn.request(
                "POST",
                "/api/login",
                body=json.dumps({}).encode("utf-8"),
                headers={"Content-Type": "application/json"},
            )
            resp = conn.getresponse()
            self.assertEqual(resp.status, 403)
            resp.read()
        finally:
            conn.close()

    def test_login_then_settings(self) -> None:
        conn = self._connection()
        try:
            conn.request(
                "POST",
                "/api/login",
                body=json.dumps({"username": "admin", "password": "correct horse battery"}).encode(
                    "utf-8"
                ),
                headers={"Content-Type": "application/json", "X-Requested-With": "lwip"},
            )
            resp = conn.getresponse()
            self.assertEqual(resp.status, 200)
            set_cookie = resp.getheader("Set-Cookie")
            self.assertIsNotNone(set_cookie)
            token = set_cookie.split(";", 1)[0]
            resp.read()
        finally:
            conn.close()

        conn = self._connection()
        try:
            conn.request("GET", "/api/settings", headers={"Cookie": token})
            resp = conn.getresponse()
            self.assertEqual(resp.status, 200)
            payload = json.loads(resp.read())
            self.assertEqual(
                payload["input_root"], str(Path(self.temp.name) / "in")
            )
            self.assertFalse(payload["db_password_set"])
        finally:
            conn.close()

    def test_wrong_password_is_rejected(self) -> None:
        conn = self._connection()
        try:
            conn.request(
                "POST",
                "/api/login",
                body=json.dumps({"username": "admin", "password": "wrong"}).encode("utf-8"),
                headers={"Content-Type": "application/json", "X-Requested-With": "lwip"},
            )
            resp = conn.getresponse()
            self.assertEqual(resp.status, 401)
            resp.read()
        finally:
            conn.close()


class SupervisorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        # A config that doesn't need to exist: these tests use a fake child
        # command that ignores it entirely.
        self.config_path = Path(self.temp.name) / "missing_config.json"

    def test_crash_sets_crashed_state_then_restarts(self) -> None:
        import sys

        crash_command = [sys.executable, "-c", "import sys; sys.exit(3)"]
        supervisor = service.Supervisor(
            self.config_path,
            backoff_seconds=0.05,
            poll_interval=0.01,
            child_command_factory=lambda _path: crash_command,
        )
        thread = threading.Thread(target=supervisor.run, daemon=True)
        thread.start()
        deadline = time.monotonic() + 10
        seen_crash = False
        while time.monotonic() < deadline:
            snap = supervisor.state.snapshot()
            if snap.get("state") == "crashed" and snap.get("last_exit_code") == 3:
                seen_crash = True
                break
            time.sleep(0.02)
        supervisor.request_shutdown()
        thread.join(5)
        self.assertTrue(seen_crash, "supervisor never reported the crash")
        self.assertFalse(thread.is_alive())

    def test_clean_exit_stops_the_supervisor(self) -> None:
        import sys

        clean_command = [sys.executable, "-c", "import sys; sys.exit(0)"]
        supervisor = service.Supervisor(
            self.config_path,
            backoff_seconds=0.05,
            poll_interval=0.01,
            child_command_factory=lambda _path: clean_command,
        )
        result = supervisor.run()
        self.assertEqual(result, 0)
        snap = supervisor.state.snapshot()
        self.assertEqual(snap.get("state"), "stopped")
        self.assertEqual(snap.get("last_exit_code"), 0)


if __name__ == "__main__":
    unittest.main()

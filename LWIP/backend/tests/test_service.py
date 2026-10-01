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
import os
import socket
import tempfile
import threading
import time
import types
import unittest
from unittest import mock
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

import bcrypt

from deskew_crop_tool import lwcam_secrets, netlogin, service
from deskew_crop_tool import service as MODULE


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
            (False, False, True, ("view", False)),
            (False, False, False, ("none", False)),  # a remote browser gets the sign-in form only
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

    def test_changing_db_host_without_the_password_is_refused(self) -> None:
        self.config_path.write_text(
            json.dumps({**self.original, "db_host": "old-host", "db_password": "pw"}),
            encoding="utf-8",
        )
        before = self.config_path.read_bytes()
        status, payload = service.apply_settings_update(self.config_path, {"db_host": "new-host"})
        self.assertEqual(status, 400)
        self.assertIn("password again", payload["error"])
        self.assertEqual(self.config_path.read_bytes(), before)

    def test_changing_db_host_with_the_password_is_saved(self) -> None:
        self.config_path.write_text(
            json.dumps({**self.original, "db_host": "old-host", "db_password": "pw"}),
            encoding="utf-8",
        )
        status, _payload = service.apply_settings_update(
            self.config_path, {"db_host": "new-host", "db_password": "pw2"}
        )
        self.assertEqual(status, 200)
        on_disk = json.loads(self.config_path.read_text(encoding="utf-8"))
        self.assertEqual(on_disk["db_host"], "new-host")
        self.assertEqual(lwcam_secrets.unprotect(on_disk["db_password"]), "pw2")  # stored protected

    def test_resending_the_same_db_values_needs_no_password(self) -> None:
        self.config_path.write_text(
            json.dumps({**self.original, "db_host": "h", "db_port": 5432, "db_password": "pw"}),
            encoding="utf-8",
        )
        status, _payload = service.apply_settings_update(
            self.config_path, {"db_host": "h", "db_port": "5432", "workers": 2}
        )
        self.assertEqual(status, 200)


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

    def test_a_second_sign_in_elsewhere_is_refused(self) -> None:
        body = json.dumps({"username": "admin", "password": "correct horse battery"}).encode("utf-8")
        headers = {"Content-Type": "application/json", "X-Requested-With": "lwip"}
        statuses = []
        for _ in range(2):  # two browsers: no cookie shared between them
            conn = self._connection()
            try:
                conn.request("POST", "/api/login", body=body, headers=headers)
                resp = conn.getresponse()
                statuses.append((resp.status, json.loads(resp.read()).get("error")))
            finally:
                conn.close()
        self.assertEqual(statuses[0], (200, None))
        self.assertEqual(statuses[1], (409, service.ALREADY_SIGNED_IN))

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

    def test_an_unreadable_request_is_one_warning_not_a_traceback(self) -> None:
        # What a browser sends when the console is opened with https://: the
        # request line never parses, so `path` is never set. The handler's
        # log_message used to read self.path and raise AttributeError.
        with self.assertLogs(service.LOGGER, "WARNING") as logs:
            with socket.create_connection(("127.0.0.1", self.port), timeout=5) as sock:
                sock.sendall(b"\x16\x03\x01\x02\x00 \x01\xfc\x03\x03 garbage\r\n\r\n")
                self.assertIn(b" 400 ", sock.recv(4096))
        self.assertEqual(len(logs.records), 1)
        self.assertIn("Unreadable request from 127.0.0.1", logs.output[0])

        conn = self._connection()
        try:
            conn.request("GET", "/api/session")
            self.assertEqual(conn.getresponse().status, 200)
        finally:
            conn.close()

    def test_network_logins_need_full_access_and_list_without_passwords(self) -> None:
        conn = self._connection()
        try:
            conn.request("GET", "/api/network-logins")
            resp = conn.getresponse()
            self.assertEqual(resp.status, 401)
            resp.read()
        finally:
            conn.close()

        # Signed in, then the database goes down: the session keeps full access.
        conn = self._connection()
        try:
            conn.request(
                "POST", "/api/login",
                body=json.dumps({"username": "admin", "password": "correct horse battery"}).encode("utf-8"),
                headers={"Content-Type": "application/json", "X-Requested-With": "lwip"},
            )
            resp = conn.getresponse()
            cookie = resp.getheader("Set-Cookie").split(";", 1)[0]
            resp.read()
        finally:
            conn.close()
        self.supervisor.state.update(database_reachable=False)
        store = Path(self.temp.name) / "logins.json"
        with patch.dict(os.environ, {netlogin.STORE_ENV: str(store)}), \
                patch.object(netlogin, "_add_connection", return_value=0), patch.object(netlogin, "_cancel"):
            conn = self._connection()
            try:
                conn.request(
                    "POST", "/api/network-logins",
                    body=json.dumps({"host": "FILE-PC", "username": "u", "password": "secret"}).encode("utf-8"),
                    headers={"Content-Type": "application/json", "X-Requested-With": "lwip",
                             "Cookie": cookie},
                )
                resp = conn.getresponse()
                self.assertEqual(json.loads(resp.read()), {"error": None})
                conn.request("GET", "/api/network-logins", headers={"Cookie": cookie})
                body = conn.getresponse().read()
            finally:
                conn.close()
        self.assertEqual(json.loads(body)["logins"][0]["host"], "FILE-PC")
        self.assertNotIn(b"secret", body)

    def test_status_carries_the_database_error(self) -> None:
        # Database down + no session = read-only view, so the
        # status is readable without signing in.
        self.supervisor.state.update(
            database_reachable=False, database_error="no pg_hba.conf entry for host"
        )
        conn = self._connection()
        try:
            conn.request("GET", "/api/status")
            resp = conn.getresponse()
            self.assertEqual(resp.status, 200)
            database = json.loads(resp.read())["database"]
            self.assertFalse(database["reachable"])
            self.assertEqual(database["error"], "no pg_hba.conf entry for host")
        finally:
            conn.close()


class DatabaseProbeTests(unittest.TestCase):
    def test_a_refused_connection_returns_the_reason(self) -> None:
        with socket.socket() as spare:
            spare.bind(("127.0.0.1", 0))
            closed_port = spare.getsockname()[1]
        config = types.SimpleNamespace(
            db_host="127.0.0.1",
            db_port=closed_port,
            db_name="lwcam",
            db_user="postgres",
            db_password="secret-never-shown",
            db_use_ssl=False,
        )
        error = service.probe_db(config, timeout=2)  # type: ignore[arg-type]
        self.assertIsInstance(error, str)
        self.assertTrue(error)
        self.assertNotIn("secret-never-shown", error)

    def test_a_database_that_stays_down_logs_once(self) -> None:
        supervisor = service.Supervisor(Path("unused.json"))
        with self.assertLogs(service.LOGGER, "INFO") as logs:
            supervisor.record_probe("refused")
            supervisor.record_probe("refused")
            supervisor.record_probe("password authentication failed")
            supervisor.record_probe(None)
            supervisor.record_probe(None)
        self.assertEqual(
            [r.getMessage() for r in logs.records],
            [
                "Database unreachable: refused",
                "Database unreachable: password authentication failed",
                "Database reachable again.",
            ],
        )
        snap = supervisor.state.snapshot()
        self.assertTrue(snap["database_reachable"])
        self.assertIsNone(snap["database_error"])


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


class SingleSignInTests(unittest.TestCase):
    """One live sign-in per account: the FIRST wins (SessionStore.create)."""

    def setUp(self) -> None:
        self.clock = 1000.0
        patcher = mock.patch.object(MODULE.time, "monotonic", lambda: self.clock)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.store = MODULE.SessionStore()

    def test_a_second_sign_in_is_refused_while_the_first_is_in_use(self) -> None:
        first = self.store.create("admin")
        self.clock += 170
        self.assertIsNone(self.store.create("Admin"), "same account, whatever the case")
        self.assertEqual(self.store.username_for(first), "admin")

    def test_polling_keeps_it_in_use(self) -> None:
        first = self.store.create("admin")
        for _ in range(10):
            self.clock += 60
            self.store.username_for(first)
        self.assertIsNone(self.store.create("admin"))

    def test_a_closed_browser_frees_the_account_after_the_idle_wait(self) -> None:
        first = self.store.create("admin")
        self.clock += MODULE.SESSION_IDLE_SECONDS + 1
        second = self.store.create("admin")
        self.assertIsNotNone(second)
        self.assertIsNone(self.store.username_for(first))
        self.assertTrue(self.store.was_replaced(first), "so that browser is told why")

    def test_signing_out_frees_it_at_once(self) -> None:
        first = self.store.create("admin")
        self.store.remove(first)
        self.assertIsNotNone(self.store.create("admin"))

    def test_the_same_browser_is_not_blocked_by_itself(self) -> None:
        first = self.store.create("admin")
        self.assertIsNotNone(self.store.create("admin", current_token=first))
        self.assertFalse(self.store.was_replaced(first))

    def test_other_accounts_are_unaffected(self) -> None:
        self.store.create("admin")
        self.assertIsNotNone(self.store.create("someone-else"))


class DatabaseDownSignInTests(unittest.TestCase):
    """Sign-in from the saved admin list, and the caps on wrong guesses."""

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        (root / "watch").mkdir()
        (root / "in").mkdir()
        (root / "out").mkdir()
        self.config_path = root / "config.json"
        self.config_path.write_text(
            json.dumps({"input_root": str(root / "in"), "output_root": str(root / "out"), "workers": 1}), encoding="utf-8"
        )
        self.hash = bcrypt.hashpw(b"right-password", bcrypt.gensalt(4)).decode("ascii")
        self.accounts = {
            "admin": ("admin", True),
            "boss": ("super_admin", True),
            "worker": ("qc", True),
        }
        self.db_up = True

        def fake_lookup(config, username):  # noqa: ANN001
            if not self.db_up:
                raise service.DbUnavailable("down")
            if username not in self.accounts:
                return None
            roles, active = self.accounts[username]
            return {"password": self.hash, "roles": roles, "active": active, "is_deleted": False}

        self.limiter = service.RateLimiter()
        ctx, self.state = self._make_ctx(fake_lookup, root)
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), service.build_handler(ctx))
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

        def _stop() -> None:
            self.httpd.shutdown()
            self.thread.join(5)
            self.httpd.server_close()

        self.addCleanup(_stop)

    def _make_ctx(self, fake_lookup, root):
        state = service.SharedState()
        state.update(database_reachable=True, database_checked_at="now")
        supervisor = types.SimpleNamespace(state=state, request_restart=lambda: None)
        ctx = service.ServiceContext(
            config_path=self.config_path,
            supervisor=supervisor,
            sessions=service.SessionStore(),
            rate_limiter=self.limiter,
            db_lookup=fake_lookup,
            web_dir=root / "web",
        )
        return ctx, state

    def _call(self, method, path, body=None, cookie=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        headers = {"Content-Type": "application/json", "X-Requested-With": "lwip"}
        if cookie:
            headers["Cookie"] = cookie
        try:
            conn.request(
                method, path, body=json.dumps(body).encode("utf-8") if body is not None else None,
                headers=headers,
            )
            resp = conn.getresponse()
            set_cookie = resp.getheader("Set-Cookie")
            payload = json.loads(resp.read() or b"{}")
            return resp.status, payload, (set_cookie.split(";", 1)[0] if set_cookie else None)
        finally:
            conn.close()

    def _login(self, username, password="right-password", cookie=None):
        return self._call(
            "POST", "/api/login", {"username": username, "password": password}, cookie=cookie
        )

    def test_cached_admin_signs_in_while_the_database_is_down(self) -> None:
        _, _, first = self._login("admin")   # caches "admin"
        self.assertEqual(self._login("boss")[0], 200)    # caches "boss"
        cached = {r["user_id"] for r in service.read_admin_cache(self.config_path)}
        self.assertEqual(cached, {"admin", "boss"})
        self.db_up = False
        status, _payload, cookie = self._login("admin", cookie=first)  # same browser
        self.assertEqual(status, 200)
        status, session, _ = self._call("GET", "/api/session", cookie=cookie)
        self.assertEqual((session["access"], session["from_cache"]), ("full", True))

    def test_down_wrong_password_or_non_admin_or_uncached_is_refused(self) -> None:
        self.assertEqual(self._login("admin")[0], 200)
        self.assertEqual(self._login("worker")[0], 403)  # not an admin: never cached
        self.assertNotIn("worker", {r["user_id"] for r in service.read_admin_cache(self.config_path)})
        self.db_up = False
        self.assertEqual(self._login("admin", "wrong")[0], 401)
        self.assertEqual(self._login("worker")[0], 401)
        self.assertEqual(self._login("boss")[0], 401)    # admin, but never signed in here

    def test_down_local_client_without_a_session_is_read_only(self) -> None:
        self.state.update(database_reachable=False)
        status, session, _ = self._call("GET", "/api/session")
        self.assertEqual((session["access"], session["signed_in"]), ("view", False))
        self.assertEqual(self._call("GET", "/api/status")[0], 200)
        self.assertEqual(self._call("GET", "/api/settings")[0], 403)
        self.assertEqual(self._call("POST", "/api/settings", {"workers": 2})[0], 403)

    def test_refresh_drops_an_admin_that_is_no_longer_listed(self) -> None:
        listed = [("a", "h1", "admin"), ("b", "h2", "super_admin")]
        service.refresh_admin_cache(None, self.config_path, fetch=lambda _c: listed)
        self.assertEqual({r["user_id"] for r in service.read_admin_cache(self.config_path)}, {"a", "b"})
        service.refresh_admin_cache(None, self.config_path, fetch=lambda _c: listed[:1])
        rows = service.read_admin_cache(self.config_path)
        self.assertEqual([r["user_id"] for r in rows], ["a"])
        self.assertEqual(set(rows[0]), {"user_id", "password", "roles", "cached_at"})

    def test_a_disabled_admin_is_refused_at_the_next_good_sign_in_only_by_the_database(self) -> None:
        self.assertEqual(self._login("admin")[0], 200)
        self.accounts["admin"] = ("admin", False)
        self.assertEqual(self._login("admin")[0], 403)

    def test_twenty_failures_from_one_ip_lock_every_username_out(self) -> None:
        for i in range(service.IP_ATTEMPT_LIMIT):
            self.limiter.record_failure("127.0.0.1", f"user{i}")
        self.assertEqual(self._login("admin")[0], 429)

    def test_ip_cap_is_unit_visible_and_expires(self) -> None:
        limiter = service.RateLimiter()
        for i in range(service.IP_ATTEMPT_LIMIT):
            limiter.record_failure("1.2.3.4", f"user{i}", now=0.0)
        self.assertFalse(limiter.check("1.2.3.4", "fresh", now=1.0))
        self.assertTrue(limiter.check("9.9.9.9", "fresh", now=1.0))
        self.assertTrue(limiter.check("1.2.3.4", "fresh", now=service.IP_ATTEMPT_WINDOW_SECONDS + 1))

    def test_unknown_username_still_runs_bcrypt_against_the_dummy_hash(self) -> None:
        with mock.patch.object(service.bcrypt, "checkpw", return_value=False) as checkpw:
            status, _payload, _ = self._login("nobody")
        self.assertEqual(status, 401)
        checkpw.assert_called_once()
        self.assertEqual(checkpw.call_args[0][1], service.DUMMY_HASH.encode("ascii"))


if __name__ == "__main__":
    unittest.main()

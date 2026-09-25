"""Tests for the Upload console (lwcam_upload.console).

Most of this needs neither a database nor a real socket: role parsing (shared
with LWIP's test suite, ported here since this app has its own copy of the
same functions), the access-level matrix, settings merge/validate, and the
ring buffer are all pure. The one HTTP test starts a real ThreadingHTTPServer
on port 0 with a fake user-lookup callable, same shape as LWIP's own
`test_service.py::HttpApiTests`. The loop test starts `console.run()` in a
background thread and proves a dropped `stop.request` file makes it return 0.
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

import lwcam_upload
from lwcam_upload import console
from lwcam_upload.engine import UploadCoordinator


class RoleParsingTests(unittest.TestCase):
    def test_single_role(self) -> None:
        self.assertEqual(console.role_set("admin"), {"admin"})

    def test_comma_joined_roles(self) -> None:
        self.assertEqual(console.role_set("qc,admin"), {"qc", "admin"})

    def test_stray_brackets_and_quotes_are_stripped(self) -> None:
        self.assertEqual(console.role_set('{"admin","superadmin"}'), {"admin", "super_admin"})

    def test_blank_is_empty(self) -> None:
        self.assertEqual(console.role_set(""), set())


class AccessLevelMatrixTests(unittest.TestCase):
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
                    console.compute_access_level(
                        signed_in=signed_in,
                        db_reachable=db_reachable,
                        client_is_local=client_is_local,
                    ),
                    expected,
                )


class RateLimiterTests(unittest.TestCase):
    def test_locks_out_after_five_failures_and_resets_on_success(self) -> None:
        limiter = console.RateLimiter()
        for _ in range(console.LOGIN_ATTEMPT_LIMIT):
            self.assertTrue(limiter.check("1.2.3.4", "bob", now=1000.0))
            limiter.record_failure("1.2.3.4", "bob", now=1000.0)
        self.assertFalse(limiter.check("1.2.3.4", "bob", now=1000.0))
        limiter.reset("1.2.3.4", "bob")
        self.assertTrue(limiter.check("1.2.3.4", "bob", now=1000.0))


class SettingsMergeTests(unittest.TestCase):
    def test_keeps_keys_outside_the_allowed_list(self) -> None:
        current = {"watch_root": "w", "some_future_key": 5}
        merged = console.merge_settings(current, {"interval_seconds": 90})
        self.assertEqual(merged["some_future_key"], 5)
        self.assertEqual(merged["interval_seconds"], 90)

    def test_blank_s3_secret_key_keeps_the_current_one(self) -> None:
        current = {"s3_secret_key": "secret"}
        merged = console.merge_settings(current, {"s3_secret_key": ""})
        self.assertEqual(merged["s3_secret_key"], "secret")

    def test_blank_db_password_keeps_the_current_one(self) -> None:
        current = {"db_password": "secret"}
        merged = console.merge_settings(current, {"db_password": ""})
        self.assertEqual(merged["db_password"], "secret")

    def test_a_real_new_secret_replaces_the_old_one(self) -> None:
        current = {"s3_secret_key": "secret"}
        merged = console.merge_settings(current, {"s3_secret_key": "new-secret"})
        self.assertEqual(merged["s3_secret_key"], "new-secret")

    def test_unknown_keys_in_the_update_are_ignored(self) -> None:
        merged = console.merge_settings({"watch_root": "w"}, {"not_a_setting": "x"})
        self.assertNotIn("not_a_setting", merged)


class ApplySettingsUpdateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app_root = Path(self.temp.name)
        config_dir = self.app_root / "config"
        config_dir.mkdir()
        self.config_path = config_dir / "upload_config.json"
        self.watch_root = self.app_root / "watch"
        self.watch_root.mkdir()
        self.original = {"watch_root": str(self.watch_root), "enabled": False, "interval_seconds": 60}
        self.config_path.write_text(json.dumps(self.original), encoding="utf-8")

    def test_accepted_update_replaces_the_file_and_keeps_other_keys(self) -> None:
        status, payload = console.apply_settings_update(self.config_path, {"interval_seconds": 30})
        self.assertEqual(status, 200)
        self.assertEqual(payload, {"saved": True})
        on_disk = json.loads(self.config_path.read_text(encoding="utf-8"))
        self.assertEqual(on_disk["interval_seconds"], 30)
        self.assertEqual(on_disk["watch_root"], str(self.watch_root))

    def test_invalid_update_is_rejected_and_leaves_the_file_untouched(self) -> None:
        before = self.config_path.read_bytes()
        status, payload = console.apply_settings_update(
            self.config_path, {"interval_seconds": 1}
        )
        self.assertEqual(status, 400)
        self.assertIn("error", payload)
        self.assertEqual(self.config_path.read_bytes(), before)
        leftovers = [
            p for p in self.app_root.iterdir() if p.name not in ("config", "watch")
        ]
        self.assertEqual(leftovers, [])

    def test_done_root_inside_watch_root_is_rejected(self) -> None:
        status, payload = console.apply_settings_update(
            self.config_path, {"done_root": str(self.watch_root / "done")}
        )
        self.assertEqual(status, 400)
        self.assertIn("error", payload)


class RingBufferPagingTests(unittest.TestCase):
    def setUp(self) -> None:
        # Idempotent: the very first call in the whole test process wins, and
        # every later call (here or from another test module) is a no-op -
        # see __init__.configure_logging. The log file this first call opens
        # is never closed for the life of the process (that's how a
        # RotatingFileHandler works), so it must not live in a directory a
        # test then tries to delete - a plain, uncleaned temp path instead.
        lwcam_upload.configure_logging(
            Path(tempfile.gettempdir()) / "lwcam_upload_test_ring_buffer.log"
        )

    def test_after_only_returns_newer_lines(self) -> None:
        baseline = lwcam_upload.log_last_seq()
        lwcam_upload.log("SYSTEM", "ring-buffer-test-line-1")
        lwcam_upload.log("SYSTEM", "ring-buffer-test-line-2")

        lines = lwcam_upload.log_lines_after(baseline)

        texts = [line["text"] for line in lines]
        self.assertTrue(any("ring-buffer-test-line-1" in t for t in texts))
        self.assertTrue(any("ring-buffer-test-line-2" in t for t in texts))
        seqs = [line["seq"] for line in lines]
        self.assertEqual(seqs, sorted(seqs))
        self.assertTrue(all(s > baseline for s in seqs))
        for text in texts:
            self.assertRegex(text, r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \[\w+\] ")

    def test_after_current_last_seq_returns_nothing_new(self) -> None:
        lwcam_upload.log("SYSTEM", "settle")
        last = lwcam_upload.log_last_seq()
        self.assertEqual(lwcam_upload.log_lines_after(last), [])


class HttpApiTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        (root / "watch").mkdir()
        self.config_path = root / "config.json"
        self.config_path.write_text(
            json.dumps(
                {
                    "watch_root": str(root / "watch"),
                    "enabled": False,
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

        state = console.ServiceState()
        state.update(database_reachable=True, database_checked_at="now")

        ctx = console.ServiceContext(
            config_path=self.config_path,
            coordinator=UploadCoordinator(),
            state=state,
            wake=threading.Event(),
            sessions=console.SessionStore(),
            rate_limiter=console.RateLimiter(),
            db_lookup=fake_lookup,
            web_dir=root / "web",
        )
        handler_cls = console.build_handler(ctx)
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler_cls)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

        def _stop_server() -> None:
            self.httpd.shutdown()
            self.thread.join(5)
            self.httpd.server_close()

        self.addCleanup(_stop_server)

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

    def test_login_then_settings_has_no_secret_values(self) -> None:
        conn = self._connection()
        try:
            conn.request(
                "POST",
                "/api/login",
                body=json.dumps(
                    {"username": "admin", "password": "correct horse battery"}
                ).encode("utf-8"),
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
            self.assertNotIn("s3_secret_key", payload)
            self.assertNotIn("db_password", payload)
            self.assertIn("s3_secret_key_set", payload)
            self.assertIn("db_password_set", payload)
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


class StopLoopTests(unittest.TestCase):
    def test_stop_request_file_makes_the_loop_exit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            app_root = Path(tmp)
            config_dir = app_root / "config"
            config_dir.mkdir()
            config_path = config_dir / "upload_config.json"
            watch_root = app_root / "watch"
            watch_root.mkdir()
            runtime_dir = app_root / "runtime"
            runtime_dir.mkdir()

            import socket

            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
                probe.bind(("127.0.0.1", 0))
                free_port = probe.getsockname()[1]

            config_path.write_text(
                json.dumps(
                    {
                        "watch_root": str(watch_root),
                        "enabled": False,
                        "interval_seconds": 5,
                        "ui_port": free_port,
                        "ui_bind": "127.0.0.1",
                    }
                ),
                encoding="utf-8",
            )

            result: list[int] = []

            def target() -> None:
                result.append(console.run(config_path))

            thread = threading.Thread(target=target, daemon=True)
            thread.start()
            time.sleep(0.3)  # let the loop reach its idle wait at least once

            (runtime_dir / "stop.request").write_text("", encoding="utf-8")

            thread.join(timeout=10)
            self.assertFalse(thread.is_alive(), "loop did not exit after stop.request")
            self.assertEqual(result, [0])
            self.assertFalse((runtime_dir / "stop.request").exists(), "stop.request must be consumed")


if __name__ == "__main__":
    unittest.main()

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
import os
import tempfile
import threading
import time
import unittest
from unittest import mock
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

import bcrypt

import lwcam_upload
from lwcam_upload import console, lwcam_secrets, netlogin
from lwcam_upload.engine import UploadCoordinator
from lwcam_upload import console as MODULE


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
            (False, False, True, ("view", False)),
            (False, False, False, ("none", False)),  # remote + database down: nothing
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

    def test_changing_db_host_without_the_password_is_refused(self) -> None:
        self.config_path.write_text(
            json.dumps({**self.original, "db_host": "old-host", "db_password": "pw"}),
            encoding="utf-8",
        )
        before = self.config_path.read_bytes()
        status, payload = console.apply_settings_update(self.config_path, {"db_host": "new-host"})
        self.assertEqual(status, 400)
        self.assertIn("password again", payload["error"])
        self.assertEqual(self.config_path.read_bytes(), before)

    def test_changing_db_host_with_the_password_is_saved(self) -> None:
        self.config_path.write_text(
            json.dumps({**self.original, "db_host": "old-host", "db_password": "pw"}),
            encoding="utf-8",
        )
        status, _payload = console.apply_settings_update(
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
        status, _payload = console.apply_settings_update(
            self.config_path, {"db_host": "h", "db_port": "5432", "workers": 2}
        )
        self.assertEqual(status, 200)

    def test_changing_s3_path_without_the_secret_is_refused(self) -> None:
        status, payload = console.apply_settings_update(
            self.config_path, {"s3_path": "s3://other-bucket/x"}
        )
        self.assertEqual(status, 400)
        self.assertIn("secret key again", payload["error"])

    def test_changing_s3_path_with_the_secret_is_saved(self) -> None:
        status, _payload = console.apply_settings_update(
            self.config_path, {"s3_path": "s3://other-bucket/x", "s3_secret_key": "s"}
        )
        self.assertEqual(status, 200)


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

    def test_network_logins_need_sign_in_and_never_return_the_password(self) -> None:
        conn = self._connection()
        try:
            conn.request("GET", "/api/network-logins")
            resp = conn.getresponse()
            self.assertEqual(resp.status, 401)
            resp.read()
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

        store = Path(self.temp.name) / "logins.json"
        with patch.dict(os.environ, {netlogin.STORE_ENV: str(store)}), \
                patch.object(netlogin, "_add_connection", return_value=1326), patch.object(netlogin, "_cancel"):
            conn = self._connection()
            try:
                conn.request(
                    "POST", "/api/network-logins",
                    body=json.dumps({"host": "FILE-PC", "username": "u", "password": "secret"}).encode("utf-8"),
                    headers={"Content-Type": "application/json", "X-Requested-With": "lwip", "Cookie": cookie},
                )
                saved = json.loads(conn.getresponse().read())
                conn.request("GET", "/api/network-logins", headers={"Cookie": cookie})
                body = conn.getresponse().read()
            finally:
                conn.close()
        # Saved even though the PC refused it - it may simply be off.
        self.assertEqual(saved, {"error": "FILE-PC did not accept this username or password."})
        self.assertEqual(json.loads(body)["logins"][0]["username"], "u")
        self.assertNotIn(b"secret", body)

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
                        "interval_seconds": 10,
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
            json.dumps({"watch_root": str(root / "watch"), "enabled": False}), encoding="utf-8"
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
                raise console.DbUnavailable("down")
            if username not in self.accounts:
                return None
            roles, active = self.accounts[username]
            return {"password": self.hash, "roles": roles, "active": active, "is_deleted": False}

        self.limiter = console.RateLimiter()
        ctx, self.state = self._make_ctx(fake_lookup, root)
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), console.build_handler(ctx))
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

        def _stop() -> None:
            self.httpd.shutdown()
            self.thread.join(5)
            self.httpd.server_close()

        self.addCleanup(_stop)

    def _make_ctx(self, fake_lookup, root):
        state = console.ServiceState()
        state.update(database_reachable=True, database_checked_at="now")
        ctx = console.ServiceContext(
            config_path=self.config_path,
            coordinator=UploadCoordinator(),
            state=state,
            wake=threading.Event(),
            sessions=console.SessionStore(),
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
        cached = {r["user_id"] for r in console.read_admin_cache(self.config_path)}
        self.assertEqual(cached, {"admin", "boss"})
        self.db_up = False
        status, _payload, cookie = self._login("admin", cookie=first)  # same browser
        self.assertEqual(status, 200)
        status, session, _ = self._call("GET", "/api/session", cookie=cookie)
        self.assertEqual((session["access"], session["from_cache"]), ("full", True))

    def test_down_wrong_password_or_non_admin_or_uncached_is_refused(self) -> None:
        self.assertEqual(self._login("admin")[0], 200)
        self.assertEqual(self._login("worker")[0], 403)  # not an admin: never cached
        self.assertNotIn("worker", {r["user_id"] for r in console.read_admin_cache(self.config_path)})
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
        console.refresh_admin_cache(None, self.config_path, fetch=lambda _c: listed)
        self.assertEqual({r["user_id"] for r in console.read_admin_cache(self.config_path)}, {"a", "b"})
        console.refresh_admin_cache(None, self.config_path, fetch=lambda _c: listed[:1])
        rows = console.read_admin_cache(self.config_path)
        self.assertEqual([r["user_id"] for r in rows], ["a"])
        self.assertEqual(set(rows[0]), {"user_id", "password", "roles", "cached_at"})

    def test_a_disabled_admin_is_refused_at_the_next_good_sign_in_only_by_the_database(self) -> None:
        self.assertEqual(self._login("admin")[0], 200)
        self.accounts["admin"] = ("admin", False)
        self.assertEqual(self._login("admin")[0], 403)

    def test_twenty_failures_from_one_ip_lock_every_username_out(self) -> None:
        for i in range(console.IP_ATTEMPT_LIMIT):
            self.limiter.record_failure("127.0.0.1", f"user{i}")
        self.assertEqual(self._login("admin")[0], 429)

    def test_ip_cap_is_unit_visible_and_expires(self) -> None:
        limiter = console.RateLimiter()
        for i in range(console.IP_ATTEMPT_LIMIT):
            limiter.record_failure("1.2.3.4", f"user{i}", now=0.0)
        self.assertFalse(limiter.check("1.2.3.4", "fresh", now=1.0))
        self.assertTrue(limiter.check("9.9.9.9", "fresh", now=1.0))
        self.assertTrue(limiter.check("1.2.3.4", "fresh", now=console.IP_ATTEMPT_WINDOW_SECONDS + 1))

    def test_unknown_username_still_runs_bcrypt_against_the_dummy_hash(self) -> None:
        with mock.patch.object(console.bcrypt, "checkpw", return_value=False) as checkpw:
            status, _payload, _ = self._login("nobody")
        self.assertEqual(status, 401)
        checkpw.assert_called_once()
        self.assertEqual(checkpw.call_args[0][1], console.DUMMY_HASH.encode("ascii"))


if __name__ == "__main__":
    unittest.main()

"""Round-2 hardening: HEAD 403, database write-back, heartbeat thread, retry
race, ledger damage, links, console limits, proxy."""

from __future__ import annotations

import http.client
import json
import logging
import os
import subprocess
import sys
import threading
import time
import types
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import mock

from lwcam_upload import console, engine, health
from lwcam_upload.engine import S3Store, UploadCoordinator, group_id_for
from lwcam_upload.ledger import JsonLedger, LedgerCorrupt, LedgerUnavailable, atomic_json
from tests.test_health import Conn, FakeClientError
from tests.test_upload_reupload import FakeStore, _config, _target


class TempRootCase(unittest.TestCase):
    def setUp(self) -> None:
        # No settle wait: these tests upload on the first scan.
        patcher = mock.patch.object(engine, "SETTLE_SECONDS", 0)
        patcher.start()
        self.addCleanup(patcher.stop)
        self._tmp = TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.watch = self.root / "watch"
        self.watch.mkdir()

    def package(self, name: str, data: bytes = b"page") -> Path:
        folder = self.watch / name
        folder.mkdir()
        (folder / "p.tif").write_bytes(data)
        return folder

    def config(self, **overrides):
        return _config(self.watch, state_file=self.root / "uploads.json", **overrides)


class HeadDeniedTests(unittest.TestCase):
    """A 403 on HEAD (PutObject-only IAM policy) is not 'keys rejected'."""

    def _store(self, head):
        class ClientError(Exception):
            def __init__(self, code):
                super().__init__(code)
                self.response = {"Error": {"Code": code}}

        client = mock.Mock()
        client.head_object.side_effect = head(ClientError)
        modules = {
            "boto3": types.SimpleNamespace(client=lambda *a, **k: client),
            "botocore": types.ModuleType("botocore"),
            "botocore.config": types.SimpleNamespace(Config=lambda **k: k),
            "botocore.exceptions": types.SimpleNamespace(ClientError=ClientError),
        }
        patcher = mock.patch.dict(sys.modules, modules)
        patcher.start()
        self.addCleanup(patcher.stop)
        return S3Store(_target(Path("."))), client

    def test_head_403_means_unknown_not_rejected(self) -> None:
        for code in ("403", "AccessDenied", "Forbidden"):
            store, _ = self._store(lambda CE, code=code: CE(code))
            self.assertIsNone(store.remote_info("k"))
            self.assertTrue(store.head_denied)

    def test_other_head_errors_still_raise(self) -> None:
        store, _ = self._store(lambda CE: CE("ExpiredToken"))
        with self.assertRaises(Exception):
            store.remote_info("k")

    def test_upload_goes_ahead_and_is_trusted_when_head_is_denied(self) -> None:
        with TemporaryDirectory() as tmp:
            zip_path = Path(tmp) / "G1.zip"
            zip_path.write_bytes(b"zipdata")

            class Denied(FakeStore):
                head_denied = True

                def remote_info(self, key):
                    return None

                def remote_size(self, key):
                    return None

            store = Denied()
            key, size, files = UploadCoordinator()._upload_package(store, _target(Path(tmp)), zip_path)
            self.assertEqual(store.put_calls, ["G1.zip"])
            self.assertEqual((size, files), (7, 1))

    def test_put_403_is_still_permanent(self) -> None:
        self.assertEqual(engine.classify_error(FakeClientError("AccessDenied")), ("credentials", "AccessDenied"))
        self.assertEqual(engine.classify_error(FakeClientError("403"))[0], "credentials")


class ProxyTests(unittest.TestCase):
    def test_proxy_reaches_botocore_config(self) -> None:
        seen = {}
        modules = {
            "boto3": types.SimpleNamespace(client=lambda *a, **k: seen.setdefault("client", k)),
            "botocore": types.ModuleType("botocore"),
            "botocore.config": types.SimpleNamespace(Config=lambda **k: k),
        }
        with mock.patch.dict(sys.modules, modules):
            S3Store(_target(Path("."), https_proxy="http://proxy.lan:3128"))._s3()
            cfg = seen["client"]["config"]
            self.assertEqual(cfg["proxies"], {"https": "http://proxy.lan:3128", "http": "http://proxy.lan:3128"})
            seen.clear()
            S3Store(_target(Path(".")))._s3()
            self.assertNotIn("proxies", seen["client"]["config"])
            self.assertEqual(seen["client"]["config"]["connect_timeout"], 15)

    def test_setting_is_editable_from_the_console(self) -> None:
        self.assertIn("https_proxy", console.ALLOWED_SETTINGS_KEYS)
        self.assertIn("https_proxy", console.read_settings_view(Path("nonexistent.json")))


class DbWriteBackTests(TempRootCase):
    def test_no_db_host_means_no_pending_mark_and_no_calls(self) -> None:
        self.package("G1")
        calls = []
        coordinator = UploadCoordinator(store_factory=lambda t: FakeStore())
        coordinator.db_writer = lambda g, e: calls.append(g) or True
        coordinator.scan_once(self.config(db_host=""))
        self.assertEqual(calls, [])
        self.assertNotIn("dbPending", json.loads((self.root / "uploads.json").read_text())["G1"])

    def test_first_failure_ends_the_pass_with_one_warning(self) -> None:
        for name in ("G1", "G2", "G3"):
            self.package(name)
        calls = []

        def writer(group_id, error):
            calls.append(group_id)
            raise OSError("db down")

        coordinator = UploadCoordinator(store_factory=lambda t: FakeStore())
        coordinator.db_writer = writer
        with mock.patch.object(engine, "log") as log:
            coordinator.scan_once(self.config(db_host="db"))
        self.assertEqual(len(calls), 1)
        warnings = [c for c in log.call_args_list if c.args[0] == "WARN"]
        self.assertEqual(len(warnings), 1)

    def test_writer_false_keeps_the_mark(self) -> None:
        self.package("G1")
        coordinator = UploadCoordinator(store_factory=lambda t: FakeStore())
        coordinator.db_writer = lambda g, e: False
        coordinator.scan_once(self.config(db_host="db"))
        self.assertIn("dbPending", json.loads((self.root / "uploads.json").read_text())["G1"])

    def test_dotted_folder_name_is_the_whole_group_id(self) -> None:
        self.package("G1.2")
        calls = []
        coordinator = UploadCoordinator(store_factory=lambda t: FakeStore())
        coordinator.db_writer = lambda g, e: calls.append(g) or True
        coordinator.scan_once(self.config(db_host="db"))
        self.assertEqual(calls, ["G1.2"])
        self.assertEqual(group_id_for(Path("X/G7.zip")), "G7")
        self.assertEqual(group_id_for(Path("X/G7.v2")), "G7.v2")

    def test_write_back_needs_exactly_one_row(self) -> None:
        conn = Conn(7)
        h = health.Health(lambda: conn, version="dev", host="PC1")
        conn.cur.rowcount = 0
        with mock.patch.object(health, "log") as log:
            self.assertFalse(h.write_back("G1", None))
            self.assertFalse(h.write_back("G1", None))
        self.assertEqual(log.call_count, 1, "logged once per package")
        conn.cur.rowcount = 2
        self.assertFalse(h.write_back("G2", None))
        conn.cur.rowcount = 1
        self.assertTrue(h.write_back("G3", None))


class HeartbeatThreadTests(unittest.TestCase):
    def test_beats_repeat_without_the_scan_loop(self) -> None:
        state = console.ServiceState()
        state.update(config=object())
        beats = []
        stop = threading.Event()
        with mock.patch.object(console, "HEARTBEAT_SECONDS", 0.02), mock.patch.object(
            console, "send_heartbeat", lambda *a: beats.append(1)
        ):
            thread = threading.Thread(
                target=console._heartbeat_loop,
                args=(state, mock.Mock(schema_problem=None), mock.Mock(), stop),
            )
            thread.start()
            time.sleep(0.3)
            stop.set()
            thread.join(2)
        self.assertFalse(thread.is_alive())
        self.assertGreaterEqual(len(beats), 3)

    def test_ledger_problem_travels_in_the_heartbeat_error(self) -> None:
        coordinator = mock.Mock()
        coordinator.status.return_value = {
            "failures": [], "pending": [], "lastErrorKind": None, "ledgerProblem": "damaged",
        }
        h = mock.Mock()
        console.send_heartbeat(h, coordinator, object())
        self.assertEqual(h.beat.call_args.kwargs["error"], "damaged")


class RetryAndStopTests(TempRootCase):
    def test_retry_only_sets_a_flag_and_the_scan_applies_it(self) -> None:
        self.package("G1")

        class Failing(FakeStore):
            def put_file(self, path, key):
                raise FakeClientError("SlowDown")

        coordinator = UploadCoordinator(store_factory=lambda t: Failing())
        cfg = self.config()
        coordinator.scan_once(cfg)
        ledger_file = self.root / "uploads.json"
        before = ledger_file.read_bytes()
        self.assertTrue(json.loads(before)["G1"]["nextAttemptAt"])
        coordinator.retry_failed(cfg)
        self.assertEqual(ledger_file.read_bytes(), before, "the HTTP thread must not write the ledger")
        coordinator.scan_once(cfg)  # back-off cleared, so it is tried (and fails) again
        self.assertEqual(json.loads(ledger_file.read_text())["G1"]["attempts"], 2)

    def test_stop_between_files_leaves_the_package_untouched(self) -> None:
        folder = self.package("G1")
        (folder / "q.tif").write_bytes(b"more")
        store = FakeStore()
        coordinator = UploadCoordinator(store_factory=lambda t: store)
        stops = iter([False, False, True, True, True])
        with mock.patch.object(engine, "log"):
            done = coordinator.scan_once(self.config(), stop_check=lambda: next(stops))
        self.assertEqual(done, 0)
        self.assertEqual(len(store.put_calls), 1, "stopped before the second file")
        ledger = json.loads((self.root / "uploads.json").read_text()) if (self.root / "uploads.json").exists() else {}
        self.assertNotIn("G1", ledger, "a stop is not a failure")
        coordinator.scan_once(self.config())
        self.assertEqual(json.loads((self.root / "uploads.json").read_text())["G1"]["status"], "UPLOADED")
        self.assertEqual(len(store.put_calls), 2, "the first file was not sent twice")


class LedgerDamageTests(TempRootCase):
    def test_every_save_keeps_a_bak_of_the_previous_good_file(self) -> None:
        path = self.root / "uploads.json"
        ledger = JsonLedger(path)
        ledger.save({"a": {"n": 1}})
        ledger.save({"a": {"n": 2}})
        self.assertEqual(json.loads((self.root / "uploads.json.bak").read_text()), {"a": {"n": 1}})

    def test_a_torn_main_file_is_read_from_the_bak(self) -> None:
        path = self.root / "uploads.json"
        ledger = JsonLedger(path)
        ledger.save({"a": 1})
        ledger.save({"a": 1, "b": 2})
        path.write_text("{ torn", encoding="utf-8")
        self.assertEqual(ledger.load_strict(), {"a": 1})

    def test_both_bad_refuses_and_keeps_a_copy(self) -> None:
        path = self.root / "uploads.json"
        path.write_text("garbage", encoding="utf-8")
        with self.assertRaises(LedgerCorrupt):
            JsonLedger(path).load_strict()
        with self.assertRaises(LedgerCorrupt):
            JsonLedger(path).load_strict()  # still refuses on the next scan / restart
        self.assertEqual(len(list(self.root.glob("uploads.json.bad-*"))), 1)
        self.assertEqual(path.read_text(), "garbage")

    def test_missing_ledger_is_a_first_run(self) -> None:
        self.assertEqual(JsonLedger(self.root / "uploads.json").load_strict(), {})

    def test_scan_refuses_instead_of_reuploading_everything(self) -> None:
        self.package("G1")
        (self.root / "uploads.json").write_text("garbage", encoding="utf-8")
        store = FakeStore()
        coordinator = UploadCoordinator(store_factory=lambda t: store)
        with mock.patch.object(engine, "log"):
            self.assertEqual(coordinator.scan_once(self.config()), 0)
        self.assertEqual(store.put_calls, [])
        status = coordinator.status(self.config())
        self.assertIn("unreadable", status["ledgerProblem"])
        self.assertEqual(status["pending"], [])

    def test_a_locked_ledger_is_retried_then_skipped_not_condemned(self) -> None:
        path = self.root / "uploads.json"
        path.write_text("{}", encoding="utf-8")
        calls = []

        def locked(self, *a, **k):
            calls.append(1)
            raise PermissionError("locked")

        with mock.patch.object(Path, "read_text", locked), mock.patch("lwcam_upload.ledger.time.sleep"):
            with self.assertRaises(LedgerUnavailable):
                JsonLedger(path).load_strict()
        self.assertEqual(len(calls), 3)
        self.assertEqual(list(self.root.glob("uploads.json.bad-*")), [])

    def test_atomic_json_retries_a_briefly_locked_replace(self) -> None:
        real = os.replace
        attempts = []

        def flaky(src, dst):
            attempts.append(1)
            if len(attempts) < 3:
                raise PermissionError("in use")
            return real(src, dst)

        with mock.patch("lwcam_upload.ledger.os.replace", flaky), mock.patch("lwcam_upload.ledger.time.sleep"):
            atomic_json(self.root / "x.json", {"a": 1})
        self.assertEqual(json.loads((self.root / "x.json").read_text()), {"a": 1})


def _make_link(link: Path, target: Path) -> bool:
    """A symlink, else a junction; False when neither can be made here."""
    try:
        os.symlink(target, link, target_is_directory=True)
        return True
    except (OSError, NotImplementedError):
        pass
    if os.name == "nt":
        result = subprocess.run(
            ["cmd", "/c", "mklink", "/J", str(link), str(target)], capture_output=True
        )
        return result.returncode == 0
    return False


class LinkTests(TempRootCase):
    def test_links_are_not_packages_files_or_uploaded(self) -> None:
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "secret.tif").write_bytes(b"not exported")
        real = self.package("G1")
        if not _make_link(self.watch / "G2", outside) or not _make_link(real / "sub", outside):
            self.skipTest("cannot create a symlink or junction here")
        self.assertEqual([p.name for p in UploadCoordinator.packages(self.watch)], ["G1"])
        self.assertEqual([p.name for p in engine._iter_files(engine.fs_path(real))], ["p.tif"])
        store = FakeStore()
        UploadCoordinator(store_factory=lambda t: store).scan_once(self.config())
        self.assertEqual(store.put_calls, ["G1/p.tif"])


class ConsoleLimitTests(TempRootCase):
    def test_rate_limiter_prunes_every_ip_and_caps_its_size(self) -> None:
        limiter = console.RateLimiter()
        for i in range(50):
            limiter.record_failure(f"10.0.0.{i}", "u", now=0.0)
        limiter.check("1.1.1.1", "u", now=console.IP_ATTEMPT_WINDOW_SECONDS + 5)
        self.assertEqual((len(limiter._failures), len(limiter._ip_failures)), (0, 0))
        with mock.patch.object(console, "MAX_TRACKED", 10):
            for i in range(100):
                limiter.record_failure(f"9.9.{i}.1", f"name{i}", now=1000.0 + i)
            self.assertLessEqual(len(limiter._failures), 11)
            self.assertLessEqual(len(limiter._ip_failures), 11)

    def test_handler_has_a_socket_timeout(self) -> None:
        ctx = console.ServiceContext(
            config_path=self.root / "c.json", coordinator=UploadCoordinator(),
            state=console.ServiceState(), wake=threading.Event(),
        )
        self.assertEqual(console.build_handler(ctx).timeout, 30)

    def test_handle_error_is_one_line_not_a_traceback(self) -> None:
        server = console.ConsoleServer.__new__(console.ConsoleServer)
        with self.assertLogs("lwcam_upload.console", level="WARNING") as captured:
            try:
                raise ConnectionResetError("reset")
            except ConnectionResetError:
                server.handle_error(None, ("10.0.0.9", 5555))
        self.assertEqual(len(captured.records), 1)
        self.assertIn("10.0.0.9", captured.output[0])
        self.assertNotIn("Traceback", captured.output[0])

    def test_admin_cache_read_modify_write_is_serialised(self) -> None:
        config_path = self.root / "config.json"
        config_path.write_text("{}", encoding="utf-8")
        threads = [
            threading.Thread(target=console.remember_admin, args=(config_path, f"u{i}", "h", "admin"))
            for i in range(12)
        ]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(len(console.read_admin_cache(config_path)), 12)

    def test_tls_failure_leaves_uploads_running_without_a_console(self) -> None:
        config_path = self.root / "config" / "upload_config.json"
        config_path.parent.mkdir()
        (self.root / "runtime").mkdir()
        config_path.write_text(json.dumps({
            "watch_root": str(self.watch), "enabled": False, "interval_seconds": 10,
            "ui_port": 0, "ui_bind": "127.0.0.1",
        }), encoding="utf-8")
        import socket

        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            free_port = probe.getsockname()[1]
        raw = json.loads(config_path.read_text())
        raw["ui_port"] = free_port
        config_path.write_text(json.dumps(raw), encoding="utf-8")
        result = []

        def boom(httpd, path):
            httpd.server_close()
            raise ValueError("bad certificate")

        with mock.patch.object(console.tls, "wrap_if_configured", boom), mock.patch.object(
            console, "log"
        ) as log:
            thread = threading.Thread(target=lambda: result.append(console.run(config_path)), daemon=True)
            thread.start()
            time.sleep(0.5)
            self.assertTrue(thread.is_alive(), "the service keeps running")
            (self.root / "runtime" / "stop.request").write_text("")
            thread.join(10)
        self.assertEqual(result, [0])
        self.assertTrue(any("NOT started" in str(c.args[1]) for c in log.call_args_list))


class SessionRevalidationTests(TempRootCase):
    def test_a_disabled_admin_loses_the_session_within_a_minute(self) -> None:
        import bcrypt

        config_path = self.root / "config.json"
        config_path.write_text(
            json.dumps({"watch_root": str(self.watch), "enabled": False, "db_host": "db"}),
            encoding="utf-8",
        )
        pw = bcrypt.hashpw(b"pw", bcrypt.gensalt(4)).decode()
        account = {"password": pw, "roles": "admin", "active": True, "is_deleted": False}
        down = []

        def lookup(config, username):
            if down:
                raise console.DbUnavailable("down")
            return dict(account)

        state = console.ServiceState()
        state.update(database_reachable=True)
        sessions = console.SessionStore()
        ctx = console.ServiceContext(
            config_path=config_path, coordinator=UploadCoordinator(), state=state,
            wake=threading.Event(), sessions=sessions, db_lookup=lookup, web_dir=self.root,
        )
        httpd = console.ConsoleServer(("127.0.0.1", 0), console.build_handler(ctx))
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        self.addCleanup(lambda: (httpd.shutdown(), httpd.server_close()))

        def call(method, path, body=None, cookie=None):
            conn = http.client.HTTPConnection("127.0.0.1", httpd.server_address[1], timeout=5)
            headers = {"X-Requested-With": "lwip", "Content-Type": "application/json"}
            if cookie:
                headers["Cookie"] = cookie
            conn.request(method, path, json.dumps(body) if body is not None else None, headers)
            resp = conn.getresponse()
            cookie_out = (resp.getheader("Set-Cookie") or "").split(";")[0]
            data = json.loads(resp.read() or b"{}")
            conn.close()
            return resp.status, data, cookie_out

        _, _, cookie = call("POST", "/api/login", {"username": "admin", "password": "pw"})
        token = cookie.split("=", 1)[1]
        self.assertEqual(call("GET", "/api/settings", cookie=cookie)[0], 200)
        account["active"] = False
        self.assertEqual(call("GET", "/api/settings", cookie=cookie)[0], 200, "not due yet")
        sessions._checked[token] -= 61
        down.append(1)
        self.assertEqual(call("GET", "/api/settings", cookie=cookie)[0], 200, "database down keeps it")
        sessions._checked[token] -= 61
        down.clear()
        self.assertEqual(call("GET", "/api/settings", cookie=cookie)[0], 401)


class FailedRowRetryTests(TempRootCase):
    """A FAILED row waits out its back-off only while nothing has changed."""

    class Failing(FakeStore):
        def __init__(self, code="SlowDown"):
            super().__init__()
            self.code = code

        def put_file(self, path, key):
            raise FakeClientError(self.code)

    def _fail(self, code="SlowDown", cfg=None):
        coordinator = UploadCoordinator(store_factory=lambda t: self.Failing(code))
        coordinator.scan_once(cfg or self.config())
        return coordinator

    def _row(self):
        return json.loads((self.root / "uploads.json").read_text())["G1"]

    def test_unchanged_package_still_waits(self) -> None:
        self.package("G1")
        coordinator = self._fail()
        self.assertTrue(self._row()["fingerprint"])
        coordinator.scan_once(self.config())
        self.assertEqual(self._row()["attempts"], 1)

    def test_changed_package_is_retried_at_once(self) -> None:
        folder = self.package("G1")
        coordinator = self._fail("AccessDenied")
        (folder / "p.tif").write_bytes(b"republished")
        store = FakeStore()
        coordinator._store_factory = lambda t: store
        coordinator.scan_once(self.config())
        self.assertEqual(self._row()["status"], "UPLOADED")
        self.assertEqual(self._row()["attempts"], 2)

    def test_legacy_row_without_fingerprint_is_retried_once_then_records_it(self) -> None:
        self.package("G1")
        self._fail()
        ledger = json.loads((self.root / "uploads.json").read_text())
        ledger["G1"]["fingerprint"] = None
        (self.root / "uploads.json").write_text(json.dumps(ledger))
        coordinator = UploadCoordinator(store_factory=lambda t: self.Failing())
        coordinator.scan_once(self.config())
        self.assertEqual(self._row()["attempts"], 2)
        self.assertTrue(self._row()["fingerprint"])
        coordinator.scan_once(self.config())
        self.assertEqual(self._row()["attempts"], 2, "recorded now, so it waits again")

    def test_s3_settings_change_clears_a_permanent_back_off(self) -> None:
        self.package("G1")
        self._fail("AccessDenied")
        coordinator = UploadCoordinator(store_factory=lambda t: self.Failing("AccessDenied"))
        coordinator.scan_once(self.config())
        self.assertEqual(self._row()["attempts"], 1, "same keys: still waiting")
        coordinator.scan_once(self.config(s3_secret_key="fixed"))
        self.assertEqual(self._row()["attempts"], 2, "new keys: tried now")


if __name__ == "__main__":
    unittest.main()

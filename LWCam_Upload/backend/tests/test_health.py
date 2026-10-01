"""Heartbeat, schema check, write-back and error classification (Phase 3)."""

from __future__ import annotations

import json
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from tempfile import TemporaryDirectory

from lwcam_upload import engine, health
from lwcam_upload.engine import UploadCoordinator, classify_error
from tests.test_upload_reupload import FakeStore, _config


class Cur:
    def __init__(self, level) -> None:
        self.level = level  # None = no schema_migrations table
        self.executed: list[tuple[str, object]] = []
        self._row = None
        self.rowcount = 1

    def execute(self, sql, params=None) -> None:
        self.executed.append((sql, params))
        if "to_regclass" in sql:
            self._row = (self.level is not None,)
        elif "max(" in sql:
            self._row = (self.level,)

    def fetchone(self):
        return self._row

    def __enter__(self):
        return self

    def __exit__(self, *a) -> bool:
        return False


class Conn:
    def __init__(self, level) -> None:
        self.cur = Cur(level)

    def cursor(self):
        return self.cur

    def commit(self) -> None:
        pass

    def __enter__(self):
        return self

    def __exit__(self, *a) -> bool:
        return False


class FakeClientError(Exception):
    def __init__(self, code: str) -> None:
        super().__init__(f"An error occurred ({code}) when calling the PutObject operation")
        self.response = {"Error": {"Code": code}}


class ClassificationTests(unittest.TestCase):
    def test_table(self) -> None:
        cases = {
            "InvalidAccessKeyId": "credentials", "SignatureDoesNotMatch": "credentials",
            "ExpiredToken": "credentials", "InvalidClientTokenId": "credentials",
            "AccessDenied": "credentials",
            "NoSuchBucket": "bucket", "PermanentRedirect": "bucket",
            "AuthorizationHeaderMalformed": "bucket", "IllegalLocationConstraintException": "bucket",
            "SlowDown": "other",
        }
        for code, kind in cases.items():
            self.assertEqual(classify_error(FakeClientError(code)), (kind, code), code)

    def test_network_by_class_name_and_wrapped_text(self) -> None:
        class EndpointConnectionError(Exception):
            pass

        class ReadTimeoutError(Exception):
            pass

        self.assertEqual(classify_error(EndpointConnectionError("x"))[0], "network")
        self.assertEqual(classify_error(ReadTimeoutError("x"))[0], "network")
        # boto3 wraps client errors in S3UploadFailedError: the code is only in its text.
        self.assertEqual(classify_error(RuntimeError("An error occurred (NoSuchBucket) when"))[0], "bucket")
        self.assertEqual(classify_error(ValueError("boom")), ("other", "ValueError"))


class HealthTests(unittest.TestCase):
    def test_upsert_and_backlog(self) -> None:
        conn = Conn(7)
        h = health.Health(lambda: conn, version="1.1.0+abc", host="PC1")
        h.beat({"pending": 3, "failed": 1, "last_error_kind": "bucket"}, error="boom")
        sql, params = conn.cur.executed[-1]
        self.assertIn("INSERT INTO service_heartbeat", sql)
        self.assertIn("ON CONFLICT (part, host) DO UPDATE", sql)
        self.assertEqual((params["part"], params["host"], params["version"]), ("upload", "PC1", "1.1.0+abc"))
        self.assertEqual(json.loads(params["backlog"]),
                         {"pending": 3, "failed": 1, "last_error_kind": "bucket"})
        self.assertEqual(params["error"], "boom")

    def test_schema_too_old_banner_and_no_writes(self) -> None:
        conn = Conn(5)
        h = health.Health(lambda: conn, version="dev", host="PC1")
        h.beat({})
        self.assertIn("needs level 7, has 5", h.schema_problem)
        self.assertFalse(any("service_heartbeat" in s for s, _ in conn.cur.executed))
        self.assertFalse(h.write_back("G1", None))
        self.assertFalse(any("capture_folders" in s for s, _ in conn.cur.executed))

    def test_write_back_sql(self) -> None:
        conn = Conn(7)
        h = health.Health(lambda: conn, version="dev", host="PC1")
        self.assertTrue(h.write_back("G1", None))
        self.assertTrue(h.write_back("G2", "rejected"))
        (s1, p1), (s2, p2) = conn.cur.executed
        self.assertIn("is_ingested = true", s1)
        self.assertEqual(p1, ("G1",))
        self.assertEqual((p2[1], "upload_error" in s2), ("G2", True))

    def test_heartbeat_failure_is_swallowed(self) -> None:
        def boom():
            raise OSError("down")

        health.Health(boom, version="dev", host="PC1").beat({})


class WriteBackFlowTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        (self.root / "G1").mkdir()
        (self.root / "G1" / "p.tif").write_bytes(b"page")
        self.config = _config(self.root, db_host="db.example")

    def test_success_writes_ingested_with_group_id_and_retries_after_failure(self) -> None:
        calls: list[tuple[str, str | None]] = []
        down = [True]

        def writer(group_id, error):
            if down[0]:
                raise OSError("db down")
            calls.append((group_id, error))
            return True

        coordinator = UploadCoordinator(store_factory=lambda t: FakeStore())
        coordinator.db_writer = writer
        self.assertEqual(coordinator.scan_once(self.config), 1, "a DB failure never fails the upload")
        self.assertEqual(calls, [])
        down[0] = False
        coordinator.scan_once(self.config)
        self.assertEqual(calls, [("G1", None)])
        coordinator.scan_once(self.config)
        self.assertEqual(calls, [("G1", None)], "written once, then cleared")

    def test_permanent_failure_writes_upload_error(self) -> None:
        calls: list[tuple[str, str | None]] = []

        class Rejecting(FakeStore):
            def put_file(self, path, key):
                raise FakeClientError("InvalidAccessKeyId")

        coordinator = UploadCoordinator(store_factory=lambda t: Rejecting())
        coordinator.db_writer = lambda g, e: calls.append((g, e)) or True
        coordinator.scan_once(self.config)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], "G1")
        self.assertIn("InvalidAccessKeyId", calls[0][1])
        status = coordinator.status(self.config)
        self.assertEqual(
            status["permanentProblem"],
            "The bucket or keys were rejected: InvalidAccessKeyId. Fix them in Settings.",
        )
        self.assertEqual(status["lastErrorKind"], "credentials")

    def _next_delay(self, error: Exception) -> timedelta:
        class Failing(FakeStore):
            def put_file(self, path, key):
                raise error

        coordinator = UploadCoordinator(store_factory=lambda t: Failing())
        coordinator.scan_once(self.config)
        ledger = json.loads(self.config.state_file.read_text(encoding="utf-8"))
        return datetime.fromisoformat(ledger["G1"]["nextAttemptAt"]) - engine.utc_now()

    def test_permanent_failure_uses_max_backoff_at_once(self) -> None:
        self.assertGreater(self._next_delay(FakeClientError("NoSuchBucket")), timedelta(minutes=59))

    def test_transient_failure_steps_up(self) -> None:
        self.assertLess(self._next_delay(FakeClientError("SlowDown")), timedelta(minutes=6))


if __name__ == "__main__":
    unittest.main()

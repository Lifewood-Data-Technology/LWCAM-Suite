"""Round-2 hardening: session revival, empty-password login, upload cap, docs off, jwt bounds, settings writes."""

from __future__ import annotations

import io
import os
import threading
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest import mock

from pydantic import ValidationError

from app.core import security
from app.core.errors import BusinessError


class SessionRevival(unittest.TestCase):
    def setUp(self) -> None:
        security._current_session.clear()
        security._revoked_sessions.clear()
        security._sessions_invalid_before.clear()

    def _token(self, uid=501, **kw):
        return security.decode_access_token(security.create_access_token(uid, "u", "qc", **kw))

    def test_displaced_token_stays_dead_after_takeover_and_logout(self) -> None:
        with mock.patch.object(security, "SESSION_IDLE_SECONDS", 0.0):
            first = self._token()
            second = self._token()  # idle takeover
        self.assertTrue(security.is_revoked(first["sid"]))
        security.end_session(501, second["sid"])
        self.assertFalse(security.is_current_session(501, first["sid"]))

    def test_token_issued_before_a_reset_is_dead_even_if_not_current(self) -> None:
        with mock.patch.object(security, "SESSION_IDLE_SECONDS", 0.0):
            old = self._token()
            self._token()
        security.end_user_sessions(501)
        self.assertTrue(security.issued_before_reset(501, old["iat"]))
        fresh = self._token()
        self.assertFalse(security.issued_before_reset(501, fresh["iat"]))
        self.assertFalse(security.issued_before_reset(502, old["iat"]))


class EmptyPasswordLogin(unittest.TestCase):
    def test_user_with_empty_or_null_password_cannot_sign_in_with_the_dummy_plaintext(self) -> None:
        from app.routers import auth

        for stored in ("", None):
            user = SimpleNamespace(id=9, user_id="ghost", password=stored, status="active", role="qc")
            db = mock.MagicMock()
            db.scalar.return_value = user
            request = SimpleNamespace(username="ghost", password="timing-equaliser-not-a-real-password")
            http = SimpleNamespace(client=SimpleNamespace(host="10.9.9.9"), headers={})
            with self.assertRaises(BusinessError) as caught:
                auth.login(request, http, db)
            self.assertEqual(caught.exception.http_status, 401)


class UploadLimits(unittest.TestCase):
    def test_oversize_upload_is_413_and_the_partial_is_deleted(self) -> None:
        from app.routers import qc

        with TemporaryDirectory() as tmp:
            with mock.patch.object(qc, "MAX_UPLOAD_BYTES", 1024), \
                    mock.patch.object(qc, "draft_dir", return_value=Path(tmp)):
                upload = SimpleNamespace(file=io.BytesIO(b"x" * 5000))
                with self.assertRaises(BusinessError) as caught:
                    qc.save_upload_to_temp(1, "u", upload, "big.jpg")
            self.assertEqual(caught.exception.http_status, 413)
            self.assertIn("MB", caught.exception.message)
            self.assertEqual(list((Path(tmp) / "uploads").iterdir()), [])


class Hardening(unittest.TestCase):
    def test_docs_are_off_unless_debug(self) -> None:
        from app.core.config import settings
        from app.main import app

        if not settings.app_debug:
            self.assertIsNone(app.docs_url)
            self.assertIsNone(app.redoc_url)
            self.assertIsNone(app.openapi_url)

    def test_jwt_expiry_is_bounded(self) -> None:
        from app.core.config import Settings

        for bad in (1, 4, 1441, 100000):
            with self.assertRaises(ValidationError):
                Settings(jwt_expire_minutes=bad)
        self.assertEqual(Settings(jwt_expire_minutes=5).jwt_expire_minutes, 5)

    def test_ip_failures_are_pruned_globally(self) -> None:
        from app.routers import auth

        auth._ip_failures.clear()
        auth._ip_failures["10.0.0.1"] = [1.0]
        auth.record_login_failure("10.0.0.2", "a", now=10_000.0)
        self.assertNotIn("10.0.0.1", auth._ip_failures)
        auth._ip_failures.clear()
        auth._login_failures.clear()

    def test_concurrent_settings_writes_keep_every_key(self) -> None:
        from app.core import server_settings

        with TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.txt"
            fields = ["preview_cache_max_mb", "export_worker_count", "export_temp_retention_hours", "port"]
            with mock.patch.dict(os.environ, {"LWCAM_QC_SERVER_CONFIG": str(path)}):
                errors = []

                def write(field, value):
                    try:
                        for i in range(15):
                            server_settings.write_server_settings({field: value + i % 1})
                    except Exception as error:  # noqa: BLE001
                        errors.append(error)

                threads = [threading.Thread(target=write, args=(f, 10 + n)) for n, f in enumerate(fields)]
                [t.start() for t in threads]
                [t.join() for t in threads]
                self.assertEqual(errors, [])
                loaded = server_settings.load_server_settings_overrides()
            self.assertEqual({f: loaded[f] for f in fields}, {f: 10 + n for n, f in enumerate(fields)})
            self.assertEqual([p.name for p in Path(tmp).iterdir()], ["config.txt"])


if __name__ == "__main__":
    unittest.main()

"""run_server.py hands uvicorn the certificate only when config.txt names one."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import run_server  # noqa: E402
from app.core.config import settings  # noqa: E402


class RunServerTlsTests(unittest.TestCase):
    def test_plain_http_when_not_configured(self) -> None:
        with patch.object(settings, "tls_cert_file", ""), patch.object(settings, "tls_key_file", ""):
            self.assertEqual(run_server.tls_kwargs(), {})

    def test_ssl_arguments_and_renewal_when_configured(self) -> None:
        with patch.object(settings, "tls_cert_file", r"C:\x\tls\server.crt"), patch.object(
            settings, "tls_key_file", r"C:\x\tls\server.key"
        ), patch.object(run_server, "is_managed", return_value=True), patch.object(
            run_server, "ensure_certificates"
        ) as ensure:
            kwargs = run_server.tls_kwargs()
        self.assertEqual(kwargs, {"ssl_certfile": r"C:\x\tls\server.crt", "ssl_keyfile": r"C:\x\tls\server.key"})
        ensure.assert_called_once_with(Path(r"C:\x\tls"))

    def test_a_reissued_managed_certificate_restarts_the_server(self) -> None:
        with patch.object(settings, "tls_cert_file", r"C:\x\tls\server.crt"), patch.object(
            settings, "tls_key_file", r"C:\x\tls\server.key"
        ), patch.object(run_server, "is_managed", return_value=True), patch.object(
            run_server, "keep_fresh"
        ) as keep, patch.object(run_server.os, "_exit") as exit_:
            run_server.start_renewal()
            folder, on_renew = keep.call_args.args
            self.assertEqual(folder, Path(r"C:\x\tls"))
            on_renew(None, None)
        exit_.assert_called_once_with(run_server.RENEWED_EXIT_CODE)

    def test_no_renewal_thread_for_an_operators_own_certificate(self) -> None:
        with patch.object(settings, "tls_cert_file", r"C:\certs\site.crt"), patch.object(
            settings, "tls_key_file", r"C:\certs\site.key"
        ), patch.object(run_server, "keep_fresh") as keep:
            run_server.start_renewal()
        keep.assert_not_called()

    def test_an_operators_own_certificate_is_never_renewed(self) -> None:
        with patch.object(settings, "tls_cert_file", r"C:\certs\site.crt"), patch.object(
            settings, "tls_key_file", r"C:\certs\site.key"
        ), patch.object(run_server, "ensure_certificates") as ensure:
            kwargs = run_server.tls_kwargs()
        self.assertEqual(kwargs, {"ssl_certfile": r"C:\certs\site.crt", "ssl_keyfile": r"C:\certs\site.key"})
        ensure.assert_not_called()

    def test_a_renewal_failure_still_serves_https(self) -> None:
        with patch.object(settings, "tls_cert_file", "a.crt"), patch.object(settings, "tls_key_file", "a.key"), patch.object(
            run_server, "ensure_certificates", side_effect=OSError("denied")
        ):
            self.assertEqual(set(run_server.tls_kwargs()), {"ssl_certfile", "ssl_keyfile"})

    def test_config_keys_reach_settings(self) -> None:
        from app.core.server_settings import SETTINGS_BY_KEY

        self.assertEqual(SETTINGS_BY_KEY["tlsCertFile"], "tls_cert_file")
        self.assertEqual(SETTINGS_BY_KEY["tlsKeyFile"], "tls_key_file")


if __name__ == "__main__":
    unittest.main()

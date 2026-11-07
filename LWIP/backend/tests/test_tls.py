"""tls.py - per-PC CA + server certificate, and the https wrapping of the stdlib
console server. The same module ships (byte-identical) in QC, LWIP and Upload."""

from __future__ import annotations

import datetime as dt
import ipaddress
import json
import socket
import ssl
import threading
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

from deskew_crop_tool import tls


_real_gateway_ips, _real_tailscale = tls._gateway_ips, tls._tailscale


class _Hello(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        body = tls.secure_flag(self).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args) -> None:
        pass


class TlsTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.dir = Path(temp.name) / "tls"
        for target, value in (("_gateway_ips", set()), ("_tailscale", (None, set()))):
            patcher = patch.object(tls, target, return_value=value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def _load(self, name: str) -> x509.Certificate:
        return x509.load_pem_x509_certificate((self.dir / name).read_bytes())

    def test_ca_kept_and_leaf_signed_by_it(self) -> None:
        tls.ensure_certificates(self.dir)
        ca_before = (self.dir / "lwcam-ca.crt").read_bytes()
        leaf = self._load("server.crt")
        ca = self._load("lwcam-ca.crt")
        self.assertTrue(ca.extensions.get_extension_for_class(x509.BasicConstraints).value.ca)
        self.assertIn("LWCam local CA", ca.subject.rfc4514_string())
        self.assertEqual(leaf.issuer, ca.subject)
        leaf.verify_directly_issued_by(ca)  # signature check
        self.assertGreater((ca.not_valid_after_utc - dt.datetime.now(dt.timezone.utc)).days, 3600)
        tls.ensure_certificates(self.dir)  # second run: nothing replaced
        self.assertEqual((self.dir / "lwcam-ca.crt").read_bytes(), ca_before)

    def test_leaf_names(self) -> None:
        names = ({"PC1", "pc1.lan", "localhost"}, {"127.0.0.1", "192.168.0.5", "100.64.0.9"})
        with patch.object(tls, "local_names", return_value=names):
            tls.ensure_certificates(self.dir)
        self.assertEqual(
            tls._san_set(self._load("server.crt")),
            {"PC1", "pc1.lan", "localhost", "127.0.0.1", "192.168.0.5", "100.64.0.9"},
        )
        dns, ips = tls.local_names()
        self.assertIn("localhost", dns)
        self.assertIn("127.0.0.1", ips)

    def test_tailscale_name_is_added_and_only_tailscale_ips(self) -> None:
        out = json.dumps({"Self": {"DNSName": "pc1.tail1234.ts.net.", "TailscaleIPs": [
            "100.100.2.3", "fd7a:115c:a1e0::1", "10.9.9.9", "fd00::1"]}})
        exe = self.dir.parent / "Tailscale" / "tailscale.exe"
        exe.parent.mkdir(parents=True)
        exe.write_bytes(b"")
        with patch.dict("os.environ", {"ProgramFiles": str(self.dir.parent)}), patch.object(
            tls.subprocess, "run", return_value=type("R", (), {"stdout": out})()
        ) as run:
            name, ips = _real_tailscale()
        self.assertEqual(name, "pc1.tail1234.ts.net")
        self.assertEqual(ips, {"100.100.2.3", "fd7a:115c:a1e0::1"})
        self.assertEqual(run.call_args.args[0][0], str(exe))  # the fixed path, not a PATH lookup
        self.assertLessEqual(run.call_args.kwargs["timeout"], 3)

    def test_gateway_ips_drop_link_local_and_keep_stable_addresses(self) -> None:
        lines = "192.168.0.5\n169.254.7.7\nfe80::1\n2001:db8::5\n\n"
        shell = self.dir.parent / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"
        shell.parent.mkdir(parents=True)
        shell.write_bytes(b"")
        with patch.dict("os.environ", {"SystemRoot": str(self.dir.parent)}), patch.object(
            tls.subprocess, "run", return_value=type("R", (), {"stdout": lines})()
        ):
            self.assertEqual(_real_gateway_ips(), {"192.168.0.5", "2001:db8::5"})

    def test_slow_getfqdn_does_not_block(self) -> None:
        import time

        with patch.object(tls, "_FQDN_TIMEOUT", 0.2), patch.object(
            tls.socket, "getfqdn", lambda: time.sleep(3) or "slow.example"
        ):
            began = time.monotonic()
            dns, _ = tls.local_names()
        self.assertLess(time.monotonic() - began, 2.5)
        self.assertNotIn("slow.example", dns)

    def test_leaf_reissued_when_a_name_is_missing_but_ca_is_not(self) -> None:
        base = ({"localhost"}, {"127.0.0.1", "10.0.0.5"})
        with patch.object(tls, "local_names", return_value=base):
            tls.ensure_certificates(self.dir)
            first_leaf = (self.dir / "server.crt").read_bytes()
            ca = (self.dir / "lwcam-ca.crt").read_bytes()
            tls.ensure_certificates(self.dir)
            self.assertEqual((self.dir / "server.crt").read_bytes(), first_leaf)  # nothing to renew
        with patch.object(tls, "local_names", return_value=({"localhost"}, {"127.0.0.1", "10.0.0.7"})):
            tls.ensure_certificates(self.dir)
        self.assertNotEqual((self.dir / "server.crt").read_bytes(), first_leaf)
        self.assertIn("10.0.0.7", tls._san_set(self._load("server.crt")))
        self.assertEqual((self.dir / "lwcam-ca.crt").read_bytes(), ca)

    def test_new_network_keeps_localhost_valid_without_expanding_ca(self) -> None:
        base = ({"localhost"}, {"127.0.0.1", "10.23.101.5"})
        with patch.object(tls, "local_names", return_value=base):
            tls.ensure_certificates(self.dir)
        ca_before = (self.dir / "lwcam-ca.crt").read_bytes()
        first_leaf = (self.dir / "server.crt").read_bytes()
        moved = ({"localhost"}, {"127.0.0.1", "192.168.1.127", "2001:db8::5"})
        with patch.object(tls, "local_names", return_value=moved):
            tls.ensure_certificates(self.dir)
            self.assertEqual(tls._san_set(self._load("server.crt")), {"localhost", "127.0.0.1", "10.23.101.5"})
            self.assertEqual((self.dir / "server.crt").read_bytes(), first_leaf)
            config = {"tls_cert_file": str(self.dir / "server.crt"), "tls_key_file": str(self.dir / "server.key")}
            httpd, _ = self._serve(config)
            context = ssl.create_default_context(cafile=str(self.dir / "lwcam-ca.crt"))
            with urllib.request.urlopen(f"https://localhost:{httpd.server_address[1]}/", context=context, timeout=5) as reply:
                self.assertEqual(reply.status, 200)
        self.assertEqual((self.dir / "lwcam-ca.crt").read_bytes(), ca_before)

    def test_existing_forbidden_san_is_reissued_even_when_wanted_names_present(self) -> None:
        base = ({"localhost"}, {"127.0.0.1"})
        with patch.object(tls, "local_names", return_value=base):
            tls.ensure_certificates(self.dir)
            ca = self._load("lwcam-ca.crt")
            ca_before = (self.dir / "lwcam-ca.crt").read_bytes()
            ca_key = serialization.load_pem_private_key((self.dir / "lwcam-ca.key").read_bytes(), None)
            leaf_key = serialization.load_pem_private_key((self.dir / "server.key").read_bytes(), None)
            leaf = (x509.CertificateBuilder().subject_name(ca.subject).issuer_name(ca.subject)
                .public_key(leaf_key.public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(tls._now() - dt.timedelta(days=1))
                .not_valid_after(tls._now() + dt.timedelta(days=365))
                .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
                .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost"),
                    x509.IPAddress(ipaddress.ip_address("127.0.0.1")),
                    x509.IPAddress(ipaddress.ip_address("192.168.1.127"))]), critical=False)
                .sign(ca_key, hashes.SHA256()))
            (self.dir / "server.crt").write_bytes(leaf.public_bytes(serialization.Encoding.PEM))
            self.assertFalse(tls._leaf_usable(self.dir / "server.crt", self.dir / "server.key", ca, {"localhost", "127.0.0.1"}))
            tls.ensure_certificates(self.dir)
        self.assertEqual(tls._san_set(self._load("server.crt")), {"localhost", "127.0.0.1"})
        self.assertEqual((self.dir / "lwcam-ca.crt").read_bytes(), ca_before)

    def test_leaf_reissued_when_nearly_expired(self) -> None:
        tls.ensure_certificates(self.dir)
        first = (self.dir / "server.crt").read_bytes()
        soon = dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=710)
        with patch.object(tls, "_now", return_value=soon):
            tls.ensure_certificates(self.dir)
        self.assertNotEqual((self.dir / "server.crt").read_bytes(), first)

    def _serve(self, config: dict):
        self.dir.parent.mkdir(exist_ok=True)
        tls.ensure_certificates(self.dir)  # the installer's step; the wrapper only renews
        config_path = self.dir.parent / "cfg.json"
        config_path.write_text(json.dumps(config), encoding="utf-8")
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), _Hello)
        wrapped = tls.wrap_if_configured(httpd, config_path)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        self.addCleanup(httpd.server_close)
        self.addCleanup(httpd.shutdown)
        return httpd, wrapped

    def test_live_https_handshake_and_plain_http_refused(self) -> None:
        config = {"tls_cert_file": str(self.dir / "server.crt"), "tls_key_file": str(self.dir / "server.key")}
        httpd, wrapped = self._serve(config)
        self.assertTrue(wrapped)
        port = httpd.server_address[1]
        context = ssl.create_default_context(cafile=str(self.dir / "lwcam-ca.crt"))
        with socket.create_connection(("127.0.0.1", port), timeout=10) as raw:
            with context.wrap_socket(raw, server_hostname="localhost") as secure:
                secure.sendall(b"GET / HTTP/1.0\r\n\r\n")
                reply = b""
                while chunk := secure.recv(4096):
                    reply += chunk
        self.assertTrue(reply.startswith(b"HTTP/1.0 200"))
        self.assertTrue(reply.endswith(b"; Secure"))  # the cookie helper sees TLS
        # A client that does not trust our CA is refused.
        with socket.create_connection(("127.0.0.1", port), timeout=10) as raw:
            with self.assertRaises(ssl.SSLCertVerificationError):
                ssl.create_default_context().wrap_socket(raw, server_hostname="localhost")
        # So is one that asks for the wrong name.
        with socket.create_connection(("127.0.0.1", port), timeout=10) as raw:
            with self.assertRaises(ssl.SSLCertVerificationError):
                context.wrap_socket(raw, server_hostname="not-this-pc.example")
        # Plain http gets no page.
        with self.assertRaises(OSError):
            urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=5).read()

    def test_no_tls_keys_means_plain_http_and_no_secure_flag(self) -> None:
        httpd, wrapped = self._serve({"ui_port": 1})
        self.assertFalse(wrapped)
        with urllib.request.urlopen(f"http://127.0.0.1:{httpd.server_address[1]}/", timeout=5) as reply:
            self.assertEqual(reply.read(), b"")

    def test_configured_but_unusable_certificate_raises(self) -> None:
        self.dir.parent.mkdir(exist_ok=True)
        config_path = self.dir.parent / "cfg.json"
        config_path.write_text(json.dumps({"tls_cert_file": str(self.dir / "a.crt"), "tls_key_file": str(self.dir / "a.key")}))
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), _Hello)
        with self.assertRaises(OSError):  # no such certificate on disk
            tls.wrap_if_configured(httpd, config_path)

    def test_add_to_config_json_and_txt_keep_existing_choices(self) -> None:
        js = self.dir.parent / "svc.json"
        js.write_text(json.dumps({"ui_port": 8090, "db_password": "p\u00e4ss"}), encoding="utf-8")
        self.assertTrue(tls.add_to_config(js, self.dir))
        data = json.loads(js.read_text(encoding="utf-8"))
        self.assertEqual(data["tls_cert_file"], str(self.dir / "server.crt"))
        self.assertEqual(data["tls_key_file"], str(self.dir / "server.key"))
        self.assertEqual((data["ui_port"], data["db_password"]), (8090, "p\u00e4ss"))
        self.assertFalse(tls.add_to_config(js, self.dir / "other"))  # already set: untouched
        self.assertEqual(json.loads(js.read_text(encoding="utf-8")), data)
        txt = self.dir.parent / "config.txt"
        txt.write_bytes(b"port = 8080\r\nbindHost = 0.0.0.0")  # no final newline
        self.assertTrue(tls.add_to_config(txt, self.dir))
        lines = txt.read_bytes().decode().split("\r\n")
        self.assertEqual(lines[:2], ["port = 8080", "bindHost = 0.0.0.0"])
        self.assertEqual(lines[2], f"tlsCertFile = {self.dir / 'server.crt'}")
        self.assertFalse(tls.add_to_config(txt, self.dir))

    def test_command_line(self) -> None:
        import os
        import subprocess
        import sys

        cfg = self.dir.parent / "svc.json"
        self.dir.parent.mkdir(exist_ok=True)
        cfg.write_text("{}", encoding="utf-8")
        module = tls.__spec__.name
        root = str(Path(tls.__file__).resolve().parents[len(module.split(".")) - 1])
        env = {**os.environ, "PYTHONPATH": root}
        done = subprocess.run(
            [sys.executable, "-m", module, "ensure", str(self.dir), "--config", str(cfg)],
            env=env, capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertTrue((self.dir / "server.crt").is_file() and (self.dir / "lwcam-ca.crt").is_file())
        self.assertIn("tls_cert_file", json.loads(cfg.read_text(encoding="utf-8")))

    def test_extra_names_in_the_leaf_do_not_cause_a_reissue(self) -> None:
        with patch.object(tls, "local_names", return_value=({"localhost"}, {"127.0.0.1", "10.0.0.7"})):
            tls.ensure_certificates(self.dir)
            first = (self.dir / "server.crt").read_bytes()
        with patch.object(tls, "local_names", return_value=({"localhost"}, {"127.0.0.1"})):
            tls.ensure_certificates(self.dir)  # 10.0.0.7 is gone, but nothing wanted is missing
        self.assertEqual((self.dir / "server.crt").read_bytes(), first)

    def test_leaf_with_foreign_key_or_foreign_ca_is_reissued(self) -> None:
        tls.ensure_certificates(self.dir)
        first = (self.dir / "server.crt").read_bytes()
        other = self.dir.parent / "other"
        tls.ensure_certificates(other)
        (self.dir / "server.key").write_bytes((other / "server.key").read_bytes())  # key no longer matches
        tls.ensure_certificates(self.dir)
        self.assertNotEqual((self.dir / "server.crt").read_bytes(), first)
        fixed = (self.dir / "server.crt").read_bytes()
        (self.dir / "server.crt").write_bytes((other / "server.crt").read_bytes())  # pair fine, wrong CA
        (self.dir / "server.key").write_bytes((other / "server.key").read_bytes())
        tls.ensure_certificates(self.dir)
        self._load("server.crt").verify_directly_issued_by(self._load("lwcam-ca.crt"))
        self.assertNotEqual((self.dir / "server.crt").read_bytes(), fixed)

    def test_half_a_ca_is_refused_not_regenerated(self) -> None:
        tls.ensure_certificates(self.dir)
        (self.dir / "lwcam-ca.key").unlink()
        ca = (self.dir / "lwcam-ca.crt").read_bytes()
        with self.assertRaises(RuntimeError):
            tls.ensure_certificates(self.dir)
        self.assertEqual((self.dir / "lwcam-ca.crt").read_bytes(), ca)
        self.assertFalse((self.dir / "lwcam-ca.key").exists())

    def test_ca_has_critical_name_constraints_for_this_pc(self) -> None:
        names = ({"PC1", "pc1.tail1234.ts.net", "localhost"}, {"127.0.0.1", "192.168.0.5", "100.64.0.9"})
        with patch.object(tls, "local_names", return_value=names):
            tls.ensure_certificates(self.dir)
        ext = self._load("lwcam-ca.crt").extensions.get_extension_for_class(x509.NameConstraints)
        self.assertTrue(ext.critical)
        tree = ext.value.permitted_subtrees
        self.assertTrue({"PC1", "localhost", "tail1234.ts.net"} <= {n.value for n in tree if isinstance(n, x509.DNSName)})
        nets = [n.value for n in tree if isinstance(n, x509.IPAddress)]
        self.assertTrue(any(ipaddress.ip_address("192.168.0.77") in n for n in nets if n.version == 4))
        self.assertFalse(any(ipaddress.ip_address("8.8.8.8") in n for n in nets if n.version == 4))
        self.assertEqual(tls._uncovered(self._load("lwcam-ca.crt"), *names), [])
        self.assertEqual(tls._uncovered(self._load("lwcam-ca.crt"), {"evil.example"}, {"8.8.8.8"}), ["evil.example", "8.8.8.8"])

    def test_ca_without_name_constraints_is_replaced_once(self) -> None:
        tls.ensure_certificates(self.dir)
        old_key = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "LWCam local CA old")])
        old = (
            x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(old_key.public_key())
            .serial_number(1).not_valid_before(dt.datetime(2020, 1, 1)).not_valid_after(dt.datetime(2040, 1, 1))
            .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
            .sign(old_key, hashes.SHA256())
        )
        (self.dir / "lwcam-ca.crt").write_bytes(old.public_bytes(serialization.Encoding.PEM))
        (self.dir / "lwcam-ca.key").write_bytes(tls._pem_key(old_key))
        tls.ensure_certificates(self.dir)
        replaced = (self.dir / "lwcam-ca.crt").read_bytes()
        self.assertIsNotNone(tls._ca_constraints(self._load("lwcam-ca.crt")))
        self._load("server.crt").verify_directly_issued_by(self._load("lwcam-ca.crt"))
        tls.ensure_certificates(self.dir)  # now constrained: kept
        self.assertEqual((self.dir / "lwcam-ca.crt").read_bytes(), replaced)

    def test_concurrent_ensure_leaves_one_valid_pair(self) -> None:
        errors: list[BaseException] = []

        def run() -> None:
            try:
                tls.ensure_certificates(self.dir)
            except BaseException as exc:  # noqa: BLE001
                errors.append(exc)

        threads = [threading.Thread(target=run) for _ in range(4)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(60)
        self.assertEqual(errors, [])
        self._load("server.crt").verify_directly_issued_by(self._load("lwcam-ca.crt"))
        self.assertFalse((self.dir / ".tls.lock").exists())
        self.assertEqual([p.name for p in self.dir.glob(".*.tmp")], [])

    def test_stale_lock_is_taken_over(self) -> None:
        import os

        self.dir.mkdir(parents=True)
        lock = self.dir / ".tls.lock"
        lock.write_bytes(b"")
        old = lock.stat().st_mtime - 3600
        os.utime(lock, (old, old))
        tls.ensure_certificates(self.dir)
        self.assertTrue((self.dir / "server.crt").is_file())

    def test_custom_certificate_is_used_as_is(self) -> None:
        tls.ensure_certificates(self.dir)
        custom = self.dir.parent / "custom"
        custom.mkdir()
        (custom / "my.crt").write_bytes((self.dir / "server.crt").read_bytes())
        (custom / "my.key").write_bytes((self.dir / "server.key").read_bytes())
        self.assertFalse(tls.is_managed(custom / "my.crt", custom / "my.key"))
        self.assertTrue(tls.is_managed(self.dir / "server.crt", self.dir / "server.key"))
        self.assertFalse(tls.is_managed(self.dir / "server.crt", custom / "my.key"))
        config = self.dir.parent / "cfg.json"
        config.write_text(json.dumps({"tls_cert_file": str(custom / "my.crt"), "tls_key_file": str(custom / "my.key")}))
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), _Hello)
        self.addCleanup(httpd.server_close)
        with patch.object(tls, "ensure_certificates", side_effect=AssertionError("must not manage")):
            self.assertTrue(tls.wrap_if_configured(httpd, config))

    def test_copies_match(self) -> None:
        """The module ships inside three services; they must not drift."""
        repo = Path(__file__).resolve().parents[3]
        mine = Path(tls.__file__).read_bytes()
        for other in (
            repo / "LWCam_QC_Platform" / "backend" / "app" / "core" / "tls.py",
            repo / "LWIP" / "backend" / "deskew_crop_tool" / "tls.py",
            repo / "LWCam_Upload" / "backend" / "lwcam_upload" / "tls.py",
        ):
            if not other.is_file():
                self.skipTest(f"{other} is not checked out here")
            self.assertEqual(other.read_bytes(), mine, f"{other} differs")


if __name__ == "__main__":
    unittest.main()

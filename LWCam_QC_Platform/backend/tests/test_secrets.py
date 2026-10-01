"""Config secrets at rest: the lwcam_secrets module and the QC settings file."""

from __future__ import annotations

import os
import subprocess
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from pydantic import SecretStr

from app.core import lwcam_secrets, server_settings
from app.core.server_settings import (
    load_server_settings_overrides,
    migrate_plain_secrets,
    write_server_settings,
)

REPO = Path(__file__).resolve().parents[3]
COPIES = [
    "LWCam_QC_Platform/backend/app/core/lwcam_secrets.py",
    "LWIP/backend/deskew_crop_tool/lwcam_secrets.py",
    "LWCam_Upload/backend/lwcam_upload/lwcam_secrets.py",
    "LWCam_QC_Platform/scripts/lwcam_secrets.py",
    "installer/db/lwcam_secrets.py",
]
windows_only = unittest.skipUnless(sys.platform == "win32", "DPAPI is Windows-only")


class ParityTests(unittest.TestCase):
    def test_all_five_copies_are_byte_identical(self) -> None:
        blobs = {name: (REPO / name).read_bytes() for name in COPIES}
        self.assertEqual(len(set(blobs.values())), 1, "lwcam_secrets.py copies differ")


@windows_only
class ModuleTests(unittest.TestCase):
    def test_round_trip_passthrough_and_idempotence(self) -> None:
        protected = lwcam_secrets.protect("p@ss wörd")
        self.assertTrue(protected.startswith("dpapi:"))
        self.assertNotIn("p@ss", protected)
        self.assertEqual(lwcam_secrets.unprotect(protected), "p@ss wörd")
        self.assertEqual(lwcam_secrets.protect(protected), protected)
        self.assertEqual(lwcam_secrets.protect(""), "")
        self.assertEqual(lwcam_secrets.unprotect("plain"), "plain")
        self.assertTrue(lwcam_secrets.is_protected(protected))
        self.assertFalse(lwcam_secrets.is_protected("plain"))

    def test_garbage_with_prefix_raises_naming_the_key(self) -> None:
        for bad in ("dpapi:not base64!", "dpapi:AAAA"):
            with self.assertRaises(lwcam_secrets.SecretError) as ctx:
                lwcam_secrets.unprotect(bad, "dbPassword")
            self.assertIn("dbPassword", str(ctx.exception))

    def test_protect_file_key_value_keeps_layout_and_is_idempotent(self) -> None:
        with TemporaryDirectory() as temp:
            path = Path(temp) / "config.txt"
            original = b"# comment\r\ndbHost = x\r\ndbPassword = s3cret\r\n\r\njwtSecret=abc\r\nport = 1"
            path.write_bytes(original)
            self.assertTrue(lwcam_secrets.protect_file(path, ["dbPassword", "jwtSecret", "missing"]))
            data = path.read_bytes()
            self.assertFalse(data.startswith(b"\xef\xbb\xbf"))
            self.assertNotIn(b"s3cret", data)
            lines = data.decode().split("\r\n")
            self.assertEqual(lines[:2], ["# comment", "dbHost = x"])
            self.assertTrue(lines[2].startswith("dbPassword = dpapi:"))
            self.assertTrue(lines[4].startswith("jwtSecret=dpapi:"))
            self.assertEqual(lines[5], "port = 1")
            self.assertNotIn(b"\n", data.replace(b"\r\n", b""))
            self.assertFalse(lwcam_secrets.protect_file(path, ["dbPassword", "jwtSecret"]))
            self.assertEqual(path.read_bytes(), data)
            self.assertEqual(lwcam_secrets.unprotect(lines[2].split("= ", 1)[1]), "s3cret")

    def test_protect_file_json_and_cli(self) -> None:
        with TemporaryDirectory() as temp:
            path = Path(temp) / "c.json"
            path.write_bytes(b'{\r\n  "z": 1,\r\n  "db_password": "pw",\r\n  "a": "b"\r\n}\r\n')
            module = REPO / "installer/db/lwcam_secrets.py"
            run = subprocess.run(
                [sys.executable, str(module), "protect-file", str(path), "--keys", "db_password"],
                capture_output=True, text=True,
            )
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertNotIn("pw", run.stdout + run.stderr)
            data = path.read_bytes()
            self.assertTrue(data.endswith(b"\r\n"))
            self.assertNotIn(b'"pw"', data)
            self.assertLess(data.index(b'"z"'), data.index(b'"db_password"'))
            self.assertFalse(lwcam_secrets.protect_file(path, ["db_password"]))
            bad = subprocess.run(
                [sys.executable, str(module), "protect-file", str(path.with_name("nope.json")), "--keys", "x"],
                capture_output=True, text=True,
            )
            self.assertNotEqual(bad.returncode, 0)


@windows_only
class QcSettingsTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.path = Path(temp.name) / "config.txt"
        previous = os.environ.get("LWCAM_QC_SERVER_CONFIG")
        os.environ["LWCAM_QC_SERVER_CONFIG"] = str(self.path)
        self.addCleanup(self._restore, previous)
        server_settings.SECRET_PROBLEMS.clear()
        self.addCleanup(server_settings.SECRET_PROBLEMS.clear)

    @staticmethod
    def _restore(previous: str | None) -> None:
        if previous is None:
            os.environ.pop("LWCAM_QC_SERVER_CONFIG", None)
        else:
            os.environ["LWCAM_QC_SERVER_CONFIG"] = previous

    def test_reads_a_protected_config_and_a_plain_one(self) -> None:
        secret = "j" * 40
        self.path.write_text(f"dbPassword = {lwcam_secrets.protect('dbpw')}\njwtSecret = {secret}\n")
        values = load_server_settings_overrides()
        self.assertEqual(values["db_password"], "dbpw")
        self.assertEqual(values["jwt_secret"], secret)

    def test_start_migrates_plain_and_leaves_no_plaintext(self) -> None:
        self.path.write_text(f"dbHost = h\ndbPassword = dbpw\njwtSecret = {'j' * 40}\nopenrouterApiKey = sk-abc\n")
        self.assertTrue(migrate_plain_secrets())
        text = self.path.read_text()
        for plain in ("dbpw", "j" * 40, "sk-abc"):
            self.assertNotIn(plain, text)
        self.assertIn("dbHost = h", text)
        self.assertEqual(load_server_settings_overrides()["openrouter_api_key"], "sk-abc")
        self.assertFalse(migrate_plain_secrets())

    def test_console_save_writes_protected_values_and_keeps_others(self) -> None:
        write_server_settings({"db_password": SecretStr("dbpw"), "openrouter_api_key": SecretStr("sk-abc")})
        write_server_settings({"luminance_enabled": True})  # a later save must not lose or double-wrap
        text = self.path.read_text()
        self.assertNotIn("dbpw", text)
        self.assertNotIn("sk-abc", text)
        self.assertEqual(text.count("dpapi:"), 2)
        values = load_server_settings_overrides()
        self.assertEqual((values["db_password"], values["openrouter_api_key"]), ("dbpw", "sk-abc"))

    def test_undecryptable_value_is_reported_not_fatal_and_survives_a_save(self) -> None:
        self.path.write_text("dbPassword = dpapi:AAAA\njwtSecret = " + "j" * 40 + "\n")
        values = load_server_settings_overrides()
        self.assertNotIn("db_password", values)
        self.assertIn("dbPassword", server_settings.SECRET_PROBLEMS)
        self.assertIn("Enter it again", server_settings.SECRET_PROBLEMS["dbPassword"])
        write_server_settings({"luminance_enabled": True})
        self.assertIn("dbPassword = dpapi:AAAA", self.path.read_text())

    def test_unreadable_jwt_secret_refuses_to_build_the_app(self) -> None:
        from app.main import create_app

        server_settings.SECRET_PROBLEMS["jwtSecret"] = "jwtSecret cannot be decrypted"
        with self.assertRaises(RuntimeError) as ctx:
            create_app()
        self.assertIn("cannot be decrypted", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()

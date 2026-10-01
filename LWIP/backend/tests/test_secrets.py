"""LWIP: the database password is stored protected (lwcam_secrets)."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

from deskew_crop_tool import lwcam_secrets, service
from deskew_crop_tool.config import load_config

windows_only = unittest.skipUnless(sys.platform == "win32", "DPAPI is Windows-only")


@windows_only
class SecretsTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "in").mkdir()
        (root / "out").mkdir()
        self.path = root / "config" / "deskew_crop_config.json"
        self.path.parent.mkdir()
        self.base = {"input_root": str(root / "in"), "output_root": str(root / "out")}

    def write(self, **extra) -> None:
        self.path.write_text(json.dumps({**self.base, **extra}), encoding="utf-8")

    def test_reads_protected_and_plain_passwords(self) -> None:
        self.write(db_password=lwcam_secrets.protect("pw1"))
        self.assertEqual(load_config(self.path).db_password, "pw1")
        self.write(db_password="plain-pw")
        self.assertEqual(load_config(self.path).db_password, "plain-pw")

    def test_start_migrates_a_plain_password(self) -> None:
        self.write(db_password="plain-pw", workers=2)
        self.assertTrue(service.protect_stored_password(self.path))
        text = self.path.read_text(encoding="utf-8")
        self.assertNotIn("plain-pw", text)
        self.assertEqual(json.loads(text)["workers"], 2)
        self.assertEqual(load_config(self.path).db_password, "plain-pw")
        self.assertFalse(service.protect_stored_password(self.path))

    def test_console_save_writes_a_protected_password(self) -> None:
        self.write()
        status, _ = service.apply_settings_update(self.path, {"db_host": "h", "db_password": "new-pw"})
        self.assertEqual(status, 200)
        self.assertNotIn("new-pw", self.path.read_text(encoding="utf-8"))
        self.assertEqual(load_config(self.path).db_password, "new-pw")
        status, _ = service.apply_settings_update(self.path, {"workers": 2})  # blank keeps it, no double wrap
        self.assertEqual((status, load_config(self.path).db_password), (200, "new-pw"))

    def test_undecryptable_password_is_a_clear_config_error_not_a_crash(self) -> None:
        self.write(db_password="dpapi:AAAA")
        config, error = service.try_load_config(self.path)
        self.assertIsNone(config)
        self.assertIn("db_password", error)
        self.assertIn("another PC", error)
        self.assertFalse(service.protect_stored_password(self.path))  # nothing plain to do, no raise


if __name__ == "__main__":
    unittest.main()

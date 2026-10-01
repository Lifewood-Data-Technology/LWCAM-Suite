"""Upload: the database password and S3 secret key are stored protected."""

from __future__ import annotations

import json
import socket
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

from lwcam_upload import console, lwcam_secrets
from lwcam_upload.config import load_config

windows_only = unittest.skipUnless(sys.platform == "win32", "DPAPI is Windows-only")
S3 = {"s3_path": "s3://b/p", "s3_region": "us-east-1", "s3_access_key": "AK"}


@windows_only
class SecretsTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / "watch").mkdir()
        (self.root / "config").mkdir()
        self.path = self.root / "config" / "upload_config.json"
        self.base = {"watch_root": str(self.root / "watch"), "enabled": True, **S3}

    def write(self, **extra) -> None:
        self.path.write_text(json.dumps({**self.base, **extra}), encoding="utf-8")

    def test_reads_protected_and_plain_secrets(self) -> None:
        self.write(db_password=lwcam_secrets.protect("dbpw"), s3_secret_key=lwcam_secrets.protect("sk"))
        config = load_config(self.path)
        self.assertEqual((config.db_password, config.s3_secret_key), ("dbpw", "sk"))
        self.write(db_password="dbpw", s3_secret_key="sk")
        config = load_config(self.path)
        self.assertEqual((config.db_password, config.s3_secret_key), ("dbpw", "sk"))

    def test_console_save_writes_protected_secrets(self) -> None:
        self.write(s3_secret_key="old")
        status, _ = console.apply_settings_update(
            self.path, {"db_host": "h", "db_password": "dbpw", "s3_secret_key": "new-sk"}
        )
        self.assertEqual(status, 200)
        text = self.path.read_text(encoding="utf-8")
        self.assertNotIn("dbpw", text)
        self.assertNotIn("new-sk", text)
        config = load_config(self.path)
        self.assertEqual((config.db_password, config.s3_secret_key), ("dbpw", "new-sk"))
        status, _ = console.apply_settings_update(self.path, {"interval_seconds": 30})  # no double wrap
        self.assertEqual((status, load_config(self.path).s3_secret_key), (200, "new-sk"))

    def test_undecryptable_value_is_a_clear_config_error(self) -> None:
        self.write(s3_secret_key="dpapi:AAAA")
        config, error = console.try_load_config(self.path)
        self.assertIsNone(config)
        self.assertIn("s3_secret_key", error)
        self.assertIn("another PC", error)

    def test_service_start_migrates_plain_secrets(self) -> None:
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        self.write(
            enabled=False, db_password="plain-db", s3_secret_key="plain-sk",
            ui_port=port, ui_bind="127.0.0.1",
        )
        result: list[int] = []
        thread = threading.Thread(target=lambda: result.append(console.run(self.path)), daemon=True)
        thread.start()
        time.sleep(0.5)
        text = self.path.read_text(encoding="utf-8")
        (self.root / "runtime").mkdir(exist_ok=True)
        (self.root / "runtime" / "stop.request").write_text("", encoding="utf-8")
        thread.join(timeout=10)
        self.assertEqual(result, [0])
        self.assertNotIn("plain-db", text)
        self.assertNotIn("plain-sk", text)
        self.assertEqual(load_config(self.path).s3_secret_key, "plain-sk")


if __name__ == "__main__":
    unittest.main()

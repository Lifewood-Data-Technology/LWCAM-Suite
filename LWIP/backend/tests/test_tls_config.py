"""The console's tls_cert_file / tls_key_file settings: both or neither."""

import json
import tempfile
import unittest
from pathlib import Path

from deskew_crop_tool.config import load_config


class TlsConfigTests(unittest.TestCase):
    def _load(self, **extra):
        with tempfile.TemporaryDirectory() as temporary:
            (Path(temporary) / "config").mkdir()
            path = Path(temporary) / "config" / "tool.json"
            path.write_text(json.dumps({"input_root": "in", "output_root": "out", **extra}), encoding="utf-8")
            return load_config(path)

    def test_default_is_plain_http(self) -> None:
        config = self._load()
        self.assertEqual((config.tls_cert_file, config.tls_key_file), ("", ""))

    def test_both_set_loads(self) -> None:
        config = self._load(tls_cert_file="a.crt", tls_key_file="a.key")
        self.assertEqual((config.tls_cert_file, config.tls_key_file), ("a.crt", "a.key"))

    def test_only_one_is_refused(self) -> None:
        with self.assertRaises(ValueError):
            self._load(tls_cert_file="a.crt")


if __name__ == "__main__":
    unittest.main()

"""config.load_config validation - the rules the shared contract's config
table lists. Modelled on LWIP's own `deskew_crop_tool` config tests: construct
a JSON file by hand, load it, assert either the result or the raised
ValueError's reason.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from lwcam_upload.config import load_config, parse_s3_path


def _write(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload), encoding="utf-8")


class RequiredKeysTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app_root = Path(self.temp.name)
        self.config_dir = self.app_root / "config"
        self.config_dir.mkdir()
        self.config_path = self.config_dir / "upload_config.json"
        self.watch_root = self.app_root / "watch"
        self.watch_root.mkdir()

    def test_watch_root_is_required(self) -> None:
        _write(self.config_path, {"enabled": False})
        with self.assertRaises(ValueError):
            load_config(self.config_path)

    def test_disabled_needs_no_s3_settings(self) -> None:
        _write(self.config_path, {"watch_root": str(self.watch_root), "enabled": False})
        config = load_config(self.config_path)
        self.assertFalse(config.enabled)

    def test_enabled_requires_s3_settings(self) -> None:
        _write(
            self.config_path,
            {"watch_root": str(self.watch_root), "enabled": True},
        )
        with self.assertRaises(ValueError) as ctx:
            load_config(self.config_path)
        self.assertIn("s3_path", str(ctx.exception))

    def test_enabled_with_every_s3_setting_loads(self) -> None:
        _write(
            self.config_path,
            {
                "watch_root": str(self.watch_root),
                "enabled": True,
                "s3_path": "s3://bucket/prefix",
                "s3_region": "af-south-1",
                "s3_access_key": "key",
                "s3_secret_key": "secret",
            },
        )
        config = load_config(self.config_path)
        self.assertTrue(config.enabled)
        self.assertEqual(config.s3_path, "s3://bucket/prefix")

    def test_bad_s3_path_is_refused(self) -> None:
        _write(
            self.config_path,
            {
                "watch_root": str(self.watch_root),
                "enabled": True,
                "s3_path": "not-an-s3-path",
                "s3_region": "af-south-1",
                "s3_access_key": "key",
                "s3_secret_key": "secret",
            },
        )
        with self.assertRaises(ValueError):
            load_config(self.config_path)

    def test_s3_path_with_no_bucket_is_refused(self) -> None:
        with self.assertRaises(ValueError):
            parse_s3_path("s3://")


class RootSeparationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app_root = Path(self.temp.name)
        self.config_dir = self.app_root / "config"
        self.config_dir.mkdir()
        self.config_path = self.config_dir / "upload_config.json"
        self.watch_root = self.app_root / "watch"
        self.watch_root.mkdir()

    def _base_payload(self) -> dict:
        return {"watch_root": str(self.watch_root), "enabled": False}

    def test_done_root_inside_watch_root_is_refused(self) -> None:
        payload = self._base_payload()
        payload["done_root"] = str(self.watch_root / "done")
        _write(self.config_path, payload)
        with self.assertRaises(ValueError):
            load_config(self.config_path)

    def test_done_root_equal_to_watch_root_is_refused(self) -> None:
        payload = self._base_payload()
        payload["done_root"] = str(self.watch_root)
        _write(self.config_path, payload)
        with self.assertRaises(ValueError):
            load_config(self.config_path)

    def test_summary_root_inside_watch_root_is_refused(self) -> None:
        payload = self._base_payload()
        payload["summary_root"] = str(self.watch_root / "summary")
        _write(self.config_path, payload)
        with self.assertRaises(ValueError):
            load_config(self.config_path)

    def test_done_root_outside_watch_root_is_accepted(self) -> None:
        payload = self._base_payload()
        payload["done_root"] = str(self.app_root / "done")
        _write(self.config_path, payload)
        config = load_config(self.config_path)
        self.assertEqual(config.done_root, (self.app_root / "done").resolve())

    def test_blank_done_root_is_none(self) -> None:
        _write(self.config_path, self._base_payload())
        config = load_config(self.config_path)
        self.assertIsNone(config.done_root)
        self.assertIsNone(config.summary_root)


class PathResolutionTests(unittest.TestCase):
    def test_relative_state_file_resolves_against_the_config_files_grandparent(self) -> None:
        with TemporaryDirectory() as tmp:
            app_root = Path(tmp)
            config_dir = app_root / "config"
            config_dir.mkdir()
            config_path = config_dir / "upload_config.json"
            watch_root = app_root / "watch"
            watch_root.mkdir()
            _write(config_path, {"watch_root": str(watch_root), "enabled": False})

            config = load_config(config_path)

            self.assertEqual(config.state_file, (app_root / "runtime" / "uploads.json").resolve())
            self.assertEqual(config.log_file, (app_root / "logs" / "upload.log").resolve())


class OtherValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app_root = Path(self.temp.name)
        self.config_dir = self.app_root / "config"
        self.config_dir.mkdir()
        self.config_path = self.config_dir / "upload_config.json"
        self.watch_root = self.app_root / "watch"
        self.watch_root.mkdir()

    def test_interval_below_minimum_is_refused(self) -> None:
        _write(
            self.config_path,
            {"watch_root": str(self.watch_root), "enabled": False, "interval_seconds": 4},
        )
        with self.assertRaises(ValueError):
            load_config(self.config_path)

    def test_interval_is_bounded_both_ways(self) -> None:
        for value, ok in ((9, False), (10, True), (3600, True), (3601, False)):
            _write(
                self.config_path,
                {"watch_root": str(self.watch_root), "enabled": False, "interval_seconds": value},
            )
            if ok:
                self.assertEqual(load_config(self.config_path).interval_seconds, value)
            else:
                with self.assertRaises(ValueError):
                    load_config(self.config_path)

    def test_https_proxy_must_be_http_url_with_port(self) -> None:
        for value, ok in (
            ("", True), ("http://proxy.lan:3128", True), ("https://10.0.0.5:8080/", True),
            ("proxy.lan:3128", False), ("http://proxy.lan", False), ("ftp://p:1", False),
            ("http://user:pw@proxy.lan:3128", False), ("http://p:1/path", False),
        ):
            _write(
                self.config_path,
                {"watch_root": str(self.watch_root), "enabled": False, "https_proxy": value},
            )
            if ok:
                self.assertEqual(load_config(self.config_path).https_proxy, value.rstrip("/"))
            else:
                with self.assertRaises(ValueError, msg=value):
                    load_config(self.config_path)

    def test_enabled_must_be_a_bool(self) -> None:
        _write(
            self.config_path,
            {"watch_root": str(self.watch_root), "enabled": "true"},
        )
        with self.assertRaises(ValueError):
            load_config(self.config_path)

    def test_ui_port_out_of_range_is_refused(self) -> None:
        _write(
            self.config_path,
            {"watch_root": str(self.watch_root), "enabled": False, "ui_port": 70000},
        )
        with self.assertRaises(ValueError):
            load_config(self.config_path)

    def test_defaults_are_applied(self) -> None:
        _write(self.config_path, {"watch_root": str(self.watch_root), "enabled": False})
        config = load_config(self.config_path)
        self.assertEqual(config.interval_seconds, 60)
        self.assertEqual(config.ui_port, 8091)
        self.assertEqual(config.ui_bind, "0.0.0.0")
        self.assertEqual(config.db_port, 5432)
        self.assertEqual(config.db_name, "lwcam")
        self.assertFalse(config.db_use_ssl)


if __name__ == "__main__":
    unittest.main()

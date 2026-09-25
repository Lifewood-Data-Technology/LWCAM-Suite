"""Round-trip and validate the QC server's config.txt settings."""

from __future__ import annotations

import os
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from fastapi.middleware.cors import CORSMiddleware
from pydantic import SecretStr

from app.core.config import DEVELOPMENT_JWT_SECRET, Settings, settings
from app.core.server_settings import load_server_settings_overrides, write_server_settings
from app.main import create_app

UNC_PATH = r"\\nas\LWCamCapture\3.Export"


class ServerSettingsFileTests(unittest.TestCase):
    """Read/write against a real temp file, isolated by LWCAM_QC_SERVER_CONFIG."""

    def setUp(self) -> None:
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.config_path = Path(temp.name) / "config.txt"
        previous = os.environ.get("LWCAM_QC_SERVER_CONFIG")
        os.environ["LWCAM_QC_SERVER_CONFIG"] = str(self.config_path)
        self.addCleanup(self._restore_env, previous)

    def _restore_env(self, previous: str | None) -> None:
        if previous is None:
            os.environ.pop("LWCAM_QC_SERVER_CONFIG", None)
        else:
            os.environ["LWCAM_QC_SERVER_CONFIG"] = previous

    def test_missing_file_reads_as_empty(self) -> None:
        self.assertFalse(self.config_path.exists())
        self.assertEqual(load_server_settings_overrides(), {})

    def test_write_then_load_round_trips_every_key(self) -> None:
        values = {
            "export_temp_dir": r"C:\Console\Temp",
            "export_output_dir": r"C:\Console\Output",
            "export_zip_output": False,
            "export_tiff_output": False,
            "luminance_enabled": True,
            "preview_cache_max_mb": 4096,
        }
        write_server_settings(values)
        self.assertTrue(self.config_path.exists())
        self.assertEqual(load_server_settings_overrides(), values)

    def test_comments_and_blank_lines_are_ignored(self) -> None:
        """It exists to be hand-edited, so it has to tolerate being written on."""
        self.config_path.write_text(
            "\n".join(
                [
                    "# LWCam QC engine configuration",
                    "",
                    r"exportWorkRoot = C:\Station\Temp",
                    "   # an indented note someone left",
                    "exportZipOutput = false",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        self.assertEqual(
            load_server_settings_overrides(),
            {"export_temp_dir": r"C:\Station\Temp", "export_zip_output": False},
        )

    def test_qc_input_root_is_the_image_folder(self) -> None:
        self.config_path.write_text(
            f"qcInputRoot = {UNC_PATH}\nexportWorkRoot = C:\\Work\n", encoding="utf-8"
        )
        self.assertEqual(
            load_server_settings_overrides(),
            {"qc_images_root": UNC_PATH, "export_temp_dir": r"C:\Work"},
        )

    def test_a_file_from_before_the_rename_keeps_its_meanings(self) -> None:
        """Installed stations have qcImagesRoot = images, qcInputRoot = export work."""
        self.config_path.write_text(
            "qcImagesRoot = \nqcInputRoot = C:\\QC\\Export Work\n", encoding="utf-8"
        )
        self.assertEqual(
            load_server_settings_overrides(), {"export_temp_dir": r"C:\QC\Export Work"}
        )
        # The next save rewrites it with the new keys and the same values.
        write_server_settings({"qc_images_root": UNC_PATH})
        text = self.config_path.read_text(encoding="utf-8")
        self.assertIn(f"qcInputRoot = {UNC_PATH}", text)
        self.assertIn(r"exportWorkRoot = C:\QC\Export Work", text)
        self.assertNotIn("qcImagesRoot =", text)
        self.assertEqual(
            load_server_settings_overrides(),
            {"qc_images_root": UNC_PATH, "export_temp_dir": r"C:\QC\Export Work"},
        )

    def test_a_unc_path_survives_intact(self) -> None:
        """The reason this file matters on a split site - backslashes and all."""
        self.config_path.write_text(f"qcOutputRoot = {UNC_PATH}\n", encoding="utf-8")
        self.assertEqual(
            load_server_settings_overrides(), {"export_output_dir": UNC_PATH}
        )

    def test_booleans_accept_the_words_an_operator_would_type(self) -> None:
        cases = {
            "true": True,
            "TRUE": True,
            "yes": True,
            "on": True,
            "1": True,
            "false": False,
            "no": False,
            "off": False,
            "0": False,
        }
        for text, expected in cases.items():
            with self.subTest(text=text):
                self.config_path.write_text(
                    f"exportTiffOutput = {text}\n", encoding="utf-8"
                )
                self.assertEqual(
                    load_server_settings_overrides(), {"export_tiff_output": expected}
                )

    def test_a_boolean_that_is_not_one_is_reported_not_guessed(self) -> None:
        """This particular typo decides whether deliveries are lossless."""
        self.config_path.write_text("exportTiffOutput = maybe\n", encoding="utf-8")
        with self.assertRaises(RuntimeError):
            load_server_settings_overrides()

    def test_an_integer_setting_round_trips(self) -> None:
        self.config_path.write_text("previewCacheMaxMb = 4096\n", encoding="utf-8")
        self.assertEqual(
            load_server_settings_overrides(), {"preview_cache_max_mb": 4096}
        )

    def test_an_integer_that_is_not_one_is_reported_not_guessed(self) -> None:
        """A typo here should not silently disable or shrink the cache cap."""
        self.config_path.write_text("previewCacheMaxMb = a lot\n", encoding="utf-8")
        with self.assertRaises(RuntimeError):
            load_server_settings_overrides()

    def test_settings_station_setup_used_to_supply_round_trip(self) -> None:
        """These came from the node config; losing them would reset a station to defaults."""
        write_server_settings(
            {"export_worker_count": 6, "jwt_expire_minutes": 120, "export_temp_retention_hours": 48}
        )
        self.assertEqual(
            load_server_settings_overrides(),
            {"export_worker_count": 6, "jwt_expire_minutes": 120, "export_temp_retention_hours": 48},
        )
        for key in ("exportWorkerCount", "jwtExpireMinutes", "exportTempRetentionHours"):
            self.config_path.write_text(f"{key} = several\n", encoding="utf-8")
            with self.assertRaises(RuntimeError, msg=key):
                load_server_settings_overrides()

    def test_unknown_keys_on_disk_are_dropped_not_rejected(self) -> None:
        """A file from an older or newer build should still load under this one."""
        self.config_path.write_text(
            "exportZipOutput = false\nsomeFutureKey = x\n", encoding="utf-8"
        )
        self.assertEqual(load_server_settings_overrides(), {"export_zip_output": False})

    def test_unknown_keys_passed_to_write_are_not_persisted(self) -> None:
        write_server_settings({"export_zip_output": False, "not_a_real_setting": "x"})
        text = self.config_path.read_text(encoding="utf-8")
        self.assertIn("exportZipOutput = false", text)
        self.assertNotIn("not_a_real_setting", text)

    def test_a_save_keeps_settings_it_was_not_asked_to_change(self) -> None:
        """The console rewrites the whole file; it must not drop what it did not send."""
        write_server_settings(
            {"export_temp_dir": r"C:\Keep\Me", "export_zip_output": True}
        )
        write_server_settings({"export_zip_output": False})
        loaded = load_server_settings_overrides()
        self.assertEqual(loaded["export_temp_dir"], r"C:\Keep\Me")
        self.assertFalse(loaded["export_zip_output"])

    def test_the_written_file_explains_itself(self) -> None:
        """Someone who did not write it opens it in Notepad."""
        write_server_settings({"export_tiff_output": True})
        text = self.config_path.read_text(encoding="utf-8")
        self.assertTrue(text.lstrip().startswith("#"))
        self.assertIn("exportTiffOutput = true", text)


    def test_secret_settings_round_trip_through_pydantic(self) -> None:
        secrets = {
            "db_password": SecretStr("db-secret-for-test"),
            "jwt_secret": SecretStr("j" * 40),
            "openrouter_api_key": SecretStr("router-secret-for-test"),
        }
        write_server_settings(secrets)
        loaded = Settings(**load_server_settings_overrides())
        self.assertTrue(all(getattr(loaded, field) == value for field, value in secrets.items()))

    def test_database_and_server_values_are_coerced(self) -> None:
        self.config_path.write_text(
            "dbUseSsl = yes\nport = 8090\ndbPort = 5544\n",
            encoding="utf-8",
        )
        self.assertEqual(
            load_server_settings_overrides(),
            {"db_use_ssl": True, "port": 8090, "db_port": 5544},
        )

    def test_blank_secrets_are_skipped_on_load(self) -> None:
        self.config_path.write_text(
            "dbPassword = \njwtSecret = \nopenrouterApiKey = \n",
            encoding="utf-8",
        )
        self.assertEqual(load_server_settings_overrides(), {})

    def test_old_upload_keys_are_ignored_but_the_rest_of_the_file_still_loads(self) -> None:
        """Upload moved to the standalone LWCam Upload service (2026-09-25).

        A config.txt saved before that move still has uploadEnabled/
        uploadS3Path/uploadS3Region/uploadS3AccessKey/uploadS3SecretKey/
        uploadDoneRoot/uploadSummaryRoot lines. They are simply unrecognised
        keys now - same as any other stale line - so the engine keeps
        starting on the file, and a console save silently drops them instead
        of writing them back.
        """
        self.config_path.write_text(
            "dbPort = 5544\n"
            "uploadEnabled = true\n"
            "uploadS3Path = s3://bucket/prefix\n"
            "uploadS3Region = us-east-1\n"
            "uploadS3AccessKey = key-id\n"
            "uploadS3SecretKey = secret-value\n"
            "uploadDoneRoot = C:\\Uploaded\n"
            "uploadSummaryRoot = C:\\Upload Reports\n",
            encoding="utf-8",
        )
        self.assertEqual(load_server_settings_overrides(), {"db_port": 5544})

        # A Settings save must not crash on them, and the next save drops them
        # as WRITTEN `key = value` lines - the header's own explanation of the
        # move necessarily still names them in prose.
        write_server_settings({"export_zip_output": False})
        lines = self.config_path.read_text(encoding="utf-8").splitlines()
        for key in (
            "uploadEnabled", "uploadS3Path", "uploadS3Region", "uploadS3AccessKey",
            "uploadS3SecretKey", "uploadDoneRoot", "uploadSummaryRoot",
        ):
            self.assertFalse(any(line.startswith(f"{key} = ") for line in lines), key)
        self.assertEqual(
            load_server_settings_overrides(),
            {"db_port": 5544, "export_zip_output": False},
        )

    def test_dev_jwt_secret_is_refused_for_non_loopback_bind(self) -> None:
        with patch.object(settings, "bind_host", "0.0.0.0"), patch.object(
            settings, "jwt_secret", SecretStr(DEVELOPMENT_JWT_SECRET)
        ):
            with self.assertRaisesRegex(RuntimeError, "jwtSecret"):
                create_app()


    def test_cors_is_disabled_for_lan_without_origins_and_kept_for_loopback(self) -> None:
        with patch.object(settings, "cors_allowed_origins", ""), patch.object(
            settings, "jwt_secret", SecretStr("k" * 40)
        ):
            with patch.object(settings, "bind_host", "0.0.0.0"):
                lan_app = create_app()
                self.assertFalse(
                    any(middleware.cls is CORSMiddleware for middleware in lan_app.user_middleware)
                )
            with patch.object(settings, "bind_host", "localhost"):
                loopback_app = create_app()
                cors = [
                    middleware
                    for middleware in loopback_app.user_middleware
                    if middleware.cls is CORSMiddleware
                ]
                self.assertEqual(len(cors), 1)
                self.assertEqual(
                    cors[0].kwargs["allow_origin_regex"],
                    r"http://(localhost|127\.0\.0\.1):\d+",
                )


class ExportAutoEnabledTests(unittest.TestCase):
    """The auto-export toggle the console added.

    It is the one setting here whose OFF position stops the station producing
    anything, so what matters is that it survives the round trip and that a
    file which predates it does not read as OFF.
    """

    def setUp(self) -> None:
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.config_path = Path(temp.name) / "config.txt"
        previous = os.environ.get("LWCAM_QC_SERVER_CONFIG")
        os.environ["LWCAM_QC_SERVER_CONFIG"] = str(self.config_path)
        self.addCleanup(self._restore_env, previous)

    def _restore_env(self, previous: str | None) -> None:
        if previous is None:
            os.environ.pop("LWCAM_QC_SERVER_CONFIG", None)
        else:
            os.environ["LWCAM_QC_SERVER_CONFIG"] = previous

    def test_off_survives_the_round_trip(self) -> None:
        write_server_settings({"export_auto_enabled": False})
        self.assertIn("exportAutoEnabled = false", self.config_path.read_text(encoding="utf-8"))
        self.assertIs(load_server_settings_overrides()["export_auto_enabled"], False)

    def test_on_survives_the_round_trip(self) -> None:
        write_server_settings({"export_auto_enabled": True})
        self.assertIs(load_server_settings_overrides()["export_auto_enabled"], True)

    def test_a_file_written_before_the_toggle_existed_does_not_read_as_off(self) -> None:
        """Absence is not False.

        An older console wrote no exportAutoEnabled line. If the loader reported
        one anyway it would override Settings' own True default, and every
        station that upgraded would quietly stop exporting - with nothing on
        screen saying so.
        """
        write_server_settings({"export_temp_dir": r"C:\Console\Temp"})
        self.assertNotIn("export_auto_enabled", load_server_settings_overrides())
        self.assertIs(Settings(**load_server_settings_overrides()).export_auto_enabled, True)

    def test_a_technician_typing_the_word_off_is_understood(self) -> None:
        """The file is edited in Notepad; `off` and `no` are what people type."""
        self.config_path.write_text("exportAutoEnabled = off\n", encoding="utf-8")
        self.assertIs(load_server_settings_overrides()["export_auto_enabled"], False)

    def test_a_typo_is_reported_rather_than_defaulted(self) -> None:
        """Same rule the other booleans follow: this decides whether deliveries
        get produced, so a value nobody can read is an error, not a default."""
        self.config_path.write_text("exportAutoEnabled = maybe\n", encoding="utf-8")
        with self.assertRaises(RuntimeError):
            load_server_settings_overrides()

"""The Admin settings endpoint persists console-owned AI settings."""

from __future__ import annotations

import os
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest.mock import patch

from pydantic import SecretStr

from app.core import netlogin
from app.core.config import Settings, settings
from app.core.errors import BusinessError
from app.core.server_settings import load_server_settings_overrides, write_server_settings
from app.routers.admin import check_directory, get_path_settings, update_server_settings, validate_path_settings
from app.schemas.admin import UpdatePathSettingsRequest, UpdateServerSettingsRequest


class EmptyDb:
    def scalars(self, *_args, **_kwargs):
        return SimpleNamespace(all=lambda: [])


class AdminServerSettingsTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.config_path = self.root / "config.txt"
        previous = os.environ.get("LWCAM_QC_SERVER_CONFIG")
        os.environ["LWCAM_QC_SERVER_CONFIG"] = str(self.config_path)
        self.addCleanup(self._restore_env, previous)
        # Never the real per-PC login store under %ProgramData%.
        store = patch.dict(os.environ, {netlogin.STORE_ENV: str(self.root / "logins.json")})
        store.start()
        self.addCleanup(store.stop)

        names = (
            "qc_images_root",
            "export_temp_dir",
            "export_output_dir",
            "export_zip_output",
            "export_tiff_output",
            "luminance_enabled",
            "export_auto_enabled",
            "ai_review_enabled",
            "ai_preanalysis_enabled",
            "openrouter_api_key",
            "openrouter_extract_model",
            "openrouter_compare_model",
        )
        previous_settings = {name: getattr(settings, name) for name in names}
        self.addCleanup(self._restore_settings, previous_settings)

        self.export_temp = self.root / "export-temp"
        self.export_output = self.root / "export-output"
        for directory in (self.export_temp, self.export_output):
            directory.mkdir()

        settings.qc_images_root = ""
        settings.export_temp_dir = str(self.export_temp)
        settings.export_output_dir = str(self.export_output)
        settings.export_zip_output = True
        settings.export_tiff_output = True
        settings.luminance_enabled = False
        settings.export_auto_enabled = True
        settings.ai_review_enabled = False
        settings.ai_preanalysis_enabled = False
        settings.openrouter_api_key = None

    def _restore_env(self, previous: str | None) -> None:
        if previous is None:
            os.environ.pop("LWCAM_QC_SERVER_CONFIG", None)
        else:
            os.environ["LWCAM_QC_SERVER_CONFIG"] = previous

    @staticmethod
    def _restore_settings(values: dict[str, object]) -> None:
        for name, value in values.items():
            setattr(settings, name, value)

    def _request(self, **fields) -> UpdateServerSettingsRequest:
        values = {
            "qcImagesRoot": "",
            "exportTempDir": str(self.export_temp),
            "exportOutputDir": str(self.export_output),
            "exportZipOutput": True,
            "exportTiffOutput": True,
            "luminanceEnabled": False,
            "exportAutoEnabled": True,
        }
        values.update(fields)
        return UpdateServerSettingsRequest(**values)

    def _update(self, **fields):
        return update_server_settings(self._request(**fields), None, EmptyDb())

    def test_writer_rejects_control_characters_without_overwriting_config(self) -> None:
        existing = b"preserve this config\r\n"
        self.config_path.write_bytes(existing)
        submitted = "secret-marker\ninjected-value"

        with self.assertRaises(RuntimeError) as caught:
            write_server_settings({"openrouter_api_key": SecretStr(submitted)})

        self.assertIn("openrouterApiKey", str(caught.exception))
        self.assertNotIn("openrouter_api_key", str(caught.exception))
        self.assertNotIn("secret-marker", str(caught.exception))
        self.assertEqual(self.config_path.read_bytes(), existing)

    def test_openrouter_key_control_characters_are_a_bad_request_without_echo(self) -> None:
        submitted = "private-key-marker\ncontinued"

        with self.assertRaises(BusinessError) as caught:
            self._update(openrouterApiKey=submitted)

        self.assertEqual(caught.exception.http_status, 400)
        self.assertIn("openrouterApiKey", caught.exception.message)
        self.assertNotIn("private-key-marker", caught.exception.message)
        self.assertNotIn("openrouter_api_key", caught.exception.message)

    def test_unicode_line_separators_are_refused_but_ordinary_non_ascii_is_kept(self) -> None:
        for separator in ("\u2028", "\u2029", "\x85"):
            with self.assertRaises(BusinessError, msg=repr(separator)):
                self._update(openrouterExtractModel=f"model{separator}jwtSecret = x")
        # An accented or CJK name is ordinary text, not a line break.
        self._update(openrouterExtractModel="modèle-中文")
        self.assertEqual(load_server_settings_overrides()["openrouter_extract_model"], "modèle-中文")

    def test_blank_model_name_clears_and_omitted_fields_stay_untouched(self) -> None:
        settings.openrouter_extract_model = "existing-extract-model"
        settings.openrouter_compare_model = "existing-compare-model"
        write_server_settings(
            {
                "openrouter_extract_model": settings.openrouter_extract_model,
                "openrouter_compare_model": settings.openrouter_compare_model,
            }
        )

        response = self._update(openrouterExtractModel="")

        # Cleared means the DEFAULT model, live and after a restart - an empty
        # model name would send every AI request with no model at all.
        default = Settings.model_fields["openrouter_extract_model"].default
        self.assertTrue(default)
        self.assertEqual(settings.openrouter_extract_model, default)
        self.assertEqual(response.data.ai.extractModel, default)
        self.assertEqual(load_server_settings_overrides()["openrouter_extract_model"], default)
        self.assertEqual(settings.openrouter_compare_model, "existing-compare-model")
        self.assertEqual(
            load_server_settings_overrides()["openrouter_compare_model"],
            "existing-compare-model",
        )

    def test_new_openrouter_key_is_saved_and_applied_live(self) -> None:
        response = self._update(aiReviewEnabled=True, openrouterApiKey="new-key-12345")

        self.assertEqual(settings.openrouter_api_key.get_secret_value(), "new-key-12345")
        self.assertEqual(
            load_server_settings_overrides()["openrouter_api_key"],
            "new-key-12345",
        )
        self.assertTrue(response.data.ai.keyConfigured)
        self.assertNotIn("new-key-12345", response.model_dump_json())

    def test_get_settings_never_exposes_secret_values(self) -> None:
        settings.ai_review_enabled = True
        settings.openrouter_api_key = SecretStr("private-openrouter-secret")
        response = get_path_settings(None)
        serialized = response.model_dump_json()

        self.assertTrue(response.data.ai.keyConfigured)
        self.assertNotIn("private-openrouter-secret", serialized)
        self.assertNotIn("openrouter_api_key", serialized)

    def test_enabled_ai_without_a_key_is_rejected(self) -> None:
        settings.ai_review_enabled = False
        settings.openrouter_api_key = None
        with self.assertRaises(BusinessError):
            self._update(aiReviewEnabled=True)

    def test_input_root_must_exist_and_is_never_created(self) -> None:
        missing = self.root / "no-such-share"
        with self.assertRaises(BusinessError):
            self._update(qcImagesRoot=str(missing))
        self.assertFalse(missing.exists())

    def test_work_folder_must_be_separate_from_input_and_output(self) -> None:
        images = self.root / "batches"
        images.mkdir()
        for work in (self.export_output, self.export_output / "work", images, images / "work"):
            with self.subTest(work=work):
                with self.assertRaises(BusinessError) as caught:
                    self._update(qcImagesRoot=str(images), exportTempDir=str(work))
                self.assertIn(
                    "exportTempDirSeparate", [c["key"] for c in caught.exception.data["checks"]]
                )
        self._update(qcImagesRoot=str(images))
        self.assertEqual(settings.qc_images_root, str(images))

    def test_a_drive_letter_the_server_cannot_see_is_explained(self) -> None:
        free = next(
            (f"{letter}:" for letter in "ZYXWVUTSRQPONMLKJ" if not os.path.isdir(f"{letter}:\\")),
            None,
        )
        if free is None:
            self.skipTest("no unused drive letter")
        check = check_directory("exportOutputDir", f"{free}\\Export", require_writable=True)
        self.assertFalse(check.writable)
        self.assertIn("\\\\server\\share", check.message)

    def test_a_refused_network_login_is_explained_not_a_500(self) -> None:
        """What a workgroup PC answers the QC server's SYSTEM task: WinError 1326.

        On Python 3.13 (the shipped runtime) Path.is_dir() raises it; 3.14's
        answers False. Both are patched in, so this fails on either runtime
        unless the check neither raises nor calls it "does not exist".
        """
        for refused in (
            OSError(22, "The user name or password is incorrect", r"\\PC1\share", 1326),
            # What the QC PC's own log showed on 2026-09-28, for \\FILE-PC\...
            PermissionError(13, "Access is denied", r"\\PC1\share", 5),
        ):
            with (
                self.subTest(winerror=refused.winerror),
                patch("pathlib.Path.is_dir", side_effect=refused),
                patch("app.routers.admin.os.stat", side_effect=refused),
            ):
                check = check_directory("exportOutputDir", r"\\PC1\share\3.Export", require_writable=True)
                self.assertFalse(check.exists)
                self.assertFalse(check.writable)
                self.assertIn(refused.strerror, check.message)
                self.assertIn("Add a login for PC1 under Network folder logins", check.message)

    def test_a_saved_network_login_is_used_and_its_refusal_reported(self) -> None:
        with patch.object(netlogin, "_add_connection", return_value=0), patch.object(netlogin, "_cancel"):
            netlogin.save_login("PC1", r"PC1\lwcam-share", "secret")
        with patch.object(netlogin, "_add_connection", return_value=1326) as add:
            check = check_directory("exportOutputDir", r"\\PC1\share\3.Export", require_writable=True)
        add.assert_called_with("PC1", r"PC1\lwcam-share", "secret")
        self.assertFalse(check.writable)
        self.assertEqual(check.message, "PC1 did not accept this username or password.")

    def test_netlogin_copies_match(self) -> None:
        """The module ships inside three products; they must not drift."""
        repo = Path(__file__).resolve().parents[3]
        mine = Path(netlogin.__file__).read_bytes()
        for other in (
            repo / "LWIP" / "backend" / "deskew_crop_tool" / "netlogin.py",
            repo / "LWCam_Upload" / "backend" / "lwcam_upload" / "netlogin.py",
        ):
            if not other.is_file():
                self.skipTest(f"{other} is not checked out here")
            self.assertEqual(other.read_bytes(), mine, f"{other} differs from app/core/netlogin.py")

    def test_an_unknown_network_pc_is_not_called_a_missing_folder(self) -> None:
        missing_pc = FileNotFoundError(2, "The network path was not found", r"\\PC1\share", 53)
        with patch("app.routers.admin.os.stat", side_effect=missing_pc):
            check = check_directory("qcImagesRoot", r"\\PC1\share", require_writable=True, must_exist=True)
        self.assertEqual(check.message, "This folder could not be reached: The network path was not found.")

    def test_every_path_can_be_a_network_path(self) -> None:
        """\\\\localhost\\C$ reaches this PC's own disk through SMB, as a share would."""
        drive, rest = os.path.splitdrive(str(self.root))
        if len(drive) != 2 or not os.path.isdir(f"\\\\localhost\\{drive[0]}$\\"):
            self.skipTest("administrative share not reachable")
        unc = lambda path: f"\\\\localhost\\{drive[0]}${os.path.splitdrive(str(path))[1]}"
        images = self.root / "batches"
        images.mkdir()
        self._update(
            qcImagesRoot=unc(images),
            exportTempDir=unc(self.export_temp),
            exportOutputDir=unc(self.export_output),
        )
        saved = load_server_settings_overrides()
        self.assertEqual(saved["qc_images_root"], unc(images))
        self.assertEqual(saved["export_temp_dir"], unc(self.export_temp))
        self.assertEqual(saved["export_output_dir"], unc(self.export_output))

    def test_folder_probe_counts_only_folders_waiting_for_qc(self) -> None:
        """Finished folders' batches get archived; counting them kept the 0-of-N warning up."""
        seen = []

        class RecordingDb:
            def scalars(self, statement, *_args, **_kwargs):
                seen.append(str(statement.compile(compile_kwargs={"literal_binds": True})))
                return SimpleNamespace(all=lambda: [])

        validation = validate_path_settings(
            RecordingDb(),
            UpdatePathSettingsRequest(exportTempDir=str(self.export_temp), exportOutputDir=str(self.export_output)),
        )
        self.assertIn("upper(capture_folders.qc_status) = 'PENDING'", seen[0])
        # The retired prefix pair is not reported unless someone sends it.
        self.assertNotIn("captureImageLocalRoot", [check.key for check in validation.checks])

    def test_older_request_shape_leaves_ai_values_unchanged(self) -> None:
        settings.ai_review_enabled = True
        settings.ai_preanalysis_enabled = True
        settings.openrouter_api_key = SecretStr("existing-ai-secret")
        write_server_settings(
            {
                "ai_review_enabled": True,
                "ai_preanalysis_enabled": True,
                "openrouter_api_key": settings.openrouter_api_key,
            }
        )
        before = {
            key: value
            for key, value in load_server_settings_overrides().items()
            if key.startswith("ai_") or key == "openrouter_api_key"
        }

        self._update()

        after = load_server_settings_overrides()
        self.assertTrue(settings.ai_review_enabled)
        self.assertTrue(settings.ai_preanalysis_enabled)
        self.assertEqual(settings.openrouter_api_key.get_secret_value(), "existing-ai-secret")
        self.assertEqual(
            {key: value for key, value in after.items() if key in before},
            before,
        )


if __name__ == "__main__":
    unittest.main()

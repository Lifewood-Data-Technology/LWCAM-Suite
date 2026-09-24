"""The Admin settings endpoint persists console-owned upload and AI settings."""

from __future__ import annotations

import os
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace

from pydantic import SecretStr

from app.core.config import Settings, settings
from app.core.errors import BusinessError
from app.core.server_settings import load_server_settings_overrides, write_server_settings
from app.routers.admin import get_path_settings, update_server_settings
from app.schemas.admin import UpdateServerSettingsRequest
from app.services.upload import UploadError, upload_runtime_config


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

        names = (
            "qc_images_root",
            "export_temp_dir",
            "export_output_dir",
            "export_zip_output",
            "export_tiff_output",
            "luminance_enabled",
            "export_auto_enabled",
            "upload_enabled",
            "upload_s3_path",
            "upload_s3_region",
            "upload_s3_access_key",
            "upload_s3_secret_key",
            "upload_done_dir",
            "upload_summary_dir",
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
        self.done = self.root / "uploaded"
        self.summary = self.root / "upload-summary"
        for directory in (self.export_temp, self.export_output, self.done, self.summary):
            directory.mkdir()

        settings.qc_images_root = ""
        settings.export_temp_dir = str(self.export_temp)
        settings.export_output_dir = str(self.export_output)
        settings.export_zip_output = True
        settings.export_tiff_output = True
        settings.luminance_enabled = False
        settings.export_auto_enabled = True
        settings.upload_enabled = False
        settings.upload_s3_path = ""
        settings.upload_s3_region = ""
        settings.upload_s3_access_key = ""
        settings.upload_s3_secret_key = None
        settings.upload_done_dir = ""
        settings.upload_summary_dir = ""
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

    def _seed_upload(self, *, secret: str | None = "existing-s3-secret", done: Path | None = None) -> None:
        settings.upload_enabled = True
        settings.upload_s3_path = "s3://qc-test-bucket/packages"
        settings.upload_s3_region = "us-east-1"
        settings.upload_s3_access_key = "access-id"
        settings.upload_s3_secret_key = SecretStr(secret) if secret is not None else None
        settings.upload_done_dir = str(done or self.done)
        settings.upload_summary_dir = str(self.summary)
        values = {
            "upload_enabled": True,
            "upload_s3_path": settings.upload_s3_path,
            "upload_s3_region": settings.upload_s3_region,
            "upload_s3_access_key": settings.upload_s3_access_key,
            "upload_done_dir": settings.upload_done_dir,
            "upload_summary_dir": settings.upload_summary_dir,
        }
        if settings.upload_s3_secret_key:
            values["upload_s3_secret_key"] = settings.upload_s3_secret_key
        write_server_settings(values)

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

    def test_upload_path_control_characters_are_a_bad_request_without_echo(self) -> None:
        submitted = "s3://bucket/path-marker\ncontinued"

        with self.assertRaises(BusinessError) as caught:
            self._update(uploadS3Path=submitted)

        self.assertEqual(caught.exception.http_status, 400)
        self.assertIn("uploadS3Path", caught.exception.message)
        self.assertNotIn("path-marker", caught.exception.message)
        self.assertNotIn("upload_s3_path", caught.exception.message)

    def test_unicode_line_separators_are_refused_but_ordinary_non_ascii_is_kept(self) -> None:
        for separator in ("\u2028", "\u2029", "\x85"):
            with self.assertRaises(BusinessError, msg=repr(separator)):
                self._update(openrouterExtractModel=f"model{separator}jwtSecret = x")
        # An accented or CJK name is ordinary text, not a line break.
        self._update(openrouterExtractModel="modèle-中文")
        self.assertEqual(load_server_settings_overrides()["openrouter_extract_model"], "modèle-中文")

    def test_summary_root_inside_export_root_is_rejected_by_upload_runtime(self) -> None:
        self._seed_upload()
        nested = self.export_output / "summary"
        nested.mkdir()
        settings.upload_summary_dir = str(nested)

        with self.assertRaises(UploadError) as caught:
            upload_runtime_config(settings, export_output_dir=self.export_output)

        self.assertEqual(
            str(caught.exception),
            "The summary folder must be outside the QC output folder",
        )

    def test_summary_root_inside_export_root_is_rejected_by_settings_endpoint(self) -> None:
        self._seed_upload()
        nested = self.export_output / "summary"
        nested.mkdir()

        with self.assertRaises(BusinessError) as caught:
            self._update(uploadEnabled=True, uploadSummaryRoot=str(nested))

        self.assertEqual(caught.exception.http_status, 400)
        self.assertEqual(
            caught.exception.message,
            "uploadSummaryRoot must be outside the export output folder",
        )

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

    def test_blank_upload_secret_keeps_existing_secret(self) -> None:
        self._seed_upload()
        self._update(uploadEnabled=True, uploadS3SecretKey="")

        self.assertEqual(
            settings.upload_s3_secret_key.get_secret_value(),
            "existing-s3-secret",
        )
        self.assertEqual(
            load_server_settings_overrides()["upload_s3_secret_key"],
            "existing-s3-secret",
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
        self._seed_upload()
        settings.ai_review_enabled = True
        settings.openrouter_api_key = SecretStr("private-openrouter-secret")
        response = get_path_settings(None)
        serialized = response.model_dump_json()

        self.assertTrue(response.data.upload.secretKeyConfigured)
        self.assertTrue(response.data.ai.keyConfigured)
        self.assertNotIn("existing-s3-secret", serialized)
        self.assertNotIn("private-openrouter-secret", serialized)
        self.assertNotIn("upload_s3_secret_key", serialized)
        self.assertNotIn("openrouter_api_key", serialized)

    def test_invalid_s3_path_is_rejected(self) -> None:
        self._seed_upload()

        with self.assertRaises(BusinessError):
            self._update(uploadEnabled=True, uploadS3Path="https://example.com/bucket")

    def test_upload_done_root_inside_export_root_is_rejected(self) -> None:
        nested = self.export_output / "uploaded"
        nested.mkdir()
        self._seed_upload(done=nested)

        with self.assertRaises(BusinessError):
            self._update(uploadEnabled=True)

    def test_enabled_upload_or_ai_without_a_key_is_rejected(self) -> None:
        self._seed_upload(secret=None)
        with self.assertRaises(BusinessError):
            self._update(uploadEnabled=True)

        settings.upload_enabled = False
        settings.ai_review_enabled = False
        settings.openrouter_api_key = None
        with self.assertRaises(BusinessError):
            self._update(aiReviewEnabled=True)

    def test_older_request_shape_leaves_upload_and_ai_values_unchanged(self) -> None:
        self._seed_upload()
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
            if key.startswith("upload_") or key.startswith("ai_") or key == "openrouter_api_key"
        }

        self._update()

        after = load_server_settings_overrides()
        self.assertTrue(settings.upload_enabled)
        self.assertTrue(settings.ai_review_enabled)
        self.assertTrue(settings.ai_preanalysis_enabled)
        self.assertEqual(settings.openrouter_api_key.get_secret_value(), "existing-ai-secret")
        self.assertEqual(
            {key: value for key, value in after.items() if key in before},
            before,
        )


if __name__ == "__main__":
    unittest.main()

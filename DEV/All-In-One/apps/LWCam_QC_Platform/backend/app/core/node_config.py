import json
import os
from pathlib import Path
from typing import Any


def load_node_config(path: str | Path | None = None) -> dict[str, Any]:
    value = path or os.environ.get("LWCAM_NODE_CONFIG")
    if not value:
        return {}
    config_path = Path(value).expanduser()
    try:
        data = json.loads(config_path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise RuntimeError(f"LWCam configuration not found: {config_path}") from error
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"LWCam configuration is unreadable: {config_path}") from error
    if not isinstance(data, dict):
        raise RuntimeError(f"LWCam configuration must contain a JSON object: {config_path}")
    return data


def settings_overrides(data: dict[str, Any]) -> dict[str, Any]:
    if not data:
        return {}
    required = (
        "pgHost",
        "pgDatabase",
        "pgUser",
        "pgPassword",
        "qcJwtSecret",
        "qcInputRoot",
        "qcOutputRoot",
    )
    missing = [key for key in required if not str(data.get(key) or "").strip()]
    if missing:
        raise RuntimeError(f"LWCam QC configuration is missing: {', '.join(missing)}")
    if len(str(data["qcJwtSecret"])) < 32:
        raise RuntimeError("LWCam QC JWT secret must be at least 32 characters")
    mapping = {
        "pgHost": "db_host",
        "pgPort": "db_port",
        "pgDatabase": "db_name",
        "pgUser": "db_user",
        "pgPassword": "db_password",
        "pgUseSsl": "db_use_ssl",
        "qcJwtSecret": "jwt_secret",
        "qcJwtExpireMinutes": "jwt_expire_minutes",
        "qcInputRoot": "export_temp_dir",
        "qcOutputRoot": "export_output_dir",
        # Prefix remap for capture_folders.folder_path (app/core/paths.py).
        # LWCAM owns that column and writes it as an absolute path on the
        # CAPTURE PC, so a station that reviews or exports work captured
        # elsewhere cannot open it as stored. Mapping the stored prefix onto one
        # this PC can reach - typically a local path onto the capture PC's UNC
        # share - is what makes a split capture/QC site work, and it is why the
        # capture PC does not have to write UNC paths (and pay SMB on its own
        # writes) just so another PC can read them.
        #
        # Both blank on a single-PC station: paths.to_local is then an identity
        # mapping. Previously reachable only from the Vue console, which no
        # longer ships, leaving no way to set this on an installed station.
        "captureImageHostPath": "capture_image_host_path",
        "captureImageContainerPath": "capture_image_container_path",
        "exportCsvEncoding": "export_csv_encoding",
        "exportCsvLineEnding": "export_csv_line_ending",
        "exportTempRetentionHours": "export_temp_retention_hours",
        "exportWorkerCount": "export_worker_count",
        "exportZipOutput": "export_zip_output",
        # Whether QC offers Luminance Correction. Off for clients working to
        # archival standards -- the tool rewrites tones, which FamilySearch and
        # similar reject as image enhancement. Defaults on, so a station that
        # predates the key keeps the behaviour it had.
        "luminanceEnabled": "luminance_enabled",
        # AI metadata review. Set in LWCam Admin's Station Setup, which is the
        # suite's only configuration tool. The API key rides in the node config
        # rather than app_settings on purpose: LWCAM pulls app_settings onto every
        # capture PC and writes it to lwcam_users.json, so a key stored there would
        # be copied in plaintext to every station. This file is per-machine.
        "aiReviewEnabled": "ai_review_enabled",
        "aiPreanalysisEnabled": "ai_preanalysis_enabled",
        "openrouterApiKey": "openrouter_api_key",
        "openrouterExtractModel": "openrouter_extract_model",
        "openrouterCompareModel": "openrouter_compare_model",
        # Upload phase. Same per-machine argument as the OpenRouter key: the S3
        # secret must never reach app_settings, which every capture PC copies.
        "uploadEnabled": "upload_enabled",
        "uploadS3Path": "upload_s3_path",
        "uploadS3Region": "upload_s3_region",
        "uploadS3AccessKey": "upload_s3_access_key",
        "uploadS3SecretKey": "upload_s3_secret_key",
        "uploadDoneRoot": "upload_done_dir",
        "uploadSummaryRoot": "upload_summary_dir",
    }
    result = {
        target: data[source]
        for source, target in mapping.items()
        if data.get(source) is not None
    }
    result.update(app_env="production", app_debug=False)
    local = os.environ.get("LOCALAPPDATA")
    if local:
        cache = Path(local) / "LWCam" / "QC"
        result.update(
            preview_cache_dir=str(cache / "previews"),
            qc_work_dir=str(cache / "qc_work"),
            qc_audit_dir=str(cache / "qc_audit"),
            ai_review_cache_dir=str(cache / "ai_review"),
        )
    return result

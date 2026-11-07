"""Per-page calibration, independent of capture/LWIP processes and settings."""
from pathlib import Path

from color_cal_tool.contract import CalibrationError, digest, profile_for
from app.services.lwip_baseline import _load_manifest
from app.services.qc_ops_store import read_qc_ops


def effective_profile(folder_path: Path | None, name: str, draft: dict | None = None) -> dict | None:
    if folder_path is None:
        return None
    if draft and (draft.get('status') in ('inserted', 'replaced') or draft.get('color_disabled')):
        return None
    entry = (read_qc_ops(folder_path).get('images') or {}).get(name) or {}
    if not (draft or {}).get('restored') and (entry.get('color_disabled') or entry.get('kept') in ('inserted', 'replaced')):
        return None
    manifest = _load_manifest(folder_path)
    if manifest is None:
        # A missing legacy manifest is ordinary; a corrupt present manifest
        # cannot safely be treated as a folder with no calibration.
        from app.core.paths import fs_path
        if fs_path(Path(folder_path) / '.deskew_crop_manifest.json').exists():
            raise CalibrationError('Unreadable image-processing manifest')
        return None
    return profile_for(manifest.get('source_identity'), name)


def profile_version(profile: dict | None) -> int:
    return int(digest(profile)[:8], 16) if profile else 0

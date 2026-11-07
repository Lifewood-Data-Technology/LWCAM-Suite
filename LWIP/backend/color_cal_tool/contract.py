"""Versioned, self-contained calibration data carried by capture folders.

Profiles are JSON strings keyed by SHA-256 of those exact UTF-8 bytes. This
avoids JSON number/canonicalisation differences between Dart and Python.
Absence is backwards compatible; malformed declared data is never absence.
"""
from __future__ import annotations

import hashlib
import json
from copy import deepcopy

from .profile import validate_profile


class CalibrationError(ValueError):
    pass


def digest(value) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'),
                                    ensure_ascii=False, allow_nan=False).encode()).hexdigest()


def validate_correction(profile: dict) -> None:
    try:
        if not isinstance(profile, dict):
            raise ValueError('profile is not an object')
        if profile.get('working_space') != 'linear_srgb_d65':
            raise ValueError('unsupported working space')
        validate_profile(dict(profile, schema_version=profile.get('schema_version', 1)))
    except (TypeError, ValueError, KeyError, IndexError) as exc:
        raise CalibrationError(f'Invalid colour calibration: {exc}') from exc


def block_of(identity: dict | None) -> dict | None:
    if not isinstance(identity, dict):
        return None
    if 'color_calibration' not in identity:
        return None
    block = identity['color_calibration']
    if not isinstance(block, dict) or type(block.get('version')) is not int or block.get('version') != 1:
        raise CalibrationError('Unsupported color_calibration version')
    profiles, images = block.get('profiles'), block.get('images')
    if not isinstance(profiles, dict) or not isinstance(images, dict):
        raise CalibrationError('Calibration profiles/images must be objects')
    for key, payload in profiles.items():
        if not isinstance(payload, str) or hashlib.sha256(payload.encode()).hexdigest() != key:
            raise CalibrationError('Calibration profile checksum mismatch')
        try:
            validate_correction(json.loads(payload))
        except ValueError as exc:
            raise CalibrationError(str(exc)) from exc
    for name, binding in images.items():
        if (not isinstance(name, str) or not name or name in ('.', '..')
                or any(c in name for c in '/\\:\x00')):
            raise CalibrationError('Calibration image names must be bare filenames')
        if not isinstance(binding, dict):
            raise CalibrationError(f'Missing calibration binding: {name}')
        ref = binding.get('profile')
        if ref is None:
            if binding.get('reason') not in ('disabled', 'skipped', 'historical', 'external'):
                raise CalibrationError(f'Unexplained uncalibrated image: {name}')
        elif not isinstance(ref, str) or ref not in profiles:
            raise CalibrationError(f'Missing profile for {name}')
    return block


def profile_for(identity: dict | None, name: str) -> dict | None:
    block = block_of(identity)
    if block is not None:
        binding = block['images'].get(name)
        if binding is None:
            raise CalibrationError(f'Missing calibration binding for {name}')
        ref = binding.get('profile')
        return json.loads(block['profiles'][ref]) if ref else None
    legacy = identity.get('color_profile') if isinstance(identity, dict) else None
    if legacy is None:
        return None
    if not isinstance(legacy, dict):
        raise CalibrationError('Invalid legacy colour profile')
    if legacy.get('calibrated_today') is not True:
        return None
    validate_correction(legacy)
    return legacy


def calibration_digest(identity: dict | None) -> str:
    block = block_of(identity)
    if block is not None:
        return digest(block)
    legacy = identity.get('color_profile') if isinstance(identity, dict) else None
    return digest(legacy) if legacy is not None else ''


def subset(identity: dict, names) -> dict:
    result = deepcopy(identity)
    block = block_of(result)
    if block is not None:
        block['images'] = {n: b for n, b in block['images'].items() if n in names}
        refs = {b.get('profile') for b in block['images'].values()}
        block['profiles'] = {k: v for k, v in block['profiles'].items() if k in refs}
    return result

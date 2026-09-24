from __future__ import annotations

import importlib.util
from functools import lru_cache
from pathlib import Path
from types import ModuleType


LUMINANCE_DIR = Path(__file__).resolve().parents[1] / "Luminance Correction"
LUMINANCE_MODULE_PATH = LUMINANCE_DIR / "luminance_process.py"
LUMINANCE_CONFIG_PATH = LUMINANCE_DIR / "config.txt"


@lru_cache(maxsize=1)
def luminance_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location("lwcam_luminance_process", LUMINANCE_MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load luminance module: {LUMINANCE_MODULE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@lru_cache(maxsize=1)
def luminance_config() -> dict[str, str]:
    module = luminance_module()
    return module.read_config(LUMINANCE_CONFIG_PATH)


def apply_luminance(path: Path) -> None:
    module = luminance_module()
    module.process_image(path, luminance_config())

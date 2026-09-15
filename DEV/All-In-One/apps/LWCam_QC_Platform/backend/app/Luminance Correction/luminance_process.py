from __future__ import annotations

import math
import os
import sys
import traceback
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path
from typing import Iterable

import numpy as np
from PIL import Image, ImageFilter, ImageOps

# This file doubles as a standalone script (Run_Luminance_Correction.bat runs
# it directly from this folder, with no `app` package on sys.path) and as a
# module the QC engine loads in-process by file path (app/services/luminance.py).
# Adding the backend root ourselves - rather than assuming it is already on
# sys.path - makes `import app.core.paths` work in both cases; it is a no-op
# when the engine has already put it there.
_BACKEND_ROOT = Path(__file__).resolve().parents[2]
if str(_BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(_BACKEND_ROOT))
from app.core.paths import fs_path  # noqa: E402


SUPPORTED_EXTENSIONS = {".jpg", ".jpeg", ".tif", ".tiff", ".png"}
TEMP_MARKER = ".luminance_tmp"

CURVE_PRESETS = {
    1: "0,0;48,60;96,118;128,150;192,214;255,255",
    2: "0,0;40,64;76,122;112,174;160,220;220,248;255,255",
    3: "0,0;32,74;64,130;96,184;140,230;205,250;255,255",
}

EVEN_EXPOSURE_STRENGTH = {
    1: 0.18,
    2: 0.32,
    3: 0.44,
}

PROFILE_FIELDS = (
    "min_p72",
    "target_p72",
    "max_p72",
    "max_p95",
    "saturation",
    "red_green",
    "blue_green",
)


def read_config(config_path: Path) -> dict[str, str]:
    config: dict[str, str] = {}
    if not fs_path(config_path).exists():
        return config

    for raw_line in fs_path(config_path).read_text(encoding="utf-8").splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        config[key.strip().lower()] = value.strip()
    return config


def as_bool(value: str | None, default: bool) -> bool:
    if value is None or value == "":
        return default
    return value.strip().lower() in {"1", "true", "yes", "y", "on"}


def as_int(value: str | None, default: int, minimum: int, maximum: int) -> int:
    try:
        parsed = int(str(value).strip())
    except (TypeError, ValueError):
        return default
    return max(minimum, min(maximum, parsed))


def as_float(value: str | None, default: float, minimum: float, maximum: float) -> float:
    try:
        parsed = float(str(value).strip())
    except (TypeError, ValueError):
        return default
    return max(minimum, min(maximum, parsed))


def analysis_size(width: int, height: int, max_dimension: int) -> tuple[int, int]:
    if max_dimension <= 0 or max(width, height) <= max_dimension:
        return width, height

    scale = max_dimension / float(max(width, height))
    return max(1, int(round(width * scale))), max(1, int(round(height * scale)))


def resize_float_plane(values: np.ndarray, size: tuple[int, int], resample=Image.Resampling.BILINEAR) -> np.ndarray:
    image = Image.fromarray(values.astype(np.float32), mode="F")
    return np.asarray(image.resize(size, resample=resample), dtype=np.float32)


def correction_scale_map(original_rgb: np.ndarray, corrected_rgb: np.ndarray) -> np.ndarray:
    original_y = luminance(original_rgb)
    corrected_y = luminance(corrected_rgb)
    return np.clip((corrected_y + 1.0) / (original_y + 1.0), 0.35, 2.5)


def parse_curve_points(value: str) -> list[tuple[int, int]]:
    points: list[tuple[int, int]] = []
    for point in value.split(";"):
        point = point.strip()
        if not point:
            continue
        left, right = point.split(",", 1)
        x = max(0, min(255, int(left.strip())))
        y = max(0, min(255, int(right.strip())))
        points.append((x, y))

    if not points:
        raise ValueError("curve has no points")

    points = sorted(set(points))
    if points[0][0] != 0:
        points.insert(0, (0, 0))
    if points[-1][0] != 255:
        points.append((255, 255))
    return points


def build_curve_lut(points: list[tuple[int, int]]) -> np.ndarray:
    xs = np.array([x for x, _ in points], dtype=np.float32)
    ys = np.array([y for _, y in points], dtype=np.float32)
    lut = np.interp(np.arange(256, dtype=np.float32), xs, ys)
    return np.clip(np.rint(lut), 0, 255).astype(np.uint8)


def luminance(rgb: np.ndarray) -> np.ndarray:
    return (
        rgb[..., 0] * 0.299
        + rgb[..., 1] * 0.587
        + rgb[..., 2] * 0.114
    ).astype(np.float32)


def rescale_luminance(rgb: np.ndarray, old_y: np.ndarray, new_y: np.ndarray) -> np.ndarray:
    scale = (new_y + 1.0) / (old_y + 1.0)
    return np.clip(rgb.astype(np.float32) * scale[..., None], 0, 255)


def measured_document_luminance(y: np.ndarray, mask: np.ndarray, percentile: float) -> float | None:
    doc_pixels = mask > 0.35
    if int(doc_pixels.sum()) < 100:
        return None

    return float(np.percentile(y[doc_pixels], percentile))


def document_statistics(rgb: np.ndarray, mask: np.ndarray) -> dict[str, float] | None:
    doc_pixels = mask > 0.35
    if int(doc_pixels.sum()) < 100:
        return None

    y = luminance(rgb)
    y_doc = y[doc_pixels]
    rgb_doc = rgb[doc_pixels]
    channel_max = rgb_doc.max(axis=1)
    channel_min = rgb_doc.min(axis=1)
    channel_means = rgb_doc.mean(axis=0)

    return {
        "p72": float(np.percentile(y_doc, 72)),
        "p85": float(np.percentile(y_doc, 85)),
        "p95": float(np.percentile(y_doc, 95)),
        "saturation": float(np.mean((channel_max - channel_min) / (channel_max + 1.0))),
        "red_green": float(channel_means[0] - channel_means[1]),
        "blue_green": float(channel_means[2] - channel_means[1]),
    }


def parse_reference_profiles(config: dict[str, str]) -> list[dict[str, float | str]]:
    profiles: list[dict[str, float | str]] = []
    for key, value in sorted(config.items()):
        if not key.startswith("reference_profile_") or not value.strip():
            continue

        parts = [part.strip() for part in value.split(",")]
        if len(parts) != len(PROFILE_FIELDS):
            raise ValueError(
                f"{key} must contain {len(PROFILE_FIELDS)} comma-separated values: "
                "min_p72,target_p72,max_p72,max_p95,saturation,red_green,blue_green"
            )

        profile: dict[str, float | str] = {"name": key.removeprefix("reference_profile_")}
        for field, part in zip(PROFILE_FIELDS, parts):
            profile[field] = float(part)
        profiles.append(profile)

    return profiles


def reference_profile_score(stats: dict[str, float], profile: dict[str, float | str]) -> float:
    saturation_score = abs(stats["saturation"] - float(profile["saturation"])) / 0.08
    red_green_score = abs(stats["red_green"] - float(profile["red_green"])) / 15.0
    blue_green_score = abs(stats["blue_green"] - float(profile["blue_green"])) / 20.0

    if float(profile["min_p72"]) <= stats["p72"] <= float(profile["max_p72"]):
        luminance_score = 0.0
    else:
        target_distance = abs(stats["p72"] - float(profile["target_p72"]))
        luminance_score = min(target_distance, 35.0) / 35.0

    return saturation_score + red_green_score + blue_green_score + (luminance_score * 0.5)


def choose_reference_profile(
    stats: dict[str, float],
    profiles: list[dict[str, float | str]],
    max_score: float,
) -> dict[str, float | str] | None:
    if not profiles:
        return None

    best = min(profiles, key=lambda profile: reference_profile_score(stats, profile))
    if reference_profile_score(stats, best) > max_score:
        return None

    return best


def document_mask(rgb: np.ndarray, protect_black_background: bool) -> np.ndarray:
    height, width = rgb.shape[:2]
    if not protect_black_background:
        return np.ones((height, width), dtype=np.float32)

    y = luminance(rgb)
    raw = (y > 24).astype(np.uint8) * 255
    mask_img = Image.fromarray(raw, mode="L")

    # Keep expansion modest. The goal is to catch paper edge transitions without
    # letting the document mask spill deeply into a black photographed border.
    for _ in range(2):
        mask_img = mask_img.filter(ImageFilter.MaxFilter(5))
    mask_img = mask_img.filter(ImageFilter.GaussianBlur(radius=max(2, min(width, height) // 240)))

    mask = np.asarray(mask_img, dtype=np.float32) / 255.0
    near_black_gate = np.clip((y - 18.0) / 18.0, 0.0, 1.0)
    return mask * near_black_gate


def apply_curve(rgb: np.ndarray, lut: np.ndarray) -> np.ndarray:
    old_y = luminance(rgb)
    new_y = lut[np.clip(np.rint(old_y), 0, 255).astype(np.uint8)].astype(np.float32)
    return rescale_luminance(rgb, old_y, new_y)


def apply_even_exposure(
    rgb: np.ndarray,
    mask: np.ndarray,
    brightness_level: int,
    center_shadow_fix: bool,
) -> np.ndarray:
    doc_pixels = mask > 0.35
    if int(doc_pixels.sum()) < 100:
        return rgb

    y = luminance(rgb)
    target = float(np.percentile(y[doc_pixels], 72))
    fill = float(np.median(y[doc_pixels]))
    filled_y = y * mask + fill * (1.0 - mask)

    height, width = y.shape
    radius = max(24, min(120, min(width, height) // 18))
    local = Image.fromarray(np.clip(filled_y, 0, 255).astype(np.uint8), mode="L")
    local = local.filter(ImageFilter.GaussianBlur(radius=radius))
    local_y = np.asarray(local, dtype=np.float32)

    strength = EVEN_EXPOSURE_STRENGTH.get(brightness_level, EVEN_EXPOSURE_STRENGTH[2])
    if center_shadow_fix:
        center = y[height // 4 : height * 3 // 4, width // 4 : width * 3 // 4]
        center_mask = doc_pixels[height // 4 : height * 3 // 4, width // 4 : width * 3 // 4]
        if int(center_mask.sum()) > 100:
            center_mean = float(center[center_mask].mean())
            doc_mean = float(y[doc_pixels].mean())
            if center_mean + 10.0 < doc_mean:
                strength = min(0.62, strength * 1.35)

    correction = np.clip(target / (local_y + 1.0), 0.82, 1.42)
    balanced_y = y * (1.0 + strength * (correction - 1.0))
    balanced_y = np.maximum(balanced_y, y * 0.94)
    return rescale_luminance(rgb, y, np.clip(balanced_y, 0, 255))


def match_target_luminance(
    rgb: np.ndarray,
    mask: np.ndarray,
    target_luminance: float,
    tolerance: float,
    percentile: float,
    min_scale: float,
    max_scale: float,
) -> np.ndarray:
    y = luminance(rgb)
    current = measured_document_luminance(y, mask, percentile)
    if current is None or current <= 0:
        return rgb

    delta = target_luminance - current
    if abs(delta) <= tolerance:
        return rgb

    scale = np.clip(target_luminance / current, min_scale, max_scale)
    target_y = np.clip(y * scale, 0, 255)
    adjusted = rescale_luminance(rgb, y, target_y)

    # Blend stronger adjustments slightly so text and color do not get crushed.
    strength = np.clip(abs(delta) / max(tolerance * 4.0, 1.0), 0.35, 1.0)
    return rgb * (1.0 - strength) + adjusted * strength


def match_profile_luminance(
    rgb: np.ndarray,
    mask: np.ndarray,
    profile: dict[str, float | str],
    tolerance: float,
    highlight_tolerance: float,
    min_scale: float,
    max_scale: float,
    max_iterations: int,
    warm_document_max_p72: float,
    warm_saturation_threshold: float,
    warm_red_green_threshold: float,
) -> np.ndarray:
    corrected = rgb
    iterations = max(1, max_iterations)

    for _ in range(iterations):
        stats = document_statistics(corrected, mask)
        if stats is None or stats["p72"] <= 0:
            return corrected

        min_p72 = float(profile["min_p72"])
        target_p72 = float(profile["target_p72"])
        max_p72 = float(profile["max_p72"])
        max_p95 = float(profile["max_p95"]) + highlight_tolerance

        is_warm_document = (
            stats["saturation"] >= warm_saturation_threshold
            and stats["red_green"] >= warm_red_green_threshold
            and stats["blue_green"] < 0
        )
        if is_warm_document:
            max_p72 = min(max_p72, warm_document_max_p72)
            target_p72 = min(target_p72, max_p72)

        current_p72 = stats["p72"]
        current_p95 = stats["p95"]

        if min_p72 <= current_p72 <= max_p72 and current_p95 <= max_p95:
            return corrected

        if current_p95 > max_p95:
            desired_p72 = min(target_p72, current_p72 * (max_p95 / current_p95))
        elif current_p72 < min_p72:
            desired_p72 = target_p72
        elif current_p72 > max_p72:
            desired_p72 = target_p72
        else:
            return corrected

        scale = np.clip(desired_p72 / current_p72, min_scale, max_scale)
        y = luminance(corrected)
        adjusted = rescale_luminance(corrected, y, np.clip(y * scale, 0, 255))
        delta = abs(desired_p72 - current_p72)
        if current_p95 > max_p95:
            delta = max(delta, current_p95 - max_p95)
        strength = np.clip(delta / max(tolerance * 5.0, 1.0), 0.30, 0.90)
        corrected = corrected * (1.0 - strength) + adjusted * strength

    return corrected


def output_save_kwargs(path: Path, image: Image.Image, config: dict[str, str]) -> dict:
    ext = path.suffix.lower()
    kwargs: dict = {}

    if "exif" in image.info:
        kwargs["exif"] = image.info["exif"]
    if "icc_profile" in image.info:
        kwargs["icc_profile"] = image.info["icc_profile"]

    if ext in {".jpg", ".jpeg"}:
        kwargs["quality"] = as_int(config.get("jpeg_quality"), 100, 1, 100)
        kwargs["subsampling"] = 0
        kwargs["optimize"] = True
    elif ext == ".png":
        kwargs["compress_level"] = 6
    elif ext in {".tif", ".tiff"}:
        compression = image.info.get("compression")
        if compression:
            kwargs["compression"] = compression

    return kwargs


def temp_path_for(path: Path) -> Path:
    return path.with_name(f".{path.stem}{TEMP_MARKER}.{os.getpid()}{path.suffix}")


def is_temp_file(path: Path) -> bool:
    name = path.name.lower()
    if TEMP_MARKER in name:
        return True
    return (
        path.name.startswith(".")
        and ".tmp." in name
        and path.suffix.lower() in SUPPORTED_EXTENSIONS
    )


def cleanup_temp_files(folder: Path) -> int:
    removed = 0
    for path in fs_path(folder).iterdir():
        if not path.is_file() or not is_temp_file(path):
            continue
        try:
            path.unlink()
            removed += 1
        except OSError as exc:
            print(f"WARNING: Could not remove temp file {path.name}: {exc}")
    return removed


def process_image(path: Path, config: dict[str, str]) -> tuple[Path, str]:
    brightness_level = as_int(config.get("brightness_level"), 2, 1, 3)
    curve_text = config.get("custom_curve_points") or CURVE_PRESETS[brightness_level]
    lut = build_curve_lut(parse_curve_points(curve_text))

    analysis_max_dimension = as_int(config.get("analysis_max_dimension"), 2200, 0, 20000)
    target_luminance = as_float(config.get("target_luminance"), 178.27, 1.0, 255.0)
    luminance_tolerance = as_float(config.get("luminance_tolerance"), 5.0, 0.0, 50.0)
    luminance_percentile = as_float(config.get("luminance_percentile"), 72.0, 1.0, 99.0)
    min_luminance_scale = as_float(config.get("min_luminance_scale"), 0.65, 0.1, 1.0)
    max_luminance_scale = as_float(config.get("max_luminance_scale"), 1.8, 1.0, 4.0)
    highlight_tolerance = as_float(config.get("highlight_tolerance"), 6.0, 0.0, 50.0)
    profile_match_threshold = as_float(config.get("profile_match_threshold"), 5.0, 0.5, 20.0)
    profile_correction_passes = as_int(config.get("profile_correction_passes"), 3, 1, 6)
    warm_document_max_p72 = as_float(config.get("warm_document_max_p72"), 135.0, 50.0, 220.0)
    warm_saturation_threshold = as_float(config.get("warm_saturation_threshold"), 0.30, 0.0, 1.0)
    warm_red_green_threshold = as_float(config.get("warm_red_green_threshold"), 18.0, -50.0, 80.0)
    reference_profiles = parse_reference_profiles(config)
    even_exposure = as_bool(config.get("even_exposure"), True)
    center_shadow_fix = as_bool(config.get("center_shadow_fix"), True)
    protect_black_background = as_bool(config.get("protect_black_background"), True)

    with Image.open(fs_path(path)) as original:
        source = ImageOps.exif_transpose(original)
        has_alpha = source.mode in {"RGBA", "LA"} or (
            source.mode == "P" and "transparency" in source.info
        )

        if has_alpha:
            rgba = source.convert("RGBA")
            alpha = rgba.getchannel("A")
            rgb_image = rgba.convert("RGB")
        else:
            alpha = None
            rgb_image = source.convert("RGB")

        rgb = np.asarray(rgb_image, dtype=np.float32)
        full_width, full_height = rgb_image.size
        analysis_width, analysis_height = analysis_size(full_width, full_height, analysis_max_dimension)
        if (analysis_width, analysis_height) == (full_width, full_height):
            analysis_rgb = rgb
        else:
            analysis_image = rgb_image.resize((analysis_width, analysis_height), Image.Resampling.BILINEAR)
            analysis_rgb = np.asarray(analysis_image, dtype=np.float32)

        analysis_mask = document_mask(analysis_rgb, protect_black_background)
        stats = document_statistics(analysis_rgb, analysis_mask)
        profile = (
            choose_reference_profile(stats, reference_profiles, profile_match_threshold)
            if stats
            else None
        )

        if profile:
            matched = match_profile_luminance(
                analysis_rgb,
                analysis_mask,
                profile,
                luminance_tolerance,
                highlight_tolerance,
                min_luminance_scale,
                max_luminance_scale,
                profile_correction_passes,
                warm_document_max_p72,
                warm_saturation_threshold,
                warm_red_green_threshold,
            )
            target_after_match = float(profile["target_p72"])
            use_curve_fallback = False
        else:
            matched = match_target_luminance(
                analysis_rgb,
                analysis_mask,
                target_luminance,
                luminance_tolerance,
                luminance_percentile,
                min_luminance_scale,
                max_luminance_scale,
            )
            target_after_match = target_luminance
            use_curve_fallback = True

        matched_y = luminance(matched)
        matched_value = measured_document_luminance(matched_y, analysis_mask, luminance_percentile)

        if (
            use_curve_fallback
            and matched_value is not None
            and matched_value + luminance_tolerance < target_after_match
        ):
            curved = apply_curve(matched, lut)
        else:
            curved = matched

        should_even_exposure = even_exposure
        if stats is not None and stats["p72"] > target_after_match:
            should_even_exposure = False

        corrected = (
            apply_even_exposure(curved, analysis_mask, brightness_level, center_shadow_fix)
            if should_even_exposure
            else curved
        )

        if corrected.shape[:2] == rgb.shape[:2]:
            scale_map = correction_scale_map(analysis_rgb, corrected)
            full_mask = analysis_mask
        else:
            scale_map = resize_float_plane(
                correction_scale_map(analysis_rgb, corrected),
                (full_width, full_height),
            )
            full_mask = resize_float_plane(analysis_mask, (full_width, full_height))

        corrected_full = np.clip(rgb * scale_map[..., None], 0, 255)
        full_mask = np.clip(full_mask, 0.0, 1.0)
        blended = np.clip(rgb * (1.0 - full_mask[..., None]) + corrected_full * full_mask[..., None], 0, 255)
        out = Image.fromarray(np.rint(blended).astype(np.uint8), mode="RGB")
        if alpha is not None:
            out.putalpha(alpha)

        if path.suffix.lower() in {".jpg", ".jpeg"} and out.mode == "RGBA":
            out = out.convert("RGB")

        save_kwargs = output_save_kwargs(path, source, config)

    temp_path = temp_path_for(path)
    try:
        out.save(fs_path(temp_path), **save_kwargs)
        os.replace(fs_path(temp_path), fs_path(path))
    finally:
        if fs_path(temp_path).exists():
            fs_path(temp_path).unlink()

    return path, "ok"


def iter_images(folder: Path) -> Iterable[Path]:
    for path in sorted(fs_path(folder).iterdir()):
        if path.is_file() and path.suffix.lower() in SUPPORTED_EXTENSIONS:
            if is_temp_file(path):
                continue
            yield path


def worker(args: tuple[str, dict[str, str]]) -> tuple[str, bool, str]:
    path_text, config = args
    path = Path(path_text)
    try:
        process_image(path, config)
        return str(path), True, "processed"
    except Exception:
        return str(path), False, traceback.format_exc().rstrip()


def choose_folder(default_folder: Path) -> Path:
    print("Paste the image folder path, then press Enter.")
    print(f"Press Enter without a path to use: {default_folder}")
    folder_text = input("> ").strip().strip('"')
    folder = Path(folder_text) if folder_text else default_folder
    return folder.expanduser().resolve()


def main() -> int:
    script_dir = Path(__file__).resolve().parent
    config = read_config(script_dir / "config.txt")
    folder = choose_folder(script_dir)

    if not fs_path(folder).exists() or not fs_path(folder).is_dir():
        print(f"ERROR: Folder does not exist: {folder}")
        return 1

    removed = cleanup_temp_files(folder)
    if removed:
        print(f"Removed {removed} leftover temp file(s).")

    files = list(iter_images(folder))
    if not files:
        print(f"No supported images found in: {folder}")
        return 0

    usage = as_float(config.get("processor_usage"), 0.5, 0.1, 1.0)
    workers = max(1, min(len(files), math.floor((os.cpu_count() or 1) * usage)))

    print(f"Processing {len(files)} image(s) in: {folder}")
    print(f"Using {workers} worker(s). Originals will be replaced after successful saves.")

    ok_count = 0
    fail_count = 0

    if workers == 1:
        results = [worker((str(path), config)) for path in files]
    else:
        try:
            results = []
            with ProcessPoolExecutor(max_workers=workers) as executor:
                future_map = {executor.submit(worker, (str(path), config)): path for path in files}
                for future in as_completed(future_map):
                    results.append(future.result())
        except OSError as exc:
            print(f"Parallel processing unavailable ({exc}). Running one image at a time.")
            results = [worker((str(path), config)) for path in files]

    for path_text, ok, message in sorted(results, key=lambda item: item[0].lower()):
        if ok:
            ok_count += 1
            print(f"OK: {Path(path_text).name}")
        else:
            fail_count += 1
            print(f"ERROR: {Path(path_text).name}")
            print(message)
            print()

    removed = cleanup_temp_files(folder)
    if removed:
        print(f"Removed {removed} temp file(s) after processing.")

    print(f"Done. Processed: {ok_count}. Failed: {fail_count}.")
    return 0 if fail_count == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())

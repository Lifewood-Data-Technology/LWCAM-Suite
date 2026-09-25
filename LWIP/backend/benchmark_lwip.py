"""Create a repeatable on-disk LWIP throughput fixture and process it.

The fixture contains 100 folders with 2--100 JPEGs each. It is deliberately
large enough to exercise the shared scheduler, but smaller than a production
day so it can run on a development workstation.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import time
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

from deskew_crop_tool.config import DEFAULT_CROP_PADDING, ToolConfig
from deskew_crop_tool.orchestrator import FolderOrchestrator, configure_logging


FOLDER_COUNTS = [2] * 15 + [3] * 15 + [10] * 40 + [25] * 4 + [50] * 20 + [100] * 6
COMPACT_FOLDER_COUNTS = [2] * 15 + [3] * 15 + [5] * 40 + [15] * 4 + [15] * 20 + [100] * 6
TARGET_BYTES = 14_000_000


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--workers", type=int, default=0, help="0 = CPU count minus one")
    parser.add_argument(
        "--source-root",
        type=Path,
        help="Use direct child-folder images as representative capture sources",
    )
    parser.add_argument(
        "--compact",
        action="store_true",
        help="Use the 1,235-image profile for large real capture files",
    )
    args = parser.parse_args()

    root = args.root.resolve()
    if root.exists():
        raise SystemExit(f"Benchmark root already exists: {root}")
    workers = args.workers or max(1, (os.cpu_count() or 2) - 1)
    input_root = root / "incoming"
    output_root = root / "output"
    work_root = root / "work"

    root.mkdir(parents=True)
    folder_counts = COMPACT_FOLDER_COUNTS if args.compact else FOLDER_COUNTS
    if args.source_root:
        sources = _source_images(args.source_root.resolve())
        if not sources:
            raise SystemExit(f"No source images found in: {args.source_root}")
        _make_fixture(input_root, sources, folder_counts)
    else:
        seed = root / "seed.jpg"
        _make_seed_image(seed)
        _make_fixture(input_root, [seed], folder_counts)
    input_bytes = _total_bytes(input_root)

    config = ToolConfig(
        input_root=input_root,
        output_root=output_root,
        work_root=work_root,
        state_file=root / "state.json",
        log_file=root / "lwip.log",
        workers=workers,
        poll_interval_seconds=1,
        stable_seconds=0,
        minimum_file_age_seconds=0,
        presence_check_interval_seconds=0,
        checksum_check_interval_seconds=0,
        crop_padding=DEFAULT_CROP_PADDING,
        jpeg_quality=95,
        completion_marker="ready.json",
        recursive=True,
        extensions=(".jpg",),
        folder_depth=1,
        thumbnail_width=0,
        thumbnail_quality=85,
        thumbnail_dirname="thumbs",
    )
    configure_logging(config)
    started = time.perf_counter()
    completed = FolderOrchestrator(config).run_once()
    elapsed = time.perf_counter() - started
    report = {
        "folders": len(folder_counts),
        "images": sum(folder_counts),
        "workers": workers,
        "source_images": len(sources) if args.source_root else 1,
        "input_bytes": input_bytes,
        "output_bytes": _total_bytes(output_root),
        "completed_folders": completed,
        "elapsed_seconds": round(elapsed, 3),
        "images_per_second": round(sum(FOLDER_COUNTS) / elapsed, 3),
    }
    (root / "result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


def _make_seed_image(path: Path) -> None:
    # A noisy 12 MP image gives deskew/crop realistic pixel work. Trailing
    # bytes make every source file a consistent 14 MB without changing JPEG
    # decoding, then both PIL and OpenCV validate that assumption below.
    pixels = np.random.default_rng(20260801).integers(
        0, 256, size=(3000, 4000, 3), dtype=np.uint8
    )
    if not cv2.imwrite(str(path), pixels, [cv2.IMWRITE_JPEG_QUALITY, 95]):
        raise OSError(f"Could not create fixture image: {path}")
    if path.stat().st_size < TARGET_BYTES:
        with path.open("ab") as stream:
            stream.truncate(TARGET_BYTES)
    with Image.open(path) as image:
        image.verify()
    if cv2.imread(str(path)) is None:
        raise OSError(f"Fixture image is not readable by OpenCV: {path}")


def _source_images(root: Path) -> list[Path]:
    extensions = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp"}
    return sorted(
        (
            path
            for entry in root.iterdir()
            for path in (
                [entry]
                if entry.is_file()
                else entry.iterdir()
                if entry.is_dir() and not entry.name.startswith(".")
                else []
            )
            if path.is_file() and path.suffix.lower() in extensions
        ),
        key=lambda path: path.as_posix().lower(),
    )


def _make_fixture(input_root: Path, sources: list[Path], folder_counts: list[int]) -> None:
    source_index = 0
    for folder_index, image_count in enumerate(folder_counts, start=1):
        folder = input_root / f"box-{folder_index:03d}"
        folder.mkdir(parents=True)
        for image_index in range(1, image_count + 1):
            source = sources[source_index % len(sources)]
            source_index += 1
            shutil.copyfile(source, folder / f"image-{image_index:03d}{source.suffix}")
        (folder / "ready.json").write_text("{}\n", encoding="utf-8")


def _total_bytes(root: Path) -> int:
    return sum(path.stat().st_size for path in root.glob("**/*") if path.is_file())


if __name__ == "__main__":
    main()

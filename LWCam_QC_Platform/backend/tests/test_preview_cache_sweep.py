"""The preview cache never shrinks on its own (`previews.py` writes one JPEG
per render and never removes anything), so a long-running station's cache
grows without bound. `sweep_preview_cache` is the cap: evict oldest-by-mtime
until the cache is comfortably under `settings.preview_cache_max_mb`.

mtime, not atime: the cache key is `sha256(source path | size | mtime_ns |
pending-ops chain)` (`previews.preview_cache_path`), so an entry is written
once and never touched again - its mtime IS its birth time - and NTFS does
not update atime by default on the platform this ships to, so atime could
not be trusted even if it mattered.

unittest.TestCase, like the rest of this tree, calling `sweep_preview_cache`
directly - no conftest, no TestClient. Mtimes are set explicitly with
`os.utime` so age is deterministic rather than racing the test's own clock.
"""

from __future__ import annotations

import os
import time
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from app.core.config import settings
from app.services import previews


def _write_cache_file(folder: Path, name: str, size: int, age_seconds: float) -> Path:
    path = folder / name
    path.write_bytes(b"\0" * size)
    when = time.time() - age_seconds
    os.utime(path, (when, when))
    return path


class SweepPreviewCacheTests(unittest.TestCase):
    def _sweep(self, cache_dir: Path, max_mb: float) -> None:
        with patch.object(settings, "preview_cache_dir", str(cache_dir)), patch.object(
            settings, "preview_cache_max_mb", max_mb
        ):
            previews.sweep_preview_cache()

    def test_over_cap_evicts_oldest_first_and_ends_under_the_target(self) -> None:
        with TemporaryDirectory() as temp:
            cache_dir = Path(temp) / "cache"
            cache_dir.mkdir()
            one_mb = 1024 * 1024
            # Five 1MB entries, oldest to newest, well past the recent-file
            # guard so age alone decides eviction order.
            for i in range(5):
                _write_cache_file(
                    cache_dir, f"{i}.jpg", one_mb, age_seconds=3600 + (5 - i) * 60
                )

            # Cap of 3MB -> target is 80% of that = ~2.4MB, so the sweep must
            # bring 5MB down to 2MB (the two newest survive) rather than
            # stopping the instant it dips under 3MB.
            self._sweep(cache_dir, max_mb=3)

            remaining = sorted(p.name for p in cache_dir.iterdir())
            self.assertEqual(remaining, ["3.jpg", "4.jpg"])
            total = sum(p.stat().st_size for p in cache_dir.iterdir())
            self.assertLessEqual(total, int(3 * one_mb * previews.PREVIEW_CACHE_SWEEP_TARGET_RATIO))

    def test_under_cap_is_left_untouched(self) -> None:
        with TemporaryDirectory() as temp:
            cache_dir = Path(temp) / "cache"
            cache_dir.mkdir()
            one_mb = 1024 * 1024
            for i in range(3):
                _write_cache_file(cache_dir, f"{i}.jpg", one_mb, age_seconds=3600)

            self._sweep(cache_dir, max_mb=100)

            remaining = sorted(p.name for p in cache_dir.iterdir())
            self.assertEqual(remaining, ["0.jpg", "1.jpg", "2.jpg"])

    def test_a_very_recent_entry_survives_even_when_over_cap(self) -> None:
        with TemporaryDirectory() as temp:
            cache_dir = Path(temp) / "cache"
            cache_dir.mkdir()
            one_mb = 1024 * 1024
            _write_cache_file(cache_dir, "old.jpg", one_mb, age_seconds=3600)
            # Just rendered - inside PREVIEW_CACHE_MIN_AGE_SECONDS - and must
            # not be removable regardless of how far over the cap this puts
            # the cache. This is the same file a concurrent request may be
            # about to serve (see render_lock's own comment on why a
            # half-open file on Windows is worse than a delayed sweep).
            _write_cache_file(cache_dir, "fresh.jpg", one_mb, age_seconds=1)

            self._sweep(cache_dir, max_mb=1)

            remaining = sorted(p.name for p in cache_dir.iterdir())
            self.assertEqual(remaining, ["fresh.jpg"])

    def test_a_subdirectory_and_a_file_that_vanishes_mid_sweep_do_not_raise(self) -> None:
        with TemporaryDirectory() as temp:
            cache_dir = Path(temp) / "cache"
            cache_dir.mkdir()
            one_mb = 1024 * 1024
            (cache_dir / "not_a_cache_entry").mkdir()
            _write_cache_file(cache_dir, "old.jpg", one_mb, age_seconds=3600)
            vanishing = _write_cache_file(cache_dir, "vanishing.jpg", one_mb, age_seconds=7200)

            real_remove = os.remove

            def _remove_and_vanish(path, *, _target=str(vanishing)):
                if str(path) == _target:
                    real_remove(path)
                    # Simulate a second remover already having taken it -
                    # the sweep's own os.remove must tolerate this too.
                    raise FileNotFoundError(path)
                return real_remove(path)

            with patch("os.remove", side_effect=_remove_and_vanish):
                try:
                    self._sweep(cache_dir, max_mb=0.001)
                except Exception as error:  # noqa: BLE001 - the assertion IS "never raises"
                    self.fail(f"sweep_preview_cache raised: {error!r}")

            # The directory entry is harmless and left alone; the sweep does
            # not crash trying to remove it as if it were a file.
            self.assertTrue((cache_dir / "not_a_cache_entry").is_dir())


if __name__ == "__main__":
    unittest.main()

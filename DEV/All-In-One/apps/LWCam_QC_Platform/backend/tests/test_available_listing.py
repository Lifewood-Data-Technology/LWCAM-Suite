"""One directory listing per folder, instead of one stat per image.

Ported from a hotfix applied to station QC-STATION on 2026-09-09, where Quality
Check could not open at all: the images live on \\\\CAPTURE-PC\\2.Batches over a
Tailscale tunnel, every filesystem call is a 23-65 ms SMB round trip, and
to_task_vo made three of them per image. 11 folders / 1,184 images cost 78
seconds of I/O and the client timed out first. The banner blamed the engine,
which was healthy.

The optimisation is only safe if it is verdict-for-verdict identical to the
per-image check it replaces, so that equivalence is what these tests pin - the
same comparison run on the live queue there (1,184 verdicts, 0 mismatches).
"""

from __future__ import annotations

import os
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from app.models.capture import CaptureFolder, CaptureImage
from app.routers.qc import (
    available_image_names,
    image_available,
    image_available_in,
)


def _folder(path: str | None) -> CaptureFolder:
    return CaptureFolder(folder_path=path, thumbnail_path=None)


def _image(name: str) -> CaptureImage:
    return CaptureImage(image_name=name)


class VerdictEquivalenceTests(unittest.TestCase):
    """The listing must agree with the per-image check on every input."""

    def _both(self, folder: CaptureFolder, image: CaptureImage) -> tuple[bool, bool]:
        old = image_available(folder, image)
        new = image_available_in(available_image_names(folder), image)
        return old, new

    def test_a_present_file_is_available_both_ways(self) -> None:
        with TemporaryDirectory() as temporary:
            (Path(temporary) / "page.jpg").write_bytes(b"x")
            old, new = self._both(_folder(temporary), _image("page.jpg"))
            self.assertEqual((old, new), (True, True))

    def test_a_missing_file_is_unavailable_both_ways(self) -> None:
        with TemporaryDirectory() as temporary:
            old, new = self._both(_folder(temporary), _image("absent.jpg"))
            self.assertEqual((old, new), (False, False))

    def test_an_unconfigured_directory_is_unavailable_both_ways(self) -> None:
        old, new = self._both(_folder(None), _image("page.jpg"))
        self.assertEqual((old, new), (False, False))
        self.assertIsNone(available_image_names(_folder(None)))

    def test_a_missing_directory_is_unavailable_both_ways(self) -> None:
        with TemporaryDirectory() as temporary:
            gone = os.path.join(temporary, "not-there")
            old, new = self._both(_folder(gone), _image("page.jpg"))
            self.assertEqual((old, new), (False, False))
            self.assertIsNone(available_image_names(_folder(gone)))

    def test_a_subdirectory_is_not_a_file(self) -> None:
        with TemporaryDirectory() as temporary:
            os.mkdir(os.path.join(temporary, "thumbs"))
            old, new = self._both(_folder(temporary), _image("thumbs"))
            self.assertEqual((old, new), (False, False))

    def test_traversal_is_refused_both_ways(self) -> None:
        # safe_filename still runs, so the guard is unchanged.
        with TemporaryDirectory() as temporary:
            for attempt in ("../page.jpg", "..\\page.jpg", "", ".", ".."):
                with self.subTest(attempt=attempt):
                    old, new = self._both(_folder(temporary), _image(attempt))
                    self.assertEqual((old, new), (False, False))

    def test_case_matching_follows_the_platform(self) -> None:
        with TemporaryDirectory() as temporary:
            (Path(temporary) / "PAGE.JPG").write_bytes(b"x")
            old, new = self._both(_folder(temporary), _image("page.jpg"))
            # Whatever the platform does, both paths must agree - that is the
            # point of normcase rather than a blanket .lower().
            self.assertEqual(old, new)
            if os.name == "nt":
                self.assertTrue(new)


class OneListingPerFolderTests(unittest.TestCase):
    def test_the_directory_is_listed_once_for_many_images(self) -> None:
        """The whole reason for the change: round trips, not bytes."""
        with TemporaryDirectory() as temporary:
            names = ["page%03d.jpg" % i for i in range(50)]
            for name in names:
                (Path(temporary) / name).write_bytes(b"x")
            folder = _folder(temporary)

            real_scandir = os.scandir
            calls = []

            def counting_scandir(path):
                calls.append(path)
                return real_scandir(path)

            with patch("app.routers.qc.os.scandir", counting_scandir):
                on_disk = available_image_names(folder)
                verdicts = [image_available_in(on_disk, _image(n)) for n in names]

            self.assertEqual(len(calls), 1, "one listing, however many images")
            self.assertTrue(all(verdicts))

    def test_none_is_treated_as_nothing_available(self) -> None:
        self.assertFalse(image_available_in(None, _image("page.jpg")))
        self.assertFalse(image_available_in(set(), _image("page.jpg")))


if __name__ == "__main__":
    unittest.main()

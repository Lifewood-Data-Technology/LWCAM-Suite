"""Windows long-path handling (`app/core/paths.fs_path` / `display_path`).

The engine's own paths are LONGER than LWIP's (output root is
`<input>_processed`, plus `\\thumbs`), and LWIP already needed this fix for
paths that exceed Windows' 260-char MAX_PATH under LongPathsEnabled=off (see
LWIP/backend/deskew_crop_tool/image_ops.py's `fs_path`, which this is ported
from). Without it, `os.scandir`/`Image.open`/`shutil.*` fail with a bare
OSError and QC shows "Images missing" with nothing in the DB explaining it.

Written as unittest.TestCase so it runs under `python -m unittest` with
nothing but the shipped runtime wheels; pytest collects it too.
"""

from __future__ import annotations

import os
import shutil
import tempfile
import unittest
from pathlib import Path

from app.core.paths import display_path, fs_path, to_local
from app.models.capture import CaptureFolder
from app.routers.qc import available_image_names


class FsPathRoundTripTests(unittest.TestCase):
    def test_local_path_round_trips(self) -> None:
        local = Path(r"C:\some\local\folder\file.tif")
        prefixed = fs_path(local)
        if os.name == "nt":
            self.assertTrue(str(prefixed).startswith("\\\\?\\"))
        self.assertEqual(display_path(prefixed), str(local))

    def test_unc_path_round_trips(self) -> None:
        unc = r"\\CAPTURE-PC\2.Batches\folder\file.tif"
        prefixed = fs_path(Path(unc))
        if os.name == "nt":
            self.assertTrue(str(prefixed).startswith("\\\\?\\UNC\\"))
        self.assertEqual(display_path(prefixed), unc)

    def test_idempotent(self) -> None:
        local = Path(r"C:\some\local\folder")
        once = fs_path(local)
        twice = fs_path(once)
        self.assertEqual(once, twice)

    def test_display_path_passes_through_an_unprefixed_path(self) -> None:
        self.assertEqual(display_path(r"C:\plain\path"), r"C:\plain\path")

    def test_to_local_unaffected_by_fs_path_existing(self) -> None:
        """`to_local`'s prefix-remap matching must still see a plain DB value.

        fs_path is only ever applied AFTER to_local resolves the stored value
        to a local path (never before), so to_local's own host/container
        prefix matching always runs against an unprefixed string - this pins
        that a bare DB-style value still resolves exactly as it did before
        fs_path existed.
        """
        db_value = r"C:\LWCAM_DBs\2.Batches\SomeFolder"
        self.assertEqual(to_local(db_value), Path(db_value).expanduser())


@unittest.skipUnless(os.name == "nt", "extended-length paths are a Windows concept")
class RepresentativeCallSiteTests(unittest.TestCase):
    """A real call site (available_image_names) over a path past MAX_PATH."""

    def test_available_image_names_over_a_300_char_path(self) -> None:
        # Not a `with TemporaryDirectory()`: its own cleanup walks the tree
        # with plain (unprefixed) paths and hits this exact MAX_PATH bug -
        # confirmed live, it fails to fully delete a tree this deep. Torn
        # down below through fs_path instead, same as a real caller would.
        tmp = tempfile.mkdtemp()
        try:
            # Padded nested segments so the absolute path clears 260 chars.
            deep = Path(tmp)
            while len(str(deep)) < 300:
                deep = deep / ("folder_segment_" + "x" * 40)
            fs_path(deep).mkdir(parents=True, exist_ok=True)
            fs_path(deep / "page1.tif").write_bytes(b"fake-tiff-bytes")
            fs_path(deep / "page2.jpg").write_bytes(b"fake-jpeg-bytes")

            self.assertGreater(len(str(deep)), 260)
            folder = CaptureFolder(folder_path=str(deep), thumbnail_path=None)
            names = available_image_names(folder)

            self.assertEqual(names, {"page1.tif", "page2.jpg"})
        finally:
            shutil.rmtree(fs_path(Path(tmp)), ignore_errors=True)


if __name__ == "__main__":
    unittest.main()

"""The single-setting image relocation: `paths.relocate_under`.

LWCAM records an absolute path per capture folder, so on a site where QC runs
somewhere else there is no one "images folder" to point the engine at - there
are as many paths as there are folders, all written by another application into
a column this engine does not own and must not rewrite.

What every stored path shares is its tail: the capture date folder and
everything under it. `relocate_under` keeps that and replaces the head. These
tests pin the cases that decide whether that is safe to rely on - a UNC share,
the thumbnail path's extra level, and a layout the rule does not recognise.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from app.core.paths import relocate_under

FOLDER = r"C:\Program Files\LW Suite\LWCam Capture\2.Batches\20260909\9155 1234-5678 file no. 1234"
THUMBS = FOLDER + r"\thumbs"
UNC_ROOT = r"\\office-nas\LWCamCapture"
LOCAL_ROOT = r"D:\QCImages"


class RelocateUnderTests(unittest.TestCase):
    def test_empty_root_declines_so_the_stored_path_is_used(self) -> None:
        """The single-PC station, and the default. Nothing should be remapped."""
        self.assertIsNone(relocate_under(FOLDER, ""))
        self.assertIsNone(relocate_under(FOLDER, "   "))

    def test_folder_keeps_its_date_and_name_under_the_new_root(self) -> None:
        self.assertEqual(
            relocate_under(FOLDER, LOCAL_ROOT),
            Path(LOCAL_ROOT) / "20260909" / "9155 1234-5678 file no. 1234",
        )

    def test_a_unc_root_survives_as_a_unc_path(self) -> None:
        """The whole point on a split site; a collapsed leading slash finds nothing."""
        result = str(relocate_under(FOLDER, UNC_ROOT))
        self.assertTrue(result.startswith("\\\\"), result)
        self.assertEqual(result, UNC_ROOT + r"\20260909\9155 1234-5678 file no. 1234")

    def test_thumbnail_path_keeps_its_extra_level(self) -> None:
        """thumbnail_path is one directory deeper than folder_path.

        Counting segments from the right would re-root this one level short and
        hand back the folder itself, which exists - so the failure would be a
        wrong directory rather than a missing one. Anchoring on the date is what
        avoids that.
        """
        self.assertEqual(
            relocate_under(THUMBS, LOCAL_ROOT),
            Path(LOCAL_ROOT) / "20260909" / "9155 1234-5678 file no. 1234" / "thumbs",
        )

    def test_a_different_capture_root_still_relocates(self) -> None:
        """Two stations writing different roots is exactly what this rule buys.

        Nothing about the head of the stored path is consulted, so a folder
        captured on a station that used D:\\SomeOther\\Batches lands in the same
        place as one from C:\\Program Files\\...
        """
        other = r"D:\SomeOtherStation\Batches\20260910\9145 1334-1350 file no. 1334"
        self.assertEqual(
            relocate_under(other, LOCAL_ROOT),
            Path(LOCAL_ROOT) / "20260910" / "9145 1334-1350 file no. 1334",
        )

    def test_a_trailing_separator_on_the_root_is_tolerated(self) -> None:
        """Operators paste paths with and without one."""
        self.assertEqual(
            relocate_under(FOLDER, LOCAL_ROOT + "\\"),
            relocate_under(FOLDER, LOCAL_ROOT),
        )

    def test_a_path_with_no_date_segment_declines_rather_than_guessing(self) -> None:
        """An unrecognised layout must fail as "missing", not as a wrong folder.

        Returning None sends the caller back to the stored path, so the existing
        directory-missing error surfaces. Inventing a location would point at
        whatever happens to sit under the root with that name.
        """
        self.assertIsNone(relocate_under(r"C:\somewhere\without\a\date", LOCAL_ROOT))

    def test_forward_slashes_are_accepted(self) -> None:
        """Nothing guarantees the stored separator style forever."""
        self.assertEqual(
            relocate_under(FOLDER.replace("\\", "/"), LOCAL_ROOT),
            Path(LOCAL_ROOT) / "20260909" / "9155 1234-5678 file no. 1234",
        )
    def test_a_capture_root_with_its_own_date_segment_uses_the_last_one(self) -> None:
        stored = r"D:\20260101\2.Batches\20260909\name one"
        self.assertEqual(relocate_under(stored, LOCAL_ROOT), Path(LOCAL_ROOT) / "20260909" / "name one")

    def test_a_trailing_date_segment_with_nothing_after_it_is_not_an_anchor(self) -> None:
        self.assertIsNone(relocate_under(r"C:\x\20260909", LOCAL_ROOT))
        self.assertIsNone(relocate_under("C:/x/20260909/", LOCAL_ROOT))


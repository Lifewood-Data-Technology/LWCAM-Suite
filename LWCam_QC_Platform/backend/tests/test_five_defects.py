"""Regression tests for the 2026-09-10 defect sweep.

Five suspected defects were checked against the real code path; each test here
pins the one that was CONFIRMED and fixed (see the fix commit for the REFUTED
count - there was none this round). unittest.TestCase, like the rest of this
tree, so `python -m unittest discover` and pytest both collect it.
"""

from __future__ import annotations

import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import Mock, patch

from app.core.config import settings
from app.models.capture import CaptureBox, CaptureFolder, CaptureImage
from app.models.project import Device
from app.routers import qc
from app.services import ai_review
from app.services import qc_drafts


def _folder(folder_path: str, images: list[CaptureImage], thumbnail_path: str | None = None) -> CaptureFolder:
    folder = CaptureFolder(
        id=1, folder_name="folder", box_id=1, device_id=1, folder_seq=1,
        folder_path=folder_path, thumbnail_path=thumbnail_path, qc_locked_by="op",
    )
    folder.box = CaptureBox(box_id=1, box_name="box")
    folder.device = Device(device_id="DEV1")
    folder.images = images
    return folder


class ReplaceAcrossFormatsTests(unittest.TestCase):
    """commit_current_draft (routers/qc.py) must follow a replacement's name.

    A page replaced with a different-extension file used to keep the row's
    OLD image_name/file_format while the file on disk under that old name got
    the NEW bytes - a .tif row holding JPEG content. This also exercises the
    staged-commit fix: nothing lands under a real name until finalize() runs.
    """

    def test_replace_renames_the_row_and_retires_the_stale_file(self) -> None:
        with TemporaryDirectory() as temp:
            official_dir = Path(temp) / "official"
            official_dir.mkdir()
            official_path = official_dir / "page1.tif"
            official_path.write_bytes(b"TIFFBYTES")
            image = CaptureImage(id=5, image_name="page1.tif", file_format="tif", device_id=1, folder_id=1)
            folder = _folder(str(official_dir), [image])

            with patch.object(settings, "qc_work_dir", str(Path(temp) / "work")):
                work_dir = qc_drafts.draft_dir(folder.id, "op") / "images"
                work_dir.mkdir(parents=True)
                work_path = work_dir / "5_page1.jpg"
                work_path.write_bytes(b"JPEGBYTES")
                manifest = qc_drafts.empty_manifest(folder.id, "op")
                manifest["images"]["5"] = {
                    "image_name": "page1.jpg",
                    "work_path": str(work_path),
                    "dirty": True,
                    "status": "replaced",
                }
                qc_drafts.write_manifest(folder.id, "op", manifest)

                with patch.object(qc, "object_session", return_value=Mock()):
                    _separation, finalize, _abort = qc.commit_current_draft(folder, "op")
                    # Staged, not yet visible: the DB row already reflects the
                    # rename, but the new file is not there under its real
                    # name until finalize runs (the old one is already staged
                    # aside under a hidden sibling name - see defer_retirement
                    # - which is the reversible half abort() undoes below).
                    self.assertEqual(image.image_name, "page1.jpg")
                    self.assertFalse((official_dir / "page1.jpg").exists())
                    finalize()

            self.assertEqual(image.file_format, "jpg")
            new_path = official_dir / "page1.jpg"
            self.assertTrue(new_path.is_file())
            self.assertEqual(new_path.read_bytes(), b"JPEGBYTES")
            self.assertFalse(official_path.exists(), "the stale .tif must not survive a format-changing replace")

    def test_a_failed_db_commit_leaves_every_file_untouched(self) -> None:
        """abort() undoes the staging - the fix for item 3."""
        with TemporaryDirectory() as temp:
            official_dir = Path(temp) / "official"
            official_dir.mkdir()
            official_path = official_dir / "page1.tif"
            official_path.write_bytes(b"TIFFBYTES")
            image = CaptureImage(id=5, image_name="page1.tif", file_format="tif", device_id=1, folder_id=1)
            folder = _folder(str(official_dir), [image])

            with patch.object(settings, "qc_work_dir", str(Path(temp) / "work")):
                work_dir = qc_drafts.draft_dir(folder.id, "op") / "images"
                work_dir.mkdir(parents=True)
                work_path = work_dir / "5_page1.tif"
                work_path.write_bytes(b"EDITEDBYTES")
                manifest = qc_drafts.empty_manifest(folder.id, "op")
                manifest["images"]["5"] = {
                    "image_name": "page1.tif",
                    "work_path": str(work_path),
                    "dirty": True,
                    "status": "existing",
                }
                qc_drafts.write_manifest(folder.id, "op", manifest)

                with patch.object(qc, "object_session", return_value=Mock()):
                    _separation, _finalize, abort = qc.commit_current_draft(folder, "op")
                    abort()

            self.assertTrue(official_path.is_file())
            self.assertEqual(official_path.read_bytes(), b"TIFFBYTES")
            self.assertEqual(list(official_dir.iterdir()), [official_path], "no leftover staged file")


class EnsureWorkCopyTests(unittest.TestCase):
    """ensure_work_copy (services/qc_drafts.py) must not drop edit state.

    flush_all_pending_ops rebuilds a work copy AV quarantine or a
    %LOCALAPPDATA% cleanup deleted out from under a pending edit. Assigning a
    fresh dict over the manifest item silently dropped pending_ops/dirty/
    version, so the edit was rebuilt as dirty=False and never committed.
    """

    def test_a_rebuilt_work_copy_keeps_its_pending_edit(self) -> None:
        with TemporaryDirectory() as temp:
            with patch.object(settings, "qc_work_dir", str(Path(temp) / "work")):
                source = Path(temp) / "page1.tif"
                source.write_bytes(b"ORIGINAL")
                work_path = qc_drafts.ensure_work_copy(1, "op", 5, "page1.tif", source)

                manifest = qc_drafts.read_manifest(1, "op")
                item = manifest["images"]["5"]
                item["dirty"] = True
                item["pending_ops"] = [{"op": "deskew", "degrees": 1.5}]
                item["version"] = 1234567
                qc_drafts.write_manifest(1, "op", manifest)

                work_path.unlink()  # the AV/cleanup scenario

                qc_drafts.ensure_work_copy(1, "op", 5, "page1.tif", source)

                rebuilt = qc_drafts.read_manifest(1, "op")["images"]["5"]
                self.assertTrue(rebuilt["dirty"])
                self.assertEqual(rebuilt["pending_ops"], [{"op": "deskew", "degrees": 1.5}])
                self.assertEqual(rebuilt["version"], 1234567)
                self.assertTrue(Path(rebuilt["work_path"]).is_file())


class ArchiveDateSuggestionTests(unittest.TestCase):
    """ai_review.py's date guard, relaxed for free-text archive coverage."""

    def test_accepts_the_archive_free_text_shapes(self) -> None:
        for value in ("1914", "1914-06", "1877-Mar-05", "1877-mar-05", "1877-1927"):
            with self.subTest(value=value):
                self.assertTrue(ai_review.is_plausible_archive_date(value))

    def test_rejects_prose_and_garbage(self) -> None:
        for value in ("", "circa 1914", "the year 1939 is clearly visible", "12345", "x" * 30):
            with self.subTest(value=value):
                self.assertFalse(ai_review.is_plausible_archive_date(value))

    def test_canonical_value_is_the_whole_string_case_folded(self) -> None:
        self.assertEqual(
            ai_review.canonical_metadata_value("startDate", "  1877-Mar-05 "),
            ai_review.canonical_metadata_value("startDate", "1877-MAR-05"),
        )
        # The bug: truncating to the leading 4 digits made these compare equal.
        self.assertNotEqual(
            ai_review.canonical_metadata_value("startDate", "1877"),
            ai_review.canonical_metadata_value("startDate", "1877-Mar-05"),
        )


class SourceHashDiskAwarenessTests(unittest.TestCase):
    """source_hash (routers/qc.py) must see a rework that never touched the DB."""

    def test_source_hash_moves_when_the_file_changes_without_a_db_bump(self) -> None:
        with TemporaryDirectory() as temp:
            path = Path(temp) / "page1.tif"
            path.write_bytes(b"AAAA")
            image = CaptureImage(id=1, image_name="page1.tif", file_format="tif", device_id=1, folder_id=1)
            folder = _folder(str(temp), [image])

            before = qc.source_hash(folder)
            # A capture rework overwrites the file directly; image_updated_at
            # is untouched, exactly as it is not bumped by the real LWIP path.
            path.write_bytes(b"BBBBBBBB")
            after = qc.source_hash(folder)

            self.assertNotEqual(before, after)

    def test_a_missing_file_does_not_raise(self) -> None:
        with TemporaryDirectory() as temp:
            image = CaptureImage(id=1, image_name="ghost.tif", file_format="tif", device_id=1, folder_id=1)
            folder = _folder(str(temp), [image])
            qc.source_hash(folder)  # must not raise


if __name__ == "__main__":
    unittest.main()

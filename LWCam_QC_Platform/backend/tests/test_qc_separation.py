"""Regression tests for two data-integrity bugs in folder separation.

Both were verified live before this fix: a folder split into two children
left its committed qc_ops.json (a deskew, a crop, a rotate) sitting in the
now-deleted PARENT directory - neither child got one - and both children's
thumbnail_path pointed back inside that same dead parent folder.

unittest.TestCase, like the rest of this tree, so `python -m unittest
discover` and pytest both collect it.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import Mock, patch

from app.core.config import settings
from app.models.capture import CaptureBox, CaptureFolder, CaptureImage
from app.models.project import Device
from app.routers import qc
from app.services import qc_drafts
from app.services.qc_ops_store import write_image_ops
from app.services.qc_separation import SeparationFileTransaction


def _folder(folder_path: str, images: list[CaptureImage], thumbnail_path: str | None = None) -> CaptureFolder:
    folder = CaptureFolder(
        id=1, folder_name="folder", box_id=1, device_id=1, folder_seq=1,
        folder_path=folder_path, thumbnail_path=thumbnail_path, qc_locked_by="op",
    )
    folder.box = CaptureBox(box_id=1, box_name="box")
    folder.device = Device(device_id="DEV1")
    folder.images = images
    return folder


class ChildThumbnailNestingTests(unittest.TestCase):
    """SeparationFileTransaction (services/qc_separation.py) must put a
    child's thumbnails under the CHILD's own image directory.

    The old code derived the child thumbnail dir from the PARENT thumbnail
    dir's own name ("thumbs", which does not end in "_thumbnail_path") and
    fell into the generic "<name>_NNN" branch - producing "thumbs_001" as a
    SIBLING of "thumbs", i.e. still inside the parent image folder that
    separation is about to delete.
    """

    def test_child_thumbnails_land_under_the_childs_own_image_dir(self) -> None:
        with TemporaryDirectory() as temp:
            root = Path(temp)
            image_dir = root / "9155 parent"
            image_dir.mkdir()
            thumb_dir = image_dir / "thumbs"
            thumb_dir.mkdir()
            names = ["p1.jpg", "p2.jpg", "p3.jpg", "p4.jpg"]
            for name in names:
                (image_dir / name).write_bytes(b"IMG-" + name.encode())
                (thumb_dir / name).write_bytes(b"THUMB-" + name.encode())

            groups = [["p1.jpg", "p2.jpg"], ["p3.jpg", "p4.jpg"]]
            transaction = SeparationFileTransaction(image_dir, thumb_dir, groups)
            transaction.apply()

            for group, expected_names in zip(transaction.groups, groups):
                # Nested under the child's own image dir, matching what LWIP
                # produces for a normal folder.
                self.assertEqual(group.final_thumbnail_dir, group.final_image_dir / "thumbs")
                self.assertTrue(group.final_thumbnail_dir.is_dir())
                # Not left inside the dead parent folder.
                with self.assertRaises(ValueError):
                    group.final_thumbnail_dir.relative_to(image_dir)
                for name in expected_names:
                    self.assertEqual(
                        (group.final_thumbnail_dir / name).read_bytes(), b"THUMB-" + name.encode()
                    )
                    self.assertEqual(
                        (group.final_image_dir / name).read_bytes(), b"IMG-" + name.encode()
                    )

            # Every file moved out of the parent - nothing of either kind is
            # left behind for a later cleanup of the parent to destroy.
            self.assertEqual(list(image_dir.glob("*.jpg")), [])
            self.assertEqual(list(thumb_dir.iterdir()), [])

    def test_rollback_restores_thumbnails_to_the_parent(self) -> None:
        with TemporaryDirectory() as temp:
            root = Path(temp)
            image_dir = root / "9155 parent"
            image_dir.mkdir()
            thumb_dir = image_dir / "thumbs"
            thumb_dir.mkdir()
            for name in ["p1.jpg", "p2.jpg"]:
                (image_dir / name).write_bytes(b"IMG-" + name.encode())
                (thumb_dir / name).write_bytes(b"THUMB-" + name.encode())

            transaction = SeparationFileTransaction(image_dir, thumb_dir, [["p1.jpg"], ["p2.jpg"]])
            transaction.apply()
            transaction.rollback()

            self.assertEqual((image_dir / "p1.jpg").read_bytes(), b"IMG-p1.jpg")
            self.assertEqual((thumb_dir / "p1.jpg").read_bytes(), b"THUMB-p1.jpg")
            self.assertEqual((image_dir / "p2.jpg").read_bytes(), b"IMG-p2.jpg")
            self.assertEqual((thumb_dir / "p2.jpg").read_bytes(), b"THUMB-p2.jpg")
            for group in transaction.groups:
                self.assertFalse(group.final_image_dir.exists())


class CommitCurrentDraftSeparationOpsTests(unittest.TestCase):
    """commit_current_draft (routers/qc.py) must not orphan qc_ops.json in
    the parent directory when this same commit also separates the folder.

    Verified live before this fix: folder 2 was split into 8 and 9;
    qc_ops.json held a deskew, a crop and a rotate but stayed in the parent's
    (now-deleted) directory, and neither child got one.
    """

    @staticmethod
    def _mock_db(images: list[CaptureImage]) -> Mock:
        db = Mock()
        db.scalar.return_value = 0
        db.scalars.return_value.all.return_value = images
        return db

    def test_each_child_gets_only_its_own_ops_and_the_parent_file_is_retired(self) -> None:
        with TemporaryDirectory() as temp:
            official_dir = Path(temp) / "official"
            official_dir.mkdir()
            images = [
                CaptureImage(id=1, image_name="page1.jpg", file_format="jpg", device_id=1, folder_id=1),
                CaptureImage(id=2, image_name="page2.jpg", file_format="jpg", device_id=1, folder_id=1),
                CaptureImage(id=3, image_name="page3.jpg", file_format="jpg", device_id=1, folder_id=1),
                CaptureImage(id=4, image_name="page4.jpg", file_format="jpg", device_id=1, folder_id=1),
            ]
            for image in images:
                (official_dir / image.image_name).write_bytes(b"BYTES-" + image.image_name.encode())
            folder = _folder(str(official_dir), images)

            # A round already committed earlier - page1 has a deskew, page3 a
            # crop. Nothing new is edited this round; only the separation
            # itself happens, exactly like the live case.
            write_image_ops(official_dir, "page1.jpg", [{"op": "deskew", "degrees": 1.5}], False)
            write_image_ops(official_dir, "page3.jpg", [{"op": "crop", "rect": [0, 0, 1, 1]}], False)

            with patch.object(settings, "qc_work_dir", str(Path(temp) / "work")):
                qc_drafts.set_separation_markers(folder.id, "op", [1, 3], [1, 2, 3, 4])

                db = self._mock_db(images)
                with patch.object(qc, "object_session", return_value=db):
                    separation, finalize, _abort = qc.commit_current_draft(folder, "op")

                    self.assertIsNotNone(separation)
                    child1_dir, child2_dir = (group.final_image_dir for group in separation.groups)

                    # Staged: nothing is visible under the real name yet.
                    self.assertFalse((child1_dir / "qc_ops.json").exists())
                    self.assertFalse((child2_dir / "qc_ops.json").exists())

                    finalize()

            child1_ops = json.loads((child1_dir / "qc_ops.json").read_text(encoding="utf-8"))
            child2_ops = json.loads((child2_dir / "qc_ops.json").read_text(encoding="utf-8"))
            self.assertEqual(set(child1_ops["images"]), {"page1.jpg"})
            self.assertEqual(set(child2_ops["images"]), {"page3.jpg"})
            self.assertEqual(child1_ops["images"]["page1.jpg"]["ops"], [{"op": "deskew", "degrees": 1.5}])
            self.assertEqual(child2_ops["images"]["page3.jpg"]["ops"], [{"op": "crop", "rect": [0, 0, 1, 1]}])

            # The parent's own file must not survive describing images it no
            # longer holds.
            self.assertFalse((official_dir / "qc_ops.json").exists())

    def test_abort_restores_the_parents_file_and_leaves_no_staged_child_file(self) -> None:
        with TemporaryDirectory() as temp:
            official_dir = Path(temp) / "official"
            official_dir.mkdir()
            images = [
                CaptureImage(id=1, image_name="page1.jpg", file_format="jpg", device_id=1, folder_id=1),
                CaptureImage(id=2, image_name="page2.jpg", file_format="jpg", device_id=1, folder_id=1),
            ]
            for image in images:
                (official_dir / image.image_name).write_bytes(b"BYTES")
            folder = _folder(str(official_dir), images)
            write_image_ops(official_dir, "page1.jpg", [{"op": "deskew", "degrees": 2.0}], False)
            original_ops = (official_dir / "qc_ops.json").read_text(encoding="utf-8")

            with patch.object(settings, "qc_work_dir", str(Path(temp) / "work")):
                qc_drafts.set_separation_markers(folder.id, "op", [1, 2], [1, 2])

                db = self._mock_db(images)
                with patch.object(qc, "object_session", return_value=db):
                    separation, _finalize, abort = qc.commit_current_draft(folder, "op")
                    child_dirs = [group.final_image_dir for group in separation.groups]
                    abort()

            # A failed commit must leave every file exactly as it was - the
            # parent's qc_ops.json restored, and no child ever got one.
            self.assertEqual((official_dir / "qc_ops.json").read_text(encoding="utf-8"), original_ops)
            for child_dir in child_dirs:
                self.assertEqual([p for p in child_dir.iterdir() if "qc_ops" in p.name], [])


if __name__ == "__main__":
    unittest.main()

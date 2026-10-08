"""Missing-page repair (Part B), kept pages through a capture rework (Part A)
and the implicit-first separation marker (Part C).

A capture rework makes LWIP rebuild the whole output folder, so every file QC
added to it - inserted pages, replacement files, qc_ops.json - is gone while
the capture_images rows (which LWIP never touches) live on.

unittest.TestCase with Mock sessions, like the rest of this tree.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import contextlib
import shutil
import unittest
from datetime import datetime, timezone
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest.mock import Mock, patch

from fastapi import UploadFile
from PIL import Image

from app.core.config import settings
from app.core.errors import BusinessError
from app.models.capture import CaptureBox, CaptureFolder, CaptureImage
from app.models.project import Device
from app.routers import qc
from app.schemas.qc import (
    RejectRequest,
    ReorderImagesRequest,
    ReviewRequest,
    RotateImageRequest,
    SeparationMarkersRequest,
)
from app.routers import qc as _qc_router  # noqa: F401  (imported before export: no cycle)
from app.services import export, qc_drafts, qc_kept_pages
from app.services.lwip_baseline import MANIFEST_NAME

USER = "op"
HASH = "0" * 64


def _jpeg(color: int = 128) -> bytes:
    buffer = io.BytesIO()
    Image.new("RGB", (40, 60), (color, color, color)).save(buffer, "JPEG")
    return buffer.getvalue()


def _upload(name: str = "new.jpg", color: int = 10) -> UploadFile:
    return UploadFile(io.BytesIO(_jpeg(color)), filename=name)


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _folder(official: Path, names: list[str], thumbs: Path | None = None) -> CaptureFolder:
    folder = CaptureFolder(
        id=1, folder_name="folder", box_id=1, device_id=1, folder_seq=1,
        folder_path=str(official), thumbnail_path=str(thumbs) if thumbs else None,
        qc_locked_by=USER, qc_status="PENDING", source_created_at=datetime.now(timezone.utc),
    )
    folder.box = CaptureBox(box_id=1, box_name="box")
    folder.device = Device(device_id="DEV1")
    folder.images = [
        CaptureImage(id=index, image_name=name, file_format="jpg", device_id=1, folder_id=1)
        for index, name in enumerate(names, start=1)
    ]
    return folder


class FakeDb:
    """Just enough session for commit_current_draft: add() hands out ids,
    expire() makes folder.images show the rows added/deleted since."""

    def __init__(self, folder: CaptureFolder | None = None, rework_image_ids: list[int] | None = None) -> None:
        self.folder = folder
        self.rework_image_ids = rework_image_ids or []
        self.added: list = []
        self.removed: list = []
        self.statements: list = []
        self._next_id = 100
        self.scalar = Mock(return_value=0)

    def __getattr__(self, name):
        # commit, rollback, expire_all ... : accept and ignore.
        mock = Mock()
        setattr(self, name, mock)
        return mock

    def begin_nested(self):
        return contextlib.nullcontext()

    def add(self, obj) -> None:
        self.added.append(obj)

    def delete(self, obj) -> None:
        self.removed.append(obj)

    def flush(self) -> None:
        for obj in self.added:
            if getattr(obj, "id", None) is None:
                obj.id = self._next_id
                self._next_id += 1

    def _images(self) -> list[CaptureImage]:
        rows = [r for r in self.folder.images if r not in self.removed]
        return rows + [r for r in self.added if isinstance(r, CaptureImage) and r not in rows and r not in self.removed]

    def scalars(self, statement):
        self.statements.append(statement)
        result = Mock()
        result.all.return_value = self.rework_image_ids if "rework_logs" in str(statement) else self._images()
        return result

    def expire(self, obj, names=None) -> None:
        self.folder.images = self._images()


def _db(images: list[CaptureImage] | None = None) -> Mock:
    db = Mock()
    db.scalar.return_value = 0
    db.scalars.return_value.all.return_value = images or []
    return db


def _draft_manifest() -> dict:
    return qc_drafts.read_manifest(1, USER)


class _Env(unittest.TestCase):
    """A temp work dir and an official folder, optionally with pages missing."""

    def setUp(self) -> None:
        self._temp = TemporaryDirectory()
        self.addCleanup(self._temp.cleanup)
        root = Path(self._temp.name)
        self.official = root / "official"
        self.thumbs = self.official / "thumbs"
        self.thumbs.mkdir(parents=True)
        patcher = patch.object(settings, "qc_work_dir", str(root / "work"))
        patcher.start()
        self.addCleanup(patcher.stop)
        self.user = SimpleNamespace(id=1, user_id=USER)

    def make_folder(self, names: list[str], missing: tuple[str, ...] = ()) -> CaptureFolder:
        for name in names:
            if name not in missing:
                (self.official / name).write_bytes(_jpeg())
                (self.thumbs / name).write_bytes(_jpeg())
        return _folder(self.official, names, self.thumbs)

    def endpoint(self, folder: CaptureFolder, func, *args, **kwargs):
        """Run a router function against [folder] with the lookups stubbed."""
        with patch.object(qc, "folder_or_404", return_value=folder), patch.object(
            qc, "verify_reviewable_folder"
        ), patch.object(qc, "write_qc_audit"), patch.object(qc, "to_task_vo", return_value=None):
            return func(*args, **kwargs)

    def commit(self, folder: CaptureFolder, db: FakeDb | None = None):
        """Save changes: commit, finalize, then refresh the kept-pages copy."""
        db = db or FakeDb(folder)
        with patch.object(qc, "object_session", return_value=db):
            separation, finalize, _abort = qc.commit_current_draft(folder, USER)
            finalize()
        qc.keep_kept_pages_current(db, folder, separation)
        return separation

    def approve(self, folder: CaptureFolder) -> None:
        db = FakeDb(folder)
        with patch.object(qc, "folder_or_404", return_value=folder), patch.object(
            qc, "verify_reviewable_folder"
        ), patch.object(qc, "metadata_template", return_value=Mock()), patch.object(
            qc, "effective_metadata_snapshot", return_value={}
        ), patch.object(qc, "validate_metadata_for_approval"), patch.object(
            qc, "cancel_ai_jobs_after_finalization"
        ), patch.object(qc, "write_qc_audit"), patch.object(qc, "object_session", return_value=db):
            qc.approve_task(1, ReviewRequest(sourceHash=HASH), self.user, db)


class MissingPageRepairTests(_Env):
    def test_preview_of_a_missing_page_is_a_clear_404(self) -> None:
        folder = self.make_folder(["p1.jpg", "p2.jpg"], missing=("p2.jpg",))
        with patch.object(qc, "folder_or_404", return_value=folder):
            with self.assertRaises(BusinessError) as caught:
                qc.preview(1, 2, self.user, Mock())
        self.assertEqual(caught.exception.http_status, 404)

    def test_replace_then_save_writes_the_page_and_its_thumbnail(self) -> None:
        folder = self.make_folder(["p1.jpg", "p2.jpg"], missing=("p2.jpg",))
        self.endpoint(folder, qc.replace_image, 1, 2, self.user, Mock(), sourceHash=HASH, file=_upload())
        self.commit(folder)
        self.assertTrue((self.official / "p2.jpg").is_file())
        self.assertTrue((self.thumbs / "p2.jpg").is_file())

    def test_a_replaced_missing_page_is_available_in_the_task_view(self) -> None:
        folder = self.make_folder(["p1.jpg", "p2.jpg"], missing=("p2.jpg",))
        before = {i.id: i.available for i in qc.to_task_vo(_db(), folder, USER).images}
        self.assertEqual(before, {1: True, 2: False})
        self.endpoint(folder, qc.replace_image, 1, 2, self.user, Mock(), sourceHash=HASH, file=_upload())
        task = qc.to_task_vo(_db(), folder, USER)
        self.assertEqual({i.id: i.available for i in task.images}, {1: True, 2: True})
        self.assertTrue(task.imageAvailable)

    def test_delete_then_save_succeeds(self) -> None:
        folder = self.make_folder(["p1.jpg", "p2.jpg"], missing=("p2.jpg",))
        self.endpoint(folder, qc.delete_qc_image, 1, 2, ReviewRequest(sourceHash=HASH), self.user, Mock())
        self.commit(folder)

    def test_approve_after_replace_does_not_trip_on_the_missing_file(self) -> None:
        folder = self.make_folder(["p1.jpg", "p2.jpg"], missing=("p2.jpg",))
        self.endpoint(folder, qc.replace_image, 1, 2, self.user, Mock(), sourceHash=HASH, file=_upload())
        self.approve(folder)
        self.assertEqual(folder.qc_status, "PASS")
        self.assertTrue((self.official / "p2.jpg").is_file())

    def test_approve_after_delete_does_not_trip_on_the_missing_file(self) -> None:
        folder = self.make_folder(["p1.jpg", "p2.jpg"], missing=("p2.jpg",))
        self.endpoint(folder, qc.delete_qc_image, 1, 2, ReviewRequest(sourceHash=HASH), self.user, Mock())
        self.approve(folder)
        self.assertEqual(folder.qc_status, "PASS")

    def test_approve_still_refuses_an_untouched_missing_page(self) -> None:
        folder = self.make_folder(["p1.jpg", "p2.jpg"], missing=("p2.jpg",))
        with self.assertRaises(BusinessError) as caught:
            self.approve(folder)
        self.assertEqual(caught.exception.http_status, 404)

    def test_rotate_of_a_missing_page_stays_a_clear_404(self) -> None:
        folder = self.make_folder(["p1.jpg", "p2.jpg"], missing=("p2.jpg",))
        with self.assertRaises(BusinessError) as caught:
            self.endpoint(
                folder, qc.rotate_qc_image, 1, 2,
                RotateImageRequest(sourceHash=HASH, degrees=90), self.user, Mock(),
            )
        self.assertEqual(caught.exception.http_status, 404)


class _KeptEnv(_Env):
    """A four-page folder with an LWIP manifest, and helpers to rebuild it."""

    NAMES = ["p1.jpg", "p2.jpg", "p3.jpg", "p4.jpg"]

    def setUp(self) -> None:
        super().setUp()
        self.folder = self.make_folder(self.NAMES)
        self.originals = {name: (self.official / name).read_bytes() for name in self.NAMES}
        self.write_manifest("A", self.originals)

    def write_manifest(self, fingerprint: str, contents: dict[str, bytes], created: str = "t1") -> None:
        path = self.official / MANIFEST_NAME
        path.write_text(json.dumps({
            "source_fingerprint": fingerprint,
            "created_at": created,
            "files": [{"relative_path": n, "sha256": _sha(b), "qc_ops": []} for n, b in contents.items()],
        }), encoding="utf-8")
        # The manifest cache is keyed by mtime: make a rewrite always look new.
        stamp = os.stat(path).st_mtime + 10 * ord(fingerprint[0]) + 1000 * len(created) + 7 * ord(created[-1])
        os.utime(path, (stamp, stamp))

    def qc_session(self) -> None:
        """Insert before p2, replace p3, rotate p1 and p4; then Save changes."""
        self.endpoint(self.folder, qc.insert_image_before, 1, 2, self.user, Mock(), sourceHash=HASH, file=_upload("ins.jpg", 40))
        self.endpoint(self.folder, qc.replace_image, 1, 3, self.user, Mock(), sourceHash=HASH, file=_upload("r.jpg", 200))
        for image_id in (1, 4):
            self.endpoint(
                self.folder, qc.rotate_qc_image, 1, image_id,
                RotateImageRequest(sourceHash=HASH, degrees=90), self.user, Mock(),
            )
        self.db = FakeDb(self.folder)
        self.commit(self.folder, self.db)
        qc_drafts.discard_draft(1, USER)  # as save_draft does once the commit is durable
        self.inserted = next(i for i in self.folder.images if i.image_name == "ins.jpg")
        self.kept_bytes = {n: (self.official / n).read_bytes() for n in ("ins.jpg", "p3.jpg")}

    def republish(
        self, recaptured: tuple[str, ...] = ("p4.jpg",), fingerprint: str = "B", created: str = "t2"
    ) -> None:
        """What LWIP leaves behind: a fresh folder holding only its own files."""
        for path in list(self.official.iterdir()):
            if path.is_file():
                path.unlink()
        shutil.rmtree(self.thumbs)
        self.thumbs.mkdir()
        contents = dict(self.originals)
        for name in recaptured:
            contents[name] = _jpeg(7)
        for name in self.NAMES:
            (self.official / name).write_bytes(contents[name])
            (self.thumbs / name).write_bytes(contents[name])
        self.write_manifest(fingerprint, contents, created)

    def restore(self, rework_image_ids: list[int] | None = None) -> None:
        qc_kept_pages.restore_after_republish(self.folder, FakeDb(self.folder, rework_image_ids))

    def saved_ops(self) -> dict:
        return json.loads((self.official / "qc_ops.json").read_text(encoding="utf-8"))["images"]



class KeptPagesTests(_KeptEnv):
    """The folder is rebuilt by LWIP; QC puts its pages and edits back."""

    def test_added_pages_and_edits_of_untouched_pages_come_back(self) -> None:
        self.qc_session()
        self.republish()
        self.assertFalse((self.official / "ins.jpg").exists())
        self.restore()
        self.assertEqual((self.official / "ins.jpg").read_bytes(), self.kept_bytes["ins.jpg"])
        self.assertTrue((self.thumbs / "ins.jpg").is_file())
        self.assertEqual((self.official / "p3.jpg").read_bytes(), self.kept_bytes["p3.jpg"])
        images = self.saved_ops()
        self.assertEqual(images["p1.jpg"]["ops"], [{"op": "rotate", "degrees": 90.0}])
        self.assertEqual(images["ins.jpg"]["kept"], "inserted")
        self.assertEqual(images["p3.jpg"]["kept"], "replaced")
        # p4 was recaptured: its edit is gone and it starts fresh.
        self.assertNotIn("p4.jpg", images)
        self.assertEqual((self.official / "p4.jpg").read_bytes(), _jpeg(7))

    def test_a_page_sent_back_for_recapture_loses_its_edits_even_with_the_same_bytes(self) -> None:
        self.qc_session()
        self.republish(recaptured=())
        self.restore(rework_image_ids=[1])
        images = self.saved_ops()
        self.assertNotIn("p1.jpg", images)
        self.assertIn("p4.jpg", images)

    def test_restore_is_idempotent_and_does_nothing_without_a_republish(self) -> None:
        self.qc_session()
        self.restore()  # same manifest fingerprint: nothing was rebuilt
        self.assertEqual((self.official / "p3.jpg").read_bytes(), self.kept_bytes["p3.jpg"])
        self.republish()
        self.restore()
        first = (self.official / "qc_ops.json").read_text(encoding="utf-8")
        (self.official / "ins.jpg").write_bytes(b"touched")
        self.restore()  # re-snapshotted under the new fingerprint: no second restore
        self.assertEqual((self.official / "ins.jpg").read_bytes(), b"touched")
        self.assertEqual((self.official / "qc_ops.json").read_text(encoding="utf-8"), first)

    def test_a_cross_format_replace_retires_the_file_lwip_made(self) -> None:
        png = io.BytesIO()
        Image.new("RGB", (30, 30), (1, 2, 3)).save(png, "PNG")
        upload = UploadFile(io.BytesIO(png.getvalue()), filename="x.png")
        self.endpoint(self.folder, qc.replace_image, 1, 3, self.user, Mock(), sourceHash=HASH, file=upload)
        self.commit(self.folder)
        self.assertTrue((self.official / "p3.png").is_file())
        self.republish(recaptured=())
        self.restore()
        self.assertTrue((self.official / "p3.png").is_file())
        self.assertFalse((self.official / "p3.jpg").exists())
        self.assertFalse((self.thumbs / "p3.jpg").exists())

    def test_a_failing_restore_never_raises(self) -> None:
        self.qc_session()
        self.republish()
        with patch.object(qc_kept_pages, "_restore", side_effect=OSError("share gone")):
            qc_kept_pages.restore_after_republish(self.folder, FakeDb(self.folder))

    def test_claim_restores_before_the_task_view_is_built(self) -> None:
        self.qc_session()
        self.republish()
        self.folder.qc_locked_by = None
        self.folder.qc_locked_at = None
        seen: list[bool] = []

        def vo(*_args):
            seen.append((self.official / "ins.jpg").is_file())

        db = FakeDb(self.folder)
        with patch.object(qc, "project_ids_for_user", return_value=[1]), patch.object(
            qc, "folder_or_404", return_value=self.folder
        ), patch.object(qc, "to_task_vo", side_effect=vo), patch.object(qc, "write_qc_audit"):
            qc.claim_task(1, self.user, db)
        self.assertEqual(seen, [True])

    def test_reject_refuses_a_page_added_or_replaced_in_qc(self) -> None:
        self.qc_session()
        for image_id in (self.inserted.id, 3):
            request = RejectRequest(sourceHash=HASH, imageIds=[image_id], rejectReason="blurry")
            with patch.object(qc, "folder_or_404", return_value=self.folder), patch.object(
                qc, "verify_reviewable_folder"
            ):
                with self.assertRaises(BusinessError) as caught:
                    qc.reject_task(1, request, self.user, FakeDb(self.folder))
            self.assertEqual(caught.exception.http_status, 400)
            self.assertEqual(self.folder.qc_status, "PENDING")

    def test_reject_still_works_for_an_untouched_page(self) -> None:
        self.qc_session()
        request = RejectRequest(sourceHash=HASH, imageIds=[1], rejectReason="blurry")
        self.folder.box.user_id = 5
        with patch.object(qc, "folder_or_404", return_value=self.folder), patch.object(
            qc, "verify_reviewable_folder"
        ), patch.object(qc, "cancel_ai_jobs_after_finalization"), patch.object(qc, "write_qc_audit"):
            qc.reject_task(1, request, self.user, FakeDb(self.folder))
        self.assertEqual(self.folder.qc_status, "REWORK")

    def test_a_deleted_added_page_leaves_the_store(self) -> None:
        self.qc_session()
        self.endpoint(
            self.folder, qc.delete_qc_image, 1, self.inserted.id, ReviewRequest(sourceHash=HASH), self.user, Mock()
        )
        self.commit(self.folder, self.db)
        stored = json.loads((qc_kept_pages.store_dir(1) / "kept.json").read_text(encoding="utf-8"))
        self.assertNotIn("ins.jpg", stored["pages"])
        self.assertFalse((qc_kept_pages.store_dir(1) / "pages" / "ins.jpg").exists())

    def test_a_later_edit_to_an_added_page_keeps_it_marked(self) -> None:
        self.qc_session()
        self.endpoint(
            self.folder, qc.rotate_qc_image, 1, self.inserted.id,
            RotateImageRequest(sourceHash=HASH, degrees=90), self.user, Mock(),
        )
        self.commit(self.folder, self.db)
        self.assertEqual(self.saved_ops()["ins.jpg"]["kept"], "inserted")


class KeptPagesRound2Tests(_KeptEnv):
    """Review findings: what counts as a republish, tags that must survive,
    names read from shared files, and the store's lifetime."""

    def test_a_rebuild_under_the_same_fingerprint_is_still_a_republish(self) -> None:
        self.qc_session()
        self.republish(recaptured=(), fingerprint="A", created="t2")
        self.restore()
        self.assertEqual((self.official / "ins.jpg").read_bytes(), self.kept_bytes["ins.jpg"])
        self.assertIn("p1.jpg", self.saved_ops())

    def test_a_missing_kept_page_or_ops_file_alone_counts_as_a_republish(self) -> None:
        self.qc_session()
        (self.official / "ins.jpg").unlink()
        os.unlink(self.official / "qc_ops.json")
        self.restore()  # same manifest throughout
        self.assertEqual((self.official / "ins.jpg").read_bytes(), self.kept_bytes["ins.jpg"])
        self.assertIn("p1.jpg", self.saved_ops())

    def test_a_snapshot_taken_without_a_manifest_still_restores_the_pages(self) -> None:
        (self.official / MANIFEST_NAME).unlink()
        self.qc_session()
        stored = json.loads((qc_kept_pages.store_dir(1) / "kept.json").read_text(encoding="utf-8"))
        self.assertIsNone(stored["manifest_marker"])
        self.republish()
        self.restore()
        self.assertTrue((self.official / "ins.jpg").is_file())
        # Nothing to compare the other pages against: their edits are dropped.
        self.assertNotIn("p1.jpg", self.saved_ops())

    def test_the_first_claim_with_no_store_changes_nothing(self) -> None:
        self.folder.qc_locked_by = None
        before = sorted(p.name for p in self.official.iterdir())
        seen = []
        with patch.object(qc, "project_ids_for_user", return_value=[1]), patch.object(
            qc, "folder_or_404", return_value=self.folder
        ), patch.object(qc, "to_task_vo", side_effect=lambda *a: seen.append(1)), patch.object(
            qc, "write_qc_audit"
        ):
            qc.claim_task(1, self.user, FakeDb(self.folder))
        self.assertEqual(seen, [1])
        self.assertEqual(sorted(p.name for p in self.official.iterdir()), before)

    def test_approve_refreshes_the_store(self) -> None:
        self.endpoint(self.folder, qc.insert_image_before, 1, 2, self.user, Mock(), sourceHash=HASH, file=_upload("ins.jpg", 40))
        self.approve(self.folder)
        stored = json.loads((qc_kept_pages.store_dir(1) / "kept.json").read_text(encoding="utf-8"))
        self.assertIn("ins.jpg", stored["pages"])

    def test_the_reject_guard_reads_the_store_alone(self) -> None:
        self.qc_session()
        os.unlink(self.official / "qc_ops.json")
        os.unlink(self.official / MANIFEST_NAME)  # and no manifest to give it away either
        request = RejectRequest(sourceHash=HASH, imageIds=[self.inserted.id], rejectReason="blurry")
        with patch.object(qc, "folder_or_404", return_value=self.folder), patch.object(qc, "verify_reviewable_folder"):
            with self.assertRaises(BusinessError):
                qc.reject_task(1, request, self.user, FakeDb(self.folder))

    def test_restore_original_on_a_kept_page_keeps_it_kept(self) -> None:
        self.qc_session()
        for page_id in (self.inserted.id, 3):
            # A draft has to exist for a restore to mean anything.
            self.endpoint(
                self.folder, qc.rotate_qc_image, 1, page_id,
                RotateImageRequest(sourceHash=HASH, degrees=90), self.user, Mock(),
            )
            self.endpoint(
                self.folder, qc.restore_qc_image, 1, page_id, ReviewRequest(sourceHash=HASH), self.user, Mock()
            )
        self.commit(self.folder, self.db)
        images = self.saved_ops()
        for name in ("ins.jpg", "p3.jpg"):
            self.assertTrue(images[name]["kept"])
            self.assertTrue(images[name]["ignore_lwip"])
        stored = json.loads((qc_kept_pages.store_dir(1) / "kept.json").read_text(encoding="utf-8"))
        self.assertEqual(set(stored["pages"]), {"ins.jpg", "p3.jpg"})
        self.republish()
        self.restore()
        self.assertTrue((self.official / "ins.jpg").is_file())

    def test_restored_edits_are_re_rendered_into_the_thumbnail(self) -> None:
        self.qc_session()
        self.republish()
        calls = {}
        real = qc_kept_pages.generate_thumbnail_file

        def spy(source, target, ops=None):
            calls[Path(target).name] = ops
            return real(source, target, ops)

        with patch.object(qc_kept_pages, "generate_thumbnail_file", spy):
            self.restore()
        self.assertEqual(calls["p1.jpg"], [{"op": "rotate", "degrees": 90.0}])
        self.assertNotIn("p4.jpg", calls)

    def test_a_snapshot_after_a_failed_restore_does_not_overwrite_the_good_copy(self) -> None:
        self.qc_session()
        self.republish()
        with patch.object(qc_kept_pages, "_restore", side_effect=OSError("share gone")):
            qc_kept_pages.restore_after_republish(self.folder, FakeDb(self.folder))
        qc_kept_pages.snapshot_folder(self.folder, FakeDb(self.folder))
        self.assertEqual((self.official / "ins.jpg").read_bytes(), self.kept_bytes["ins.jpg"])
        self.assertIn("p1.jpg", self.saved_ops())

    def test_a_database_error_reading_rework_logs_never_blocks_a_restore(self) -> None:
        self.qc_session()
        self.republish(recaptured=())
        db = FakeDb(self.folder)
        db.scalars = Mock(side_effect=RuntimeError("aborted transaction"))
        qc_kept_pages.restore_after_republish(self.folder, db)
        self.assertTrue((self.official / "ins.jpg").is_file())
        self.assertNotIn("p1.jpg", self.saved_ops())  # unsure: edits dropped

    def test_a_pre_tag_added_page_is_recognised_by_the_manifest(self) -> None:
        self.qc_session()
        path = self.official / "qc_ops.json"
        data = json.loads(path.read_text(encoding="utf-8"))
        for entry in data["images"].values():
            entry.pop("kept", None)
        data["images"]["p2.jpg"] = {"ops": [], "ignore_lwip": True}  # a luminance-baked LWIP page
        path.write_text(json.dumps(data), encoding="utf-8")
        shutil.rmtree(qc_kept_pages.store_dir(1))
        self.assertTrue(qc_kept_pages.is_kept_page(1, self.official, "ins.jpg"))
        self.assertFalse(qc_kept_pages.is_kept_page(1, self.official, "p2.jpg"))
        qc_kept_pages.snapshot_folder(self.folder, FakeDb(self.folder))
        stored = json.loads((qc_kept_pages.store_dir(1) / "kept.json").read_text(encoding="utf-8"))
        self.assertIn("ins.jpg", stored["pages"])
        self.assertNotIn("p2.jpg", stored["pages"])

    def test_a_tampered_lwip_name_cannot_move_files_outside_the_folder(self) -> None:
        png = io.BytesIO()
        Image.new("RGB", (30, 30)).save(png, "PNG")
        self.endpoint(
            self.folder, qc.replace_image, 1, 3, self.user, Mock(),
            sourceHash=HASH, file=UploadFile(io.BytesIO(png.getvalue()), filename="x.png"),
        )
        self.commit(self.folder)
        victim = self.official.parent / "victim.jpg"
        victim.write_bytes(b"keep me")
        kept = qc_kept_pages.store_dir(1) / "kept.json"
        data = json.loads(kept.read_text(encoding="utf-8"))
        data["pages"]["p3.png"]["lwip_name"] = "../victim.jpg"
        data["pages"]["../victim.jpg"] = {"kind": "inserted", "sha256": "0"}
        kept.write_text(json.dumps(data), encoding="utf-8")
        self.republish(recaptured=())
        self.restore()
        self.assertEqual(victim.read_bytes(), b"keep me")
        self.assertTrue((self.official / "p3.jpg").exists())  # not retired: the name was refused

    def test_a_truncated_store_copy_is_not_written_over_the_folder(self) -> None:
        self.qc_session()
        (qc_kept_pages.store_dir(1) / "pages" / "ins.jpg").write_bytes(b"trunc")
        self.republish()
        self.restore()
        self.assertFalse((self.official / "ins.jpg").exists())
        self.assertEqual([p.name for p in self.official.iterdir() if "kept_tmp" in p.name], [])

    def test_a_save_is_not_undone_by_a_restore_it_triggers(self) -> None:
        self.qc_session()
        (self.official / "ins.jpg").unlink()  # lost to a scan: no republish
        self.endpoint(
            self.folder, qc.rotate_qc_image, 1, 1,
            RotateImageRequest(sourceHash=HASH, degrees=90), self.user, Mock(),
        )
        self.commit(self.folder, self.db)
        self.assertEqual(
            self.saved_ops()["p1.jpg"]["ops"],
            [{"op": "rotate", "degrees": 90.0}, {"op": "rotate", "degrees": 90.0}],
        )
        self.assertEqual((self.official / "ins.jpg").read_bytes(), self.kept_bytes["ins.jpg"])

    def test_a_kept_page_on_disk_is_not_overwritten_without_a_republish(self) -> None:
        self.qc_session()
        (self.official / "qc_ops.json").unlink()  # forces a restore, marker unchanged
        newer = _jpeg(99)
        (self.official / "p3.jpg").write_bytes(newer)
        self.restore()
        self.assertEqual((self.official / "p3.jpg").read_bytes(), newer)

    def test_export_leaves_the_store_alone(self) -> None:
        self.qc_session()
        folder = SimpleNamespace(is_deleted=False, is_exported=False, group_id=None, qc_status="PASS")
        session = Mock()
        session.__enter__ = Mock(return_value=session)
        session.__exit__ = Mock(return_value=False)
        session.scalar.return_value = folder
        with patch.object(export, "SessionLocal", return_value=session):
            export.finalize_folder(1, "G1", True)
        self.assertTrue(folder.is_exported)
        self.assertTrue(qc_kept_pages.store_dir(1).exists())

    def test_the_rework_log_check_allows_for_millisecond_rounding(self) -> None:
        self.qc_session()
        kept = qc_kept_pages.store_dir(1) / "kept.json"
        data = json.loads(kept.read_text(encoding="utf-8"))
        data["snapshot_at"] = "2026-10-02T10:00:00.123100+00:00"
        kept.write_text(json.dumps(data), encoding="utf-8")
        self.republish()
        db = FakeDb(self.folder)
        qc_kept_pages.restore_after_republish(self.folder, db)
        bound = [v for s in db.statements for v in s.compile().params.values() if isinstance(v, datetime)]
        # A log stamped .1234 is stored as .123: it must still count.
        self.assertEqual(set(bound), {datetime.fromisoformat("2026-10-02T10:00:00.122000+00:00")})

    def test_pages_named_at_reject_time_are_recaptured_with_no_log_at_all(self) -> None:
        self.qc_session()
        qc_kept_pages.snapshot_folder(self.folder, FakeDb(self.folder), ["p1.jpg"])
        stored = json.loads((qc_kept_pages.store_dir(1) / "kept.json").read_text(encoding="utf-8"))
        self.assertEqual(stored["recaptured"], ["p1.jpg"])
        self.assertNotIn("p1.jpg", stored["qc_ops"]["images"])
        self.assertIn("p4.jpg", stored["qc_ops"]["images"])
        self.republish(recaptured=())
        self.restore(rework_image_ids=[])
        self.assertNotIn("p1.jpg", self.saved_ops())
        self.assertIn("p4.jpg", self.saved_ops())
        stored = json.loads((qc_kept_pages.store_dir(1) / "kept.json").read_text(encoding="utf-8"))
        self.assertEqual(stored["recaptured"], [])  # the next cycle starts clean

    def test_a_reject_fixed_without_a_republish_stops_excluding_the_page(self) -> None:
        self.qc_session()
        qc_kept_pages.snapshot_folder(self.folder, FakeDb(self.folder), ["p1.jpg"])
        self.restore()  # back to PENDING by a metadata-only fix: no republish
        self.endpoint(
            self.folder, qc.rotate_qc_image, 1, 1,
            RotateImageRequest(sourceHash=HASH, degrees=90), self.user, Mock(),
        )
        self.commit(self.folder, self.db)
        qc_drafts.discard_draft(1, USER)
        qc_kept_pages.snapshot_folder(self.folder, FakeDb(self.folder), ["p4.jpg"])
        self.republish(recaptured=("p4.jpg",))
        self.restore(rework_image_ids=[4])
        images = self.saved_ops()
        self.assertEqual(len(images["p1.jpg"]["ops"]), 2)
        self.assertNotIn("p4.jpg", images)

    def test_a_snapshot_does_not_re_read_a_kept_page_that_has_not_changed(self) -> None:
        self.qc_session()
        calls = []
        real = qc_kept_pages._file_sha
        with patch.object(qc_kept_pages, "_file_sha", lambda p: calls.append(p) or real(p)):
            qc_kept_pages.snapshot_folder(self.folder, FakeDb(self.folder))
        self.assertEqual(calls, [])

    def test_a_reject_after_a_client_rework_snapshots_first(self) -> None:
        self.qc_session()
        shutil.rmtree(qc_kept_pages.store_dir(1))  # nobody has saved since the revert
        self.folder.box.user_id = 5
        db = FakeDb(self.folder)
        request = RejectRequest(sourceHash=HASH, imageIds=[1], rejectReason="blurry")
        with patch.object(qc, "folder_or_404", return_value=self.folder), patch.object(
            qc, "verify_reviewable_folder"
        ), patch.object(qc, "cancel_ai_jobs_after_finalization"), patch.object(qc, "write_qc_audit"):
            qc.reject_task(1, request, self.user, db)
        stored = json.loads((qc_kept_pages.store_dir(1) / "kept.json").read_text(encoding="utf-8"))
        self.assertEqual(set(stored["pages"]), {"ins.jpg", "p3.jpg"})
        self.assertEqual(stored["recaptured"], ["p1.jpg"])
        log = next(obj for obj in db.added if hasattr(obj, "rework_type"))
        self.assertGreaterEqual(log.created_at, datetime.fromisoformat(stored["snapshot_at"]))
        # The rebuild that follows: pages come back, the rejected page starts fresh.
        self.republish(recaptured=())
        self.restore(rework_image_ids=[1])
        self.assertTrue((self.official / "ins.jpg").is_file())
        self.assertNotIn("p1.jpg", self.saved_ops())
        self.assertIn("p4.jpg", self.saved_ops())

    @unittest.skipUnless(os.name == "nt", "case-insensitive file names")
    def test_a_case_difference_with_the_manifest_does_not_make_pages_added(self) -> None:
        self.write_manifest("A", {n.upper(): b for n, b in self.originals.items()})
        self.assertFalse(qc_kept_pages.is_kept_page(1, self.official, "p2.jpg"))

    def test_the_store_goes_when_the_folder_is_split(self) -> None:
        self.qc_session()
        request = SeparationMarkersRequest(sourceHash=HASH, firstPageImageIds=[3])
        self.endpoint(self.folder, qc.update_separation_markers, 1, request, self.user, Mock())
        self.commit(self.folder, self.db)
        self.assertFalse(qc_kept_pages.store_dir(1).exists())


class SeparationMarkerTests(_Env):
    def setUp(self) -> None:
        super().setUp()
        self.folder = self.make_folder(["p1.jpg", "p2.jpg", "p3.jpg", "p4.jpg"])

    def put(self, ids: list[int]):
        request = SeparationMarkersRequest(sourceHash=HASH, firstPageImageIds=ids)
        return self.endpoint(self.folder, qc.update_separation_markers, 1, request, self.user, Mock())

    def stored(self) -> list[int]:
        return _draft_manifest()["separation_markers"]

    def test_page_one_is_implicit_and_empty_clears(self) -> None:
        self.put([3])
        self.assertEqual(self.stored(), [3])
        self.put([1, 3])  # an old client still sends page 1: ignored
        self.assertEqual(self.stored(), [3])
        self.put([])
        self.assertEqual(self.stored(), [])
        self.put([1])  # only the implicit start: nothing to split
        self.assertEqual(self.stored(), [])

    def test_unknown_page_is_refused(self) -> None:
        with self.assertRaises(BusinessError) as caught:
            self.put([99])
        self.assertEqual(caught.exception.http_status, 400)

    def test_page_one_reads_as_a_start_only_with_another_start(self) -> None:
        self.put([3])
        starts = {i.id: i.separationStart for i in qc.to_task_vo(_db(), self.folder, USER).images}
        self.assertEqual(starts, {1: True, 2: False, 3: True, 4: False})
        self.put([])
        self.assertFalse(any(i.separationStart for i in qc.to_task_vo(_db(), self.folder, USER).images))

    def test_save_splits_at_the_extra_start(self) -> None:
        self.put([3])
        separation = self.commit(self.folder)
        self.assertEqual([g.image_names for g in separation.groups], [("p1.jpg", "p2.jpg"), ("p3.jpg", "p4.jpg")])

    def test_a_mark_that_ended_up_on_page_one_means_no_split(self) -> None:
        self.put([3])
        self.endpoint(
            self.folder, qc.reorder_qc_images, 1,
            ReorderImagesRequest(sourceHash=HASH, imageIds=[3, 1, 2, 4]), self.user, Mock(),
        )
        self.assertIsNone(self.commit(self.folder))

    def test_insert_and_separation_in_the_same_save(self) -> None:
        self.endpoint(self.folder, qc.insert_image_before, 1, 3, self.user, Mock(), sourceHash=HASH, file=_upload("ins.jpg", 40))
        temp_id = next(i for i in _draft_manifest()["images"] if int(i) < 0)
        self.put([int(temp_id)])
        separation = self.commit(self.folder)
        first, second = separation.groups
        self.assertEqual(first.image_names, ("p1.jpg", "p2.jpg"))
        self.assertEqual(second.image_names, ("ins.jpg", "p3.jpg", "p4.jpg"))
        self.assertTrue((second.final_image_dir / "ins.jpg").is_file())
        self.assertTrue((second.final_thumbnail_dir / "ins.jpg").is_file())
        self.assertEqual([p.name for p in self.official.iterdir() if p.is_file()], [])

    def test_replacing_a_missing_page_and_splitting_in_one_save(self) -> None:
        (self.official / "p2.jpg").unlink()
        (self.thumbs / "p2.jpg").unlink()
        self.endpoint(self.folder, qc.replace_image, 1, 2, self.user, Mock(), sourceHash=HASH, file=_upload("r.jpg", 200))
        replacement = qc_drafts.draft_image_path(1, USER, 2).read_bytes()
        self.put([3])
        first = self.commit(self.folder).groups[0]
        self.assertEqual((first.final_image_dir / "p2.jpg").read_bytes(), replacement)
        self.assertTrue((first.final_thumbnail_dir / "p2.jpg").is_file())

    def test_a_folder_with_no_images_does_not_raise(self) -> None:
        self.folder.images = []
        self.put([])
        qc_drafts.set_separation_markers(1, USER, [3], [])
        self.assertEqual(qc.to_task_vo(_db(), self.folder, USER).images, [])

    def test_save_with_a_mark_left_on_page_one_does_not_lock_a_look_alike_folder(self) -> None:
        self.put([3])
        self.endpoint(
            self.folder, qc.reorder_qc_images, 1,
            ReorderImagesRequest(sourceHash=HASH, imageIds=[3, 1, 2, 4]), self.user, Mock(),
        )
        db = FakeDb(self.folder)
        shown = []
        with patch.object(qc, "folder_or_404", return_value=self.folder), patch.object(
            qc, "verify_reviewable_folder"
        ), patch.object(qc, "write_qc_audit"), patch.object(
            qc, "object_session", return_value=db
        ), patch.object(qc, "to_task_vo", side_effect=lambda _db, f, _u: shown.append(f)):
            qc.save_draft(1, ReviewRequest(sourceHash=HASH), self.user, db)
        self.assertEqual(shown, [self.folder])
        db.scalar.assert_not_called()

    def test_replace_and_edit_in_the_same_save_land_in_the_child(self) -> None:
        self.endpoint(self.folder, qc.replace_image, 1, 3, self.user, Mock(), sourceHash=HASH, file=_upload("r.jpg", 200))
        replacement = qc_drafts.draft_image_path(1, USER, 3).read_bytes()
        self.endpoint(
            self.folder, qc.rotate_qc_image, 1, 4,
            RotateImageRequest(sourceHash=HASH, degrees=90), self.user, Mock(),
        )
        self.put([3])
        separation = self.commit(self.folder)
        second = separation.groups[1]
        self.assertEqual((second.final_image_dir / "p3.jpg").read_bytes(), replacement)
        self.assertTrue((second.final_thumbnail_dir / "p3.jpg").is_file())
        # Nothing was written into the emptied parent.
        self.assertEqual([p.name for p in self.official.iterdir() if p.is_file()], [])
        self.assertEqual([p.name for p in self.thumbs.iterdir()], [])


if __name__ == "__main__":
    unittest.main()

"""Guards around client rework and stale drafts.

Each test fails without its fix:
- identity from the first CAPTURE filename, not the first page (insert-before-1);
- revert refuses a folder in capture REWORK;
- claim and admin force-release discard any draft left on the folder.

unittest.TestCase so they run with the shipped wheels alone; pytest collects them too.
"""

from __future__ import annotations

import unittest
from datetime import date
from types import SimpleNamespace
from unittest.mock import Mock, patch

from app.core.errors import BusinessError
from app.routers import admin, qc
from app.schemas.qc import RejectRequest, ReviewRequest
from app.services.export import ExportError, parse_source_identity


class SourceIdentityTests(unittest.TestCase):
    def test_identity_skips_a_page_inserted_before_page_one(self) -> None:
        user, day = parse_source_identity("scan.tif", "U1_IMG_20260804_142930_001.jpg")
        self.assertEqual((user, day), ("U1", date(2026, 8, 4)))

    def test_no_capture_filename_still_fails(self) -> None:
        with self.assertRaises(ExportError) as caught:
            parse_source_identity("scan.tif", "page2.tif")
        self.assertEqual(caught.exception.key, "sourceFilenameInvalid")


class RevertGuardTests(unittest.TestCase):
    def test_revert_refuses_capture_rework(self) -> None:
        folder = SimpleNamespace(id=7, qc_status="REWORK", qc_locked_by=None)
        request = ReviewRequest(sourceHash="0" * 64)
        with patch.object(qc, "folder_or_404", return_value=folder):
            with self.assertRaises(BusinessError) as caught:
                qc.revert_task(7, request, SimpleNamespace(id=1, user_id="rev"), Mock())
        self.assertEqual(caught.exception.http_status, 409)
        self.assertEqual(folder.qc_status, "REWORK")


class StaleDraftTests(unittest.TestCase):
    def test_claim_discards_a_leftover_draft(self) -> None:
        folder = SimpleNamespace(id=7, qc_status="PENDING", qc_locked_by=None, qc_locked_at=None)
        db = Mock()
        db.scalar.return_value = None
        with patch.object(qc, "project_ids_for_user", return_value=[1]), patch.object(
            qc, "folder_or_404", return_value=folder
        ), patch.object(qc, "to_task_vo", return_value=None), patch.object(
            qc, "write_qc_audit"
        ), patch.object(qc, "discard_draft") as discard:
            qc.claim_task(7, SimpleNamespace(id=1, user_id="rev"), db)
        discard.assert_called_once_with(7, "rev")
        self.assertEqual(folder.qc_locked_by, "rev")

    def test_admin_release_discards_the_holders_draft(self) -> None:
        folder = SimpleNamespace(id=7, qc_status="PENDING", qc_locked_by="rev", qc_locked_at=None, is_deleted=False, updated_at=None)
        db = Mock()
        db.scalar.return_value = folder
        with patch.object(admin, "discard_draft") as discard:
            admin.admin_release_qc_task(7, SimpleNamespace(id=1), db)
        discard.assert_called_once_with(7, "rev")
        self.assertIsNone(folder.qc_locked_by)


class SeparatedChildRejectionGuardTests(unittest.TestCase):
    """A child created by Separation has no recapture target LWCAM's rework
    loop can find (see CaptureFolder.separated_from_folder_id and migration
    005) - reject_task must refuse it outright rather than let a stray
    recapture folder get created, while approve stays open."""

    @staticmethod
    def _folder(**overrides) -> SimpleNamespace:
        image = SimpleNamespace(id=1, image_name="p1.jpg")
        base = dict(
            id=9,
            folder_path="",
            qc_status="PENDING",
            qc_locked_by="rev",
            qc_locked_at=None,
            qc_reviewed_by=None,
            separated_from_folder_id=None,
            images=[image],
            box=SimpleNamespace(user_id=42),
        )
        base.update(overrides)
        return SimpleNamespace(**base)

    def test_reject_refuses_a_separated_child(self) -> None:
        folder = self._folder(separated_from_folder_id=3)
        request = RejectRequest(sourceHash="0" * 64, imageIds=[1], rejectReason="blurry")
        with patch.object(qc, "folder_or_404", return_value=folder), patch.object(
            qc, "assert_lock_owner"
        ), patch.object(qc, "verify_reviewable_folder"):
            with self.assertRaises(BusinessError) as caught:
                qc.reject_task(9, request, SimpleNamespace(id=1, user_id="rev"), Mock())
        self.assertEqual(caught.exception.http_status, 400)
        # Refused before anything changed - still PENDING, still locked.
        self.assertEqual(folder.qc_status, "PENDING")
        self.assertEqual(folder.qc_locked_by, "rev")

    def test_reject_still_works_for_a_normal_folder(self) -> None:
        folder = self._folder(separated_from_folder_id=None)
        request = RejectRequest(sourceHash="0" * 64, imageIds=[1], rejectReason="blurry")
        with patch.object(qc, "folder_or_404", return_value=folder), patch.object(
            qc, "assert_lock_owner"
        ), patch.object(qc, "verify_reviewable_folder"), patch.object(
            qc, "read_manifest", return_value={}
        ), patch.object(qc, "cancel_ai_jobs_after_finalization"), patch.object(
            qc, "discard_draft"
        ), patch.object(qc, "write_qc_audit"), patch.object(qc, "effective_profile", return_value=None):
            qc.reject_task(9, request, SimpleNamespace(id=1, user_id="rev"), Mock())
        self.assertEqual(folder.qc_status, "REWORK")

    def test_approve_still_works_for_a_separated_child(self) -> None:
        folder = self._folder(separated_from_folder_id=3)
        request = ReviewRequest(sourceHash="0" * 64)
        with patch.object(qc, "folder_or_404", return_value=folder), patch.object(
            qc, "assert_lock_owner"
        ), patch.object(qc, "verify_reviewable_folder"), patch.object(
            qc, "read_manifest", return_value={}
        ), patch.object(qc, "metadata_template", return_value=Mock()), patch.object(
            qc, "effective_metadata_snapshot", return_value={}
        ), patch.object(qc, "validate_metadata_for_approval"), patch.object(
            qc, "visible_order", return_value=[1]
        ), patch.object(qc, "draft_image_item", return_value=None), patch.object(
            qc, "resolve_image_file"
        ), patch.object(
            qc, "commit_current_draft", return_value=(None, lambda: None, lambda: None)
        ), patch.object(qc, "cancel_ai_jobs_after_finalization"), patch.object(
            qc, "discard_draft"
        ), patch.object(qc, "write_qc_audit"), patch.object(qc, "effective_profile", return_value=None):
            qc.approve_task(9, request, SimpleNamespace(id=1, user_id="rev"), Mock())
        self.assertEqual(folder.qc_status, "PASS")

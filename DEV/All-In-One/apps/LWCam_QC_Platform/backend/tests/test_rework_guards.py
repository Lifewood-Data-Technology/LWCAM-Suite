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
from app.schemas.qc import ReviewRequest
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

"""Reviewer attribution: CaptureFolder.qc_reviewed_by and the dashboard
aggregate built on it.

Covers two things a stub dashboard cannot: that approve and reject are the
ONLY two of qc.py's four `qc_locked_by = None` sites that stamp the acting
reviewer (release must not - it is a hand-back, not a decision), and that
`reviewer_workload` turns that column into real per-user PASS/REWORK counts
instead of the old hardcoded 0/0/0.

unittest.TestCase, direct function calls, mocked db - the pattern
test_rework_guards.py already uses. No TestClient, no fixtures.
"""

from __future__ import annotations

import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

from app.routers import admin, qc
from app.models.user import User
from app.schemas.qc import RejectRequest, ReviewRequest


def _folder(**overrides) -> SimpleNamespace:
    image = SimpleNamespace(id=1, image_name="p1.jpg")
    base = dict(
        id=7,
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


class ApproveRejectAttributionTests(unittest.TestCase):
    """The two sites that must set qc_reviewed_by."""

    def test_approve_attributes_the_acting_reviewer(self) -> None:
        folder = _folder()
        request = ReviewRequest(sourceHash="0" * 64)
        db = Mock()
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
        ), patch.object(qc, "write_qc_audit"):
            qc.approve_task(7, request, SimpleNamespace(id=55, user_id="rev"), db)
        self.assertEqual(folder.qc_status, "PASS")
        self.assertIsNone(folder.qc_locked_by)
        self.assertEqual(folder.qc_reviewed_by, 55)

    def test_reject_attributes_the_acting_reviewer(self) -> None:
        folder = _folder()
        request = RejectRequest(sourceHash="0" * 64, imageIds=[1], rejectReason="blurry")
        db = Mock()
        with patch.object(qc, "folder_or_404", return_value=folder), patch.object(
            qc, "assert_lock_owner"
        ), patch.object(qc, "verify_reviewable_folder"), patch.object(
            qc, "read_manifest", return_value={}
        ), patch.object(qc, "cancel_ai_jobs_after_finalization"), patch.object(
            qc, "discard_draft"
        ), patch.object(qc, "write_qc_audit"):
            qc.reject_task(7, request, SimpleNamespace(id=77, user_id="rev"), db)
        self.assertEqual(folder.qc_status, "REWORK")
        self.assertIsNone(folder.qc_locked_by)
        self.assertEqual(folder.qc_reviewed_by, 77)

    def test_release_does_not_attribute_a_reviewer(self) -> None:
        """Release is a hand-back to the queue, not a decision - qc_reviewed_by
        must be left exactly as it was (unset, or a prior review's value)."""
        folder = _folder(qc_reviewed_by=None)
        db = Mock()
        with patch.object(qc, "folder_or_404", return_value=folder), patch.object(
            qc, "assert_lock_owner"
        ), patch.object(qc, "read_manifest", return_value={}), patch.object(
            qc, "cancel_manual_ai_after_release"
        ), patch.object(qc, "discard_draft"), patch.object(qc, "write_qc_audit"):
            qc.release_task(7, SimpleNamespace(id=1, user_id="rev"), db)
        self.assertIsNone(folder.qc_locked_by)
        self.assertIsNone(folder.qc_reviewed_by)


class ReviewerWorkloadTests(unittest.TestCase):
    """The extracted aggregate, called directly - no route, no auth dependency."""

    @staticmethod
    def _users(*rows: tuple[int, str, str]) -> Mock:
        """A db.execute result standing in for the user query.

        Real User instances, not tuples, because the function filters on
        `role_set` - the property that splits users.roles on commas. Mocking
        that away is how the multi-role undercount survived review: a test
        that hands back pre-filtered tuples cannot tell an `== 'qc'` match
        from a correct one.
        """
        users = []
        for user_id, name, roles in rows:
            user = User(user_id=name, roles=roles)
            user.id = user_id
            users.append(user)
        return Mock(scalars=Mock(return_value=Mock(all=Mock(return_value=users))))

    def test_counts_pass_and_rework_per_reviewer(self) -> None:
        db = Mock()
        db.execute.side_effect = [
            self._users((1, "alice", "qc"), (2, "bob", "qc")),
            Mock(all=Mock(return_value=[(1, "pass", 3), (1, "rework", 1), (2, "pass", 5)])),
        ]
        result = admin.reviewer_workload(db)
        self.assertEqual(
            result,
            [
                {"reviewerId": 1, "reviewerName": "alice", "total": 4, "approved": 3, "rejected": 1},
                {"reviewerId": 2, "reviewerName": "bob", "total": 5, "approved": 5, "rejected": 0},
            ],
        )

    def test_a_qc_user_with_no_reviewed_folders_yet_is_all_zero(self) -> None:
        db = Mock()
        db.execute.side_effect = [
            self._users((3, "carol", "qc")),
            Mock(all=Mock(return_value=[])),
        ]
        result = admin.reviewer_workload(db)
        self.assertEqual(
            result,
            [{"reviewerId": 3, "reviewerName": "carol", "total": 0, "approved": 0, "rejected": 0}],
        )

    def test_no_qc_users_is_an_empty_list(self) -> None:
        db = Mock()
        db.execute.side_effect = [self._users(), Mock(all=Mock(return_value=[]))]
        self.assertEqual(admin.reviewer_workload(db), [])

    def test_a_multi_role_qc_account_is_counted(self) -> None:
        """The undercount this filter used to cause.

        users.roles is comma-joined and 'qc,admin' is a normal account - it
        passes QcUser, claims folders and gets stamped into qc_reviewed_by.
        An equality match on the column dropped exactly those reviewers, so
        their work aggregated correctly and was then discarded.
        """
        db = Mock()
        db.execute.side_effect = [
            self._users((1, "alice", "qc"), (2, "dana", "qc,admin"), (3, "shawn", "capture,admin")),
            Mock(all=Mock(return_value=[(1, "pass", 2), (2, "pass", 7), (2, "rework", 1)])),
        ]
        result = admin.reviewer_workload(db)
        names = [row["reviewerName"] for row in result]
        self.assertEqual(names, ["alice", "dana"], "a qc,admin reviewer must be counted")
        self.assertNotIn("shawn", names, "an account without qc must not appear")
        dana = next(row for row in result if row["reviewerName"] == "dana")
        self.assertEqual((dana["total"], dana["approved"], dana["rejected"]), (8, 7, 1))


if __name__ == "__main__":
    unittest.main()


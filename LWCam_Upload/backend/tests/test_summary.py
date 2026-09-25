"""Upload_Summary.db3: one row per capture_id, upserted on re-upload.

Ported in spirit from QC's own upload_summary module (no dedicated test
existed there - `AGENTS.md` records the bucket-facing half of upload as
largely unexercised on that branch). Two things this app's contract calls
out specifically: the row is an UPSERT (a rework re-upload updates the same
row rather than duplicating it), and `normalize_rework` must be compared as
text, never through `bool()` (QC's own documented near-miss).
"""

from __future__ import annotations

import sqlite3
import unittest
from datetime import datetime
from pathlib import Path
from tempfile import TemporaryDirectory

from lwcam_upload import summary


class RecordUploadUpsertTests(unittest.TestCase):
    def test_second_upload_of_the_same_capture_id_updates_the_row(self) -> None:
        with TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "Upload_Summary.db3"
            summary.record_upload(
                db_path,
                capture_id="G1",
                title="First Title",
                image_count=4,
                rework="FALSE",
                size_bytes=1_000_000,
                duration_s=10.0,
                at=datetime(2026, 9, 25, 10, 0, 0),
            )
            summary.record_upload(
                db_path,
                capture_id="G1",
                title="First Title",
                image_count=4,
                rework="TRUE",
                size_bytes=2_000_000,
                duration_s=5.0,
                at=datetime(2026, 9, 25, 11, 0, 0),
            )

            connection = sqlite3.connect(db_path)
            try:
                rows = connection.execute(
                    "SELECT capture_id, rework, folder_size_mb FROM upload_summary"
                ).fetchall()
            finally:
                connection.close()

            self.assertEqual(len(rows), 1, "a re-upload must update the row, not duplicate it")
            self.assertEqual(rows[0], ("G1", "TRUE", 2.0))

    def test_distinct_capture_ids_get_distinct_rows(self) -> None:
        with TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "Upload_Summary.db3"
            for capture_id in ("G1", "G2"):
                summary.record_upload(
                    db_path,
                    capture_id=capture_id,
                    title="A Title",
                    image_count=1,
                    rework="FALSE",
                    size_bytes=1000,
                    duration_s=1.0,
                    at=datetime(2026, 9, 25),
                )
            connection = sqlite3.connect(db_path)
            try:
                count = connection.execute("SELECT COUNT(*) FROM upload_summary").fetchone()[0]
            finally:
                connection.close()
            self.assertEqual(count, 2)


class NormalizeReworkTests(unittest.TestCase):
    def test_true_and_false_are_upper_cased(self) -> None:
        self.assertEqual(summary.normalize_rework("true"), "TRUE")
        self.assertEqual(summary.normalize_rework("False"), "FALSE")

    def test_blank_and_none_are_none(self) -> None:
        self.assertIsNone(summary.normalize_rework(""))
        self.assertIsNone(summary.normalize_rework(None))

    def test_bool_of_the_text_false_would_be_true_which_is_the_bug_this_guards(self) -> None:
        # The reason normalize_rework's result is compared as text, never
        # through bool(): bool("FALSE") is True in Python.
        self.assertTrue(bool("FALSE"))
        self.assertEqual(summary.normalize_rework("FALSE"), "FALSE")
        self.assertNotEqual(summary.normalize_rework("FALSE"), "TRUE")


if __name__ == "__main__":
    unittest.main()

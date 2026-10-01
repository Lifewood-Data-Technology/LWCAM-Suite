"""The journal sweep that reports finished folders to the database.

Two properties, both learned the hard way in review:

1. An entry whose row has not synced yet (NOT_YET) must not block the entries
   behind it - the sweep moves on and still makes at most one write per poll.
2. Entries completed before reporting was switched on were LWCAM's to report
   and QC may have moved them on since; replaying them would reset PASS/REWORK
   folders to PENDING, so they are settled once, without a write.
"""

from __future__ import annotations

import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

from deskew_crop_tool import cloud_report
from deskew_crop_tool.orchestrator import MANIFEST_NAME, FolderOrchestrator, StateStore


class ReportSweepTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temp = tempfile.TemporaryDirectory()
        self.addCleanup(self._temp.cleanup)
        self.root = Path(self._temp.name)
        self.orchestrator = FolderOrchestrator.__new__(FolderOrchestrator)
        self.orchestrator.state = StateStore(self.root / "state.json")
        self.orchestrator._pg = object()  # anything not None: reporting is on
        self.orchestrator._waiting_logged = set()

    def add_completed(self, name: str) -> Path:
        source = self.root / "in" / name
        source.mkdir(parents=True)
        output = self.root / "out" / name
        output.mkdir(parents=True)
        (output / MANIFEST_NAME).write_text(
            json.dumps({"source_fingerprint": f"fp-{name}"}), encoding="utf-8"
        )
        self.orchestrator.state.data["completed"][str(source.resolve())] = {
            "fingerprint": f"fp-{name}",
            "output_folder": str(output.resolve()),
            "retry_required": False,
        }
        return source

    def sweep(self, results: list[cloud_report.ReportResult]) -> list[Path]:
        seen: list[Path] = []

        def fake_report(_pg, _manifest, output_folder: Path, **_kw):
            seen.append(output_folder)
            return results[len(seen) - 1]

        with mock.patch.object(cloud_report, "report_folder", fake_report):
            self.orchestrator._sweep_unreported()
        return seen

    def test_a_not_yet_entry_does_not_block_the_ones_behind_it(self) -> None:
        self.orchestrator.state.data["cloud_report_since"] = "already on"
        stuck = self.add_completed("stuck")
        ready = self.add_completed("ready")
        self.add_completed("later")

        seen = self.sweep([cloud_report.ReportResult.NOT_YET, cloud_report.ReportResult.REPORTED])

        self.assertEqual([p.name for p in seen], ["stuck", "ready"], "one write, then stop")
        self.assertIsNone(self.orchestrator.state.completed_record(stuck).get("reported_at"))
        self.assertIsNotNone(self.orchestrator.state.completed_record(ready).get("reported_at"))

    def test_an_entry_whose_output_a_later_run_replaced_is_settled(self) -> None:
        # The same capture processed twice - from C:\LWIP\1.Images, then from a
        # share - into ONE output folder: the manifest there is the second
        # run's, so the first entry can never report. Seen on 2026-09-29.
        self.orchestrator.state.data["cloud_report_since"] = "already on"
        old = self.add_completed("F")
        output = self.orchestrator.state.completed_record(old)["output_folder"]
        new = self.root / "share" / "F"
        new.mkdir(parents=True)
        self.orchestrator.state.data["completed"][str(new.resolve())] = {
            "fingerprint": "fp-new-run", "output_folder": output, "retry_required": False,
        }
        (Path(output) / MANIFEST_NAME).write_text(
            json.dumps({"source_fingerprint": "fp-new-run"}), encoding="utf-8"
        )

        seen = self.sweep([cloud_report.ReportResult.REPORTED])

        self.assertEqual(len(seen), 1, "only the run that owns the output reports")
        settled = self.orchestrator.state.completed_record(old)
        self.assertEqual(settled.get("reported_skip_reason"), "superseded")
        self.assertIsNotNone(self.orchestrator.state.completed_record(new).get("reported_at"))

    def test_a_mismatch_nobody_explains_keeps_waiting(self) -> None:
        # A re-run still publishing looks the same; never settle on a guess.
        self.orchestrator.state.data["cloud_report_since"] = "already on"
        entry = self.add_completed("F")
        output = Path(self.orchestrator.state.completed_record(entry)["output_folder"])
        (output / MANIFEST_NAME).write_text(json.dumps({"source_fingerprint": "unknown"}), encoding="utf-8")
        self.assertEqual(self.sweep([]), [])
        self.assertIsNone(self.orchestrator.state.completed_record(entry).get("reported_at"))

    def test_waiting_for_the_capture_record_is_logged_once(self) -> None:
        self.orchestrator.state.data["cloud_report_since"] = "already on"
        self.add_completed("F")
        with self.assertLogs("deskew_crop", "WARNING") as logs:
            self.sweep([cloud_report.ReportResult.NOT_YET])
            self.sweep([cloud_report.ReportResult.NOT_YET])
        self.assertEqual(len(logs.records), 1)
        self.assertIn("Not in the database yet", logs.output[0])

    def test_an_unreachable_database_ends_the_poll(self) -> None:
        self.orchestrator.state.data["cloud_report_since"] = "already on"
        self.add_completed("a")
        self.add_completed("b")
        seen = self.sweep([cloud_report.ReportResult.UNREACHABLE])
        self.assertEqual([p.name for p in seen], ["a"])

    def legacy_journal(self, completed_at: str | None) -> Path:
        """A journal written by a pre-reporting LWIP: an entry, no cloud_report_since."""
        source = self.root / "in" / "old"
        source.mkdir(parents=True)
        output = self.root / "out" / "old"
        output.mkdir(parents=True)
        (output / MANIFEST_NAME).write_text(json.dumps({"source_fingerprint": "fp-old"}), encoding="utf-8")
        entry = {"fingerprint": "fp-old", "output_folder": str(output.resolve()), "retry_required": False}
        if completed_at:
            entry["completed_at"] = completed_at
        (self.root / "legacy.json").write_text(
            json.dumps({"version": 1, "completed": {str(source.resolve()): entry}}), encoding="utf-8"
        )
        self.orchestrator.state = StateStore(self.root / "legacy.json")
        return source

    def test_entries_from_before_reporting_are_settled_without_a_write(self) -> None:
        old = self.legacy_journal("2020-01-01T00:00:00+00:00")
        self.assertFalse(self.orchestrator.state.data.get("cloud_report_since"))
        seen = self.sweep([])
        self.assertEqual(seen, [])
        record = self.orchestrator.state.completed_record(old)
        self.assertEqual(record.get("reported_skip_reason"), "predates_reporting")
        self.assertTrue(self.orchestrator.state.data.get("cloud_report_since"))
        # Survives a restart: the switch-on is in the journal, not in memory.
        reloaded = StateStore(self.root / "legacy.json")
        self.assertTrue(reloaded.data.get("cloud_report_since"))

        # And a folder finished AFTER the switch-on is reported normally.
        new = self.add_completed("new")
        seen = self.sweep([cloud_report.ReportResult.REPORTED])
        self.assertEqual([p.name for p in seen], ["new"])
        self.assertIsNotNone(self.orchestrator.state.completed_record(new).get("reported_at"))

    def test_legacy_journal_entry_finished_after_load_is_reported(self) -> None:
        # Old entries settle, but one completed after this process loaded the
        # journal and before the first sweep must not be swept under the rug.
        old = self.legacy_journal("2020-01-01T00:00:00+00:00")
        fresh = self.add_completed("fresh")
        self.orchestrator.state.data["completed"][str(fresh.resolve())]["completed_at"] = (
            datetime.now(timezone.utc).isoformat()
        )
        seen = self.sweep([cloud_report.ReportResult.REPORTED])
        self.assertEqual([p.name for p in seen], ["fresh"])
        self.assertEqual(
            self.orchestrator.state.completed_record(old).get("reported_skip_reason"),
            "predates_reporting",
        )

    def test_a_fresh_journal_reports_a_folder_finished_right_after_start(self) -> None:
        # No state file at all (new install, moved PC): nothing to defer to.
        self.assertTrue(self.orchestrator.state.data.get("cloud_report_since"))
        first = self.add_completed("first")
        seen = self.sweep([cloud_report.ReportResult.REPORTED])
        self.assertEqual([p.name for p in seen], ["first"])
        self.assertIsNone(self.orchestrator.state.completed_record(first).get("reported_skip_reason"))

    def test_a_recovered_journal_reports_adopted_entries(self) -> None:
        # state.json lost or corrupt: the fresh journal re-adopts folders, and
        # they must report (the UPDATE never moves a PASSed folder off PASS).
        (self.root / "state.json").write_text("{not json", encoding="utf-8")
        self.orchestrator.state = StateStore(self.root / "state.json")
        adopted = self.add_completed("adopted")
        seen = self.sweep([cloud_report.ReportResult.REPORTED])
        self.assertEqual([p.name for p in seen], ["adopted"])
        self.assertIsNotNone(self.orchestrator.state.completed_record(adopted).get("reported_at"))


if __name__ == "__main__":
    unittest.main()

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

    def test_an_unreachable_database_ends_the_poll(self) -> None:
        self.orchestrator.state.data["cloud_report_since"] = "already on"
        self.add_completed("a")
        self.add_completed("b")
        seen = self.sweep([cloud_report.ReportResult.UNREACHABLE])
        self.assertEqual([p.name for p in seen], ["a"])

    def test_entries_from_before_reporting_are_settled_without_a_write(self) -> None:
        old = self.add_completed("old")
        seen = self.sweep([])
        self.assertEqual(seen, [])
        record = self.orchestrator.state.completed_record(old)
        self.assertEqual(record.get("reported_skip_reason"), "predates_reporting")
        self.assertTrue(self.orchestrator.state.data.get("cloud_report_since"))
        # Survives a restart: the switch-on is in the journal, not in memory.
        reloaded = StateStore(self.root / "state.json")
        self.assertTrue(reloaded.data.get("cloud_report_since"))

        # And a folder finished AFTER the switch-on is reported normally.
        new = self.add_completed("new")
        seen = self.sweep([cloud_report.ReportResult.REPORTED])
        self.assertEqual([p.name for p in seen], ["new"])
        self.assertIsNotNone(self.orchestrator.state.completed_record(new).get("reported_at"))


if __name__ == "__main__":
    unittest.main()

"""StateStore prunes journal entries for vanished folders - but only when it can
actually see the input root. An unreachable share must not wipe the journal."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from deskew_crop_tool.orchestrator import StateStore


class StatePruneTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temp = tempfile.TemporaryDirectory()
        self.addCleanup(self._temp.cleanup)
        self.root = Path(self._temp.name)
        self.state_file = self.root / "state.json"

    def write_journal(self, *folders: Path) -> None:
        completed = {str(f.resolve()): {"fingerprint": "fp"} for f in folders}
        self.state_file.write_text(
            json.dumps({"version": 1, "completed": completed}), encoding="utf-8"
        )

    def test_missing_input_root_prunes_nothing(self) -> None:
        gone = self.root / "share" / "a"  # neither it nor its root exists
        self.write_journal(gone)
        before = self.state_file.stat().st_mtime_ns
        store = StateStore(self.state_file, self.root / "share")
        self.assertIn(str(gone.resolve()), store.data["completed"])
        self.assertEqual(self.state_file.stat().st_mtime_ns, before)

    def test_reachable_root_prunes_only_missing_folder(self) -> None:
        inp = self.root / "in"
        kept, gone = inp / "kept", inp / "gone"
        kept.mkdir(parents=True)
        self.write_journal(kept, gone)
        store = StateStore(self.state_file, inp)
        self.assertEqual(list(store.data["completed"]), [str(kept.resolve())])
        reloaded = json.loads(self.state_file.read_text(encoding="utf-8"))
        self.assertEqual(list(reloaded["completed"]), [str(kept.resolve())])

    def test_entry_outside_root_is_kept(self) -> None:
        inp = self.root / "in"
        inp.mkdir()
        elsewhere = self.root / "old_root" / "gone"  # missing, but not under inp
        self.write_journal(elsewhere)
        store = StateStore(self.state_file, inp)
        self.assertIn(str(elsewhere.resolve()), store.data["completed"])


if __name__ == "__main__":
    unittest.main()

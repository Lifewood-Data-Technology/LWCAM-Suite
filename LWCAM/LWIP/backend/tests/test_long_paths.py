"""Long folder names must publish.

A production folder is named from operator-typed metadata, so its name can be
long. LWIP then reproduces that name under the output root AND adds staging on
top of it — `.<folder>-<hash>.publishing` for the publish, `<folder>-<hash>`
under the work root for the staged output — so the paths it builds are always
longer than the paths it delivers. Past Windows' 260-character MAX_PATH the
failure was a bare `FileNotFoundError` naming a `.tmp` file, which reads like a
missing file rather than a name that is too long.

Measured on a real batch before the fix: a 135-character folder name published
fine from a short root and failed from `2.Batches\\YYYYMMDD\\`, at 265
characters.
"""

from __future__ import annotations

import os
import shutil
import tempfile
import unittest
from pathlib import Path

from deskew_crop_tool import image_ops
from deskew_crop_tool import orchestrator as orchestrator_module
from deskew_crop_tool.image_ops import fs_path
from deskew_crop_tool.orchestrator import FolderOrchestrator

# Discovery may root at `backend` (package `tests.`) or inside `tests` itself.
try:  # pragma: no cover - import shape only
    from tests.test_deskew_crop_tool import _config, _write_test_image
except ImportError:  # pragma: no cover
    from test_deskew_crop_tool import _config, _write_test_image


# Long enough that the publishing path overruns MAX_PATH from a temp root while
# the INPUT path still fits — which is exactly the production shape: capture
# writes the folder fine, publishing is what breaks.
_LONG_NAME = "L" * 180


def _temp_root(test: unittest.TestCase) -> Path:
    """A temp root cleaned up THROUGH fs_path.

    `tempfile.TemporaryDirectory` tears down with a plain `shutil.rmtree`,
    which cannot delete the very paths these tests exist to create — cleanup
    fails with `WinError 145` and surfaces as a test error rather than as a
    product failure.
    """
    root = Path(tempfile.mkdtemp())
    test.addCleanup(shutil.rmtree, fs_path(root), True)
    return root


class FsPathTests(unittest.TestCase):
    def test_non_windows_is_untouched(self) -> None:
        if os.name == "nt":
            self.skipTest("POSIX behaviour only")
        p = Path("/tmp/x")
        self.assertEqual(fs_path(p), p)

    def test_prefixes_a_local_path(self) -> None:
        if os.name != "nt":
            self.skipTest("Windows behaviour only")
        self.assertEqual(str(fs_path(Path(r"C:\a\b"))), r"\\?\C:\a\b")

    def test_is_idempotent(self) -> None:
        if os.name != "nt":
            self.skipTest("Windows behaviour only")
        once = fs_path(Path(r"C:\a\b"))
        self.assertEqual(fs_path(once), once)

    def test_normalises_before_prefixing(self) -> None:
        # The extended-length form rejects forward slashes and `..`, so they
        # have to be gone BEFORE the prefix goes on.
        if os.name != "nt":
            self.skipTest("Windows behaviour only")
        self.assertEqual(str(fs_path(Path("C:/a/b/../c"))), r"\\?\C:\a\c")

    def test_unc_uses_the_unc_form(self) -> None:
        if os.name != "nt":
            self.skipTest("Windows behaviour only")
        self.assertEqual(
            str(fs_path(Path(r"\\server\share\f"))), r"\\?\UNC\server\share\f"
        )

    def test_a_long_path_is_writable_only_through_fs_path(self) -> None:
        if os.name != "nt":
            self.skipTest("Windows behaviour only")
        deep = _temp_root(self) / _LONG_NAME / _LONG_NAME
        fs_path(deep).mkdir(parents=True)
        target = deep / "x.txt"
        self.assertGreater(len(str(target)), 260)
        with self.assertRaises(OSError):
            target.write_text("plain", encoding="utf-8")
        fs_path(target).write_text("prefixed", encoding="utf-8")
        self.assertEqual(fs_path(target).read_text(encoding="utf-8"), "prefixed")


class LongFolderPublishTests(unittest.TestCase):
    def _build(self, root: Path) -> tuple[FolderOrchestrator, Path]:
        folder = root / "incoming" / _LONG_NAME
        folder.mkdir(parents=True)
        _write_test_image(folder / "one.jpg", angle=6)
        config = _config(root)
        return FolderOrchestrator(config), folder

    def test_publishes_a_folder_whose_staging_path_exceeds_max_path(self) -> None:
        root = _temp_root(self)
        orchestrator, folder = self._build(root)

        staging = root / "output" / f".{_LONG_NAME}-0123456789ab.publishing"
        self.assertGreater(
            len(str(staging / ".one.jpg.99999.tmp")),
            260,
            "the scenario under test is no longer a long path",
        )

        self.assertEqual(orchestrator.run_once(), 1)

        published = root / "output" / _LONG_NAME
        self.assertTrue(fs_path(published / "one.jpg").is_file())
        self.assertTrue(fs_path(published / ".deskew_crop_manifest.json").is_file())
        # Staging is transient: a leftover means publish did not complete.
        leftovers = [
            p.name
            for p in fs_path(root / "output").iterdir()
            if p.name.startswith(".") and p.name.endswith(".publishing")
        ]
        self.assertEqual(leftovers, [])
        self.assertIsNotNone(orchestrator.state.completed_record(folder))

    def test_the_same_folder_fails_without_the_guard(self) -> None:
        """The negative control: with fs_path neutered this must NOT publish.

        Without it the test above would keep passing on a machine that happens
        to have LongPathsEnabled set, and would prove nothing.
        """
        if os.name != "nt":
            self.skipTest("MAX_PATH is a Windows limit")
        root = _temp_root(self)
        orchestrator, folder = self._build(root)

        identity = lambda path: path  # noqa: E731 - one-line stub
        original_orchestrator = orchestrator_module.fs_path
        original_image_ops = image_ops.fs_path
        orchestrator_module.fs_path = identity
        image_ops.fs_path = identity
        try:
            self.assertEqual(orchestrator.run_once(), 0)
        finally:
            orchestrator_module.fs_path = original_orchestrator
            image_ops.fs_path = original_image_ops

        self.assertIsNone(orchestrator.state.completed_record(folder))


class StopFileTests(unittest.TestCase):
    """The graceful-stop channel an upgrade uses.

    LWIP's SIGINT/SIGTERM handler is unreachable from outside on Windows
    (pythonw: no console, no window), so Setup used to overwrite a LIVE process
    instead of stopping it - which is how a station ran pre-upgrade code
    through two reinstalls while reporting a clean install.
    """

    def _orchestrator(self, root: Path) -> FolderOrchestrator:
        folder = root / "incoming" / "job"
        folder.mkdir(parents=True)
        _write_test_image(folder / "one.jpg", angle=6)
        config = _config(root)
        orchestrator = FolderOrchestrator(config)
        orchestrator._prepare_directories()
        return orchestrator

    def test_absent_stop_file_is_not_a_stop(self) -> None:
        orchestrator = self._orchestrator(_temp_root(self))
        self.assertFalse(orchestrator._stop_file_requested())

    def test_stop_file_is_consumed_on_read(self) -> None:
        # Deleted as it is READ, so a stale file cannot make every future start
        # exit immediately - that would stop image processing suite-wide with
        # nothing in the log to explain it.
        orchestrator = self._orchestrator(_temp_root(self))
        marker = orchestrator.config.work_root / orchestrator.STOP_FILE_NAME
        marker.write_text("", encoding="utf-8")
        self.assertTrue(orchestrator._stop_file_requested())
        self.assertFalse(marker.exists())
        self.assertFalse(orchestrator._stop_file_requested())

    def test_a_stop_request_from_before_startup_is_ignored(self) -> None:
        """The regression that took image processing down on a real station.

        Station Setup stops LWIP and then starts a replacement. Its first
        version left its own stop request on disk, so the new process read it
        and exited two milliseconds after logging "Watching" - processing dead
        suite-wide, one line in the log. A request can only be meant for a
        process that was already running, so one present at startup is stale.
        """
        root = _temp_root(self)
        orchestrator = self._orchestrator(root)
        marker = orchestrator.config.work_root / orchestrator.STOP_FILE_NAME
        marker.write_text("", encoding="utf-8")

        # run_once re-prepares, which clears it; the folder is processed.
        self.assertEqual(orchestrator.run_once(), 1)
        self.assertFalse(orchestrator.stop_requested)
        self.assertFalse(marker.exists())
        self.assertTrue((root / "output" / "job" / "one.jpg").is_file())

    def test_a_stop_drops_pending_work_and_the_next_run_redoes_it(self) -> None:
        """A dropped folder must come back. This is what makes stopping safe."""
        root = _temp_root(self)
        orchestrator = self._orchestrator(root)
        # Set on the instance rather than through a file, because a file
        # written before startup is now (correctly) treated as stale.
        orchestrator.stop_requested = True
        self.assertEqual(orchestrator.run_once(), 0)
        self.assertFalse((root / "output" / "job").exists())

        resumed = FolderOrchestrator(_config(root))
        self.assertEqual(resumed.run_once(), 1)
        self.assertTrue((root / "output" / "job" / "one.jpg").is_file())


if __name__ == "__main__":
    unittest.main()

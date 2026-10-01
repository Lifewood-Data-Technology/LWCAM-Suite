"""Client-rework republish must never leave the delivery without a package.

The old package is renamed aside and deleted only once the corrected one is in
place; a failure in between puts it back. Each test fails against the old
delete-first code.

unittest.TestCase so they run with the shipped wheels alone; pytest collects them too.
"""

from __future__ import annotations

import os
import time
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from app.services import export
from app.services.export import ExportedZip, ExportRuntimeConfig, publish_folder


def _config(root: Path) -> ExportRuntimeConfig:
    return ExportRuntimeConfig(
        temp_dir=root, output_dir=root / "out", encoding="utf-8",
        line_ending_name="LF", line_ending="\n", zip_output=False,
    )


def _package(path: Path, content: bytes) -> ExportedZip:
    path.mkdir(parents=True)
    (path / "page.tif").write_bytes(content)
    return ExportedZip(path=path, size=len(content), sha256="")


class PublishFolderReplaceTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.config = _config(self.root)
        self.final = self.root / "out" / "G1"
        self.final.mkdir(parents=True)
        (self.final / "page.tif").write_bytes(b"old")
        patcher = patch.object(export, "verify_published_folder")
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_replace_swaps_in_the_new_package_and_leaves_no_leftovers(self) -> None:
        built = _package(self.root / "built", b"new")
        publish_folder(built, "G1", self.config, 1, replace=True)
        self.assertEqual((self.final / "page.tif").read_bytes(), b"new")
        self.assertEqual([p.name for p in (self.root / "out").iterdir()], ["G1"])

    def test_without_replace_an_existing_package_is_a_conflict(self) -> None:
        built = _package(self.root / "built", b"new")
        with self.assertRaises(export.ExportError) as caught:
            publish_folder(built, "G1", self.config, 1)
        self.assertEqual(caught.exception.key, "folderConflict")
        self.assertEqual((self.final / "page.tif").read_bytes(), b"old")

    def test_failed_final_rename_keeps_the_old_package_under_its_name(self) -> None:
        built = _package(self.root / "built", b"new")
        real = os.replace

        def fail_into_final(src, dst):
            if ".old-" not in Path(src).name and Path(dst) == Path(export.fs_path(self.final)):
                raise OSError("simulated failure")
            return real(src, dst)

        with patch.object(export.os, "replace", side_effect=fail_into_final):
            with self.assertRaises(OSError):
                publish_folder(built, "G1", self.config, 1, replace=True)
        self.assertEqual((self.final / "page.tif").read_bytes(), b"old")
        self.assertEqual([p.name for p in (self.root / "out").iterdir()], ["G1"])

    def test_failed_verification_never_touches_the_old_package(self) -> None:
        built = _package(self.root / "built", b"new")
        with patch.object(export, "verify_published_folder", side_effect=export.ExportError("publishedFolderInvalid")):
            with self.assertRaises(export.ExportError):
                publish_folder(built, "G1", self.config, 1, replace=True)
        self.assertEqual((self.final / "page.tif").read_bytes(), b"old")

    def test_stale_asides_are_swept_and_fresh_ones_kept(self) -> None:
        staging = self.root / "out" / ".staging"
        staging.mkdir()
        old = staging / f"G0.old-{int(time.time()) - 2 * 86400}-abc"
        fresh = staging / f"G0.old-{int(time.time())}-def"
        for aside in (old, fresh):
            aside.mkdir()
        (self.root / "out" / "G0").mkdir()  # the final package is in place
        export._sweep_stale_asides(staging)
        self.assertFalse(old.exists())
        self.assertTrue(fresh.exists())

    def test_aside_is_kept_when_its_final_package_is_missing(self) -> None:
        staging = self.root / "out" / ".staging"
        staging.mkdir()
        old = staging / f"G0.old-{int(time.time()) - 2 * 86400}-abc"
        old.mkdir()
        export._sweep_stale_asides(staging)  # out/G0 does not exist
        self.assertTrue(old.exists())

    def test_zip_replace_retries_a_briefly_locked_target(self) -> None:
        source = self.root / "built.zip"
        source.write_bytes(b"zipdata")
        exported = ExportedZip(path=source, size=7, sha256=export.sha256_file(source))
        real = os.replace
        calls = {"n": 0}

        def flaky(src, dst):
            calls["n"] += 1
            if calls["n"] < 3:
                raise PermissionError("locked")
            return real(src, dst)

        with patch.object(export.os, "replace", side_effect=flaky), patch.object(export.time, "sleep"):
            path = export.publish_zip(exported, "G9", _config(self.root), replace=True)
        self.assertEqual(path.read_bytes(), b"zipdata")
        self.assertEqual(calls["n"], 3)


if __name__ == "__main__":
    unittest.main()

"""A split must carry LWIP's deskew/crop manifest into every child folder.

Verified on UAT: the manifest stayed in the (retained) parent, so children had
no baseline and their preview, thumbnails and export lost deskew/crop. Export
reads effective_ops(child_dir, name) too, so the effective_ops test covers it.
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from app.services.lwip_baseline import MANIFEST_NAME
from app.services.qc_ops_store import effective_ops
from app.services.qc_separation import SeparationFileTransaction, child_manifest

DESKEW = [{"op": "deskew", "degrees": 1.5}]
CROP = [{"op": "crop", "rect": [0, 0, 1, 1]}]


def _make_parent(root: Path, names=("p1.jpg", "p2.jpg", "p3.jpg", "p4.jpg")) -> tuple[Path, Path]:
    parent = root / "9155 parent"
    thumbs = parent / "thumbs"
    thumbs.mkdir(parents=True)
    for n in names:
        (parent / n).write_bytes(b"IMG" + n.encode())
        (thumbs / n).write_bytes(b"T" + n.encode())
    manifest = {
        "version": 1,
        "source_fingerprint": "fp",
        "created_at": "2026-01-01T00:00:00+00:00",
        "files": [
            {"relative_path": n, "sha256": "x", "qc_ops": DESKEW if i % 2 == 0 else CROP}
            for i, n in enumerate(names)
        ],
        "thumbnails": {
            "created": True,
            "dirname": "thumbs",
            "files": [{"relative_path": f"thumbs/{Path(n).stem}.jpg"} for n in names],
        },
    }
    (parent / MANIFEST_NAME).write_text(json.dumps(manifest), encoding="utf-8")
    return parent, thumbs


class SplitCarriesManifestTests(unittest.TestCase):
    def test_each_child_gets_only_its_own_entries_and_parent_keeps_its_own(self) -> None:
        with TemporaryDirectory() as temp:
            parent, thumbs = _make_parent(Path(temp))
            tx = SeparationFileTransaction(parent, thumbs, [["p1.jpg", "p2.jpg"], ["p3.jpg", "p4.jpg"]])
            tx.apply()
            for group, expected in zip(tx.groups, (["p1.jpg", "p2.jpg"], ["p3.jpg", "p4.jpg"])):
                data = json.loads((group.final_image_dir / MANIFEST_NAME).read_text(encoding="utf-8"))
                self.assertEqual([e["relative_path"] for e in data["files"]], expected)
                self.assertEqual(data["source_fingerprint"], "fp")
                self.assertEqual(
                    [e["relative_path"] for e in data["thumbnails"]["files"]],
                    [f"thumbs/{Path(n).stem}.jpg" for n in expected],
                )
            self.assertTrue((parent / MANIFEST_NAME).is_file())

    def test_child_effective_ops_equal_the_parents_baseline_before_the_split(self) -> None:
        with TemporaryDirectory() as temp:
            parent, thumbs = _make_parent(Path(temp))
            before = {n: effective_ops(parent, n) for n in ("p1.jpg", "p3.jpg")}
            tx = SeparationFileTransaction(parent, thumbs, [["p1.jpg", "p2.jpg"], ["p3.jpg", "p4.jpg"]])
            tx.apply()
            self.assertEqual(before, {"p1.jpg": DESKEW, "p3.jpg": DESKEW})
            self.assertEqual(effective_ops(tx.groups[0].final_image_dir, "p1.jpg"), before["p1.jpg"])
            self.assertEqual(effective_ops(tx.groups[1].final_image_dir, "p3.jpg"), before["p3.jpg"])

    def test_rollback_leaves_no_child_manifest(self) -> None:
        with TemporaryDirectory() as temp:
            parent, thumbs = _make_parent(Path(temp))
            tx = SeparationFileTransaction(parent, thumbs, [["p1.jpg", "p2.jpg"], ["p3.jpg", "p4.jpg"]])
            real = os.replace
            calls: list = []

            def flaky(src, dst):
                calls.append(src)
                if len(calls) == 2:  # second child's publish fails after the first succeeded
                    raise OSError("disk full")
                return real(src, dst)

            with patch("app.services.qc_separation.os.replace", flaky):
                with self.assertRaises(Exception):
                    tx.apply()
            self.assertEqual([p.name for p in Path(temp).iterdir()], ["9155 parent"])
            self.assertEqual(
                sorted(p.name for p in parent.iterdir()),
                sorted(["p1.jpg", "p2.jpg", "p3.jpg", "p4.jpg", "thumbs", MANIFEST_NAME]),
            )

    def test_qc_inserted_page_has_no_entry(self) -> None:
        with TemporaryDirectory() as temp:
            parent, thumbs = _make_parent(Path(temp), ("p1.jpg", "p2.jpg"))
            tx = SeparationFileTransaction(
                parent, thumbs, [["p1.jpg", "new.jpg"], ["p2.jpg"]], pending_names={"new.jpg"}
            )
            tx.apply()
            data = json.loads((tx.groups[0].final_image_dir / MANIFEST_NAME).read_text(encoding="utf-8"))
            self.assertEqual([e["relative_path"] for e in data["files"]], ["p1.jpg"])
            # a group of only QC-added pages gets no manifest at all
            self.assertIsNone(child_manifest({"files": [{"relative_path": "a.jpg"}]}, {"new.jpg"}))

    def test_fallback_thumbnail_is_rendered_with_the_baseline(self) -> None:
        with TemporaryDirectory() as temp:
            parent, thumbs = _make_parent(Path(temp), ("p1.jpg", "p2.jpg"))
            (thumbs / "p1.jpg").unlink()  # LWIP made no thumbnail for p1
            tx = SeparationFileTransaction(parent, thumbs, [["p1.jpg"], ["p2.jpg"]])
            with patch(
                "app.services.qc_separation.generate_thumbnail_file", return_value=Path("x")
            ) as gen:
                tx.apply()
            self.assertEqual(gen.call_args.args[2], DESKEW)


def _load_repair():
    path = Path(__file__).resolve().parents[1] / "repair_split_manifests.py"
    spec = importlib.util.spec_from_file_location("repair_split_manifests", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class RepairScriptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repair = _load_repair()

    def _broken_split(self, root: Path) -> tuple[Path, Path]:
        """What the OLD code left: children without a manifest, parent with one."""
        parent, thumbs = _make_parent(root)
        tx = SeparationFileTransaction(parent, thumbs, [["p1.jpg", "p2.jpg"], ["p3.jpg", "p4.jpg"]])
        tx.apply()
        for g in tx.groups:
            (g.final_image_dir / MANIFEST_NAME).unlink()
        return parent, tx.groups[1].final_image_dir

    def test_parent_name_inverse(self) -> None:
        from app.services.qc_separation import child_directory_path

        for name in ("9155 parent", "x_path", "a_001", "a_001_path"):
            child = child_directory_path(Path("/r") / name, 2)
            self.assertEqual(self.repair.parent_dir_name(child.name), name)
        self.assertIsNone(self.repair.parent_dir_name("plain"))

    def test_dry_run_then_write_then_idempotent(self) -> None:
        with TemporaryDirectory() as temp:
            _parent, child = self._broken_split(Path(temp))
            self.assertEqual(effective_ops(child, "p3.jpg"), [])  # the bug
            self.assertEqual(self.repair.repair_child_dir(child)[0], "would-repair")
            self.assertFalse((child / MANIFEST_NAME).exists())
            self.assertEqual(self.repair.repair_child_dir(child, write=True)[0], "repaired")
            self.assertEqual(effective_ops(child, "p3.jpg"), DESKEW)
            data = json.loads((child / MANIFEST_NAME).read_text(encoding="utf-8"))
            self.assertEqual([e["relative_path"] for e in data["files"]], ["p3.jpg", "p4.jpg"])
            self.assertEqual(self.repair.repair_child_dir(child, write=True)[0], "has-manifest")

    def test_rerendered_thumbnails_really_apply_the_baseline(self) -> None:
        from PIL import Image

        from app.services import previews

        with TemporaryDirectory() as temp:
            parent, thumbs = _make_parent(Path(temp), ("p1.jpg", "p2.jpg"))
            for n in ("p1.jpg", "p2.jpg"):
                Image.new("RGB", (400, 400), "white").save(parent / n)
            manifest = json.loads((parent / MANIFEST_NAME).read_text(encoding="utf-8"))
            for e in manifest["files"]:
                e["qc_ops"] = [{"op": "crop", "rect": [0, 0, 0.5, 0.5]}]
            (parent / MANIFEST_NAME).write_text(json.dumps(manifest), encoding="utf-8")
            tx = SeparationFileTransaction(parent, thumbs, [["p1.jpg"], ["p2.jpg"]])
            tx.apply()
            child = tx.groups[0].final_image_dir
            (child / MANIFEST_NAME).unlink()
            # the router normally installs the replay as an import side effect; the script must do it itself
            with patch.object(previews, "_replay", None):
                self.repair.repair_child_dir(child, child / "thumbs", write=True)
                with Image.open(child / "thumbs" / "p1.jpg") as t:
                    self.assertLess(t.width, 250)

    def test_failure_after_the_manifest_write_removes_it_so_a_rerun_retries(self) -> None:
        with TemporaryDirectory() as temp:
            _parent, child = self._broken_split(Path(temp))
            with patch("app.services.previews.generate_thumbnail_file", side_effect=RuntimeError("boom")):
                status, _ = self.repair_child_dir_with_thumbs(child)
            self.assertEqual(status, "unrepairable")
            self.assertFalse((child / MANIFEST_NAME).exists())
            self.assertEqual(self.repair.repair_child_dir(child, write=True)[0], "repaired")

    def repair_child_dir_with_thumbs(self, child):
        return self.repair.repair_child_dir(child, child / "thumbs", write=True)

    def test_manifest_from_further_up_keeps_only_pages_whose_sha_matches(self) -> None:
        import hashlib

        with TemporaryDirectory() as temp:
            parent, thumbs = _make_parent(Path(temp))
            manifest = json.loads((parent / MANIFEST_NAME).read_text(encoding="utf-8"))
            sha = lambda n: hashlib.sha256((parent / n).read_bytes()).hexdigest()
            for e in manifest["files"]:
                e["sha256"] = sha(e["relative_path"])
            manifest["files"][2]["sha256"] = "replaced-page"  # p3 was replaced in QC under the same name
            (parent / MANIFEST_NAME).write_text(json.dumps(manifest), encoding="utf-8")
            tx = SeparationFileTransaction(parent, thumbs, [["p1.jpg", "p2.jpg"], ["p3.jpg", "p4.jpg"]])
            tx.apply()
            grand = tx.groups[1].final_image_dir
            (grand / MANIFEST_NAME).unlink()
            # a middle level (a child that was split again) with no manifest of its own
            middle = grand.with_name("9155 parent_002_001")
            grand.rename(middle)
            self.assertEqual(self.repair.repair_child_dir(middle, write=True)[0], "repaired")
            data = json.loads((middle / MANIFEST_NAME).read_text(encoding="utf-8"))
            self.assertEqual([e["relative_path"] for e in data["files"]], ["p4.jpg"])

    def test_unrepairable_when_parent_or_manifest_is_gone(self) -> None:
        with TemporaryDirectory() as temp:
            parent, child = self._broken_split(Path(temp))
            (parent / MANIFEST_NAME).unlink()
            self.assertEqual(self.repair.repair_child_dir(child, write=True)[0], "unrepairable")
            self.assertFalse((child / MANIFEST_NAME).exists())
            self.assertEqual(self.repair.repair_child_dir(Path(temp) / "nope_001")[0], "unrepairable")


class RollbackErrorCollectionTests(unittest.TestCase):
    def test_a_manifest_that_cannot_be_removed_does_not_abort_the_rollback(self) -> None:
        from app.services.qc_separation import SeparationFileError

        with TemporaryDirectory() as temp:
            parent, thumbs = _make_parent(Path(temp))
            tx = SeparationFileTransaction(parent, thumbs, [["p1.jpg", "p2.jpg"], ["p3.jpg", "p4.jpg"]])
            tx.apply()
            real = Path.unlink

            def deny(self, *a, **k):
                if self.name == MANIFEST_NAME and self.parent.name.endswith("_002"):
                    raise PermissionError("denied")
                return real(self, *a, **k)

            with patch.object(Path, "unlink", deny):
                with self.assertRaises(SeparationFileError):
                    tx.rollback()
            # the first child was still put back
            self.assertTrue((parent / "p1.jpg").is_file())


if __name__ == "__main__":
    unittest.main()

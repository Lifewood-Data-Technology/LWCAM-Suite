"""Geometry edits must never be baked into the delivered page JPEG.

FamilySearch rejected the Taiping delivery for "image enhancement"; the root
cause was LWIP re-encoding every page. LWIP no longer bakes its own measured
straighten/crop either - it writes them as a deferred op list into its own
manifest instead, in the same schema a reviewer's own pending ops use (see
`services/lwip_baseline.py`). This module pins the contract end to end: LWIP's
baseline is read correctly, it layers with a reviewer's committed/pending ops
in the right order (`services/qc_ops_store.py`), a preview render actually
straightens a tilted page, an approval with only geometry pending leaves the
page file byte-for-byte untouched while recording the ops as data, restore
drops committed history back to the baseline, replace opts a page out of the
baseline entirely, and the export TIFF is where the whole chain finally
becomes pixels.

unittest.TestCase, like the rest of this tree, so `python -m unittest
discover` and pytest both collect it.
"""

from __future__ import annotations

import json
import unittest
from hashlib import sha256
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import Mock, patch

from PIL import Image, ImageDraw

from app.core.config import settings
from app.models.capture import CaptureBox, CaptureFolder, CaptureImage
from app.models.project import Device
from app.routers import qc  # noqa: F401 - import side effect registers previews' replay
from app.services import previews, qc_drafts
from app.services import geometry_ops
from app.services.export import convert_to_tiff
from app.services.geometry_ops import replay_pending_ops
from app.services.lwip_baseline import MANIFEST_NAME, baseline_ops
from app.services.qc_ops_store import (
    QC_OPS_NAME,
    committed_ops,
    effective_ops,
    ignore_lwip,
    read_qc_ops,
    write_image_ops,
)


def _write_manifest(folder: Path, files: list[dict]) -> None:
    (folder / MANIFEST_NAME).write_text(json.dumps({"version": 1, "files": files}), encoding="utf-8")


def _folder(folder_path: str, images: list[CaptureImage], thumbnail_path: str | None = None) -> CaptureFolder:
    folder = CaptureFolder(
        id=1, folder_name="folder", box_id=1, device_id=1, folder_seq=1,
        folder_path=folder_path, thumbnail_path=thumbnail_path, qc_locked_by="op",
    )
    folder.box = CaptureBox(box_id=1, box_name="box")
    folder.device = Device(device_id="DEV1")
    folder.images = images
    return folder


class BaselineOpsTests(unittest.TestCase):
    def test_reads_the_manifest_entry_for_this_image(self) -> None:
        with TemporaryDirectory() as temp:
            folder = Path(temp)
            _write_manifest(folder, [
                {"relative_path": "page1.jpg", "qc_ops": [{"op": "deskew", "degrees": 1.2}]},
                {"relative_path": "page2.jpg", "qc_ops": []},
            ])
            self.assertEqual(baseline_ops(folder, "page1.jpg"), [{"op": "deskew", "degrees": 1.2}])
            self.assertEqual(baseline_ops(folder, "page2.jpg"), [])

    def test_missing_manifest_or_entry_is_empty(self) -> None:
        with TemporaryDirectory() as temp:
            folder = Path(temp)
            self.assertEqual(baseline_ops(folder, "ghost.jpg"), [])
            _write_manifest(folder, [{"relative_path": "page1.jpg", "qc_ops": [{"op": "crop", "rect": [0, 0, 1, 1]}]}])
            self.assertEqual(baseline_ops(folder, "page2.jpg"), [])


class EffectiveOpsTests(unittest.TestCase):
    def test_layers_baseline_then_committed_then_pending_in_order(self) -> None:
        with TemporaryDirectory() as temp:
            folder = Path(temp)
            _write_manifest(folder, [{"relative_path": "page1.jpg", "qc_ops": [{"op": "deskew", "degrees": 1.5}]}])
            write_image_ops(folder, "page1.jpg", [{"op": "crop", "rect": [0.1, 0.1, 0.9, 0.9]}], False)
            pending = [{"op": "rotate", "degrees": 90.0}]
            self.assertEqual(
                effective_ops(folder, "page1.jpg", pending),
                [
                    {"op": "deskew", "degrees": 1.5},
                    {"op": "crop", "rect": [0.1, 0.1, 0.9, 0.9]},
                    {"op": "rotate", "degrees": 90.0},
                ],
            )

    def test_ignore_lwip_drops_the_baseline_only(self) -> None:
        with TemporaryDirectory() as temp:
            folder = Path(temp)
            _write_manifest(folder, [{"relative_path": "page1.jpg", "qc_ops": [{"op": "deskew", "degrees": 1.5}]}])
            write_image_ops(folder, "page1.jpg", [{"op": "crop", "rect": [0, 0, 1, 1]}], True)
            self.assertTrue(ignore_lwip(folder, "page1.jpg"))
            self.assertEqual(committed_ops(folder, "page1.jpg"), [{"op": "crop", "rect": [0, 0, 1, 1]}])
            self.assertEqual(effective_ops(folder, "page1.jpg"), [{"op": "crop", "rect": [0, 0, 1, 1]}])

    def test_read_qc_ops_is_tolerant_of_a_missing_or_corrupt_file(self) -> None:
        with TemporaryDirectory() as temp:
            folder = Path(temp)
            self.assertEqual(read_qc_ops(folder), {})
            (folder / QC_OPS_NAME).write_text("{not json", encoding="utf-8")
            self.assertEqual(read_qc_ops(folder), {})


class PreviewStraightensTiltedPageTests(unittest.TestCase):
    """A preview must replay LWIP's baseline, not just a reviewer's own ops."""

    def _leftmost_dark_x(self, image: Image.Image, y: int) -> int | None:
        pixels = image.load()
        for x in range(image.width):
            if sum(pixels[x, y][:3]) < 200:
                return x
        return None

    def test_manifest_deskew_straightens_the_render(self) -> None:
        angle = 10.0
        base = Image.new("RGB", (300, 400), "white")
        ImageDraw.Draw(base).rectangle([40, 20, 260, 380], fill="black")
        tilted = base.rotate(angle, expand=True, fillcolor="white")

        with TemporaryDirectory() as temp:
            folder = Path(temp)
            page = folder / "page1.jpg"
            tilted.save(page, format="JPEG", quality=100)
            rows = [tilted.height // 2 - 50, tilted.height // 2, tilted.height // 2 + 50]

            with patch.object(settings, "preview_cache_dir", str(folder / "cache")):
                untouched = Image.open(previews.generate_preview_image(page, []))
                tilted_spread = max(
                    x for x in (self._leftmost_dark_x(untouched, y) for y in rows) if x is not None
                ) - min(x for x in (self._leftmost_dark_x(untouched, y) for y in rows) if x is not None)

                # LWIP recorded the tilt it measured; replaying -angle is what
                # baseline_ops + the preview's own replay chain is for.
                straightened = Image.open(
                    previews.generate_preview_image(page, [{"op": "deskew", "degrees": angle}])
                )
                straight_spread = max(
                    x for x in (self._leftmost_dark_x(straightened, y) for y in rows) if x is not None
                ) - min(x for x in (self._leftmost_dark_x(straightened, y) for y in rows) if x is not None)

        # Tilted: the rectangle's left edge crosses these rows at noticeably
        # different x. Straightened: it is one vertical line again.
        self.assertGreater(tilted_spread, 10)
        self.assertLessEqual(straight_spread, 2)


class ApprovalNeverBakesGeometryTests(unittest.TestCase):
    """The core contract: a pending geometry-only edit must not touch pixels."""

    def test_approval_with_a_pending_rotate_leaves_the_page_bytes_identical(self) -> None:
        with TemporaryDirectory() as temp:
            official_dir = Path(temp) / "official"
            official_dir.mkdir()
            official_path = official_dir / "page1.jpg"
            official_path.write_bytes(b"CAMERA-ORIGINAL-BYTES")
            before = sha256(official_path.read_bytes()).hexdigest()
            image = CaptureImage(id=5, image_name="page1.jpg", file_format="jpg", device_id=1, folder_id=1)
            folder = _folder(str(official_dir), [image])

            with patch.object(settings, "qc_work_dir", str(Path(temp) / "work")):
                work_dir = qc_drafts.draft_dir(folder.id, "op") / "images"
                work_dir.mkdir(parents=True)
                work_path = work_dir / "5_page1.jpg"
                work_path.write_bytes(b"CAMERA-ORIGINAL-BYTES")
                manifest = qc_drafts.empty_manifest(folder.id, "op")
                manifest["images"]["5"] = {
                    "image_name": "page1.jpg",
                    "work_path": str(work_path),
                    "dirty": True,
                    "status": "edited",
                    "pending_ops": [{"op": "rotate", "degrees": 90.0}],
                }
                qc_drafts.write_manifest(folder.id, "op", manifest)

                with patch.object(qc, "object_session", return_value=Mock()):
                    _separation, finalize, _abort = qc.commit_current_draft(folder, "op")
                    finalize()

            after = sha256(official_path.read_bytes()).hexdigest()
            self.assertEqual(before, after, "the delivered page file must not be re-encoded")

            written = json.loads((official_dir / QC_OPS_NAME).read_text(encoding="utf-8"))
            self.assertEqual(
                written["images"]["page1.jpg"],
                {"ops": [{"op": "rotate", "degrees": 90.0}], "ignore_lwip": False},
            )

    def test_restore_then_approve_empties_committed_but_keeps_baseline(self) -> None:
        with TemporaryDirectory() as temp:
            official_dir = Path(temp) / "official"
            official_dir.mkdir()
            official_path = official_dir / "page1.jpg"
            official_path.write_bytes(b"CAMERA-ORIGINAL-BYTES")
            _write_manifest(official_dir, [{"relative_path": "page1.jpg", "qc_ops": [{"op": "deskew", "degrees": 2.0}]}])
            # A prior approval round had already committed a crop on top.
            write_image_ops(official_dir, "page1.jpg", [{"op": "crop", "rect": [0, 0, 1, 1]}], False)

            image = CaptureImage(id=5, image_name="page1.jpg", file_format="jpg", device_id=1, folder_id=1)
            folder = _folder(str(official_dir), [image])

            with patch.object(settings, "qc_work_dir", str(Path(temp) / "work")):
                manifest = qc_drafts.empty_manifest(folder.id, "op")
                manifest["images"]["5"] = {"restored": True}
                qc_drafts.write_manifest(folder.id, "op", manifest)

                with patch.object(qc, "object_session", return_value=Mock()):
                    _separation, finalize, _abort = qc.commit_current_draft(folder, "op")
                    finalize()

            self.assertEqual(committed_ops(official_dir, "page1.jpg"), [])
            self.assertFalse(ignore_lwip(official_dir, "page1.jpg"))
            # The baseline itself is LWIP's, untouched by a restore.
            self.assertEqual(baseline_ops(official_dir, "page1.jpg"), [{"op": "deskew", "degrees": 2.0}])
            self.assertEqual(effective_ops(official_dir, "page1.jpg"), [{"op": "deskew", "degrees": 2.0}])

    def test_insert_then_rotate_survives_approval(self) -> None:
        """A page inserted during QC, then rotated, must still be rotated in
        the export.

        The rotate lives in the draft's pending_ops and the preview replays it,
        so the reviewer sees it. Before the fix the insert branch published the
        work copy and wrote no qc_ops entry at all, so the ops died with the
        draft and the delivered TIFF was the bare upload.
        """
        with TemporaryDirectory() as temp:
            official_dir = Path(temp) / "official"
            official_dir.mkdir()
            folder = _folder(str(official_dir), [])

            with patch.object(settings, "qc_work_dir", str(Path(temp) / "work")):
                work_dir = qc_drafts.draft_dir(folder.id, "op") / "images"
                work_dir.mkdir(parents=True)
                work_path = work_dir / "-1_scan.jpg"
                work_path.write_bytes(b"INSERTED-UPLOAD-BYTES")
                manifest = qc_drafts.empty_manifest(folder.id, "op")
                manifest["images"]["-1"] = {
                    "image_name": "scan.jpg",
                    "official_path": None,
                    "work_path": str(work_path),
                    "dirty": True,
                    "status": "inserted",
                    "pending_ops": [{"op": "rotate", "degrees": 90.0}],
                }
                manifest["order"] = [-1]
                qc_drafts.write_manifest(folder.id, "op", manifest)

                with patch.object(qc, "object_session", return_value=Mock()):
                    _separation, finalize, _abort = qc.commit_current_draft(folder, "op")
                    finalize()

            self.assertEqual((official_dir / "scan.jpg").read_bytes(), b"INSERTED-UPLOAD-BYTES")
            self.assertEqual(committed_ops(official_dir, "scan.jpg"), [{"op": "rotate", "degrees": 90.0}])
            self.assertTrue(ignore_lwip(official_dir, "scan.jpg"))
            self.assertEqual(effective_ops(official_dir, "scan.jpg"), [{"op": "rotate", "degrees": 90.0}])

    def test_replace_then_rotate_survives_approval(self) -> None:
        """Same for a replaced page: the upload's bytes ship untouched, and the
        rotate ships as data beside them.

        Before the fix the replace branch applied pending ops only to a `baked`
        item (luminance's path) and then wrote `ops: []`, so a plain
        replace-and-rotate lost the rotate at approval.
        """
        with TemporaryDirectory() as temp:
            official_dir = Path(temp) / "official"
            official_dir.mkdir()
            official_path = official_dir / "page1.jpg"
            official_path.write_bytes(b"OLD-CAPTURE-BYTES")
            _write_manifest(official_dir, [{"relative_path": "page1.jpg", "qc_ops": [{"op": "deskew", "degrees": 3.0}]}])

            image = CaptureImage(id=5, image_name="page1.jpg", file_format="jpg", device_id=1, folder_id=1)
            folder = _folder(str(official_dir), [image])

            with patch.object(settings, "qc_work_dir", str(Path(temp) / "work")):
                work_dir = qc_drafts.draft_dir(folder.id, "op") / "images"
                work_dir.mkdir(parents=True)
                work_path = work_dir / "5_page1.jpg"
                work_path.write_bytes(b"NEW-CAPTURE-BYTES")
                manifest = qc_drafts.empty_manifest(folder.id, "op")
                manifest["images"]["5"] = {
                    "image_name": "page1.jpg",
                    "work_path": str(work_path),
                    "dirty": True,
                    "status": "replaced",
                    "pending_ops": [{"op": "rotate", "degrees": 180.0}],
                }
                qc_drafts.write_manifest(folder.id, "op", manifest)

                with patch.object(qc, "object_session", return_value=Mock()):
                    _separation, finalize, _abort = qc.commit_current_draft(folder, "op")
                    finalize()

            self.assertEqual(official_path.read_bytes(), b"NEW-CAPTURE-BYTES")
            self.assertEqual(committed_ops(official_dir, "page1.jpg"), [{"op": "rotate", "degrees": 180.0}])
            # Still opted out of LWIP's measurement of the OLD capture...
            self.assertTrue(ignore_lwip(official_dir, "page1.jpg"))
            # ...so the chain is the reviewer's rotate alone.
            self.assertEqual(effective_ops(official_dir, "page1.jpg"), [{"op": "rotate", "degrees": 180.0}])

    def test_replace_opts_the_new_capture_out_of_the_baseline(self) -> None:
        with TemporaryDirectory() as temp:
            official_dir = Path(temp) / "official"
            official_dir.mkdir()
            official_path = official_dir / "page1.jpg"
            official_path.write_bytes(b"OLD-CAPTURE-BYTES")
            _write_manifest(official_dir, [{"relative_path": "page1.jpg", "qc_ops": [{"op": "deskew", "degrees": 3.0}]}])
            write_image_ops(official_dir, "page1.jpg", [{"op": "crop", "rect": [0, 0, 1, 1]}], False)

            image = CaptureImage(id=5, image_name="page1.jpg", file_format="jpg", device_id=1, folder_id=1)
            folder = _folder(str(official_dir), [image])

            with patch.object(settings, "qc_work_dir", str(Path(temp) / "work")):
                work_dir = qc_drafts.draft_dir(folder.id, "op") / "images"
                work_dir.mkdir(parents=True)
                work_path = work_dir / "5_page1.jpg"
                work_path.write_bytes(b"NEW-CAPTURE-BYTES")
                manifest = qc_drafts.empty_manifest(folder.id, "op")
                manifest["images"]["5"] = {
                    "image_name": "page1.jpg",
                    "work_path": str(work_path),
                    "dirty": True,
                    "status": "replaced",
                }
                qc_drafts.write_manifest(folder.id, "op", manifest)

                with patch.object(qc, "object_session", return_value=Mock()):
                    _separation, finalize, _abort = qc.commit_current_draft(folder, "op")
                    finalize()

            self.assertEqual(official_path.read_bytes(), b"NEW-CAPTURE-BYTES")
            self.assertTrue(ignore_lwip(official_dir, "page1.jpg"))
            self.assertEqual(committed_ops(official_dir, "page1.jpg"), [])
            # LWIP's own measurement is still sitting in its manifest; it is
            # just no longer consulted for this (now different) capture.
            self.assertEqual(baseline_ops(official_dir, "page1.jpg"), [{"op": "deskew", "degrees": 3.0}])
            self.assertEqual(effective_ops(official_dir, "page1.jpg"), [])


class ConvertToTiffReplaysOpsTests(unittest.TestCase):
    def _capture(self, path: Path) -> None:
        frame = Image.new("RGB", (120, 90), (200, 200, 200))
        ImageDraw.Draw(frame).rectangle([10, 10, 60, 40], fill=(10, 10, 10))
        frame.save(path, format="JPEG", quality=100, subsampling=0)

    def test_with_ops_matches_a_direct_replay_of_the_source(self) -> None:
        with TemporaryDirectory() as temp:
            source = Path(temp) / "page.jpg"
            target = Path(temp) / "page.tif"
            self._capture(source)
            ops = [{"op": "rotate", "degrees": 90.0}, {"op": "crop", "rect": [0.1, 0.1, 0.9, 0.9]}]

            convert_to_tiff(source, target, ops)

            with Image.open(source) as decoded:
                expected = replay_pending_ops(decoded.copy(), ops).convert("RGB")
            with Image.open(target) as artifact:
                self.assertEqual(artifact.size, expected.size)
                self.assertEqual(artifact.convert("RGB").tobytes(), expected.tobytes())

    def test_with_no_ops_is_pixel_identical_to_the_source_decode(self) -> None:
        with TemporaryDirectory() as temp:
            source = Path(temp) / "page.jpg"
            target = Path(temp) / "page.tif"
            self._capture(source)

            convert_to_tiff(source, target)

            with Image.open(source) as decoded, Image.open(target) as artifact:
                self.assertEqual(decoded.convert("RGB").tobytes(), artifact.convert("RGB").tobytes())


def _marker_centroid(image: "Image.Image") -> tuple[float, float] | None:
    """Center of the red marker _asymmetric_page draws, for a geometry check
    independent of which resample filter blurred its edges."""
    import numpy as np

    array = np.array(image.convert("RGB"))
    mask = (array[:, :, 0] > 150) & (array[:, :, 1] < 100) & (array[:, :, 2] < 100)
    ys, xs = np.nonzero(mask)
    if len(xs) == 0:
        return None
    return float(xs.mean()), float(ys.mean())


def _asymmetric_page(size: tuple[int, int]) -> "Image.Image":
    """A page with no symmetry, so a placement bug shows up as a moved marker
    rather than an accidentally-identical mirror image."""
    width, height = size
    frame = Image.new("RGB", size, "white")
    draw = ImageDraw.Draw(frame)
    draw.rectangle([0, 0, width - 1, height - 1], outline="black", width=2)
    marker_w, marker_h = max(6, width // 10), max(6, height // 14)
    draw.ellipse([width // 8, height // 10, width // 8 + marker_w, height // 10 + marker_h], fill="red")
    return frame


class Cv2LanczosRotationTests(unittest.TestCase):
    """OpenCV replaces Pillow's BICUBIC for a non-quarter-turn rotate/deskew -
    see geometry_ops.py's module docstring - but the output canvas has to
    match Pillow's rotate(-degrees, expand=True) exactly: LWIP's manifest crop
    rects, and a reviewer's own, are normalised against that exact frame.
    """

    SIZES = [(640, 480), (1801, 1201)]
    ANGLES = [0.3, -0.3, 2.7, -2.7, 7.9, -7.9, 45.0]

    def test_output_size_matches_pillow_exactly(self) -> None:
        for size in self.SIZES:
            for degrees in self.ANGLES:
                with self.subTest(size=size, degrees=degrees):
                    frame = _asymmetric_page(size)
                    expected_size = frame.rotate(
                        -degrees, expand=True, resample=Image.Resampling.BICUBIC
                    ).size
                    result = replay_pending_ops(frame, [{"op": "deskew", "degrees": degrees}])
                    self.assertEqual(result.size, expected_size)

    def test_marker_lands_within_one_pixel_of_pillows_own_rotate(self) -> None:
        max_deviation = 0.0
        for size in self.SIZES:
            for degrees in self.ANGLES:
                with self.subTest(size=size, degrees=degrees):
                    frame = _asymmetric_page(size)
                    # NEAREST on both sides: this checks GEOMETRY (where the
                    # marker lands), not which filter blurs its edges more -
                    # that is the whole point of switching filters.
                    reference = frame.rotate(-degrees, expand=True, resample=Image.Resampling.NEAREST)
                    result = geometry_ops._rotate_cv2_lanczos(frame, degrees)
                    self.assertIsNotNone(result, "cv2 must be importable in this test environment")
                    ref_centroid = _marker_centroid(reference)
                    got_centroid = _marker_centroid(result)
                    self.assertIsNotNone(ref_centroid)
                    self.assertIsNotNone(got_centroid)
                    deviation = (
                        (ref_centroid[0] - got_centroid[0]) ** 2 + (ref_centroid[1] - got_centroid[1]) ** 2
                    ) ** 0.5
                    max_deviation = max(max_deviation, deviation)
                    self.assertLessEqual(
                        deviation, 1.0, f"marker moved {deviation:.3f}px at size={size} degrees={degrees}"
                    )
        # Surfaced for the terse report this task asked for - not asserted
        # beyond the per-case check above.
        print(f"\nmax centroid deviation across the grid: {max_deviation:.4f}px")

    def test_quarter_turns_still_go_through_pillow_unchanged(self) -> None:
        frame = _asymmetric_page((300, 200))
        for degrees in (90.0, -90.0, 180.0, 270.0):
            with self.subTest(degrees=degrees):
                expected = frame.rotate(-degrees, expand=True, resample=Image.Resampling.BICUBIC)
                result = replay_pending_ops(frame, [{"op": "rotate", "degrees": degrees}])
                self.assertEqual(result.size, expected.size)
                self.assertEqual(result.convert("RGB").tobytes(), expected.convert("RGB").tobytes())

    def test_falls_back_to_pillow_bicubic_when_cv2_is_unavailable(self) -> None:
        frame = _asymmetric_page((300, 200))
        degrees = 5.5
        expected = frame.rotate(-degrees, expand=True, resample=Image.Resampling.BICUBIC)
        with patch.object(geometry_ops, "cv2", None), patch.object(geometry_ops, "np", None), patch.object(
            geometry_ops, "_cv2_unavailable_logged", False
        ):
            result = replay_pending_ops(frame, [{"op": "deskew", "degrees": degrees}])
            self.assertEqual(result.size, expected.size)
            self.assertEqual(result.convert("RGB").tobytes(), expected.convert("RGB").tobytes())
            self.assertTrue(geometry_ops._cv2_unavailable_logged, "the fallback must log (once)")


if __name__ == "__main__":
    unittest.main()

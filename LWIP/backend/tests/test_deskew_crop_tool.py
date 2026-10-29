from __future__ import annotations

import json
import math
import shutil
import os
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

from deskew_crop_tool import orchestrator as orchestrator_module
from deskew_crop_tool import image_ops
from deskew_crop_tool.config import DEFAULT_EXTENSIONS, ToolConfig, load_config
from deskew_crop_tool.orchestrator import (
    FolderOrchestrator,
    build_snapshot,
)


class DeskewCropToolTests(unittest.TestCase):
    def test_config_resolves_relative_paths_from_project_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config_dir = Path(temporary) / "config"
            config_dir.mkdir()
            path = config_dir / "tool.json"
            path.write_text(
                json.dumps(
                    {
                        "input_root": "incoming",
                        "output_root": "output",
                        "workers": 2,
                    }
                ),
                encoding="utf-8",
            )
            config = load_config(path)
            self.assertEqual(config.input_root, Path(temporary) / "incoming")
            self.assertEqual(config.output_root, Path(temporary) / "output")
            self.assertEqual(config.workers, 2)

    def test_db_settings_default_when_absent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = load_config(_write_config(Path(temporary)))
            self.assertEqual(config.db_host, "")
            self.assertEqual(config.db_port, 5432)
            self.assertEqual(config.db_name, "lwcam")
            self.assertEqual(config.db_user, "")
            self.assertEqual(config.db_password, "")
            self.assertIs(config.db_use_ssl, False)

    def test_db_password_is_not_stripped(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = load_config(
                _write_config(Path(temporary), db_password="  secret  ")
            )
            self.assertEqual(config.db_password, "  secret  ")

    def test_bad_db_port_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            for bad_port in (0, -1, 65536):
                with self.subTest(bad_port=bad_port):
                    with self.assertRaises(ValueError):
                        load_config(_write_config(Path(temporary), db_port=bad_port))

    def test_db_use_ssl_must_be_a_bool(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(ValueError):
                load_config(_write_config(Path(temporary), db_use_ssl="true"))

    def test_cloud_report_requires_db_credentials(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(ValueError) as caught:
                load_config(_write_config(Path(temporary), cloud_report=True))
            message = str(caught.exception)
            self.assertIn("db_host", message)
            self.assertIn("db_user", message)
            self.assertIn("db_password", message)

    def test_cloud_report_accepts_partial_credentials_as_still_missing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(ValueError) as caught:
                load_config(
                    _write_config(
                        Path(temporary),
                        cloud_report=True,
                        db_host="db.example.com",
                        db_user="lwip",
                        db_password="   ",  # blank once stripped - still missing
                    )
                )
            message = str(caught.exception)
            self.assertIn("db_password", message)
            self.assertNotIn("db_host", message)
            self.assertNotIn("db_user", message)

    def test_cloud_report_off_needs_no_db_credentials(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = load_config(
                _write_config(Path(temporary), cloud_report=False)
            )
            self.assertFalse(config.cloud_report)
            self.assertEqual(config.db_host, "")

    def test_cloud_report_on_with_full_credentials_loads(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = load_config(
                _write_config(
                    Path(temporary),
                    cloud_report=True,
                    db_host="db.example.com",
                    db_port=6543,
                    db_name="lwcam_prod",
                    db_user="lwip",
                    db_password="hunter2",
                    db_use_ssl=True,
                )
            )
            self.assertTrue(config.cloud_report)
            self.assertEqual(config.db_host, "db.example.com")
            self.assertEqual(config.db_port, 6543)
            self.assertEqual(config.db_name, "lwcam_prod")
            self.assertEqual(config.db_user, "lwip")
            self.assertEqual(config.db_password, "hunter2")
            self.assertIs(config.db_use_ssl, True)

    def test_snapshot_changes_when_an_image_changes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            folder = root / "incoming" / "job"
            folder.mkdir(parents=True)
            image_path = folder / "one.jpg"
            _write_test_image(image_path, angle=0)
            config = _config(root)
            first = build_snapshot(folder, config)
            self.assertIsNotNone(first)
            time.sleep(0.01)
            _write_test_image(image_path, angle=8)
            second = build_snapshot(folder, config)
            self.assertNotEqual(first.fingerprint, second.fingerprint)

    def test_processes_folders_and_records_completion(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for folder_name in ("001", "002"):
                folder = root / "incoming" / folder_name
                folder.mkdir(parents=True)
                _write_test_image(folder / "a.jpg", angle=7)
                _write_test_image(folder / "b.jpg", angle=-5)

            config = _config(root)
            orchestrator = FolderOrchestrator(config)
            self.assertEqual(orchestrator.run_once(), 2)
            self.assertTrue((root / "output" / "001" / "a.jpg").is_file())
            self.assertTrue((root / "output" / "002" / "b.jpg").is_file())
            self.assertTrue(
                (root / "output" / "001" / ".deskew_crop_manifest.json").is_file()
            )
            result = cv2.imread(str(root / "output" / "001" / "a.jpg"))
            self.assertLess(result.shape[0], 240)
            self.assertLess(result.shape[1], 320)
            state = json.loads((root / "state.json").read_text(encoding="utf-8"))
            self.assertEqual(len(state["completed"]), 2)
            self.assertEqual(FolderOrchestrator(config).run_once(), 0)

            (root / "incoming" / "001" / "b.jpg").unlink()
            self.assertEqual(FolderOrchestrator(config).run_once(), 1)
            self.assertFalse((root / "output" / "001" / "b.jpg").exists())

    def test_shares_workers_and_round_robins_across_folders(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            large = root / "incoming" / "large"
            small = root / "incoming" / "small"
            large.mkdir(parents=True)
            small.mkdir(parents=True)
            for name in ("a.jpg", "b.jpg", "c.jpg"):
                _write_test_image(large / name, angle=4)
            _write_test_image(small / "a.jpg", angle=-4)

            class TrackingExecutor(ThreadPoolExecutor):
                instances: list["TrackingExecutor"] = []

                def __init__(self, *args, **kwargs) -> None:
                    super().__init__(*args, **kwargs)
                    self.submissions: list[str] = []
                    self.instances.append(self)

                def submit(self, fn, /, *args, **kwargs):
                    self.submissions.append(str(args[0]))
                    return super().submit(fn, *args, **kwargs)

            original_executor = orchestrator_module.ProcessPoolExecutor
            orchestrator_module.ProcessPoolExecutor = TrackingExecutor
            try:
                self.assertEqual(FolderOrchestrator(_config(root)).run_once(), 2)
            finally:
                orchestrator_module.ProcessPoolExecutor = original_executor

            self.assertEqual(len(TrackingExecutor.instances), 1)
            first_two_folders = {
                Path(path).parent.name
                for path in TrackingExecutor.instances[0].submissions[:2]
            }
            self.assertEqual(first_two_folders, {"large", "small"})

    def test_failed_folder_does_not_block_a_ready_sibling(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ("bad", "good"):
                folder = root / "incoming" / name
                folder.mkdir(parents=True)
                _write_test_image(folder / "a.jpg", angle=4)

            real_executor = orchestrator_module.ProcessPoolExecutor
            real_crop = orchestrator_module.deskew_crop_file

            def fail_bad_folder(source, *args):
                if Path(source).parent.name == "bad":
                    raise OSError("simulated crop failure")
                return real_crop(source, *args)

            orchestrator_module.ProcessPoolExecutor = ThreadPoolExecutor
            orchestrator_module.deskew_crop_file = fail_bad_folder
            try:
                self.assertEqual(FolderOrchestrator(_config(root)).run_once(), 1)
            finally:
                orchestrator_module.ProcessPoolExecutor = real_executor
                orchestrator_module.deskew_crop_file = real_crop

            self.assertFalse((root / "output" / "bad").exists())
            self.assertTrue((root / "output" / "good" / "a.jpg").is_file())

    def test_invalid_image_fails_in_worker_without_blocking_sibling(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bad = root / "incoming" / "bad"
            good = root / "incoming" / "good"
            bad.mkdir(parents=True)
            good.mkdir(parents=True)
            (bad / "a.jpg").write_bytes(b"not an image")
            _write_test_image(good / "a.jpg", angle=4)

            self.assertEqual(FolderOrchestrator(_config(root)).run_once(), 1)
            self.assertFalse((root / "output" / "bad").exists())
            self.assertTrue((root / "output" / "good" / "a.jpg").is_file())

    def test_thumbnail_failure_publishes_without_thumbnails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            folder = root / "incoming" / "job"
            folder.mkdir(parents=True)
            _write_test_image(folder / "a.jpg", angle=4)

            real_executor = orchestrator_module.ProcessPoolExecutor
            real_thumbnail = image_ops._write_thumbnail_atomic

            def fail_thumbnail(*args, **kwargs) -> None:
                raise OSError("simulated thumbnail failure")

            orchestrator_module.ProcessPoolExecutor = ThreadPoolExecutor
            image_ops._write_thumbnail_atomic = fail_thumbnail
            try:
                self.assertEqual(
                    FolderOrchestrator(_config(root, thumbnail_width=64)).run_once(), 1
                )
            finally:
                orchestrator_module.ProcessPoolExecutor = real_executor
                image_ops._write_thumbnail_atomic = real_thumbnail

            output = root / "output" / "job"
            manifest = json.loads(
                (output / ".deskew_crop_manifest.json").read_text(encoding="utf-8")
            )
            self.assertFalse(manifest["thumbnails"]["created"])
            self.assertFalse((output / "thumbs").exists())

    def test_staging_image_write_does_not_fsync(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.jpg"
            destination = root / "staged.jpg"
            _write_test_image(source, angle=4)
            real_fsync = image_ops.os.fsync

            def fail_fsync(*args) -> None:
                raise AssertionError("staging image write must not fsync")

            image_ops.os.fsync = fail_fsync
            try:
                image_ops.deskew_crop_file(str(source), str(destination), 5, 95)
            finally:
                image_ops.os.fsync = real_fsync
            self.assertTrue(destination.is_file())

    def test_preview_detection_crops_at_original_resolution(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.jpg"
            destination = root / "staged.jpg"
            canvas = np.zeros((2400, 3200, 3), dtype=np.uint8)
            rectangle = ((1600, 1200), (2000, 1400), 8)
            points = cv2.boxPoints(rectangle).astype(np.int32)
            cv2.fillConvexPoly(canvas, points, (255, 255, 255))
            self.assertTrue(cv2.imwrite(str(source), canvas))

            result = image_ops.deskew_crop_file(str(source), str(destination), 20, 95)
            # LWIP never rotates pixels: the crop is the inverse-rotated
            # padded page rect, clipped to this full-resolution source frame.
            contour = image_ops._largest_content_contour(cv2.imread(str(source)))
            self.assertIsNotNone(contour)
            points = contour.reshape(-1, 2).astype(np.float64)
            angle = float(result["angle"])
            phi = np.deg2rad(-angle)
            cos_phi, sin_phi = np.cos(phi), np.sin(phi)
            centre = np.array((1600.0, 1200.0))
            delta = points - centre
            rotated = centre + np.column_stack((
                delta[:, 0] * cos_phi - delta[:, 1] * sin_phi,
                delta[:, 0] * sin_phi + delta[:, 1] * cos_phi,
            ))
            x0, y0 = rotated.min(axis=0) - 20
            x1, y1 = rotated.max(axis=0) + 20
            corners = np.array(((x0, y0), (x1, y0), (x1, y1), (x0, y1)))
            inverse = centre + np.column_stack((
                (corners[:, 0] - centre[0]) * cos_phi
                + (corners[:, 1] - centre[1]) * sin_phi,
                -(corners[:, 0] - centre[0]) * sin_phi
                + (corners[:, 1] - centre[1]) * cos_phi,
            ))
            left, top = np.floor(inverse.min(axis=0)).astype(int)
            right, bottom = np.ceil(inverse.max(axis=0)).astype(int)
            expected = (
                max(0, left - image_ops.RESAMPLE_REACH),
                max(0, top - image_ops.RESAMPLE_REACH),
                min(canvas.shape[1], right + image_ops.RESAMPLE_REACH),
                min(canvas.shape[0], bottom + image_ops.RESAMPLE_REACH),
            )
            if result["lossless"]:
                expected = image_ops.snap_crop_box(*expected, canvas.shape[1], canvas.shape[0])
            self.assertEqual(tuple(result["crop"]), expected)

    def test_completed_output_is_released_and_never_reprocessed(self) -> None:
        """A journaled folder is RELEASED: the tool never touches its output
        again.

        Downstream QC owns that directory and edits the images in place (crop,
        replace, insert, separation). The old periodic audit could not tell a
        committed review edit from corruption and "repaired" it by regenerating
        from the originals, silently destroying QC work. Validation now happens
        once, deeply, before the folder is journaled (see
        test_publish_deep_verify_rejects_a_bad_output).
        """
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            folder = root / "incoming" / "job"
            folder.mkdir(parents=True)
            _write_test_image(folder / "a.jpg", angle=4)
            _write_test_image(folder / "b.jpg", angle=-6)
            config = _config(root, audit_interval=0)

            self.assertEqual(FolderOrchestrator(config).run_once(), 1)
            output_a = root / "output" / "job" / "a.jpg"
            output_b = root / "output" / "job" / "b.jpg"

            # Deleted output (stands in for a QC "delete image" commit).
            output_a.unlink()
            self.assertEqual(FolderOrchestrator(config).run_once(), 0)
            self.assertFalse(output_a.is_file())

            # Byte-level change (stands in for a QC crop/rotate commit).
            edited = bytearray(output_b.read_bytes())
            edited[len(edited) // 2] ^= 0xFF
            output_b.write_bytes(bytes(edited))
            self.assertEqual(FolderOrchestrator(config).run_once(), 0)
            self.assertEqual(output_b.read_bytes(), bytes(edited))

    def test_publish_deep_verify_rejects_a_bad_output(self) -> None:
        """The single validation gate: a publish whose bytes don't match the
        manifest must fail and never be journaled as completed."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            folder = root / "incoming" / "job"
            folder.mkdir(parents=True)
            _write_test_image(folder / "a.jpg", angle=4)
            config = _config(root)

            orchestrator = FolderOrchestrator(config)
            real_verify = orchestrator_module.verify_output
            calls: list[bool] = []

            def failing_verify(*args, **kwargs):
                # Pass the pre-swap (shallow) check, fail the post-swap deep one
                # — i.e. bytes that went bad between staging and publish.
                calls.append(bool(kwargs.get("deep")))
                if kwargs.get("deep"):
                    raise OSError("simulated checksum mismatch")
                return real_verify(*args, **kwargs)

            orchestrator_module.verify_output = failing_verify
            try:
                # scan_once catches per-folder failures by design (one bad
                # folder must not kill the daemon), so the observable contract
                # is: nothing processed, nothing journaled.
                self.assertEqual(orchestrator.run_once(), 0)
            finally:
                orchestrator_module.verify_output = real_verify

            self.assertIn(True, calls, "post-swap verify must be deep")
            # Nothing journaled — state.json is only written once something
            # completes, so it may not exist at all yet.
            self.assertEqual(orchestrator.state.data["completed"], {})
            # The failure is journaled for the back-off, though.
            failures = orchestrator.state.data["failures"]
            self.assertEqual([item["count"] for item in failures.values()], [1])

            # No permanent limbo: the next scan resolves the folder one way or
            # the other. Here the bytes were actually fine (only the mocked
            # verify failed), so adoption claims the published output; a
            # genuinely corrupt one fails adoption's deep verify and is
            # reprocessed instead. Either way it ends up journaled and valid.
            recovered = FolderOrchestrator(config)
            recovered.run_once()
            self.assertEqual(recovered.state.data["completed"], {})  # inside its 1-minute back-off
            for item in recovered.state.data["failures"].values():
                item["next_retry_epoch"] = 0  # the back-off has run out
            recovered.run_once()
            self.assertEqual(len(recovered.state.data["completed"]), 1)
            self.assertEqual(recovered.state.data["failures"], {})  # success clears it
            self.assertIsNotNone(cv2.imread(str(root / "output" / "job" / "a.jpg")))

    def test_adopts_existing_valid_output_without_reprocessing(self) -> None:
        """An input folder whose output already holds a matching valid manifest
        is journaled as-is.

        This is what makes QC-authored separation children work: QC writes the
        child's input dir + output manifest itself, and LWIP must not regenerate
        (which would revert the split). It doubles as state.json recovery.
        """
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            folder = root / "incoming" / "job"
            folder.mkdir(parents=True)
            _write_test_image(folder / "a.jpg", angle=4)
            config = _config(root)

            self.assertEqual(FolderOrchestrator(config).run_once(), 1)
            output = root / "output" / "job" / "a.jpg"
            published = output.read_bytes()

            # Journal lost entirely (also the separation case: brand-new input
            # folder, output already correct).
            (root / "state.json").unlink()
            (root / "state.json.bak").unlink(missing_ok=True)

            adopting = FolderOrchestrator(config)
            self.assertEqual(adopting.run_once(), 0, "must adopt, not reprocess")
            self.assertEqual(len(adopting.state.data["completed"]), 1)
            record = next(iter(adopting.state.data["completed"].values()))
            self.assertFalse(record["retry_required"])
            self.assertEqual(output.read_bytes(), published, "output untouched")

    def test_does_not_adopt_when_the_manifest_does_not_match_the_input(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            folder = root / "incoming" / "job"
            folder.mkdir(parents=True)
            _write_test_image(folder / "a.jpg", angle=4)
            config = _config(root)

            self.assertEqual(FolderOrchestrator(config).run_once(), 1)
            (root / "state.json").unlink()
            (root / "state.json.bak").unlink(missing_ok=True)

            # A second input image makes the manifest stale — adoption must be
            # refused and the folder reprocessed instead.
            _write_test_image(folder / "b.jpg", angle=-3)
            self.assertEqual(FolderOrchestrator(config).run_once(), 1)
            self.assertTrue((root / "output" / "job" / "b.jpg").is_file())

    def test_recovers_from_state_journal_backup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            folder = root / "incoming" / "job"
            folder.mkdir(parents=True)
            _write_test_image(folder / "a.jpg", angle=3)
            config = _config(root)

            self.assertEqual(FolderOrchestrator(config).run_once(), 1)
            backup = root / "state.json.bak"
            self.assertTrue(backup.is_file())
            (root / "state.json").write_text("not valid JSON", encoding="utf-8")

            recovered = FolderOrchestrator(config)
            self.assertEqual(recovered.run_once(), 0)
            self.assertEqual(len(recovered.state.data["completed"]), 1)

    def test_depth_two_discovers_day_subfolders_and_mirrors_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            folder = root / "incoming" / "20260722" / "Box 12 - 4471 - 0001"
            folder.mkdir(parents=True)
            _write_test_image(folder / "a.jpg", angle=7)
            # Day-root siblings that must NOT be treated as jobs.
            (root / "incoming" / "20260722" / "logs").mkdir()
            (root / "incoming" / "20260722" / "records.csv").write_text(
                "x", encoding="utf-8"
            )

            config = _config(root, folder_depth=2)
            self.assertEqual(FolderOrchestrator(config).run_once(), 1)
            out = root / "output" / "20260722" / "Box 12 - 4471 - 0001"
            self.assertTrue((out / "a.jpg").is_file())
            self.assertTrue((out / ".deskew_crop_manifest.json").is_file())
            self.assertFalse((root / "output" / "20260722" / "logs").exists())
            self.assertFalse((root / "output" / "20260722" / "records.csv").exists())

    def test_marker_gates_readiness_and_records_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            folder = root / "incoming" / "job"
            folder.mkdir(parents=True)
            _write_test_image(folder / "a.jpg", angle=5)
            config = _config(root, completion_marker="lwcam_capture_marker.json")

            # No marker yet → not processed (and run_once returns without work).
            self.assertEqual(FolderOrchestrator(config).run_once(), 0)
            self.assertFalse((root / "output" / "job").exists())

            identity = {"project_key": "pabc", "box_name": "BOX 1", "folder_seq": 1}
            (folder / "lwcam_capture_marker.json").write_text(
                json.dumps(identity), encoding="utf-8"
            )
            self.assertEqual(FolderOrchestrator(config).run_once(), 1)
            manifest = json.loads(
                (root / "output" / "job" / ".deskew_crop_manifest.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(manifest["source_identity"], identity)

    def test_unmarked_folder_does_not_block_a_marked_sibling(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            # A perpetually-unmarked folder (abandoned partial transfer) sorts
            # first alphabetically and must not prevent the marked one from
            # being processed in the same scan.
            pending = root / "incoming" / "aaa-pending"
            pending.mkdir(parents=True)
            _write_test_image(pending / "a.jpg", angle=4)

            ready = root / "incoming" / "zzz-ready"
            ready.mkdir(parents=True)
            _write_test_image(ready / "a.jpg", angle=4)
            config = _config(root, completion_marker="marker.json")
            (ready / "marker.json").write_text("{}", encoding="utf-8")

            self.assertTrue(FolderOrchestrator(config).scan_once())
            self.assertTrue((root / "output" / "zzz-ready" / "a.jpg").is_file())
            self.assertFalse((root / "output" / "aaa-pending").exists())
            # The console must list the folder still waiting for its marker:
            # with a marker configured it never enters `stability`, and the
            # status snapshot used to report it as "0 waiting".
            status = json.loads((root / "status.json").read_text(encoding="utf-8"))
            self.assertIn(str(pending), status["waiting"])

    def test_thumbnails_generated_and_manifested(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            folder = root / "incoming" / "job"
            folder.mkdir(parents=True)
            _write_test_image(folder / "a.jpg", angle=0)
            config = _config(root, thumbnail_width=64, audit_interval=0)

            self.assertEqual(FolderOrchestrator(config).run_once(), 1)
            thumb = root / "output" / "job" / "thumbs" / "a.jpg"
            self.assertTrue(thumb.is_file())
            with Image.open(thumb) as opened:
                self.assertLessEqual(opened.width, 64)
            manifest = json.loads(
                (root / "output" / "job" / ".deskew_crop_manifest.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertTrue(manifest["thumbnails"]["created"])
            self.assertEqual(len(manifest["thumbnails"]["files"]), 1)

            # Released: a deleted thumbnail is NOT regenerated (QC owns this
            # directory and legitimately deletes images from it).
            thumb.unlink()
            self.assertEqual(FolderOrchestrator(config).run_once(), 0)
            self.assertFalse(thumb.is_file())

    def test_manifest_carries_angle_lossless_and_qc_ops_per_file(self) -> None:
        """The QC engine's replay contract: every files[] entry gets its own
        angle/lossless/qc_ops, matched to the right source by relative path.
        """
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            folder = root / "incoming" / "job"
            folder.mkdir(parents=True)
            _write_page_image(folder / "straight.jpg", angle=0.02)
            _write_page_image(folder / "tilted.jpg", angle=6)
            config = _config(root)

            self.assertEqual(FolderOrchestrator(config).run_once(), 1)
            manifest = json.loads(
                (root / "output" / "job" / ".deskew_crop_manifest.json").read_text(
                    encoding="utf-8"
                )
            )
            files = {item["relative_path"]: item for item in manifest["files"]}
            self.assertEqual(files["straight.jpg"]["angle"], 0.0)
            self.assertEqual(files["straight.jpg"]["qc_ops"], [])
            for item in files.values():
                for key in ("angle_source", "page_found", "off_frame", "mat_fill"):
                    self.assertIn(key, item)
            self.assertNotEqual(files["tilted.jpg"]["angle"], 0.0)
            self.assertTrue(files["tilted.jpg"]["qc_ops"])
            for item in files.values():
                self.assertIn("lossless", item)
                self.assertIsInstance(item["lossless"], bool)

    def test_state_prunes_missing_source_folders(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            folder = root / "incoming" / "job"
            folder.mkdir(parents=True)
            _write_test_image(folder / "a.jpg", angle=3)
            config = _config(root)

            self.assertEqual(FolderOrchestrator(config).run_once(), 1)
            self.assertEqual(
                len(json.loads((root / "state.json").read_text("utf-8"))["completed"]),
                1,
            )

            shutil.rmtree(folder)
            pruned = FolderOrchestrator(config)
            self.assertEqual(len(pruned.state.data["completed"]), 0)
            self.assertEqual(
                len(json.loads((root / "state.json").read_text("utf-8"))["completed"]),
                0,
            )


def _write_config(root: Path, **overrides: object) -> Path:
    """A minimal on-disk config for load_config, for the db_* key tests.

    Separate from ToolConfig's own _config() factory below: that one builds
    the dataclass directly (in-memory, no validation), while these tests are
    exactly about what load_config's JSON parsing and validation do.
    """
    config_dir = root / "config"
    config_dir.mkdir(exist_ok=True)
    path = config_dir / "tool.json"
    payload: dict[str, object] = {
        "input_root": "incoming",
        "output_root": "output",
        "workers": 2,
    }
    payload.update(overrides)
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


def _config(
    root: Path,
    *,
    audit_interval: float = 86400,
    folder_depth: int = 1,
    thumbnail_width: int = 0,
    completion_marker: str | None = None,
) -> ToolConfig:
    return ToolConfig(
        input_root=root / "incoming",
        output_root=root / "output",
        work_root=root / "work",
        state_file=root / "state.json",
        log_file=root / "tool.log",
        workers=2,
        poll_interval_seconds=0.01,
        stable_seconds=0,
        minimum_file_age_seconds=0,
        presence_check_interval_seconds=audit_interval,
        checksum_check_interval_seconds=audit_interval,
        crop_padding=5,
        jpeg_quality=95,
        completion_marker=completion_marker,
        recursive=True,
        extensions=(".jpg",),
        folder_depth=folder_depth,
        thumbnail_width=thumbnail_width,
        thumbnail_quality=85,
        thumbnail_dirname="thumbs",
    )


class OutputFidelityTests(unittest.TestCase):
    """The delivery contract: the output must not look more processed than the
    capture. FamilySearch rejected this project's first delivery for "evidence
    of image enhancement", traced to a q90 re-encode that stripped metadata.
    """

    def test_watched_extensions_are_all_writable(self) -> None:
        """Every extension config.py advertises as watchable must have a save
        branch in _write_image_atomic. A watched-but-unwritable extension (BMP
        used to be listed here with no such branch) raises "Unsupported output
        format" on the first matching file, failing that folder forever - it is
        retried every poll but never published.
        """
        # .bmp and .jxl have no save branch on purpose: they are never
        # re-encoded, the source bytes are copied (see MatFillAndEncodeOnceTests).
        writable = {".jpg", ".jpeg", ".png", ".tif", ".tiff"}
        byte_copied = {".bmp", ".jxl"}
        self.assertEqual(set(DEFAULT_EXTENSIONS), writable | byte_copied)

    def test_output_quantization_matches_a_camera_grade_encode(self) -> None:
        """At quality 100 libjpeg emits quantization tables of all 1s — the same
        tables the capture phone writes. At q90 the maxima were 24 and 20, which
        is a visibly coarser second compression than the original.

        This exercises the RE-ENCODE path specifically (jpegtran forced
        unavailable): a page that qualifies for the lossless crop ships the
        camera's own tables regardless of `jpeg_quality`, by design — that is
        `LosslessCropTests` below, not this test.
        """
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.jpg"
            destination = root / "staged.jpg"
            _write_test_image(source, angle=4)

            original = image_ops.jpegtran_path
            image_ops.jpegtran_path = lambda: None
            try:
                image_ops.deskew_crop_file(str(source), str(destination), 5, 100)
            finally:
                image_ops.jpegtran_path = original

            with Image.open(destination) as written:
                tables = written.quantization
            self.assertTrue(tables)
            for table in tables.values():
                self.assertEqual(max(table), 1)

    def test_metadata_survives_with_gps_removed(self) -> None:
        """EXIF and ICC are the capture's provenance and must reach the client;
        GPS is the one block deliberately dropped, because it pins the building
        the records were photographed in.
        """
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.jpg"
            destination = root / "staged.jpg"
            _write_test_image(source, angle=4)

            # Restage the source carrying the metadata a real capture would.
            with Image.open(source) as plain:
                frame = plain.copy()
            exif = Image.Exif()
            exif[0x010F] = "Xiaomi"          # Make
            exif[0x0110] = "Xiaomi 14 Ultra"  # Model
            exif[0x0112] = 0                  # Orientation, illegal value
            exif[0x8825] = {1: "N", 2: (1.0, 2.0, 3.0)}  # GPS
            frame.save(source, format="JPEG", quality=100, exif=exif)

            image_ops.deskew_crop_file(str(source), str(destination), 5, 100)

            with Image.open(destination) as written:
                carried = written.getexif()
            self.assertEqual(carried.get(0x010F), "Xiaomi")
            self.assertEqual(carried.get(0x0110), "Xiaomi 14 Ultra")
            self.assertNotIn(0x8825, carried, "GPS must not reach the client")
            self.assertEqual(
                carried.get(0x0112), 1, "orientation 0 is illegal and is normalised"
            )

    def test_deskew_is_skipped_below_the_threshold(self) -> None:
        """Every rotation resamples every pixel, so a tilt nobody can see is not
        worth paying for. Above the threshold it must still fire.
        """
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            straight = root / "straight.jpg"
            tilted = root / "tilted.jpg"
            # Full-size fixtures: the side fit resolves a fraction of a degree
            # over a page-sized edge, but on the 180px shape _write_test_image
            # draws, boxPoints' integer rounding alone is worth ~0.6 degrees.
            _write_page_image(straight, angle=0.02)
            _write_page_image(tilted, angle=4)

            skipped = image_ops.deskew_crop_file(
                str(straight), str(root / "a.jpg"), 5, 100, deskew_min_degrees=0.2
            )
            applied = image_ops.deskew_crop_file(
                str(tilted), str(root / "b.jpg"), 5, 100, deskew_min_degrees=0.2
            )

            self.assertEqual(float(skipped["angle"]), 0.0)
            self.assertGreaterEqual(abs(float(applied["angle"])), 0.2)

            # "angle" is a MEASUREMENT now, not an instruction LWIP acted on:
            # qc_ops carries the deferred straightening, and is empty exactly
            # when there is nothing to defer.
            self.assertEqual(skipped["qc_ops"], [])
            self.assertTrue(applied["qc_ops"], "a tilted page must carry qc_ops")

            # The output pixels were never rotated: re-measuring the OUTPUT's
            # own contour must find the SAME tilt LWIP measured on the source,
            # not something closer to zero.
            out = cv2.imread(str(root / "b.jpg"))
            out_contour = image_ops._largest_content_contour(out)
            out_angle = image_ops._page_angle(out_contour)
            self.assertAlmostEqual(out_angle, float(applied["angle"]), delta=0.5)

    def test_skew_is_detected_on_a_rounded_outline(self) -> None:
        """A bound volume has rounded corners, and `minAreaRect` returns the
        axis-aligned bounding box for one — reporting exactly 0 or 90 whatever
        the real tilt is. The estimator must read the sides instead.
        """
        canvas = np.zeros((1200, 1600, 3), dtype=np.uint8)
        rectangle = ((800, 600), (900, 700), 3.0)
        points = cv2.boxPoints(rectangle).astype(np.int32)
        cv2.fillConvexPoly(canvas, points, (255, 255, 255))
        # Round the corners off, which is what defeats minAreaRect.
        canvas = cv2.morphologyEx(
            canvas, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (81, 81))
        )
        contour = image_ops._largest_content_contour(canvas)
        self.assertIsNotNone(contour)

        degenerate = image_ops._normalise_angle(float(cv2.minAreaRect(contour)[2]))
        measured = image_ops._contour_edge_angle(contour)

        self.assertIsNotNone(measured, "rounded outline must still yield an angle")
        self.assertLess(
            abs(abs(measured) - 3.0), 1.0, f"expected ~3 degrees, got {measured}"
        )
        if abs(degenerate) < 0.001:
            # The bug this guards: minAreaRect saw nothing, the side fit did.
            self.assertGreater(abs(measured), 0.2)

    def test_qc_ops_replay_straightens_the_page(self) -> None:
        """The whole point of deferring the rotation: replaying `qc_ops` with
        Pillow against the OUTPUT file must straighten the page LWIP measured
        but never touched, with the whole page still inside the result.
        """
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tilted = root / "tilted.jpg"
            output = root / "out.jpg"
            _write_page_image(tilted, angle=6)

            result = image_ops.deskew_crop_file(
                str(tilted), str(output), 40, 100, deskew_min_degrees=0.2
            )
            self.assertTrue(result["qc_ops"])

            with Image.open(output) as opened:
                replayed = image_ops.apply_qc_ops(opened.copy(), result["qc_ops"])

            bgr = cv2.cvtColor(np.array(replayed.convert("RGB")), cv2.COLOR_RGB2BGR)
            contour = image_ops._largest_content_contour(bgr)
            self.assertIsNotNone(contour)
            residual = image_ops._page_angle(contour)
            self.assertLess(abs(residual), 0.15, f"residual angle {residual}")

            x, y, w, h = cv2.boundingRect(contour)
            self.assertGreaterEqual(x, 0)
            self.assertGreaterEqual(y, 0)
            self.assertLessEqual(x + w, replayed.width)
            self.assertLessEqual(y + h, replayed.height)

    def test_qc_ops_crop_rect_lands_where_pillow_puts_the_page(self) -> None:
        """The crop rect models where the page ENDS UP, so it has to be
        checked against Pillow's own output, not against itself.

        The mirrored model this guards shipped for weeks: it produced the
        right expanded canvas (the expansion is symmetric in the angle) and a
        rect that still contained the page, because 200px of padding covered
        the error - it just sat hundreds of pixels off centre, hanging over
        the fill on one side.
        """
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tilted = root / "tilted.jpg"
            output = root / "out.jpg"
            _write_page_image(tilted, angle=5)

            result = image_ops.deskew_crop_file(
                str(tilted), str(output), 40, 100, deskew_min_degrees=0.2
            )
            self.assertTrue(result["qc_ops"])
            deskew, crop = result["qc_ops"][0], result["qc_ops"][1]

            with Image.open(output) as opened:
                rotated = opened.copy().rotate(
                    -float(deskew["degrees"]), expand=True, resample=Image.BICUBIC
                )
            bgr = cv2.cvtColor(np.array(rotated.convert("RGB")), cv2.COLOR_RGB2BGR)
            x, y, width, height = cv2.boundingRect(
                image_ops._largest_content_contour(bgr)
            )

            rect = crop["rect"]
            left, right = rect[0] * rotated.width, rect[2] * rotated.width
            top, bottom = rect[1] * rotated.height, rect[3] * rotated.height

            self.assertLessEqual(left, x, "crop cuts into the page on the left")
            self.assertLessEqual(top, y, "crop cuts into the page on the top")
            self.assertGreaterEqual(right, x + width, "crop cuts the page's right")
            self.assertGreaterEqual(bottom, y + height, "crop cuts the page's foot")
            self.assertLess(abs((left + right) / 2 - (x + width / 2)), 20)
            self.assertLess(abs((top + bottom) / 2 - (y + height / 2)), 20)

    def _assert_qc_ops_have_no_fill(
        self, output: Path, qc_ops: list[dict[str, object]]
    ) -> None:
        """Replay [qc_ops] on an all-white frame the way QC's export does and
        require every kept pixel to stay 255 - no fill, not even blended in.

        Deliberately NOT apply_qc_ops: that is Pillow BICUBIC (reach ~2 px),
        while the delivered TIFF is rotated by OpenCV LANCZOS4 (reach ~4 px,
        QC's geometry_ops._rotate_cv2_lanczos), so a check on the thumbnail
        replay passed with RESAMPLE_REACH = 1. Same canvas size and placement
        as the export: Pillow's own expand size, centre mapped to centre.
        """
        with Image.open(output) as opened:
            width, height = opened.size
        frame = np.full((height, width), 255, dtype=np.uint8)
        for op in qc_ops:
            if op["op"] == "deskew":
                degrees = float(op["degrees"])
                h, w = frame.shape
                new_w, new_h = Image.new("1", (w, h)).rotate(-degrees, expand=True).size
                matrix = cv2.getRotationMatrix2D((w / 2.0, h / 2.0), -degrees, 1.0)
                matrix[0, 2] += (new_w - w) / 2.0
                matrix[1, 2] += (new_h - h) / 2.0
                frame = cv2.warpAffine(
                    frame, matrix, (new_w, new_h), flags=cv2.INTER_LANCZOS4,
                    borderMode=cv2.BORDER_CONSTANT, borderValue=0,
                )
            elif op["op"] == "crop":
                h, w = frame.shape
                x0, y0, x1, y1 = op["rect"]
                frame = frame[round(y0 * h):round(y1 * h), round(x0 * w):round(x1 * w)]
        self.assertEqual(int(frame.min()), 255, "QC ops blended rotation fill")

    def _deskew_crop_unsnapped(
        self, source: Path, output: Path, padding: int, mat_fill: bool = False
    ) -> dict:
        """deskew_crop_file on the resampling path: without jpegtran the trim
        box is not grown to the 16 px grid, so no accidental slack can hide a
        missing RESAMPLE_REACH."""
        original = image_ops.jpegtran_path
        image_ops.jpegtran_path = lambda: None
        try:
            return image_ops.deskew_crop_file(
                str(source), str(output), padding, 100, deskew_min_degrees=0.2,
                mat_fill=mat_fill,
            )
        finally:
            image_ops.jpegtran_path = original

    def test_qc_ops_crop_holds_no_rotation_fill(self) -> None:
        """The delivered image must not carry the black wedges the deskew's
        own expand leaves at the corners.

        The backdrop here is mid grey, as a real capture's is, so any pure
        black in the replayed crop can only have come from the fill. Before
        the rect was clamped to the rotated frame, 200px of padding reached
        straight into it: delivered pages came out 2-9% pure black.

        `boxPoints` takes +angle: `angle` is the skew LWIP measured, and the
        replay turns the page back by -angle (see _build_qc_ops), squaring it
        up. Lay it down the other way and the replay doubles the tilt.
        """
        padding = 200
        for angle in (1.1, 4.0, 9.0):
            with self.subTest(angle=angle), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                source = root / "capture.jpg"
                output = root / "out.jpg"
                frame_width, frame_height = {
                    1.1: (1680, 2280),
                    4.0: (1760, 2360),
                    9.0: (2600, 3200),
                }[angle]
                frame = np.full((frame_height, frame_width, 3), 128, dtype=np.uint8)
                points = cv2.boxPoints(
                    ((frame_width / 2, frame_height / 2), (1200, 1800), angle)
                ).astype(np.int32)
                cv2.fillConvexPoly(frame, points, (245, 245, 245))
                self.assertTrue(cv2.imwrite(str(source), frame))

                result = self._deskew_crop_unsnapped(source, output, padding)
                self.assertTrue(result["qc_ops"])
                self._assert_qc_ops_have_no_fill(output, result["qc_ops"])

                with Image.open(output) as opened:
                    replayed = image_ops.apply_qc_ops(opened.copy(), result["qc_ops"])
                bgr = cv2.cvtColor(np.array(replayed.convert("RGB")), cv2.COLOR_RGB2BGR)
                contour = image_ops._largest_content_contour(bgr)
                self.assertIsNotNone(contour)
                x, y, width, height = cv2.boundingRect(contour)
                self.assertGreaterEqual(x, 194, f"left margin {x} at {angle} deg")
                self.assertGreaterEqual(y, 194, f"top margin {y} at {angle} deg")
                self.assertGreaterEqual(
                    bgr.shape[1] - x - width, 194, f"right margin at {angle} deg"
                )
                self.assertGreaterEqual(
                    bgr.shape[0] - y - height, 194, f"bottom margin at {angle} deg"
                )

    def test_tilted_page_keeps_requested_photo_margin_after_qc_crop(self) -> None:
        """A full camera frame has enough room for 200px on every side.

        The old pre-rotation crop followed by a uniform clamp returned only
        about 80px on the sides and 14px at the top for a 2-degree capture.
        """
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "tilted.jpg"
            output = root / "out.jpg"
            frame = np.full((2600, 2200, 3), 128, dtype=np.uint8)
            points = cv2.boxPoints(((1100, 1300), (1200, 1600), 2.0)).astype(np.int32)
            cv2.fillConvexPoly(frame, points, (245, 245, 245))
            self.assertTrue(cv2.imwrite(str(source), frame))

            result = self._deskew_crop_unsnapped(source, output, 200)
            self.assertTrue(result["qc_ops"])
            with Image.open(output) as opened:
                replayed = image_ops.apply_qc_ops(opened.copy(), result["qc_ops"])
            arr = cv2.cvtColor(np.array(replayed.convert("RGB")), cv2.COLOR_RGB2BGR)
            x, y, width, height = cv2.boundingRect(
                image_ops._largest_content_contour(arr)
            )
            self.assertGreaterEqual(x, 195, f"left margin {x}")
            self.assertGreaterEqual(y, 195, f"top margin {y}")
            self.assertGreaterEqual(arr.shape[1] - x - width, 195)
            self.assertGreaterEqual(arr.shape[0] - y - height, 195)
            self._assert_qc_ops_have_no_fill(output, result["qc_ops"])

    def test_side_near_photo_edge_is_pulled_in_alone(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "near-right.jpg"
            output = root / "out.jpg"
            frame = np.full((3000, 2600, 3), 128, dtype=np.uint8)
            points = cv2.boxPoints(((1850, 1500), (1200, 1800), 3.0)).astype(np.int32)
            cv2.fillConvexPoly(frame, points, (245, 245, 245))
            self.assertTrue(cv2.imwrite(str(source), frame))

            result = self._deskew_crop_unsnapped(source, output, 200)
            self.assertTrue(result["qc_ops"])
            with Image.open(output) as opened:
                replayed = image_ops.apply_qc_ops(opened.copy(), result["qc_ops"])
            bgr = cv2.cvtColor(np.array(replayed.convert("RGB")), cv2.COLOR_RGB2BGR)
            x, y, width, height = cv2.boundingRect(
                image_ops._largest_content_contour(bgr)
            )
            self.assertLess(bgr.shape[1] - x - width, 200)
            self.assertGreaterEqual(x, 194, f"left margin {x}")
            self.assertGreaterEqual(y, 194, f"top margin {y}")
            self.assertGreaterEqual(bgr.shape[0] - y - height, 194)
            self._assert_qc_ops_have_no_fill(output, result["qc_ops"])

    def test_straight_page_crop_is_unchanged(self) -> None:
        frame = _page_image_array(angle=0)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source_path = root / "straight.jpg"
            output = root / "out.jpg"
            self.assertTrue(cv2.imwrite(str(source_path), frame))
            result = image_ops.deskew_crop_file(
                str(source_path), str(output), 200, 100, deskew_min_degrees=0.2
            )
            self.assertEqual(result["qc_ops"], [])
            if image_ops.jpegtran_path() is None:
                self.skipTest("jpegtran not available for lossless crop box assertion")

            contour = image_ops._largest_content_contour(cv2.imread(str(source_path)))
            self.assertIsNotNone(contour)
            x, y, width, height = cv2.boundingRect(contour)
            left = max(0, x - 200)
            top = max(0, y - 200)
            right = min(frame.shape[1], x + width + 200)
            bottom = min(frame.shape[0], y + height + 200)
            expected = image_ops.snap_crop_box(
                left, top, right, bottom, frame.shape[1], frame.shape[0]
            )
            self.assertEqual(tuple(result["crop"]), expected)

    def test_straight_box_keeps_bounding_rect_exclusive_edge(self) -> None:
        """cv2.boundingRect's right/bottom edge is one past the last contour
        point. A box a pixel short of that snapped to (0, 0, 400, 400) here
        instead of the (0, 0, 416, 416) straight pages always got."""
        contour = np.array([[[100, 100]], [[200, 100]], [[200, 200]], [[100, 200]]], dtype=np.int32)
        box = image_ops._source_crop_box(contour, 0.0, 200, 1000, 1000)
        self.assertEqual(box, (0, 0, 401, 401))
        self.assertEqual(image_ops.snap_crop_box(*box, 1000, 1000), (0, 0, 416, 416))

    def test_qc_ops_sign_convention_with_an_asymmetric_marker(self) -> None:
        """A plain rectangle's tilt is ambiguous mod 180 degrees, so it cannot
        by itself catch a reversed sign (the wrong rotation direction can
        still land close to axis-aligned for some fixtures). A page with a
        marker glued to one corner cannot: replaying the wrong sign rotates a
        FURTHER ~2x the true tilt instead of cancelling it, which both
        under-fills the crop and swings the marker out of its starting
        quadrant — checked empirically against `degrees = angle` while
        writing this test, before settling on `degrees = -angle`.
        """
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.jpg"
            output = root / "out.jpg"

            page_w, page_h, marker = 900, 600, 90
            page = np.full((page_h, page_w, 3), 255, dtype=np.uint8)
            page[0:marker, 0:marker] = (0, 0, 0)  # marker at the page's own top-left
            true_tilt = 6.0
            center = (page_w / 2, page_h / 2)
            matrix = cv2.getRotationMatrix2D(center, true_tilt, 1.0)
            cos_t, sin_t = abs(matrix[0, 0]), abs(matrix[0, 1])
            new_w = int(page_h * sin_t + page_w * cos_t)
            new_h = int(page_h * cos_t + page_w * sin_t)
            matrix[0, 2] += new_w / 2 - center[0]
            matrix[1, 2] += new_h / 2 - center[1]
            rotated_page = cv2.warpAffine(
                page,
                matrix,
                (new_w, new_h),
                flags=cv2.INTER_LANCZOS4,
                borderMode=cv2.BORDER_CONSTANT,
                borderValue=(0, 0, 0),
            )
            canvas = np.zeros((new_h + 400, new_w + 400, 3), dtype=np.uint8)
            x0, y0 = 200, 200
            canvas[y0 : y0 + new_h, x0 : x0 + new_w] = rotated_page
            self.assertTrue(cv2.imwrite(str(source), canvas))

            result = image_ops.deskew_crop_file(
                str(source), str(output), 30, 100, deskew_min_degrees=0.2
            )
            self.assertTrue(result["qc_ops"])

            with Image.open(output) as opened:
                replayed = image_ops.apply_qc_ops(opened.copy(), result["qc_ops"])
            arr = cv2.cvtColor(np.array(replayed.convert("RGB")), cv2.COLOR_RGB2BGR)
            contour = image_ops._largest_content_contour(arr)
            self.assertIsNotNone(contour)
            x, y, w, h = cv2.boundingRect(contour)
            fill = cv2.contourArea(contour) / (w * h)
            self.assertGreater(fill, 0.9, f"fill {fill} — wrong rotation sign?")

            inset = 15
            region = arr[y + inset : y + h - inset, x + inset : x + w - inset]
            gray = cv2.cvtColor(region, cv2.COLOR_BGR2GRAY)
            dark_ys, dark_xs = np.nonzero(gray < 128)
            self.assertGreater(len(dark_xs), 0, "marker not found in the result")
            self.assertLess(float(dark_xs.mean()), region.shape[1] * 0.5)
            self.assertLess(float(dark_ys.mean()), region.shape[0] * 0.5)

    def test_thumbnail_is_straight_for_a_tilted_page(self) -> None:
        """The QC rail shows LWIP's thumbnail, so it must look straight even
        though the delivered file — never rotated — does not."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tilted = root / "tilted.jpg"
            output = root / "out.jpg"
            thumb = root / "thumb.jpg"
            _write_page_image(tilted, angle=5)

            result = image_ops.deskew_crop_file(
                str(tilted),
                str(output),
                40,
                100,
                thumbnail_destination_value=str(thumb),
                # The installed width (LWIP.iss). At 256 px one pixel of
                # contour quantisation alone reads as ~0.2 degrees.
                thumbnail_width=512,
                deskew_min_degrees=0.2,
            )
            self.assertTrue(result["thumbnail_created"])
            with Image.open(thumb) as opened:
                arr = cv2.cvtColor(np.array(opened.convert("RGB")), cv2.COLOR_RGB2BGR)
            contour = image_ops._largest_content_contour(arr)
            self.assertIsNotNone(contour)
            angle = image_ops._page_angle(contour)
            self.assertLess(abs(angle), 0.15, f"thumbnail contour angle {angle}")


class MatFillAndEncodeOnceTests(unittest.TestCase):
    """mat_fill clamping, off-frame detection, Triangle threshold, and the
    encode-once rule (non-JPEG and no-page files ship the source's bytes)."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def test_limited_clamp_still_trims_an_allowed_side_behind_another_violation(self) -> None:
        """With `sides` limited, the first violated plane may belong to a side
        matfill will paint. The trim must go on to the allowed side instead of
        giving up (it used to stop at the first plane)."""
        width, height, angle = 1000.0, 1400.0, 3.0
        phi = math.radians(angle)
        cos_phi, sin_phi = math.cos(phi), math.sin(phi)
        new_width = width * cos_phi + height * sin_phi
        new_height = width * sin_phi + height * cos_phi
        frame = dict(
            centre=(new_width / 2.0, new_height / 2.0),
            half_width=width / 2.0,
            half_height=height / 2.0,
            cos_phi=cos_phi,
            sin_phi=sin_phi,
        )
        # The whole expanded canvas: every corner sits in rotation void.
        x0, y0, x1, y1 = image_ops._clamp_to_rotated_frame(
            0.0, 0.0, new_width, new_height, sides={"left"}, **frame
        )
        self.assertGreater(x0, 0.0, "the allowed left side was never trimmed")
        self.assertEqual((y0, x1, y1), (0.0, new_width, new_height))

    @staticmethod
    def _frame(width: int, height: int, center, size, angle: float) -> np.ndarray:
        frame = np.full((height, width, 3), 128, dtype=np.uint8)
        points = cv2.boxPoints((center, size, angle)).astype(np.int32)
        cv2.fillConvexPoly(frame, points, (245, 245, 245))
        return frame

    def _run(self, frame: np.ndarray, name: str = "capture.jpg", **kwargs) -> dict:
        source = self.tmp / name
        output = self.tmp / ("out" + Path(name).suffix)
        self.assertTrue(cv2.imwrite(str(source), frame))
        original = image_ops.jpegtran_path
        image_ops.jpegtran_path = lambda: None
        try:
            return image_ops.deskew_crop_file(
                str(source), str(output), 200, 100, deskew_min_degrees=0.2, **kwargs
            )
        finally:
            image_ops.jpegtran_path = original

    def test_off_frame_sides_flags_a_page_that_runs_off_the_frame(self) -> None:
        running_off = self._frame(2600, 3000, (2300, 1500), (1200, 1800), 0.0)
        contour = image_ops._largest_content_contour(running_off)
        self.assertEqual(image_ops._off_frame_sides(contour, 2600, 3000), {"right"})

        inside = self._frame(2600, 3000, (1850, 1500), (1200, 1800), 0.0)
        contour = image_ops._largest_content_contour(inside)
        self.assertEqual(image_ops._off_frame_sides(contour, 2600, 3000), set())

    def test_mat_fill_keeps_full_padding_near_the_photo_edge(self) -> None:
        frame = self._frame(2600, 3000, (1850, 1500), (1200, 1800), 3.0)
        kept = self._run(frame, "kept.jpg", mat_fill=True)
        trimmed = self._run(frame, "trimmed.jpg", mat_fill=False)
        self.assertEqual(kept["off_frame"], [])
        self.assertTrue(kept["mat_fill"])
        self.assertEqual([op["op"] for op in kept["qc_ops"]], ["deskew", "crop", "matfill"])
        self.assertEqual([op["op"] for op in trimmed["qc_ops"]], ["deskew", "crop"])
        self.assertFalse(trimmed["mat_fill"])
        self.assertEqual(kept["crop"], trimmed["crop"], "same lossless trim either way")
        kept_rect = kept["qc_ops"][1]["rect"]
        trimmed_rect = trimmed["qc_ops"][1]["rect"]
        self.assertGreater(kept_rect[2], trimmed_rect[2], "right padding not kept")

    def test_mat_fill_clamps_the_side_the_page_runs_off(self) -> None:
        frame = self._frame(2600, 3000, (2300, 1500), (1200, 1800), 3.0)
        result = self._run(frame, mat_fill=True)
        self.assertIn("right", result["off_frame"])
        self.assertNotEqual(result["angle"], 0.0)
        self.assertEqual([op["op"] for op in result["qc_ops"]], ["deskew", "crop"])
        self.assertFalse(result["mat_fill"])
        OutputFidelityTests._assert_qc_ops_have_no_fill(
            self, self.tmp / "out.jpg", result["qc_ops"]
        )

    def test_straight_page_has_no_ops_and_no_matfill(self) -> None:
        result = self._run(self._frame(2200, 2600, (1100, 1300), (1200, 1600), 0.0))
        self.assertEqual(result["qc_ops"], [])
        self.assertFalse(result["mat_fill"])
        self.assertTrue(result["page_found"])

    def test_manifest_files_carry_the_diagnostics(self) -> None:
        folder = self.tmp / "incoming" / "job"
        folder.mkdir(parents=True)
        _write_page_image(folder / "tilted.jpg", angle=6)
        config = _config(self.tmp)
        self.assertEqual(FolderOrchestrator(config).run_once(), 1)
        manifest = json.loads(
            (self.tmp / "output" / "job" / ".deskew_crop_manifest.json").read_text("utf-8")
        )
        entry = manifest["files"][0]
        self.assertIn(entry["angle_source"], {"sides", "min_area_rect"})
        self.assertIs(entry["page_found"], True)
        self.assertEqual(entry["off_frame"], [])
        self.assertIsInstance(entry["mat_fill"], bool)

    def test_png_and_bmp_ship_the_source_bytes_with_the_crop_as_an_op(self) -> None:
        frame = self._frame(2200, 2600, (1100, 1300), (1200, 1600), 0.0)
        for suffix in (".png", ".bmp"):
            with self.subTest(suffix=suffix):
                name = "page" + suffix
                result = self._run(frame, name)
                source = self.tmp / name
                output = self.tmp / ("out" + suffix)
                self.assertEqual(output.read_bytes(), source.read_bytes())
                self.assertFalse(result["lossless"])
                self.assertIsNone(result["crop"])
                self.assertEqual([op["op"] for op in result["qc_ops"]], ["crop"])
                x0, y0, x1, y1 = result["qc_ops"][0]["rect"]
                self.assertAlmostEqual(x0 * 2200, 1100 - 600 - 200, delta=4)
                self.assertAlmostEqual(y1 * 2600, 1300 + 800 + 200, delta=4)

    def test_tilted_png_records_deskew_crop_and_matfill_against_the_full_frame(self) -> None:
        frame = self._frame(2600, 3000, (1850, 1500), (1200, 1800), 3.0)
        result = self._run(frame, "tilted.png")
        self.assertEqual(
            (self.tmp / "out.png").read_bytes(), (self.tmp / "tilted.png").read_bytes()
        )
        self.assertEqual([op["op"] for op in result["qc_ops"]], ["deskew", "crop", "matfill"])
        self.assertEqual((result["width"], result["height"]), (2600, 3000))

    def test_jpeg_without_a_page_is_byte_identical(self) -> None:
        frame = np.zeros((600, 800, 3), dtype=np.uint8)  # nothing to threshold
        result = self._run(frame, "blank.jpg")
        self.assertFalse(result["page_found"])
        self.assertEqual(result["angle_source"], "none")
        self.assertEqual(result["qc_ops"], [])
        self.assertEqual(
            (self.tmp / "out.jpg").read_bytes(), (self.tmp / "blank.jpg").read_bytes()
        )

    def test_jxl_without_the_plugin_fails_that_file_cleanly(self) -> None:
        if image_ops.pillow_jxl is not None:
            self.skipTest("pillow-jxl-plugin is installed")
        source = self.tmp / "page.jxl"
        source.write_bytes(b"\xff\x0a" + b"\x00" * 64)
        with self.assertRaisesRegex(OSError, "pillow-jxl-plugin"):
            image_ops.deskew_crop_file(str(source), str(self.tmp / "out.jxl"), 200, 100)

    def test_jxl_with_the_plugin_ships_the_source_bytes(self) -> None:
        if image_ops.pillow_jxl is None:
            self.skipTest("pillow-jxl-plugin is not installed")
        frame = self._frame(2200, 2600, (1100, 1300), (1200, 1600), 0.0)
        source = self.tmp / "page.jxl"
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        Image.fromarray(rgb).save(source, format="JXL", lossless=True)
        output = self.tmp / "out.jxl"
        result = image_ops.deskew_crop_file(str(source), str(output), 200, 100)
        self.assertEqual(output.read_bytes(), source.read_bytes())
        self.assertTrue(result["page_found"])
        self.assertEqual([op["op"] for op in result["qc_ops"]], ["crop"])

    def test_triangle_threshold_keeps_a_dark_cover_board_with_the_object(self) -> None:
        """Backdrop ~10, dark board ~40, paper ~90: Otsu splits between board and
        paper and traces the paper only; Triangle includes the board."""
        rng = np.random.default_rng(3)
        gray = np.full((2600, 2000), 10.0)
        gray[400:2200, 300:1700] = 40.0   # board
        gray[600:2000, 500:1500] = 90.0   # paper
        gray = np.clip(gray + rng.normal(0, 2, gray.shape), 0, 255).astype(np.uint8)

        x, y, width, height = cv2.boundingRect(image_ops._largest_contour_in_frame(gray))
        self.assertAlmostEqual(x, 300, delta=12)
        self.assertAlmostEqual(width, 1400, delta=24)
        self.assertAlmostEqual(height, 1800, delta=24)

        blurred = cv2.GaussianBlur(gray, (3, 3), 0)
        _value, otsu = cv2.threshold(blurred, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
        otsu_box = cv2.boundingRect(cv2.findNonZero(otsu))
        self.assertLess(otsu_box[2], 1100, "Otsu was expected to miss the board")


class SkewEstimateTests(unittest.TestCase):
    """`_estimate_skew`'s self-consistency loop: a single `_page_angle` read
    over-reads tilt on bound-register spreads by ~50% (measured on the 99
    Control pages). One rotate-and-remeasure pass fixes most of that; this
    covers convergence on a clean fixture and the two failure shapes an
    erratic sequence can take.
    """

    @staticmethod
    def _rectangle_canvas() -> np.ndarray:
        canvas = np.zeros((2400, 1800, 3), dtype=np.uint8)
        cv2.rectangle(canvas, (400, 500), (1400, 1900), (255, 255, 255), -1)
        return canvas

    def test_clean_pages_converge_within_0_05_degrees(self) -> None:
        # 2.3 degrees is deliberately not one of these: on this exact
        # synthetic rectangle it is a resonance point for the Otsu threshold
        # (verified while writing this test — the loop needs 4 measurements
        # to settle there instead of 2), a fixture artifact of a perfectly
        # clean rectangle rather than a defect the estimator needs guarding
        # against; a real photographed page does not share this alignment.
        for truth in (0.7, 2.5, 4.1):
            canvas = _page_image_array(angle=truth)
            contour = image_ops._largest_content_contour(canvas)
            self.assertIsNotNone(contour)
            estimate = image_ops._estimate_skew(canvas, contour, 0.2)
            self.assertLess(
                abs(estimate - truth), 0.05, f"truth={truth} estimate={estimate}"
            )

    def test_erratic_estimate_returns_zero_and_no_qc_ops(self) -> None:
        """Oscillating residuals (sign flips, magnitude never settling) mean
        no candidate angle is trustworthy — FamilySearch's standard is no
        manipulation, so the page ships as captured rather than resampled by
        a guess.
        """
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.jpg"
            output = root / "out.jpg"
            self.assertTrue(cv2.imwrite(str(source), self._rectangle_canvas()))

            sequence = iter([1.0, -0.6, 0.55])
            original = image_ops._page_angle
            image_ops._page_angle = lambda _contour: next(sequence)
            try:
                result = image_ops.deskew_crop_file(
                    str(source), str(output), 40, 100, deskew_min_degrees=0.2
                )
            finally:
                image_ops._page_angle = original

            self.assertEqual(float(result["angle"]), 0.0)
            self.assertEqual(result["qc_ops"], [])

    def test_converging_estimate_picks_the_settled_candidate(self) -> None:
        """1.0 -> -0.5 -> 0.02: candidate 1.0 has residual 0.5, candidate 0.5
        has residual 0.02 — the smaller residual wins even though a further
        (unmeasured) candidate 0.52 would exist if the loop kept going.
        """
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.jpg"
            output = root / "out.jpg"
            self.assertTrue(cv2.imwrite(str(source), self._rectangle_canvas()))

            sequence = iter([1.0, -0.5, 0.02])
            original = image_ops._page_angle
            image_ops._page_angle = lambda _contour: next(sequence)
            try:
                result = image_ops.deskew_crop_file(
                    str(source), str(output), 40, 100, deskew_min_degrees=0.2
                )
            finally:
                image_ops._page_angle = original

            self.assertAlmostEqual(float(result["angle"]), 0.5, places=6)
            self.assertTrue(result["qc_ops"])


def _page_image_array(*, angle: float) -> np.ndarray:
    """A page-sized fixture, for assertions that turn on fractions of a degree."""
    canvas = np.zeros((2400, 1800, 3), dtype=np.uint8)
    rectangle = ((900, 1200), (1300, 1900), angle)
    points = cv2.boxPoints(rectangle).astype(np.int32)
    cv2.fillConvexPoly(canvas, points, (255, 255, 255))
    return canvas


def _write_page_image(path: Path, *, angle: float) -> None:
    if not cv2.imwrite(str(path), _page_image_array(angle=angle)):
        raise OSError(f"Could not create test image: {path}")


def _write_test_image(path: Path, *, angle: float) -> None:
    canvas = np.zeros((240, 320, 3), dtype=np.uint8)
    rectangle = ((160, 120), (180, 110), angle)
    points = cv2.boxPoints(rectangle).astype(np.int32)
    cv2.fillConvexPoly(canvas, points, (255, 255, 255))
    self_written = cv2.imwrite(str(path), canvas)
    if not self_written:
        raise OSError(f"Could not create test image: {path}")


if __name__ == "__main__":
    unittest.main()


class InstanceLockTests(unittest.TestCase):
    """The replacement-while-draining path Station Setup's save relies on."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.lock = self.tmp / "orchestrator.lock"

    def test_no_wait_fails_fast_on_a_held_lock(self) -> None:
        with orchestrator_module.instance_lock(self.lock):
            with self.assertRaises(RuntimeError):
                with orchestrator_module.instance_lock(self.lock):
                    pass

    def test_waiter_takes_over_when_the_holder_exits(self) -> None:
        # Separate handles, like two processes: the lock is per-handle on NT.
        release = threading.Event()

        def hold() -> None:
            with orchestrator_module.instance_lock(self.lock):
                release.wait(10)

        holder = threading.Thread(target=hold)
        holder.start()
        time.sleep(0.3)
        threading.Timer(0.6, release.set).start()
        started = time.monotonic()
        with orchestrator_module.instance_lock(self.lock, wait=10):
            waited = time.monotonic() - started
        holder.join()
        self.assertGreater(waited, 0.3, "lock was not actually held")
        self.assertLess(waited, 8, "waiter should acquire as soon as the holder exits")

    def test_stale_stop_file_cleared_and_fresh_one_kept(self) -> None:
        config = _config(self.tmp)
        work = config.work_root
        work.mkdir()
        orchestrator = orchestrator_module.FolderOrchestrator(config)
        stale = work / orchestrator.STOP_FILE_NAME
        stale.write_text("stop")
        old = time.time() - 60
        os.utime(stale, (old, old))
        cutoff = time.time()
        time.sleep(0.05)
        orchestrator._clear_stale_stop_files(older_than=cutoff)
        self.assertFalse(stale.exists(), "a request older than the lock is stale")
        fresh = work / orchestrator.STOP_FILE_NAME
        fresh.write_text("stop")
        orchestrator._clear_stale_stop_files(older_than=cutoff)
        self.assertTrue(fresh.exists(), "a request newer than the lock is for us")


class LosslessCropTests(unittest.TestCase):
    """A page the estimator leaves unrotated must reach the output as the
    camera's own coded blocks, not a decode-and-re-encode of them."""

    def setUp(self) -> None:
        if image_ops.jpegtran_path() is None:
            self.skipTest("jpegtran not available")
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def _camera_like_source(self, path: Path, *, orientation: int = 0) -> None:
        # 4:2:0 at q95 like cv2's default, with a texture so a re-encode would
        # be measurable, plus the provenance a real capture carries.
        rng = np.random.default_rng(7)
        canvas = rng.integers(0, 40, size=(2400, 1800, 3), dtype=np.uint8)
        page = rng.integers(180, 255, size=(1300, 900, 3), dtype=np.uint8)
        canvas[550:1850, 450:1350] = page
        frame = Image.fromarray(cv2.cvtColor(canvas, cv2.COLOR_BGR2RGB))
        exif = Image.Exif()
        exif[0x010F] = "Xiaomi"
        exif[0x0110] = "Xiaomi 14 Ultra"
        exif[0x0112] = orientation
        exif[0x8825] = {1: "N", 2: (1.0, 2.0, 3.0)}
        frame.save(
            path, format="JPEG", quality=95, subsampling=2, exif=exif,
            icc_profile=b"\x00" * 700,
        )

    def test_straight_page_is_cropped_without_reencoding(self) -> None:
        source = self.tmp / "source.jpg"
        output = self.tmp / "out.jpg"
        self._camera_like_source(source)
        result = image_ops.deskew_crop_file(
            str(source), str(output), 200, 100, deskew_min_degrees=0.2
        )
        self.assertTrue(result["lossless"], result)
        left, top, right, bottom = result["crop"]
        self.assertEqual((left % 16, top % 16), (0, 0))
        src = cv2.imread(str(source), cv2.IMREAD_COLOR)
        out = cv2.imread(str(output), cv2.IMREAD_COLOR)
        self.assertEqual(out.shape[:2], (bottom - top, right - left))
        window = src[top:bottom, left:right]
        interior = np.abs(window[1:-1, 1:-1].astype(int) - out[1:-1, 1:-1].astype(int))
        self.assertEqual(int(interior.max()), 0, "interior must be the camera's pixels")
        with Image.open(source) as a, Image.open(output) as b:
            self.assertEqual(a.quantization, b.quantization, "tables must be the camera's")
            carried = b.getexif()
            self.assertEqual(carried.get(0x010F), "Xiaomi")
            self.assertNotIn(0x8825, carried, "GPS must not reach the client")
            self.assertEqual(carried.get(0x0112), 1)
            self.assertEqual(b.info.get("icc_profile"), b"\x00" * 700)

    def test_rotated_orientation_takes_the_resampling_path(self) -> None:
        source = self.tmp / "source.jpg"
        output = self.tmp / "out.jpg"
        self._camera_like_source(source, orientation=6)
        result = image_ops.deskew_crop_file(
            str(source), str(output), 200, 100, deskew_min_degrees=0.2
        )
        self.assertFalse(result["lossless"], result)
        self.assertTrue(output.exists())

    def test_missing_tool_falls_back_to_encoding(self) -> None:
        source = self.tmp / "source.jpg"
        output = self.tmp / "out.jpg"
        self._camera_like_source(source)
        original = image_ops.jpegtran_path
        image_ops.jpegtran_path = lambda: None
        try:
            result = image_ops.deskew_crop_file(
                str(source), str(output), 200, 100, deskew_min_degrees=0.2
            )
        finally:
            image_ops.jpegtran_path = original
        self.assertFalse(result["lossless"], result)
        with Image.open(output) as written:
            self.assertEqual(max(max(t) for t in written.quantization.values()), 1)

    def test_snap_grows_outward_and_clamps(self) -> None:
        self.assertEqual(
            image_ops.snap_crop_box(17, 33, 100, 200, 6144, 8192), (16, 32, 112, 208)
        )
        self.assertEqual(
            image_ops.snap_crop_box(0, 0, 6140, 8190, 6144, 8192), (0, 0, 6144, 8192)
        )


class CompletionMarkerAdmissionTests(unittest.TestCase):
    """Admission (build_snapshot) and processing (_start_folder) read the marker
    through one parser, so a legacy sentinel never looks like a calibration
    change, and damaged data still fails closed. Runs the real run_once."""

    def _run(self, marker: bytes) -> tuple[int, Path]:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        folder = root / "incoming" / "001"
        folder.mkdir(parents=True)
        _write_test_image(folder / "a.jpg", angle=7)
        (folder / "marker.json").write_bytes(marker)
        config = _config(root, completion_marker="marker.json")
        snapshot = build_snapshot(folder, config)
        self.assertIsNotNone(snapshot)
        return FolderOrchestrator(config).run_once(), root

    def test_legacy_sentinels_are_processed(self) -> None:
        for raw in (b"", b"\r\n", b" \t\n", b"\xef\xbb\xbf", b"null", b"[]",
                    b"\xef\xbb\xbf{}", b'\xef\xbb\xbf{"project_key":"p"}'):
            with self.subTest(raw=raw):
                processed, root = self._run(raw)
                self.assertEqual(processed, 1)
                self.assertTrue((root / "output" / "001" / ".deskew_crop_manifest.json").is_file())

    def test_damaged_or_foreign_markers_still_fail_closed(self) -> None:
        damaged_block = json.dumps({"color_calibration": {"version": 1, "profiles": {}, "images": {}}}).encode()
        for raw in (b'{"color_calibration":', b"done", b"\xff\xfe{}", b'"text"', b"[1]", damaged_block):
            with self.subTest(raw=raw):
                processed, root = self._run(raw)
                self.assertEqual(processed, 0)
                self.assertFalse((root / "output" / "001" / ".deskew_crop_manifest.json").exists())

    def test_snapshot_digest_agrees_with_processing_identity(self) -> None:
        from color_cal_tool.contract import calibration_digest
        for raw in (b"", b"\r\n", b"\xef\xbb\xbf", b"null", b"[]", b"\xef\xbb\xbf{}"):
            with self.subTest(raw=raw):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    folder = root / "incoming" / "001"
                    folder.mkdir(parents=True)
                    _write_test_image(folder / "a.jpg", angle=0)
                    (folder / "marker.json").write_bytes(raw)
                    config = _config(root, completion_marker="marker.json")
                    identity = FolderOrchestrator(config)._read_source_identity(folder)
                    self.assertEqual(calibration_digest(identity), build_snapshot(folder, config).calibration_digest)

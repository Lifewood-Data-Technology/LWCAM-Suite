"""Protocol fixtures also consumed by Dart. No database or service required."""
import json
import shutil
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from color_cal_tool.task_protocol import atomic_json, read_json, sha, validate_request, ProtocolError
from deskew_crop_tool.calibration_queue import CalibrationQueue, AnalysisTimeout
from deskew_crop_tool.orchestrator import FolderOrchestrator
from test_round2 import _config

FIXTURES = Path(__file__).resolve().parents[3] / "verification/calibration_protocol"


class QueueTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = Path(tmp.name)
        self.input = self.base / "incoming"
        self.input.mkdir()
        self.request = read_json(FIXTURES / "request.json")[0]
        self.folder = self.input / ".calibration" / self.request["task_id"]
        self.folder.mkdir(parents=True)
        for name in ("chart.jpg", "request.json", "ready.json"):
            shutil.copyfile(FIXTURES / name, self.folder / name)
        self.calls = 0
        self.queue = self.make_queue()

    def run_analysis(self, work):
        self.calls += 1
        self.assertEqual((work / "chart.jpg").read_bytes(), (FIXTURES / "chart.jpg").read_bytes())
        return {"ok": True, "profile": read_json(FIXTURES / "profile.json")[0]}

    def make_queue(self, runner=None):
        queue = CalibrationQueue(SimpleNamespace(input_root=self.input),
                                 runner=runner or self.run_analysis,
                                 local_root=self.base / "local")
        self.addCleanup(queue.close)
        return queue

    def result(self):
        return read_json(self.folder / "result.json")[0]

    def chart_reads(self, operation):
        reads = []
        original = Path.read_bytes
        def tracked(path):
            if path == self.folder / "chart.jpg":
                reads.append(path)
            return original(path)
        with patch.object(Path, "read_bytes", tracked):
            operation()
        return reads

    def test_completed_idle_scans_do_not_read_chart(self):
        self.queue.tick()
        self.queue.tick()  # Establish this process's integrity check.
        self.assertEqual(self.chart_reads(lambda: [self.queue.tick() for _ in range(3)]), [])
        self.assertEqual(self.calls, 1)

    def test_failed_analysis_idle_scans_do_not_read_chart(self):
        self.queue.runner = lambda _: {"ok": False, "error": {"code": "no_chart_found"}}
        self.queue.tick()
        self.queue.tick()
        self.assertEqual(self.chart_reads(self.queue.tick), [])
        self.assertEqual(self.result()["status"], "failed")

    def test_completed_restart_revalidates_then_skips_chart(self):
        self.queue.tick()
        self.queue.close()
        restarted = self.make_queue()
        self.assertTrue(self.chart_reads(restarted.tick))
        self.assertEqual(self.chart_reads(restarted.tick), [])
        self.assertEqual(self.calls, 1)

    def test_completed_changed_chart_reports_conflict(self):
        self.queue.tick()
        self.queue.tick()
        original = (self.folder / "result.json").read_bytes()
        (self.folder / "chart.jpg").write_bytes(b"damaged")
        with patch.object(self.queue, "status") as status:
            self.queue.tick()
        self.assertTrue(any(c.kwargs.get("state") == "conflict" for c in status.call_args_list))
        self.assertEqual((self.folder / "result.json").read_bytes(), original)
        self.assertEqual(self.calls, 1)

    def test_completed_changed_ready_reports_conflict_without_chart_read(self):
        self.queue.tick()
        self.queue.tick()
        shutil.copyfile(FIXTURES / "corrupt-ready.json", self.folder / "ready.json")
        with patch.object(self.queue, "status") as status:
            self.assertEqual(self.chart_reads(self.queue.tick), [])
        self.assertTrue(any(c.kwargs.get("state") == "conflict" for c in status.call_args_list))

    def test_completed_elapsed_time_does_not_reread_chart(self):
        self.queue.tick()
        with patch("deskew_crop_tool.calibration_queue.time.monotonic", return_value=100):
            self.queue.tick()
        with patch("deskew_crop_tool.calibration_queue.time.monotonic", return_value=401):
            self.assertEqual(self.chart_reads(self.queue.tick), [])
        self.assertEqual(self.calls, 1)

    def test_completed_missing_result_republishes_after_full_validation(self):
        self.queue.tick()
        self.queue.tick()
        (self.folder / "result.json").unlink()
        self.assertTrue(self.chart_reads(self.queue.tick))
        self.assertEqual(self.result()["status"], "succeeded")
        self.assertEqual(self.calls, 1)

    def test_invalid_request_failure_can_be_republished_after_restart(self):
        (self.folder / "chart.jpg").write_bytes(b"broken")
        self.queue.tick()
        self.queue.close()
        (self.folder / "result.json").unlink()
        restarted = self.make_queue()
        restarted.tick()
        self.assertEqual(self.result()["error"]["code"], "invalid_request")
        self.assertEqual(self.calls, 0)

    def test_idle_terminal_task_reads_no_metadata(self):
        # tick() catches Exception, so an injected raise would be swallowed.
        # Assert the calls themselves: an unchanged finished task is neither
        # processed nor read again.
        self.queue.tick()
        self.queue.tick()
        reads = []
        original = Path.read_bytes
        def tracked(path):
            reads.append(path)
            return original(path)
        with patch.object(self.queue, "process", wraps=self.queue.process) as process,                 patch.object(Path, "read_bytes", tracked):
            self.queue.tick()
        process.assert_not_called()
        self.assertEqual([r for r in reads if r.parent == self.folder], [])

    def test_invalid_task_names_are_ignored_without_repeated_warnings(self):
        bad = self.folder.parent / "not-a-task"
        bad.mkdir()
        (bad / "ready.json").write_text("{}")
        (self.folder.parent / ".archive").mkdir()
        with patch("deskew_crop_tool.calibration_queue.LOG.warning") as warning:
            self.queue.tick()
            self.queue.tick()
        # Logged once, as the maintainer asked; protocol dot entries never.
        warning.assert_called_once()
        self.assertIn("not-a-task", str(warning.call_args))

    def test_completed_retention_archives_before_removing_local_state(self):
        import time
        self.queue.tick()
        task_id = self.folder.name
        with patch("deskew_crop_tool.calibration_queue.time.time", return_value=time.time() + 31 * 86400):
            self.queue.tick()
        self.assertFalse(self.folder.exists())
        self.assertTrue((self.folder.parent / ".archive" / task_id / "result.json").exists())
        self.assertNotIn(task_id, self.queue.records)
        self.assertFalse((self.queue.local / task_id).exists())

    def test_retention_does_not_delete_unpublished_work(self):
        import time
        with patch.object(self.queue, "_publish", side_effect=OSError("offline")):
            self.queue.tick()
            with patch("deskew_crop_tool.calibration_queue.time.time", return_value=time.time() + 100 * 86400):
                self.queue.tick()
        self.assertTrue(self.folder.exists())
        self.assertEqual(self.queue.records[self.folder.name]["state"], "publishing")
        self.assertTrue((self.queue.local / self.folder.name / "result.json").exists())

    def finished(self, task_id, days_ago):
        """A succeeded task record and its share folder, for retention tests."""
        import time
        from datetime import datetime, timezone
        folder = self.folder.parent / task_id
        folder.mkdir(exist_ok=True)
        (folder / "ready.json").write_text("{}")
        (folder / "result.json").write_text(json.dumps({"completed_at": datetime.fromtimestamp(
            time.time() - days_ago * 86400, timezone.utc).isoformat()}))
        (self.queue.local / task_id).mkdir(exist_ok=True)
        self.queue.records[task_id] = {"state": "succeeded", "result": json.loads((folder / "result.json").read_text())}
        return folder

    def retire(self, tasks, days_later=0):
        import time
        self.queue._last_cleanup = 0
        with patch("deskew_crop_tool.calibration_queue.time.time", return_value=time.time() + days_later * 86400):
            self.queue._retire(sorted(tasks))

    def test_retention_rename_failure_does_not_block_other_tasks(self):
        first = self.finished("00000000-0000-4000-8000-000000000001", 40)
        second = self.finished("00000000-0000-4000-8000-000000000002", 40)
        original = __import__("os").replace
        def replace(src, dst):
            if Path(src).name == first.name:
                raise PermissionError("locked")
            return original(src, dst)
        with patch("deskew_crop_tool.calibration_queue.os.replace", replace):
            self.retire([first, second])
        self.assertTrue(first.exists())
        self.assertIn(first.name, self.queue.records)
        self.assertTrue((self.queue.local / first.name).exists())
        self.assertFalse(second.exists())
        self.assertNotIn(second.name, self.queue.records)
        self.retire([first])  # recovery once the lock is gone
        self.assertFalse(first.exists())
        self.assertNotIn(first.name, self.queue.records)

    def test_unreadable_archive_entry_does_not_block_purge(self):
        valid = self.finished("00000000-0000-4000-8000-0000000000ff", 40)
        self.retire([valid])
        archive = self.folder.parent / ".archive"
        self.assertTrue((archive / valid.name).exists())
        broken = archive / "00000000-0000-4000-8000-000000000000"  # sorts first
        broken.mkdir()
        self.retire([], days_later=200)
        self.assertFalse((archive / valid.name).exists())
        self.assertTrue(broken.exists(), "an entry of unknown age is kept")

    def test_local_cleanup_failure_keeps_record_for_retry(self):
        task = self.finished("00000000-0000-4000-8000-000000000003", 40)
        with patch("deskew_crop_tool.calibration_queue.shutil.rmtree", side_effect=PermissionError("busy")):
            self.retire([task])
        self.assertFalse(task.exists())
        self.assertIn(task.name, self.queue.records)
        self.assertTrue((self.queue.local / task.name).exists())
        self.retire([])
        self.assertNotIn(task.name, self.queue.records)
        self.assertFalse((self.queue.local / task.name).exists())

    def test_legacy_markers_without_calibration_and_bom_object(self):
        orchestrator = FolderOrchestrator(_config(self.base, marker="marker.json"))
        marker = self.folder / "marker.json"
        for text in ("", "\ufeff", "null", "[]"):
            marker.write_text(text, encoding="utf-8")
            self.assertIsNone(orchestrator._read_source_identity(self.folder))
        marker.write_text('\ufeff{"project_key":"p"}', encoding="utf-8")
        self.assertEqual(orchestrator._read_source_identity(self.folder), {"project_key": "p"})
        marker.write_text('{"color_calibration":', encoding="utf-8")
        from color_cal_tool.contract import CalibrationError
        with self.assertRaises(CalibrationError):
            orchestrator._read_source_identity(self.folder)

    def test_shared_request_and_corrupt_fixture(self):
        self.assertEqual(validate_request(self.folder)[0], self.request)
        shutil.copyfile(FIXTURES / "corrupt-ready.json", self.folder / "ready.json")
        with self.assertRaises(ProtocolError):
            validate_request(self.folder)

    def test_ready_is_required_and_result_published_once(self):
        (self.folder / "ready.json").unlink()
        self.queue.tick()
        self.assertEqual(self.calls, 0)
        shutil.copyfile(FIXTURES / "ready.json", self.folder / "ready.json")
        self.queue.tick()
        self.assertEqual(self.result()["status"], "succeeded")
        self.queue.tick()
        self.assertEqual(self.calls, 1)
        self.assertEqual(self.result()["image_sha256"], self.request["image"]["sha256"])

    def test_corrupt_chart_never_executes_algorithm(self):
        (self.folder / "chart.jpg").write_bytes(b"broken")
        self.queue.tick()
        self.assertEqual(self.calls, 0)
        self.assertEqual(self.result()["error"]["code"], "invalid_request")

    def test_malformed_request_publishes_failure_without_executing(self):
        (self.folder / "request.json").write_bytes(b"{broken")
        self.queue.tick()
        self.assertEqual(self.calls, 0)
        self.assertEqual(self.result()["error"]["code"], "invalid_request")
        self.assertEqual(self.result()["request_sha256"], sha(b"{broken"))

    def test_version_has_distinct_error(self):
        self.request["version"] = 2
        atomic_json(self.folder / "request.json", self.request)
        atomic_json(self.folder / "ready.json", {
            "task_id": self.folder.name, "request_sha256": sha((self.folder / "request.json").read_bytes())})
        self.queue.tick()
        self.assertEqual(self.result()["error"]["code"], "unsupported_version")
        self.assertEqual(self.calls, 0)

    def test_publish_disconnect_resumes_without_analysis(self):
        with patch.object(self.queue, "_publish", side_effect=OSError("share offline")):
            self.queue.tick()
        self.assertEqual(self.calls, 1)
        self.assertFalse((self.folder / "result.json").exists())
        self.queue.close()
        self.make_queue().tick()
        self.assertEqual(self.calls, 1)
        self.assertEqual(self.result()["status"], "succeeded")

    def test_restart_running_task_retries(self):
        def interrupted(work):
            raise InterruptedError("shutdown")
        queue = self.make_queue(interrupted)
        queue.tick()
        self.assertEqual(queue.records[self.folder.name]["state"], "running")
        queue.close()
        self.make_queue().tick()
        self.assertEqual(self.calls, 1)

    def test_timeout_is_terminal_failure(self):
        def timeout(work):
            raise AnalysisTimeout("execution timeout")
        queue = self.make_queue(timeout)
        queue.tick()
        self.assertEqual(self.result()["error"]["code"], "analysis_timeout")
        queue.runner = self.run_analysis
        queue.tick()
        self.assertEqual(self.calls, 0)

    def test_same_uuid_different_request_keeps_original_result(self):
        self.queue.tick()
        original = (self.folder / "result.json").read_bytes()
        self.request["operator"] = "changed"
        atomic_json(self.folder / "request.json", self.request)
        self.queue.tick()
        self.assertEqual((self.folder / "result.json").read_bytes(), original)
        self.assertEqual(self.calls, 1)

    def test_only_one_live_consumer_and_lock_released(self):
        self.queue.tick()
        other = self.make_queue()
        with self.assertRaises(ProtocolError):
            other.tick()
        self.queue.close()
        other.tick()
        self.assertEqual(self.calls, 1)

    def test_charts_excluded_from_both_document_depths(self):
        (self.input / "day" / "book").mkdir(parents=True)
        for depth in (1, 2):
            config = replace(_config(self.base), folder_depth=depth)
            folders = FolderOrchestrator(config)._list_candidates()
            self.assertEqual([p.name for p in folders], ["day" if depth == 1 else "book"])

    def test_real_worker_uses_local_photo_and_returns_algorithm_failure(self):
        from PIL import Image
        work = self.base / "worker"
        work.mkdir()
        Image.new("RGB", (100, 100), "black").save(work / "chart.jpg")
        atomic_json(work / "request.json", self.request)
        result = self.queue._run(work)
        self.assertFalse(result["ok"])
        self.assertIn(result["error"]["code"], ("no_chart_found", "low_confidence"))
        self.assertIsNone(self.queue.child)

    def test_worker_deadline_kills_only_owned_child(self):
        from unittest.mock import Mock
        child = Mock()
        child.poll.return_value = None
        work = self.base / "timeout"
        work.mkdir()
        with patch("deskew_crop_tool.calibration_queue.subprocess.Popen", return_value=child), \
                patch("deskew_crop_tool.calibration_queue.time.monotonic", side_effect=[0, 121]):
            with self.assertRaises(AnalysisTimeout):
                self.queue._run(work)
        child.kill.assert_called_once()
        child.wait.assert_called_once()
        self.assertIsNone(self.queue.child)

    def test_share_request_changed_during_analysis_never_publishes_success(self):
        def changed(work):
            result = self.run_analysis(work)
            (self.folder / "chart.jpg").write_bytes(b"changed while running")
            return result
        self.queue.runner = changed
        self.queue.tick()
        self.assertFalse((self.folder / "result.json").exists())

    def test_shared_success_failure_and_corrupt_results(self):
        from color_cal_tool.contract import validate_correction
        result = read_json(FIXTURES / "succeeded.json")[0]
        self.assertEqual(result["request_sha256"], validate_request(self.folder)[1])
        self.assertEqual(result["files"]["profile.json"]["sha256"],
                         sha((FIXTURES / "profile.json").read_bytes()))
        validate_correction(read_json(FIXTURES / "profile.json")[0])
        self.assertEqual(read_json(FIXTURES / "failed.json")[0]["error"]["code"], "no_chart_found")
        self.assertNotEqual(read_json(FIXTURES / "corrupt-result.json")[0]["request_sha256"],
                            validate_request(self.folder)[1])


if __name__ == "__main__":
    unittest.main()

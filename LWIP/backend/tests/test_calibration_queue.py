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

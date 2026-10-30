"""LWIP-owned directory queue. Never reports colour charts as document pages."""
import json
import logging
import os
import shutil
import subprocess
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

from color_cal_tool.contract import validate_correction
from color_cal_tool.task_protocol import (
    MAX_JSON, ProtocolError, atomic_json, plain_path, read_json, sha, validate_request,
)

LOG = logging.getLogger("deskew_crop.calibration")

# Finished tasks stay in place this long, then move to .archive; archived
# tasks are deleted after the second period.
COMPLETED_RETENTION_SECONDS = 30 * 86400
ARCHIVE_RETENTION_SECONDS = 90 * 86400
# Invalid task-folder names are reported once each, up to this many names.
IGNORED_NAME_LOG_LIMIT = 256


class AnalysisTimeout(RuntimeError):
    pass


class RootLock:
    def __init__(self, root):
        self.file = None
        path = Path(root) / ".consumer.lock"
        if path.exists():
            plain_path(path)
        stream = path.open("a+b")
        try:
            stream.seek(0, 2)
            if stream.tell() == 0:
                stream.write(b"\0")
                stream.flush()
            stream.seek(0)
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.file = stream
        except Exception:
            stream.close()
            raise ProtocolError("Another LWIP instance owns this calibration root")

    def close(self):
        if self.file:
            self.file.close()
            self.file = None


class CalibrationQueue:
    def __init__(self, config, status=None, runner=None, local_root=None):
        self.config = config
        self.status = status or (lambda **_: None)
        self.runner = runner or self._run
        self.stop = threading.Event()
        self.child = None
        self.lock = None
        self.root = config.input_root / ".calibration"
        # Always local to this installation, never use a network work_root.
        runtime = Path(local_root) if local_root else Path(__file__).resolve().parents[2] / "runtime" / "calibration"
        self.local = runtime / sha(str(config.input_root.resolve()).encode())[:16]
        self.local.mkdir(parents=True, exist_ok=True)
        self.ledger_path = self.local / "state.json"
        # Process-local: a restart always revalidates completed photographs.
        self._completed_checks = {}
        self._terminal_signatures = {}
        self._last_cleanup = 0
        self._ignored_names = set()
        # The ledger grows with jobs; its size is not limited by the wire protocol.
        self.records = json.loads(self.ledger_path.read_text(encoding="utf-8")) if self.ledger_path.exists() else {}

    def _save(self):
        atomic_json(self.ledger_path, self.records)

    def close(self):
        self.stop.set()
        child = self.child
        if child is not None and child.poll() is None:
            child.terminate()
        if self.lock:
            self.lock.close()
            self.lock = None

    def _run(self, work):
        entry = Path(__file__).resolve().parents[1] / "run_calibration_task.py"
        with (work / "worker.log").open("wb") as log:
            self.child = subprocess.Popen(
                [sys.executable, str(entry), str(work)], cwd=str(entry.parent),
                stdout=log, stderr=log,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
            deadline = time.monotonic() + 120
            try:
                while self.child.poll() is None:
                    if self.stop.wait(.2):
                        raise InterruptedError("LWIP stopping")
                    if time.monotonic() >= deadline:
                        raise AnalysisTimeout("Calibration exceeded 120 seconds")
                if self.stop.is_set():
                    raise InterruptedError("LWIP stopping")
                if self.child.returncode:
                    raise RuntimeError(f"Calibration worker exited {self.child.returncode}")
                return read_json(work / "analysis.json")[0]
            finally:
                if self.child.poll() is None:
                    self.child.kill()
                self.child.wait()
                self.child = None

    def _publish(self, folder, work, result):
        plain_path(folder)
        request_path = plain_path(folder / "request.json")
        if request_path.stat().st_size > MAX_JSON:
            raise ProtocolError("Request exceeds protocol limit")
        raw = request_path.read_bytes()
        if sha(raw) != result.get("request_sha256"):
            raise ProtocolError("Request changed before result publication")
        error = result.get("error") or {}
        if error.get("code") not in ("invalid_request", "unsupported_version"):
            _, current_hash, _ = validate_request(folder)
            if current_hash != result["request_sha256"]:
                raise ProtocolError("Request changed before result publication")
        output = folder / "result"
        if output.exists():
            plain_path(output)
        output.mkdir(exist_ok=True)
        for name, descriptor in result.get("files", {}).items():
            source = work / name
            if sha(source.read_bytes()) != descriptor["sha256"]:
                raise ProtocolError("Local result damaged")
            target = folder / descriptor["name"]
            if target.exists():
                plain_path(target)
            temp = output / (name + ".part")
            if temp.exists():
                plain_path(temp)
            shutil.copyfile(source, temp)
            if sha(temp.read_bytes()) != descriptor["sha256"]:
                raise OSError("Result copy checksum mismatch")
            os.replace(temp, target)
        if (folder / "result.json.tmp").exists():
            plain_path(folder / "result.json.tmp")
        atomic_json(folder / "result.json", result)

    def _check_completed(self, folder, result):
        # Invalid requests are terminal failures, not candidates for analysis.
        # The caller still checks the exact request hash on every scan.
        if (result.get("error") or {}).get("code") in ("invalid_request", "unsupported_version"):
            return
        ready, _ = read_json(plain_path(folder / "ready.json"))
        if ready.get("task_id") != folder.name or ready.get("request_sha256") != result["request_sha256"]:
            raise ProtocolError("Completed task ready marker changed")
        picture = plain_path(folder / "chart.jpg")
        stat = picture.stat()
        signature = (stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns, stat.st_dev, stat.st_ino)
        now = time.monotonic()
        cached = self._completed_checks.get(folder.name)
        if cached is None or cached[0] != signature:
            # Record the pre-read signature: a concurrent change forces another
            # full check on the next scan, rather than caching the changed file.
            validate_request(folder)
            self._completed_checks[folder.name] = (signature, now)

    def process(self, folder):
        task_id = folder.name
        # Directory names must never reach local path construction unvalidated.
        if str(uuid.UUID(task_id)) != task_id:
            raise ProtocolError("Invalid task directory")
        work = self.local / task_id
        work.mkdir(exist_ok=True)
        request_hash = None
        request = {}
        previous = self.records.get(task_id, {})
        try:
            request_path = plain_path(folder / "request.json")
            if request_path.stat().st_size > MAX_JSON:
                raise ProtocolError("Request exceeds protocol limit")
            raw = request_path.read_bytes()
            request_hash = sha(raw)
            request = json.loads(raw)
            if not isinstance(request, dict):
                request = {}
                raise ProtocolError("Expected request object")
            if previous.get("request_sha256") not in (None, request_hash):
                raise ProtocolError("Task ID reused with different content")
            self.records[task_id] = previous or dict(state="discovered", request_sha256=request_hash)
            if not previous:
                self._save()
            if previous.get("state") not in ("publishing", "succeeded", "failed"):
                self.records[task_id]["state"] = "validating"
                self._save()
            if previous.get("state") in ("publishing", "succeeded", "failed"):
                result = read_json(work / "result.json")[0]
                if previous["state"] == "publishing" or not (folder / "result.json").exists():
                    self._publish(folder, work, result)
                    previous["state"] = result["status"]
                    self._save()
                else:
                    self._check_completed(folder, result)
                self.status(**{"last_" + result["status"]: result})
                return
            request, request_hash, picture = validate_request(folder)
            record = dict(state="running", request_sha256=request_hash,
                          image_sha256=request["image"]["sha256"],
                          device_id=request["device_id"], started_at=time.time())
            self.records[task_id] = record
            self._save()
            self.status(state="running", task_id=task_id, **{k: v for k, v in record.items() if k != "state"})
            (work / "chart.jpg").write_bytes(picture)
            atomic_json(work / "request.json", request)
            analysis = self.runner(work)
            if self.stop.is_set():
                raise InterruptedError("LWIP stopping")
            if analysis.get("ok"):
                validate_correction(analysis["profile"])
                atomic_json(work / "profile.json", analysis["profile"])
            result = dict(
                version=1, task_id=task_id, request_sha256=request_hash,
                image_sha256=request["image"]["sha256"], device_id=request["device_id"],
                phone_serial=request["phone_serial"], captured_at=request["captured_at"],
                capture_local_date=request["capture_local_date"],
                completed_at=datetime.now(timezone.utc).isoformat(),
                status="succeeded" if analysis.get("ok") else "failed",
                error=analysis.get("error"), warnings=analysis.get("warnings", []),
                detection=analysis.get("detection"), files={},
            )
            if analysis.get("ok"):
                result["profile_id"] = analysis["profile"]["profile_id"]
                result["stats"] = analysis["profile"].get("stats", {})
                result["files"]["profile.json"] = {"name": "result/profile.json",
                                                  "sha256": sha((work / "profile.json").read_bytes())}
            for name in ("detected.png", "rectified.png"):
                source = work / "debug" / name
                if source.is_file():
                    shutil.copyfile(source, work / name)
                    result["files"][name] = {"name": "result/" + name, "sha256": sha(source.read_bytes())}
        except InterruptedError:
            raise
        except OSError:
            # Share unavailable: retain running/publishing state for retry.
            raise
        except Exception as exc:
            if previous.get("request_sha256") not in (None, request_hash) or previous.get("state") in ("succeeded", "failed", "publishing"):
                self.status(state="conflict", task_id=task_id, error=str(exc))
                LOG.error("Calibration task conflict %s: %s", task_id, exc)
                return
            code = "analysis_timeout" if isinstance(exc, AnalysisTimeout) else (
                getattr(exc, "code", "invalid_request") if isinstance(exc, (ValueError, KeyError, TypeError)) else "worker_error")
            result = dict(version=1, task_id=task_id, request_sha256=request_hash,
                          image_sha256=(request.get("image") if isinstance(request.get("image"), dict) else {}).get("sha256"),
                          device_id=request.get("device_id"), phone_serial=request.get("phone_serial"),
                          captured_at=request.get("captured_at"), capture_local_date=request.get("capture_local_date"),
                          completed_at=datetime.now(timezone.utc).isoformat(),
                          status="failed", error={"code": code, "message": str(exc)}, files={})
        atomic_json(work / "result.json", result)
        self.records[task_id] = dict(state="publishing", request_sha256=request_hash,
                                     device_id=result.get("device_id"), result=result)
        self._save()
        self.status(state="publishing", task_id=task_id, error=None)
        self._publish(folder, work, result)
        self.records[task_id]["state"] = result["status"]
        self._save()
        self.status(state=result["status"], task_id=task_id, result=result,
                    **{"last_" + result["status"]: result}, error=None)

    @staticmethod
    def _signature(folder):
        # Stat only: unchanged terminal tasks do not read JSON or chart bytes.
        result = []
        for name in ("request.json", "ready.json", "chart.jpg", "result.json"):
            path = folder / name
            if not path.exists():
                return None
            stat = plain_path(path).stat()
            result.append((stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns,
                           stat.st_dev, stat.st_ino))
        return tuple(result)

    def _retire(self, tasks):
        now = time.time()
        if now - self._last_cleanup < 3600:
            return
        self._last_cleanup = now
        archive = self.root / ".archive"
        for folder in tasks:
            record = self.records.get(folder.name, {})
            if record.get("state") not in ("succeeded", "failed"):
                continue
            result = record.get("result", {})
            try:
                completed = datetime.fromisoformat(result["completed_at"]).timestamp()
            except (KeyError, ValueError, TypeError):
                continue
            if now - completed < COMPLETED_RETENTION_SECONDS:
                continue
            # Archive first, atomically on the same share. A failed rename
            # leaves both retry state and local worker data intact. Each task
            # fails on its own: one locked folder must not stall the others.
            try:
                archive.mkdir(exist_ok=True)
                plain_path(archive)
                os.replace(plain_path(folder), archive / folder.name)
            except OSError as exc:
                LOG.warning("Calibration retention: could not archive %s: %s", folder.name, exc)
                continue
            self._terminal_signatures.pop(folder.name, None)
            self._completed_checks.pop(folder.name, None)
            # The record outlives a failed local cleanup; the loop below
            # retries it because the share folder is now gone.
            if self._drop_local(folder.name):
                del self.records[folder.name]
                self._save()
        # Covers a crash after archive rename, and tasks removed by an
        # administrator. Never prune a pending/publishing record this way.
        for task_id, record in list(self.records.items()):
            if record.get("state") not in ("succeeded", "failed") or (self.root / task_id).exists():
                continue
            try:
                if str(uuid.UUID(task_id)) != task_id:
                    continue
                completed = datetime.fromisoformat(record["result"]["completed_at"]).timestamp()
            except (ValueError, KeyError, TypeError):
                continue
            if now - completed < COMPLETED_RETENTION_SECONDS:
                continue
            self._terminal_signatures.pop(task_id, None)
            self._completed_checks.pop(task_id, None)
            if self._drop_local(task_id):
                del self.records[task_id]
                self._save()
        if archive.exists():
            plain_path(archive)
            for folder in sorted(archive.iterdir()):
                try:
                    if str(uuid.UUID(folder.name)) != folder.name:
                        continue
                    plain_path(folder)
                    result = read_json(folder / "result.json")[0]
                    completed = datetime.fromisoformat(result["completed_at"]).timestamp()
                    if now - completed > ARCHIVE_RETENTION_SECONDS:
                        shutil.rmtree(folder)
                except (OSError, ProtocolError, ValueError, KeyError, TypeError) as exc:
                    # Kept for inspection (an archive entry without a readable
                    # result has no known age); never blocks the other entries.
                    LOG.info("Calibration archive entry %s kept: %s", folder.name, exc)
                    continue

    def _drop_local(self, task_id):
        """Remove a retired task's local work folder; False keeps its record."""
        work = self.local / task_id
        try:
            if work.exists():
                shutil.rmtree(plain_path(work))
        except OSError as exc:
            LOG.warning("Calibration retention: could not remove local work for %s: %s", task_id, exc)
            return False
        return True

    def _note_ignored(self, name):
        # Dot entries (.archive, .consumer.lock) belong to the protocol.
        if name.startswith(".") or name in self._ignored_names:
            return
        if len(self._ignored_names) >= IGNORED_NAME_LOG_LIMIT:
            return
        self._ignored_names.add(name)
        LOG.warning("Calibration: ignoring %r, not a canonical task id", name)

    def tick(self):
        plain_path(self.config.input_root)
        self.root.mkdir(exist_ok=True)
        plain_path(self.root)
        if self.lock is None:
            self.lock = RootLock(self.root)
        tasks = []
        for p in self.root.iterdir():
            try:
                canonical = str(uuid.UUID(p.name)) == p.name
            except ValueError:
                canonical = False
            if not canonical:
                self._note_ignored(p.name)
                continue
            if p.is_dir() and (p / "ready.json").is_file():
                tasks.append(p)
        tasks.sort()
        try:
            self._retire(tasks)
        except OSError as exc:
            LOG.warning("Calibration retention deferred: %s", exc)
        self.status(state="idle", error=None, queued=sum(self.records.get(p.name, {}).get("state") not in ("succeeded", "failed") for p in tasks))
        for folder in tasks:
            if self.stop.is_set():
                return
            try:
                if not folder.exists():
                    continue  # Retired above.
                signature = self._signature(folder)
                terminal = self.records.get(folder.name, {}).get("state") in ("succeeded", "failed")
                if terminal and signature is not None and self._terminal_signatures.get(folder.name) == signature:
                    continue
                self.process(plain_path(folder))
                # Cache only the pre-check signature: concurrent edits cause
                # another validation, never an unchecked cache hit.
                if terminal and signature is not None:
                    self._terminal_signatures[folder.name] = signature
            except InterruptedError:
                return
            except Exception as exc:
                LOG.warning("Calibration %s: %s", folder.name, exc)
                self.status(state="publishing" if self.records.get(folder.name, {}).get("state") == "publishing" else "file_access_failed", task_id=folder.name, error=str(exc))


class CalibrationMonitor:
    """Same service lifecycle, independent of document worker restarts."""
    def __init__(self, config_path, shared_state):
        self.path = config_path
        self.shared = shared_state
        self.stop = threading.Event()
        self.queue = None
        self.view = {}
        self.thread = threading.Thread(target=self.run, name="lwip-calibration", daemon=True)

    def update(self, **values):
        for key in ("last_succeeded", "last_failed"):
            if key in values and self.view.get(key, {}).get("completed_at", "") > values[key].get("completed_at", ""):
                del values[key]
        self.view.update(values)
        self.shared.update(calibration=dict(self.view))

    def run(self):
        from .config import load_config
        while not self.stop.is_set():
            try:
                config = load_config(self.path)
                if self.queue is None or self.queue.config.input_root != config.input_root:
                    if self.queue:
                        self.queue.close()
                    self.queue = CalibrationQueue(config, self.update)
                self.queue.tick()
            except Exception as exc:
                self.update(state="unavailable", error=str(exc))
            self.stop.wait(2)
        if self.queue:
            self.queue.close()

    def close(self):
        self.stop.set()
        if self.queue:
            self.queue.stop.set()
            child = self.queue.child
            if child and child.poll() is None:
                child.terminate()
        self.thread.join(timeout=5)

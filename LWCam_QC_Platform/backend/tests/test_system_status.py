"""Heartbeat state rules, status page rules, the schema-too-old gate, and the heartbeat upsert shape."""

from __future__ import annotations

import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

from app.core.errors import BusinessError
from app.db import session as db_session
from app.services import heartbeat, schema_check
from app.services.sweep import PeriodicSweep

MIN = 60.0


def state(part="qc", seen=30.0, ok=30.0, err=None, backlog=None):
    return heartbeat.heartbeat_state(part, seen, ok, err, backlog)


class StateRules(unittest.TestCase):
    def test_fresh_and_ok_is_green(self) -> None:
        self.assertEqual(state(), "green")

    def test_stale_is_red_upload_gets_15_minutes(self) -> None:
        self.assertEqual(state(seen=6 * MIN), "red")
        self.assertEqual(state("upload", seen=10 * MIN), "green")
        self.assertEqual(state("upload", seen=16 * MIN), "red")

    def test_error_newer_than_last_ok_is_red_at_any_age(self) -> None:
        self.assertEqual(state(ok=5 * MIN, err=2 * MIN), "red")
        self.assertEqual(state(ok=1 * MIN, err=2 * MIN), "green")
        self.assertEqual(state(ok=None, err=3600.0), "red")

    def test_backup_judged_by_last_ok(self) -> None:
        self.assertEqual(state("backup", seen=9e5, ok=25 * 3600.0), "green")
        self.assertEqual(state("backup", ok=27 * 3600.0), "red")
        self.assertEqual(state("backup", ok=None), "red")

    def test_capture_off_is_grey_not_red(self) -> None:
        self.assertEqual(state("capture", seen=3 * 3600.0, backlog={"held": 0}), "grey")
        self.assertEqual(state("capture", seen=10.0, backlog={"held": 0}), "green")

    def test_capture_red_only_on_a_real_problem(self) -> None:
        self.assertEqual(state("capture", backlog={"held": 2}), "red")
        self.assertEqual(state("capture", seen=3 * 3600.0, backlog={"oldest_unsent_minutes": 61}), "red")
        self.assertEqual(state("capture", backlog={"oldest_unsent_minutes": 60}), "green")
        self.assertEqual(state("capture", ok=5 * MIN, err=1 * MIN), "red")

    def test_backlog_problems_are_red(self) -> None:
        self.assertEqual(state("qc-export", backlog={"failures": 1}), "red")
        self.assertEqual(state("lwip", backlog={"failed": 1}), "red")
        self.assertEqual(state("lwip", backlog={"oldest_waiting_minutes": 121}), "red")
        self.assertEqual(state("lwip", backlog={"oldest_waiting_minutes": 120, "failed": 0}), "green")
        self.assertEqual(state("upload", backlog={"failed": 3}), "red")

    def test_new_backlog_red_rules(self) -> None:
        self.assertEqual(state("lwip", backlog={"oldest_unreported_minutes": 121}), "red")
        self.assertEqual(state("lwip", backlog={"oldest_unreported_minutes": 120}), "green")
        self.assertEqual(state("upload", backlog={"last_scan_minutes_ago": 16, "scan_interval_minutes": 1}), "red")
        self.assertEqual(state("upload", backlog={"last_scan_minutes_ago": 15, "scan_interval_minutes": 1}), "green")
        self.assertEqual(state("upload", backlog={"last_scan_minutes_ago": 40, "scan_interval_minutes": 15}), "green")
        self.assertEqual(state("upload", backlog={"last_scan_minutes_ago": 46, "scan_interval_minutes": 15}), "red")
        self.assertEqual(state("upload", backlog={"db_pending": 9}), "green")
        self.assertEqual(state("upload", backlog={"last_scan_minutes_ago": 500}), "green")  # scan_interval missing
        self.assertEqual(state("upload", backlog={"scan_interval_minutes": 5}), "green")  # service switched off
        self.assertEqual(state("capture", backlog={"oldest_transfer_wait_minutes": 61}), "red")
        self.assertEqual(state("capture", backlog={"oldest_transfer_wait_minutes": 60}), "green")

    def test_qc_red_rules(self) -> None:
        self.assertEqual(state("qc", backlog={"approved_not_exported": 2, "oldest_approved_minutes": 31}), "red")
        self.assertEqual(state("qc", backlog={"approved_not_exported": 2, "oldest_approved_minutes": 30}), "green")
        self.assertEqual(state("qc", backlog={"approved_not_exported": 0, "oldest_approved_minutes": 99}), "green")
        self.assertEqual(state("qc", backlog={"input_unreachable": True}), "red")
        self.assertEqual(state("qc", backlog={"exports_busy": 4}), "green")


class QcHeartbeatSignals(unittest.TestCase):
    def test_input_check_times_out_as_unreachable(self) -> None:
        gate = threading.Event()

        def hang(_):
            gate.wait(5)
            return Path("x")

        with mock.patch.object(heartbeat, "to_local", hang), mock.patch.object(heartbeat, "INPUT_CHECK_TIMEOUT", 0.2):
            self.assertTrue(heartbeat.input_unreachable(r"C:\a\20260909\f"))
        gate.set()

    def test_input_check_three_states(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(heartbeat.settings, "qc_images_root", tmp):
            (Path(tmp) / "20260909" / "f").mkdir(parents=True)
            self.assertFalse(heartbeat.input_unreachable(r"C:\a\20260909\f"))  # reachable
            self.assertFalse(heartbeat.input_unreachable(r"C:\a\20260909\gone"))  # not found
        with mock.patch.object(heartbeat.settings, "qc_images_root", r"Z:\no-such-root-xyz"):
            self.assertTrue(heartbeat.input_unreachable(r"C:\a\20260909\f"))  # unreachable
        self.assertFalse(heartbeat.input_unreachable(None))

    def test_scan_records_preflight_problem_then_clears_it(self) -> None:
        from app.services import export

        sched = export.ExportAutoScheduler()
        ready = {"ready": False, "errors": [
            {"errorKey": "pathNotWritable", "errorParams": {"setting": "EXPORT_OUTPUT_DIR", "path": r"\X\Y"}}]}
        coordinator = export.export_coordinator
        with mock.patch.object(export, "SessionLocal"), \
                mock.patch.object(export, "eligible_folder_ids", return_value=[1]), \
                mock.patch.object(coordinator, "preflight", return_value=ready), \
                mock.patch.object(coordinator, "read_failures", return_value=[]), \
                mock.patch.object(coordinator, "current", return_value=None):
            self.assertEqual(sched.scan_once(), 0)
        self.assertIn(r"\X\Y", sched.blocked_reason)
        self.assertIn("not writable", sched.blocked_reason)
        with mock.patch.object(export, "SessionLocal"), \
                mock.patch.object(export, "eligible_folder_ids", return_value=[]), \
                mock.patch.object(coordinator, "read_failures", return_value=[]), \
                mock.patch.object(coordinator, "current", return_value=None):
            sched.scan_once()
        self.assertIsNone(sched.blocked_reason)

    def test_engine_uses_tcp_keepalives(self) -> None:
        import inspect

        source = inspect.getsource(db_session)
        for key in ("keepalives", "keepalives_idle", "keepalives_interval", "keepalives_count", "connect_timeout"):
            self.assertIn(f'"{key}"', source)


class _Result:
    def __init__(self, rows=(), rowcount=0):
        self._rows, self.rowcount = rows, rowcount

    def mappings(self):
        return self

    def all(self):
        return list(self._rows)


class _Db:
    def __init__(self, rows=(), rowcount=0, upload_failed=0):
        self.rows, self.rowcount, self.upload_failed = rows, rowcount, upload_failed
        self.sql = []

    def execute(self, statement, params=None):
        self.sql.append(str(statement))
        return _Result(self.rows, self.rowcount)

    def scalar(self, statement):
        self.sql.append(str(statement))
        return self.upload_failed

    def commit(self):
        pass


def _row(part, host="pc1", seen=10.0, ok=10.0, err=None, backlog=None):
    return {"part": part, "host": host, "version": "1", "started_at": None, "last_seen": None,
            "last_ok": None, "last_error": None, "last_error_at": None, "backlog": backlog or {},
            "seen_age": seen, "ok_age": ok, "err_age": err}


class SystemStatusRules(unittest.TestCase):
    def status(self, db, **kw):
        with mock.patch.object(schema_check, "schema_level", return_value=8):
            return heartbeat.system_status(db, **kw)

    def test_ages_come_from_sql_now_and_old_rows_are_hidden(self) -> None:
        db = _Db()
        self.status(db)
        self.assertIn("EXTRACT(EPOCH FROM (now() - last_seen))", db.sql[0])
        self.assertIn("interval '7 days'", db.sql[0])
        db = _Db()
        self.status(db, show_all=True)
        self.assertNotIn("interval '7 days'", db.sql[0])

    def test_missing_expected_parts_are_red_never_reported(self) -> None:
        out = self.status(_Db([_row("qc")]))
        missing = {s["part"] for s in out["services"] if s.get("neverReported")}
        self.assertEqual(missing, {"qc-export", "lwip", "upload", "backup"})
        self.assertTrue(out["anyRed"])
        self.assertTrue(all(s["state"] == "red" for s in out["services"] if s.get("neverReported")))

    def test_offline_capture_does_not_raise_the_banner(self) -> None:
        rows = [_row(p) for p in ("qc", "qc-export", "lwip", "upload")] + [
            _row("backup", ok=3600.0), _row("capture", host="cam1", seen=99999.0)]
        out = self.status(_Db(rows))
        self.assertEqual([s["state"] for s in out["services"] if s["part"] == "capture"], ["grey"])
        self.assertFalse(out["anyRed"])

    def test_upload_failed_folders_exclude_deleted_and_feed_any_red(self) -> None:
        rows = [_row(p) for p in ("qc", "qc-export", "lwip", "upload")] + [_row("backup", ok=3600.0)]
        db = _Db(rows, upload_failed=2)
        out = self.status(db)
        self.assertTrue(out["anyRed"])
        self.assertEqual(out["uploadFailedFolders"], 2)
        self.assertIn("is_deleted", db.sql[-1])

    def test_forget_host(self) -> None:
        self.assertTrue(heartbeat.forget_host(_Db(rowcount=1), "capture", "cam1"))
        self.assertFalse(heartbeat.forget_host(_Db(rowcount=0), "capture", "cam1"))

    def test_forget_route_404_when_unknown(self) -> None:
        from app.routers import admin

        with self.assertRaises(BusinessError) as caught:
            admin.forget_pc_route("capture", "nope", None, _Db(rowcount=0))
        self.assertEqual(caught.exception.http_status, 404)
        self.assertEqual(admin.forget_pc_route("capture", "cam1", None, _Db(rowcount=1)).code, 0)

    def test_heartbeat_error_text_is_short(self) -> None:
        failure = [{"failedAt": "2026-09-30T00:00:00+00:00", "error": "x" * 900}]
        db = mock.MagicMock()
        db.execute.return_value.one.return_value = (3, 45.7)
        db.scalar.side_effect = [5, r"C:\x\20260909\f"]
        session = mock.MagicMock()
        session.return_value.__enter__.return_value = db
        with mock.patch.object(heartbeat, "SessionLocal", session), mock.patch.object(
            heartbeat.export_coordinator, "read_failures", return_value=failure
        ), mock.patch.object(heartbeat.export_coordinator, "current", return_value={"skipped": 2}), \
                mock.patch.object(heartbeat, "input_unreachable", return_value=True):
            rows = heartbeat._rows()
        self.assertLessEqual(len(rows[1]["last_error"]), 200)
        self.assertEqual(rows[0]["backlog"], {
            "pending_review": 5, "approved_not_exported": 3, "oldest_approved_minutes": 45,
            "exports_busy": 2, "input_unreachable": True})
        self.assertTrue(rows[0]["last_error"])


class SchemaGate(unittest.TestCase):
    def tearDown(self) -> None:
        schema_check._cache = None

    def test_old_schema_answers_503_schema_too_old(self) -> None:
        with mock.patch.object(schema_check, "read_level", return_value=7):
            schema_check._cache = None
            with self.assertRaises(BusinessError) as caught:
                next(db_session.get_db())
        error = caught.exception
        self.assertEqual(error.http_status, 503)
        self.assertEqual(error.data["errorKey"], "schemaTooOld")
        self.assertIn("needs level 8, has 7", error.message)

    def test_current_schema_passes_and_unreachable_db_is_not_blamed(self) -> None:
        for level in (8, 9, None):
            schema_check._cache = None
            with mock.patch.object(schema_check, "read_level", return_value=level):
                schema_check.ensure_current()


class SchemaGateHardening(unittest.TestCase):
    def tearDown(self) -> None:
        schema_check._cache = None

    def _read_with(self, code):
        from sqlalchemy.exc import ProgrammingError

        orig = type("Orig", (Exception,), {"sqlstate": code})()
        with mock.patch.object(schema_check.engine, "connect", side_effect=ProgrammingError("q", {}, orig)):
            return schema_check.read_level()

    def test_only_undefined_table_is_level_zero(self) -> None:
        self.assertEqual(self._read_with("42P01"), 0)
        self.assertEqual(self._read_with("42501"), schema_check.NO_GRANT)
        self.assertIsNone(self._read_with("57014"))

    def test_permission_error_is_not_reported_as_too_old(self) -> None:
        message = schema_check.too_old_message(schema_check.NO_GRANT)
        self.assertIn("cannot read schema_migrations", message)
        self.assertIn("re-run LWCamDatabaseSetup", message)
        self.assertNotIn("older", message)

    def test_failure_is_cached_for_five_seconds(self) -> None:
        clock = [1000.0]
        with mock.patch.object(schema_check.time, "monotonic", side_effect=lambda: clock[0]), \
                mock.patch.object(schema_check, "read_level", return_value=None) as read:
            schema_check.schema_level()
            schema_check.schema_level()
            self.assertEqual(read.call_count, 1)
            clock[0] += 6
            schema_check.schema_level()
            self.assertEqual(read.call_count, 2)

    def test_query_runs_outside_the_lock(self) -> None:
        def check():
            self.assertFalse(schema_check._lock.locked())
            return 8

        with mock.patch.object(schema_check, "read_level", side_effect=check):
            schema_check.schema_level(force=True)

    def test_sweep_skips_ticks_while_schema_is_old(self) -> None:
        for level, expect_ticks in ((7, False), (8, True)):
            schema_check._cache = None
            ticks = []
            sweep = PeriodicSweep("t", tick=lambda: ticks.append(1), interval=lambda: 0.01)
            with mock.patch.object(schema_check, "read_level", return_value=level):
                sweep.start()
                time.sleep(0.3)
                sweep.stop()
            self.assertEqual(bool(ticks), expect_ticks)

    def test_export_number_comes_from_the_db_function(self) -> None:
        from app.services import export

        db = mock.MagicMock()
        db.scalar.return_value = 41
        self.assertEqual(export.allocate_sequence(db, 5), 41)
        self.assertIn("lwcam_next_export_number", str(db.scalar.call_args[0][0]))
        self.assertNotIn("CREATE SEQUENCE", " ".join(str(c) for c in db.execute.call_args_list))


class HeartbeatSql(unittest.TestCase):
    def test_upsert_shape(self) -> None:
        sql = str(heartbeat.UPSERT_SQL)
        self.assertIn("INSERT INTO service_heartbeat", sql)
        self.assertIn("ON CONFLICT (part, host) DO UPDATE", sql)
        self.assertIn("last_seen = now()", sql)
        self.assertIn("COALESCE(EXCLUDED.last_ok", sql)

    def test_beat_never_raises(self) -> None:
        with mock.patch.object(heartbeat, "_rows", side_effect=RuntimeError("db down")):
            heartbeat.beat()


if __name__ == "__main__":
    unittest.main()

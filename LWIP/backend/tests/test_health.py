"""Heartbeat upsert, backlog shape, and the schema-too-old pause (Phase 3)."""

from __future__ import annotations

import json
import unittest
from unittest import mock

from deskew_crop_tool import cloud_report, health
from deskew_crop_tool.cloud_report import PgSettings
from deskew_crop_tool.orchestrator import FolderOrchestrator


class Cur:
    def __init__(self, level: int | None) -> None:
        self.level = level  # None = no schema_migrations table
        self.executed: list[tuple[str, object]] = []
        self._row = None

    def execute(self, sql, params=None) -> None:
        self.executed.append((sql, params))
        if "to_regclass" in sql:
            self._row = (self.level is not None,)
        elif "max(" in sql:
            self._row = (self.level,)

    def fetchone(self):
        return self._row

    def __enter__(self):
        return self

    def __exit__(self, *a) -> bool:
        return False


class Conn:
    def __init__(self, level) -> None:
        self.cur = Cur(level)
        self.committed = False

    def cursor(self):
        return self.cur

    def commit(self) -> None:
        self.committed = True

    def __enter__(self):
        return self

    def __exit__(self, *a) -> bool:
        return False


class HeartbeatTests(unittest.TestCase):
    def test_upsert_sql_and_params(self) -> None:
        conn = Conn(7)
        hb = health.Heartbeat("lwip", lambda: conn, version="1.1.0+abc", host="PC1")
        hb.beat({"waiting": 2, "oldest_waiting_minutes": 5, "failed": 1})
        sql, params = conn.cur.executed[-1]
        self.assertIn("INSERT INTO service_heartbeat", sql)
        self.assertIn("ON CONFLICT (part, host) DO UPDATE", sql)
        self.assertEqual((params["part"], params["host"], params["version"]), ("lwip", "PC1", "1.1.0+abc"))
        self.assertEqual(json.loads(params["backlog"])["waiting"], 2)
        self.assertIsNone(params["error"])
        self.assertTrue(conn.committed)
        self.assertIsNone(hb.schema_problem)

    def test_backlog_shape_and_oldest(self) -> None:
        seen: dict[str, float] = {}
        health.backlog_of(["a", "b"], [], seen, now=0.0)
        out = health.backlog_of(["b", "c"], [{"folder": "x"}], seen, now=180.0)
        self.assertEqual(out, {"waiting": 2, "oldest_waiting_minutes": 3, "failed": 1,
                                "unreported": 0, "oldest_unreported_minutes": 0})
        self.assertNotIn("a", seen)

    def test_schema_too_old_sets_problem_and_writes_nothing(self) -> None:
        conn = Conn(6)
        hb = health.Heartbeat("lwip", lambda: conn, version="dev", host="PC1")
        hb.beat({})
        self.assertIn("needs level 7, has 6", hb.schema_problem)
        self.assertIn("Run LWCamDatabaseSetup on the database PC.", hb.schema_problem)
        self.assertFalse(any("service_heartbeat" in s for s, _ in conn.cur.executed))

    def test_missing_migrations_table_is_level_zero(self) -> None:
        hb = health.Heartbeat("lwip", lambda: Conn(None), version="dev", host="PC1")
        hb.beat({})
        self.assertIn("has 0", hb.schema_problem)

    def test_failure_is_swallowed_and_logged_once(self) -> None:
        def boom():
            raise OSError("down")

        hb = health.Heartbeat("lwip", boom, version="dev", host="PC1")
        with self.assertLogs("deskew_crop_tool.health", "WARNING") as logs:
            hb.beat({})
            hb.beat({})
        self.assertEqual(len(logs.records), 1)


class SchemaPauseTests(unittest.TestCase):
    def make(self) -> FolderOrchestrator:
        o = FolderOrchestrator.__new__(FolderOrchestrator)
        o._pg = PgSettings("h", 5432, "d", "u", "p")
        o.state = mock.Mock(data={"completed": {}})
        return o

    def test_too_old_pauses_reporting(self) -> None:
        o = self.make()
        with mock.patch.object(cloud_report, "check_schema", return_value=6):
            self.assertTrue(o._schema_too_old(cloud_report))

    def test_current_or_unknown_does_not_pause(self) -> None:
        for level in (7, 9, None):
            o = self.make()
            with mock.patch.object(cloud_report, "check_schema", return_value=level):
                self.assertFalse(o._schema_too_old(cloud_report))

    def test_sweep_does_not_report_when_too_old(self) -> None:
        o = self.make()
        with mock.patch.object(cloud_report, "check_schema", return_value=3), \
                mock.patch.object(cloud_report, "report_folder") as report:
            o._sweep_unreported()
        report.assert_not_called()


if __name__ == "__main__":
    unittest.main()

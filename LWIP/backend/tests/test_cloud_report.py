"""Contract tests for the PostgreSQL reporter.

Two things matter here and neither needs a database.

1. The UPDATE must write exactly the columns `folderProcessingUpdateSql` writes
   (LWCAM's lib/services/pg_statements.dart). LWCAM's report agent writes the
   same row from the same manifest, and the two writes have to be
   indistinguishable - otherwise "whichever arrives first wins" stops being safe.

2. Each outcome must map to the right retry decision. A folder that is merely
   early (its row has not synced yet) must be retried forever; a folder that can
   never be resolved must be settled, or the sweep spins on it for the life of
   the station.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from deskew_crop_tool.cloud_report import (
    PgSettings,
    ReportResult,
    identity_of,
    report_folder,
    settings_from_config,
)
from deskew_crop_tool.config import ToolConfig

SETTINGS = PgSettings(
    host="localhost", port=5432, dbname="lwcam", user="postgres", password="x"
)

MANIFEST = {
    "source_fingerprint": "abc",
    "source_identity": {
        "project_key": "pmtba3kijvb2sve",
        "box_name": "Baptism Records",
        "folder_seq": 1,
    },
    "thumbnails": {"created": True, "dirname": "thumbs"},
}


class FakeCursor:
    def __init__(self, rows) -> None:
        self._rows = list(rows)
        self.executed: list[tuple[str, object]] = []
        self._last = None

    def execute(self, sql, params=None) -> None:
        self.executed.append((sql, params))
        if sql.lstrip().upper().startswith("SELECT"):
            self._last = self._rows.pop(0) if self._rows else None

    def fetchone(self):
        return self._last

    def __enter__(self):
        return self

    def __exit__(self, *args) -> bool:
        return False


class FakeConn:
    def __init__(self, rows) -> None:
        self.cursor_obj = FakeCursor(rows)
        self.committed = False

    def cursor(self):
        return self.cursor_obj

    def commit(self) -> None:
        self.committed = True

    def __enter__(self):
        return self

    def __exit__(self, *args) -> bool:
        return False


def connector(rows, box=None):
    """A connect() stand-in. `box` captures the connection for assertions."""

    def _connect(**_kwargs):
        conn = FakeConn(rows)
        if box is not None:
            box.append(conn)
        return conn

    return _connect


class CloudReportWriteTests(unittest.TestCase):
    def test_reports_and_writes_the_expected_columns(self) -> None:
        box: list[FakeConn] = []
        result = report_folder(
            SETTINGS,
            MANIFEST,
            Path(r"C:\out\20260901\Folder"),
            connect=connector([(7,), (11,), (23,)], box),
        )
        self.assertIs(result, ReportResult.REPORTED)
        self.assertTrue(box[0].committed)

        sql, params = box[0].cursor_obj.executed[-1]
        self.assertTrue(sql.startswith("UPDATE capture_folders SET"))
        for column in (
            "is_deskewed = TRUE",
            "is_cropped = TRUE",
            "is_created_thumbnail = %(is_created_thumbnail)s",
            "folder_path = %(folder_path)s",
            "thumbnail_path = %(thumbnail_path)s",
            "qc_status = CASE WHEN qc_status IS NULL "
            "OR upper(qc_status) IN ('', 'PENDING', 'REWORK') "
            "THEN 'PENDING' ELSE qc_status END",
        ):
            self.assertIn(column, sql)
        # A late report must never pull a PASSed folder back into the QC queue.
        self.assertNotIn("qc_status = 'PENDING'", sql)
        # ...and nothing else. A stray column here is a silent divergence from
        # the Dart writer, which is the one thing these two paths must not have.
        self.assertEqual(sql.count("="), 7)  # 6 SET terms + the WHERE

        self.assertEqual(params["folder_id"], 23)
        self.assertIs(params["is_created_thumbnail"], True)
        self.assertEqual(params["folder_path"], r"C:\out\20260901\Folder")
        self.assertEqual(
            params["thumbnail_path"],
            str(Path(r"C:\out\20260901\Folder") / "thumbs"),
        )

    def test_project_resolve_has_no_is_deleted_filter(self) -> None:
        # Must match LWCAM's own resolver (pg_statements.dart's
        # projectIdByKeySql), which never filters on is_deleted. A
        # soft-deleted project's folder used to return NOT_YET forever here -
        # retried every poll, never settled - while LWCAM wrote the row
        # regardless of the project's deleted state.
        box: list[FakeConn] = []
        report_folder(
            SETTINGS,
            MANIFEST,
            Path(r"C:\out\F"),
            connect=connector([(7,), (11,), (23,)], box),
        )
        project_sql, _ = box[0].cursor_obj.executed[0]
        self.assertIn("FROM projects", project_sql)
        self.assertNotIn("is_deleted", project_sql)

    def test_thumbnail_path_is_null_when_no_thumbnails_were_made(self) -> None:
        manifest = dict(MANIFEST, thumbnails={"created": False, "dirname": "thumbs"})
        box: list[FakeConn] = []
        self.assertIs(
            report_folder(
                SETTINGS,
                manifest,
                Path(r"C:\out\F"),
                connect=connector([(7,), (11,), (23,)], box),
            ),
            ReportResult.REPORTED,
        )
        _, params = box[0].cursor_obj.executed[-1]
        self.assertIs(params["is_created_thumbnail"], False)
        self.assertIsNone(params["thumbnail_path"])


class CloudReportRetryTests(unittest.TestCase):
    def test_unresolved_row_is_retryable_not_settled(self) -> None:
        # Each stage missing means the capture PC has not synced that row yet.
        # All three must be retryable: settling here strands the folder forever.
        for rows in ([], [(7,)], [(7,), (11,)]):
            with self.subTest(rows=len(rows)):
                self.assertIs(
                    report_folder(
                        SETTINGS,
                        MANIFEST,
                        Path(r"C:\out\F"),
                        connect=connector(rows),
                    ),
                    ReportResult.NOT_YET,
                )

    def test_missing_identity_is_terminal_and_never_connects(self) -> None:
        # No completion marker => no row can ever be resolved. The sweep settles
        # this or it retries on every poll for the life of the station.
        def _connect(**_kwargs):
            raise AssertionError("must not connect")

        for identity in ({}, {"source_identity": {"project_key": "p"}}):
            with self.subTest(identity=identity):
                manifest = dict(MANIFEST)
                manifest.pop("source_identity", None)
                manifest.update(identity)
                self.assertIs(
                    report_folder(
                        SETTINGS, manifest, Path(r"C:\out\F"), connect=_connect
                    ),
                    ReportResult.NO_IDENTITY,
                )

    def test_a_dead_database_is_retryable_and_never_raises(self) -> None:
        def _connect(**_kwargs):
            raise OSError("connection refused")

        self.assertIs(
            report_folder(SETTINGS, MANIFEST, Path(r"C:\out\F"), connect=_connect),
            ReportResult.UNREACHABLE,
        )

    def test_identity_requires_all_three_parts(self) -> None:
        self.assertEqual(
            identity_of(MANIFEST),
            {
                "project_key": "pmtba3kijvb2sve",
                "box_name": "Baptism Records",
                "folder_seq": 1,
            },
        )
        for partial in (
            {"box_name": "b", "folder_seq": 1},
            {"project_key": "p", "folder_seq": 1},
            {"project_key": "p", "box_name": "b"},
            {"project_key": " ", "box_name": "b", "folder_seq": 1},
        ):
            with self.subTest(partial=partial):
                self.assertIsNone(identity_of({"source_identity": partial}))


def _tool_config(**db_overrides: object) -> ToolConfig:
    """A ToolConfig with dummy paths - only the db_* fields matter here.

    Built directly rather than through load_config: these tests are about
    settings_from_config's own defensiveness (a ToolConfig with cloud_report
    true and blank credentials, which load_config itself already refuses to
    produce - see config.py's cloud_report check and its own tests).
    """
    # Never touches disk: settings_from_config only reads the db_* fields.
    root = Path("dummy")
    return ToolConfig(
        input_root=root / "in",
        output_root=root / "out",
        work_root=root / "work",
        state_file=root / "state.json",
        log_file=root / "tool.log",
        workers=1,
        poll_interval_seconds=1,
        stable_seconds=0,
        minimum_file_age_seconds=0,
        presence_check_interval_seconds=300,
        checksum_check_interval_seconds=86400,
        crop_padding=5,
        jpeg_quality=95,
        completion_marker=None,
        recursive=True,
        extensions=(".jpg",),
        folder_depth=1,
        thumbnail_width=0,
        thumbnail_quality=85,
        thumbnail_dirname="thumbs",
        **db_overrides,
    )


class CloudReportSettingsTests(unittest.TestCase):
    """Unconfigured must behave exactly as LWIP did before reporting existed."""

    def test_none_when_db_settings_are_blank(self) -> None:
        self.assertIsNone(settings_from_config(_tool_config()))
        self.assertIsNone(
            settings_from_config(_tool_config(db_host="", db_user="u", db_password="p"))
        )
        self.assertIsNone(
            settings_from_config(_tool_config(db_host="h", db_user="", db_password="p"))
        )
        self.assertIsNone(
            settings_from_config(_tool_config(db_host="h", db_user="u", db_password=""))
        )

    def test_full_db_settings_are_read_from_the_config(self) -> None:
        settings = settings_from_config(
            _tool_config(
                db_host="localhost",
                db_port=5432,
                db_name="lwcam",
                db_user="postgres",
                db_password="secret",
                db_use_ssl=True,
            )
        )
        self.assertIsNotNone(settings)
        assert settings is not None
        self.assertEqual(
            (settings.host, settings.port, settings.dbname, settings.user, settings.password),
            ("localhost", 5432, "lwcam", "postgres", "secret"),
        )
        self.assertTrue(settings.use_ssl)

    def test_use_ssl_defaults_false(self) -> None:
        settings = settings_from_config(
            _tool_config(db_host="h", db_user="u", db_password="p")
        )
        assert settings is not None
        self.assertFalse(settings.use_ssl)


if __name__ == "__main__":
    unittest.main()

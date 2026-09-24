"""setup_qc_db.py against a real PostgreSQL, on scratch databases only.

Each test makes its own uniquely named database, proves the name was free
before the script ran, and drops only that database afterwards. The real
`lwcam` database is never named here. Credentials come from LWCAM_DB_* in the
environment or the station's config.txt; with neither, or with no reachable
server, the tests skip.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import unittest
import uuid
from pathlib import Path
from tempfile import TemporaryDirectory

PLATFORM_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = PLATFORM_ROOT / "scripts" / "setup_qc_db.py"
DATABASE_DIR = PLATFORM_ROOT / "database"
SCRATCH_PREFIX = "lwcam_setup_test_"


def _station_credentials() -> dict[str, object] | None:
    creds: dict[str, object] = {
        "host": os.environ.get("LWCAM_DB_HOST", "localhost"),
        "port": int(os.environ.get("LWCAM_DB_PORT", "5432")),
        "user": os.environ.get("LWCAM_DB_USER", "postgres"),
        "password": os.environ.get("LWCAM_DB_PASSWORD"),
    }
    config = PLATFORM_ROOT / "config.txt"
    if creds["password"] is None and config.exists():
        keys = {"dbHost": "host", "dbPort": "port", "dbUser": "user", "dbPassword": "password"}
        for line in config.read_text(encoding="utf-8").splitlines():
            key, sep, value = line.partition("=")
            if sep and key.strip() in keys and value.strip():
                name = keys[key.strip()]
                creds[name] = int(value.strip()) if name == "port" else value.strip()
    return creds if creds["password"] else None


class SetupQcDbTests(unittest.TestCase):
    def setUp(self) -> None:
        creds = _station_credentials()
        if creds is None:
            self.skipTest("No PostgreSQL credentials available")
        self.creds = creds
        try:
            import psycopg

            self.psycopg = psycopg
            self._admin().close()
        except Exception as error:  # no driver or no server: nothing to test against
            self.skipTest(f"PostgreSQL not reachable: {type(error).__name__}")

        self.scratch_db = SCRATCH_PREFIX + uuid.uuid4().hex
        with self._admin() as conn:
            taken = conn.execute(
                "SELECT 1 FROM pg_database WHERE datname = %s", (self.scratch_db,)
            ).fetchone()
        # Outside any try: a name that is already taken must stop the test,
        # because tearDown would otherwise drop somebody else's database.
        self.assertIsNone(taken, f"{self.scratch_db} already exists; refusing to reuse it")
        # The name was free a moment ago and only the script below can create
        # it, so whatever exists under it at cleanup is this test's.
        self.addCleanup(self._drop_scratch_db)

    def _admin(self):
        return self.psycopg.connect(
            host=self.creds["host"],
            port=self.creds["port"],
            user=self.creds["user"],
            password=self.creds["password"],
            dbname="postgres",
            autocommit=True,
        )

    def _drop_scratch_db(self) -> None:
        assert self.scratch_db.startswith(SCRATCH_PREFIX)
        with self._admin() as conn:
            conn.execute(
                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
                "WHERE datname = %s AND pid <> pg_backend_pid()",
                (self.scratch_db,),
            )
            conn.execute(f'DROP DATABASE IF EXISTS "{self.scratch_db}"')

    def _server_config(self, folder: str) -> Path:
        path = Path(folder) / "config.txt"
        path.write_text(
            f"dbHost = {self.creds['host']}\n"
            f"dbPort = {self.creds['port']}\n"
            f"dbName = {self.scratch_db}\n"
            f"dbUser = {self.creds['user']}\n"
            f"dbPassword = {self.creds['password']}\n",
            encoding="utf-8",
        )
        return path

    def _run(self, mode: str, config: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "-B", str(SCRIPT), mode, str(config), "--database-dir", str(DATABASE_DIR)],
            capture_output=True,
            text=True,
        )

    def _assert_schema_complete(self) -> None:
        with self.psycopg.connect(
            host=self.creds["host"],
            port=self.creds["port"],
            user=self.creds["user"],
            password=self.creds["password"],
            dbname=self.scratch_db,
        ) as conn:
            for column in ("qc_locked_by", "qc_reviewed_by", "separated_from_folder_id"):
                present = conn.execute(
                    "SELECT EXISTS (SELECT 1 FROM information_schema.columns "
                    "WHERE table_schema = 'public' AND table_name = 'capture_folders' "
                    "AND column_name = %s)",
                    (column,),
                ).fetchone()[0]
                self.assertTrue(present, f"capture_folders.{column} missing")
            role = conn.execute("SELECT 1 FROM public.roles WHERE lower(role_name) = 'qc'").fetchone()
            self.assertIsNotNone(role, "qc role missing")

    def test_server_config_builds_a_complete_schema(self) -> None:
        with TemporaryDirectory() as folder:
            result = self._run("--server-config", self._server_config(folder))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Database ready", result.stdout)
        self._assert_schema_complete()

    def test_node_config_builds_a_complete_schema(self) -> None:
        with TemporaryDirectory() as folder:
            path = Path(folder) / "lwcam_node_config.json"
            path.write_text(
                json.dumps(
                    {
                        "pgHost": self.creds["host"],
                        "pgPort": self.creds["port"],
                        "pgDatabase": self.scratch_db,
                        "pgUser": self.creds["user"],
                        "pgPassword": self.creds["password"],
                    }
                ),
                encoding="utf-8",
            )
            result = self._run("--config", path)
        self.assertEqual(result.returncode, 0, result.stderr)
        self._assert_schema_complete()

    def test_a_second_run_upgrades_in_place(self) -> None:
        """The second run takes the existing-database path: migrations only, never the pg_dump."""
        with TemporaryDirectory() as folder:
            config = self._server_config(folder)
            first = self._run("--server-config", config)
            self.assertEqual(first.returncode, 0, first.stderr)
            second = self._run("--server-config", config)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("Database ready", second.stdout)
        self._assert_schema_complete()

    def test_a_bad_ssl_word_is_reported_not_guessed(self) -> None:
        with TemporaryDirectory() as folder:
            config = self._server_config(folder)
            with config.open("a", encoding="utf-8") as handle:
                handle.write("dbUseSsl = maybe\n")
            result = self._run("--server-config", config)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dbUseSsl", result.stderr)
        self.assertNotIn(str(self.creds["password"]), result.stderr + result.stdout)

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

PLATFORM_SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
sys.path.insert(0, str(PLATFORM_SCRIPTS))
import setup_qc_db  # noqa: E402

PLATFORM_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = PLATFORM_ROOT / "scripts" / "setup_qc_db.py"
CHECK_GRANTS = PLATFORM_ROOT / "scripts" / "check_role_grants.py"
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
        # Cleanups run last-in first: the logins (cluster-wide roles) go after the database.
        self.logins: list[str] = []
        self.addCleanup(self._drop_logins)
        self.addCleanup(self._drop_scratch_db)

    def _drop_logins(self) -> None:
        with self._admin() as conn:
            for name in self.logins:
                assert name.startswith("lwcam_t_")
                conn.execute(f'DROP ROLE IF EXISTS "{name}"')

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

    def _run(self, mode: str, config: Path, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "-B", str(SCRIPT), mode, str(config), "--database-dir", str(DATABASE_DIR), *extra],
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
            for column in ("qc_locked_by", "qc_reviewed_by", "separated_from_folder_id", "upload_error"):
                present = conn.execute(
                    "SELECT EXISTS (SELECT 1 FROM information_schema.columns "
                    "WHERE table_schema = 'public' AND table_name = 'capture_folders' "
                    "AND column_name = %s)",
                    (column,),
                ).fetchone()[0]
                self.assertTrue(present, f"capture_folders.{column} missing")
            role = conn.execute("SELECT 1 FROM public.roles WHERE lower(role_name) = 'qc'").fetchone()
            self.assertIsNotNone(role, "qc role missing")
            recorded = {r[0] for r in conn.execute("SELECT version FROM public.schema_migrations").fetchall()}
            files = {p.stem for p in (DATABASE_DIR / "migrations").glob("*.sql")}
            self.assertEqual(recorded, files, "every applied migration must be recorded")
            level = conn.execute(
                "SELECT coalesce(max(substring(version from '^[0-9]+')::int), 0) FROM public.schema_migrations"
            ).fetchone()[0]
            self.assertGreaterEqual(level, 8)
            self.assertIsNotNone(conn.execute("SELECT to_regclass('public.service_heartbeat')").fetchone()[0])

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

    def _new_login(self) -> str:
        name = "lwcam_t_" + uuid.uuid4().hex[:12]
        self.logins.append(name)  # dropped by _drop_logins, after the database
        return name

    def _check_grants(self, config: Path, *extra: str, password: str | None = None) -> None:
        env = {**os.environ, "LWCAM_APP_PASSWORD": password} if password else None
        check = subprocess.run(
            [sys.executable, "-B", str(CHECK_GRANTS), "--db", self.scratch_db, "--config", str(config), *extra],
            capture_output=True, text=True, env=env,
        )
        self.assertEqual(check.returncode, 0, check.stdout[-3000:] + check.stderr)

    def test_app_login_gets_the_shared_privileges_and_keeps_secrets(self) -> None:
        """--app-login makes one login that can do everything the parts need and nothing else
        (check_role_grants.py signs in as it), is re-runnable, and never prints the password."""
        login, password = self._new_login(), "Probe-Password-" + uuid.uuid4().hex
        env = {**os.environ, "LWCAM_APP_PASSWORD": password}
        with TemporaryDirectory() as folder:
            config = self._server_config(folder)
            for _ in range(2):  # the second run is the upgrade path: everything is already there
                run = subprocess.run(
                    [sys.executable, "-B", str(SCRIPT), "--server-config", str(config), "--database-dir",
                     str(DATABASE_DIR), "--app-login", login],
                    capture_output=True, text=True, env=env)
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertNotIn(password, run.stdout + run.stderr)
            # without a password in the environment an existing login keeps the old one
            keep = subprocess.run(
                [sys.executable, "-B", str(SCRIPT), "--server-config", str(config), "--database-dir",
                 str(DATABASE_DIR), "--app-login", login],
                capture_output=True, text=True, env={k: v for k, v in os.environ.items() if k != "LWCAM_APP_PASSWORD"})
            self.assertEqual(keep.returncode, 0, keep.stderr)
            self.assertIn("password kept", keep.stdout)
            # The probes seed rows, so run them once; they sign in with the password the FIRST run set.
            self._check_grants(config, "--login-user", login, password=password)

    @unittest.skipUnless(sys.platform == "win32", "DPAPI")
    def test_encrypted_passwords_in_database_txt_are_read_and_app_password_comes_from_the_file(self) -> None:
        """database.txt keeps dbPassword/appPassword as "dpapi:..."; setup decrypts both, and with no
        LWCAM_APP_PASSWORD the app login gets the file's appPassword."""
        sys.path.insert(0, str(SCRIPT.parent))
        import lwcam_secrets
        login, password = self._new_login(), "Probe-Password-" + uuid.uuid4().hex
        with TemporaryDirectory() as folder:
            config = self._server_config(folder)
            text = config.read_text(encoding="utf-8").replace(
                f"dbPassword = {self.creds['password']}",
                f"dbPassword = {lwcam_secrets.protect(str(self.creds['password']))}")
            config.write_text(text + f"appPassword = {lwcam_secrets.protect(password)}\n", encoding="utf-8")
            self.assertNotIn(password, config.read_text(encoding="utf-8"))
            env = {k: v for k, v in os.environ.items() if k != "LWCAM_APP_PASSWORD"}
            run = subprocess.run(
                [sys.executable, "-B", str(SCRIPT), "--server-config", str(config), "--database-dir",
                 str(DATABASE_DIR), "--app-login", login],
                capture_output=True, text=True, env=env)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertNotIn(password, run.stdout + run.stderr)
            with self.psycopg.connect(host=self.creds["host"], port=self.creds["port"], dbname=self.scratch_db,
                                      user=login, password=password, connect_timeout=10) as conn:
                self.assertEqual(conn.execute("SELECT 1").fetchone()[0], 1)

    def test_app_login_is_refused_without_a_password_or_with_a_bad_name_or_password(self) -> None:
        login = self._new_login()
        base_env = {k: v for k, v in os.environ.items() if k != "LWCAM_APP_PASSWORD"}
        with TemporaryDirectory() as folder:
            config = self._server_config(folder)
            for name, env_password, wanted in (
                (login, None, "LWCAM_APP_PASSWORD"),
                (login, "short", "at least"),
                (login, "twelve chars\x01!!", "control"),
                ("postgres", "Probe-Password-123456", "reserved"),
                ("lwcam_app", "Probe-Password-123456", "reserved"),
                ("Bad-Name", "Probe-Password-123456", "user name"),
            ):
                env = dict(base_env, **({"LWCAM_APP_PASSWORD": env_password} if env_password else {}))
                run = subprocess.run(
                    [sys.executable, "-B", str(SCRIPT), "--server-config", str(config), "--database-dir",
                     str(DATABASE_DIR), "--app-login", name],
                    capture_output=True, text=True, env=env)
                self.assertNotEqual(run.returncode, 0, name)
                self.assertIn(wanted, run.stderr)
                if env_password:
                    self.assertNotIn(env_password, run.stdout + run.stderr)
            with self._admin() as conn:
                self.assertIsNone(conn.execute("SELECT 1 FROM pg_database WHERE datname = %s",
                                               (self.scratch_db,)).fetchone(), "nothing may be created")
                self.assertIsNone(conn.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (login,)).fetchone())

    def test_the_old_per_part_logins_still_work_as_members_of_the_group(self) -> None:
        """Only on a cluster that still has them (the live PC does): a database gets the
        migrations (twice); every old login becomes a member of lwcam_app and SET ROLE to one of
        them still does everything the parts need."""
        with self._admin() as conn:
            live = conn.execute(
                "SELECT count(*) FROM pg_roles WHERE rolname = ANY(%s)", (list(setup_qc_db.MODULE_ROLES),)
            ).fetchone()[0]
        if live != len(setup_qc_db.MODULE_ROLES):
            self.skipTest("the old part logins do not exist here")
        with TemporaryDirectory() as folder:
            config = self._server_config(folder)
            for _ in range(2):
                run = self._run("--server-config", config)
                self.assertEqual(run.returncode, 0, run.stderr)
            with self._admin() as conn:
                members = {r[0] for r in conn.execute(
                    "SELECT u.rolname FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid "
                    "JOIN pg_roles u ON u.oid = m.member WHERE g.rolname = 'lwcam_app'").fetchall()}
            self.assertTrue(set(setup_qc_db.MODULE_ROLES) <= members, members)
            self._check_grants(config, "--role", "lwcam_lwip")


class _FakeCursor:
    def __init__(self, value: object = None) -> None:
        self.value = value

    def fetchone(self):
        return (self.value,) if self.value is not None else None


class _FakeConnection:
    """Records the SQL it is given; `roles` are the part logins that 'exist'."""

    def __init__(self, roles: tuple[str, ...] = ()) -> None:
        self.roles = set(roles)
        self.statements: list[str] = []
        self.inserted: list[str] = []

    def transaction(self):
        import contextlib

        return contextlib.nullcontext()

    def execute(self, query, params=None, **_kwargs):
        text = query if isinstance(query, str) else query.as_string()
        if text.startswith("SELECT count(*) FROM pg_roles"):
            return _FakeCursor(len(self.roles))
        if text.startswith("SELECT 1 FROM pg_roles"):
            return _FakeCursor(1 if params[0] in self.roles else None)
        if text.startswith("SELECT rolsuper FROM pg_roles"):
            return _FakeCursor(False if params[0] in self.roles else None)
        if text.startswith("INSERT INTO public.schema_migrations"):
            self.inserted.append(params[0])
        self.statements.append(text)
        return _FakeCursor()


class SetupScriptLogicTests(unittest.TestCase):
    def test_the_script_self_test_passes(self) -> None:
        result = subprocess.run([sys.executable, "-B", str(SCRIPT), "--self-test"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_every_migration_is_recorded_whatever_old_roles_exist(self) -> None:
        with TemporaryDirectory() as folder:
            files = []
            for name in ("005_a", "006_module_roles", "007_b"):
                path = Path(folder) / f"{name}.sql"
                path.write_text("BEGIN;\nSELECT 1;\nCOMMIT;\n", encoding="utf-8")
                files.append(path)
            for roles in ((), ("lwcam_qc",), setup_qc_db.MODULE_ROLES):
                connection = _FakeConnection(roles)
                setup_qc_db.apply_migrations(connection, files)
                self.assertEqual(connection.inserted, ["005_a", "006_module_roles", "007_b"])
                self.assertFalse(any(s.strip().upper() in ("BEGIN;", "COMMIT;")
                                     for st in connection.statements for s in st.splitlines()))

    def test_ensure_app_login_sets_safe_attributes_and_joins_the_group(self) -> None:
        password = "Probe-Password-123456"
        created = _FakeConnection()
        setup_qc_db.ensure_app_login(created, "lwcam_user", password)
        create, grant = [s for s in created.statements if "ROLE" in s or s.startswith("GRANT")]
        self.assertTrue(create.startswith("CREATE ROLE"))
        for word in ("LOGIN", "NOSUPERUSER", "NOCREATEDB", "NOCREATEROLE", "NOREPLICATION", "NOBYPASSRLS", "INHERIT"):
            self.assertIn(word, create)
        self.assertIn("PASSWORD", create)
        self.assertIn('GRANT "lwcam_app" TO "lwcam_user"', grant)
        existing = _FakeConnection(("lwcam_user",))
        setup_qc_db.ensure_app_login(existing, "lwcam_user", None)
        alter = next(s for s in existing.statements if s.startswith("ALTER ROLE"))
        self.assertNotIn("PASSWORD", alter, "an existing login keeps its password")
        with self.assertRaises(RuntimeError) as raised:
            setup_qc_db.ensure_app_login(_FakeConnection(), "lwcam_user", None)
        self.assertIn("LWCAM_APP_PASSWORD", str(raised.exception))

    def test_names_and_passwords_are_validated(self) -> None:
        for bad in ("postgres", "lwcam_app", "Upper", "1x", "a-b", "", "a" * 64):
            with self.assertRaises(RuntimeError, msg=bad):
                setup_qc_db.validate_app_login(bad)
        with self.assertRaises(RuntimeError):
            setup_qc_db.validate_app_login("sa", "sa")
        self.assertEqual(setup_qc_db.validate_app_login("lwcam_user", "postgres"), "lwcam_user")
        self.assertIsNone(setup_qc_db.validate_app_password(None))
        for bad in ("short", "eleven char", "twelve chars\x00", "twelve chars\r\n"):
            with self.assertRaises(RuntimeError, msg=repr(bad)):
                setup_qc_db.validate_app_password(bad)
        self.assertEqual(setup_qc_db.validate_app_password("exactly 12 ch"), "exactly 12 ch")

    def test_hba_lines_use_the_group_and_replace_the_old_five_name_lines(self) -> None:
        ours = setup_qc_db.role_hba_lines("site_db")
        self.assertEqual(ours[0], "hostssl site_db +lwcam_app samenet scram-sha-256")
        old = setup_qc_db.old_role_hba_lines("site_db")
        raw = ("local all all scram-sha-256\n" + "\n".join(old) + "\n").encode()
        new, kept, _ = setup_qc_db.plan_hba(raw, "site_db", strict=False)
        self.assertNotIn(b"lwcam_qc", new)
        self.assertEqual(new.count(b"+lwcam_app"), 3)
        self.assertEqual(kept, [])
        self.assertEqual(setup_qc_db.rewrite_hba(new, [], ours + old), b"local all all scram-sha-256\n")
        rows = [("app", "10.0.0.5", True), ("postgres", "10.0.0.6", False)]
        self.assertEqual(setup_qc_db.strict_blockers(rows, frozenset()), ["postgres@10.0.0.6"])
        self.assertEqual(setup_qc_db.strict_blockers(rows[:1], frozenset()), [])

    def test_legacy_samenet_line_is_removed_or_kept_with_a_note(self) -> None:
        legacy = setup_qc_db.LEGACY_HBA_LINE
        raw = ("local all all scram-sha-256" + chr(10) + legacy + chr(10)).encode()
        # no blockers -> the automatic path plans with strict=True and the line goes
        new, kept, there = setup_qc_db.plan_hba(raw, "site_db", strict=True)
        self.assertTrue(there)
        self.assertNotIn(legacy.encode(), new)
        # blockers -> strict=False keeps it, and the note names who
        new, _, there = setup_qc_db.plan_hba(raw, "site_db", strict=False)
        self.assertIn(legacy.encode(), new)
        note = setup_qc_db.legacy_line_note(["postgres@100.90.100.64"])
        self.assertTrue(note.startswith("[NOTE] Kept the old rule that lets 'postgres'"))
        self.assertIn("postgres@100.90.100.64", note)
        # no legacy line -> nothing to remove
        _, _, there = setup_qc_db.plan_hba(b"local all all trust" + bytes([10]), "site_db", strict=True)
        self.assertFalse(there)

"""Create or upgrade the LWCam PostgreSQL schema.

Run by the LWCam Database installer, which points it at its own
config\\database.txt (--server-config). The --config path (LWCam Admin's old
node config) is kept working in case anything else ever needs it, but nothing
installs that caller any more. Either way the steps are the same:

1. create the database if it does not exist;
2. on an EMPTY database only, load the newest unified schema - a pg_dump that
   must never run twice, so the capture_folders probe below is its only guard;
3. apply EVERY migrations/*.sql in name order, on fresh and existing databases
   alike. Each migration is idempotent. Listing them by name here once let 004
   and 005 go unapplied on every station; globbing means a new file is picked
   up without anyone remembering to add it;
4. verify the columns and the role the QC server cannot run without.

--open-lan (the Database installer's "allow other PCs to connect" checkbox)
additionally opens a LOCAL server to the LAN: listen_addresses='*', a
same-subnet pg_hba.conf entry, and a service restart to apply both.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
from pathlib import Path
from typing import Any

_TRUE = frozenset({"true", "yes", "on", "1"})
_FALSE = frozenset({"false", "no", "off", "0"})

# What the QC server's models and login need. A database missing any of these
# answers every QC tab with a 500, which is exactly what an unapplied 004 did.
REQUIRED_COLUMNS = ("qc_locked_by", "qc_reviewed_by", "separated_from_folder_id")


def parse_boolean(key: str, value: Any, default: bool = False) -> bool:
    """Same words as the QC server's config.txt reader; a blank means the default."""
    if isinstance(value, bool):
        return value
    text = str(value if value is not None else "").strip().lower()
    if not text:
        return default
    if text in _TRUE:
        return True
    if text in _FALSE:
        return False
    raise RuntimeError(f"{key} must be true or false, not {value!r}")


def parse_port(key: str, value: Any) -> int:
    text = str(value if value is not None else "").strip()
    if not text:
        return 5432
    try:
        return int(text)
    except ValueError:
        raise RuntimeError(f"{key} must be a whole number, not {value!r}") from None


def load_node_config(path: Path) -> dict[str, Any]:
    """LWCam Admin's lwcam_node_config.json."""
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except FileNotFoundError as error:
        raise RuntimeError(f"LWCam configuration not found: {path}") from error
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"LWCam configuration is unreadable: {path}") from error
    missing = [key for key in ("pgHost", "pgDatabase", "pgUser", "pgPassword") if not str(data.get(key) or "").strip()]
    if missing:
        raise RuntimeError(f"LWCam configuration is missing: {', '.join(missing)}")
    return {
        "host": str(data["pgHost"]).strip(),
        "port": parse_port("pgPort", data.get("pgPort")),
        "database": str(data["pgDatabase"]).strip(),
        "user": str(data["pgUser"]).strip(),
        "password": str(data["pgPassword"]),
        "ssl": parse_boolean("pgUseSsl", data.get("pgUseSsl")),
    }


def load_server_config(path: Path) -> dict[str, Any]:
    """The QC server's config.txt: `key = value` lines, # comments.

    A small local reader rather than an import of app.core.server_settings, so
    the script runs from an install folder without the backend on sys.path.
    Same rules as that reader: blank values mean "not set", and only the first
    `=` splits, so a password may contain `=`.
    """
    try:
        text = path.read_text(encoding="utf-8-sig")
    except FileNotFoundError as error:
        raise RuntimeError(f"QC server configuration not found: {path}") from error
    except OSError as error:
        raise RuntimeError(f"QC server configuration is unreadable: {path}") from error

    values: dict[str, str] = {}
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, _, value = stripped.partition("=")
        if value.strip():
            values[key.strip()] = value.strip()

    missing = [key for key in ("dbName", "dbUser", "dbPassword") if key not in values]
    if missing:
        raise RuntimeError(f"QC server configuration is missing: {', '.join(missing)}")
    return {
        "host": values.get("dbHost", "localhost"),
        "port": parse_port("dbPort", values.get("dbPort")),
        "database": values["dbName"],
        "user": values["dbUser"],
        "password": values["dbPassword"],
        "ssl": parse_boolean("dbUseSsl", values.get("dbUseSsl")),
    }


def strip_psql_meta(text: str) -> str:
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("\\")
    )


def execute_file(connection: Any, path: Path) -> None:
    print(f"[QC-DB] Running {path.name}")
    connection.execute(strip_psql_meta(path.read_text(encoding="utf-8")), prepare=False)


def prepare_database(config: dict[str, Any], database_dir: Path) -> None:
    import psycopg
    from psycopg import sql

    migrations = sorted((database_dir / "migrations").glob("*.sql"))
    if not migrations:
        raise RuntimeError(f"No migrations found in {database_dir / 'migrations'}")

    database = config["database"]
    connection = {
        "host": config["host"],
        "port": config["port"],
        "user": config["user"],
        "password": config["password"],
        "sslmode": "require" if config["ssl"] else "prefer",
    }
    print(f"[QC-DB] Target: {connection['user']}@{connection['host']}:{connection['port']}/{database}")

    with psycopg.connect(dbname="postgres", autocommit=True, **connection) as maintenance:
        exists = maintenance.execute(
            "SELECT 1 FROM pg_database WHERE datname = %s", (database,)
        ).fetchone()
        if not exists:
            print(f"[QC-DB] Creating database {database}.")
            maintenance.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(database)))

    with psycopg.connect(dbname=database, autocommit=True, **connection) as target:
        has_schema = target.execute(
            "SELECT to_regclass('public.capture_folders') IS NOT NULL"
        ).fetchone()[0]
        if not has_schema:
            schemas = sorted(database_dir.glob("LWCam_database_unified_*.sql"))
            if not schemas:
                raise RuntimeError(f"No unified schema found in {database_dir}")
            execute_file(target, schemas[-1])

        for migration in migrations:
            execute_file(target, migration)

        present = {
            row[0]
            for row in target.execute(
                "SELECT column_name FROM information_schema.columns "
                "WHERE table_schema = 'public' AND table_name = 'capture_folders'"
            ).fetchall()
        }
        missing = [column for column in REQUIRED_COLUMNS if column not in present]
        if missing:
            raise RuntimeError(f"Schema verification failed, capture_folders lacks: {', '.join(missing)}")
        if target.execute("SELECT 1 FROM public.roles WHERE lower(role_name) = 'qc'").fetchone() is None:
            raise RuntimeError("Schema verification failed: the qc role is missing from public.roles")
    print("[QC-DB] Database ready.")


def hba_entry_matches(line: str, wanted: str) -> bool:
    """True if a pg_hba.conf `line` is the same entry as `wanted`, regardless
    of how many spaces or tabs separate its columns, or a trailing comment."""
    stripped = line.split("#", 1)[0].strip()
    return bool(stripped) and " ".join(stripped.split()) == wanted


def hba_has_entry(hba_text: str, wanted: str) -> bool:
    return any(hba_entry_matches(line, wanted) for line in hba_text.splitlines())


def is_local_host(host: str) -> bool:
    """True when `host` names this PC: a loopback literal or this computer's own name."""
    normalized = host.strip().strip("[]").lower()
    if normalized in ("localhost", "127.0.0.1", "::1"):
        return True
    return normalized == socket.gethostname().lower()


def restart_postgres_service() -> None:
    """Restarts every running `postgresql*` Windows service, so a changed
    listen_addresses (restart-only) and pg_hba.conf (reload, covered by the
    same restart) both take effect. The name varies by installer and version,
    hence the wildcard rather than one hardcoded service name."""
    powershell = str(
        Path(os.environ.get("SystemRoot", r"C:\Windows"))
        / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"
    )
    listing = subprocess.run(
        [powershell, "-NoProfile", "-Command",
         "(Get-Service 'postgresql*' | Where-Object Status -eq 'Running').Name"],
        capture_output=True, text=True, check=False,
    )
    names = [line.strip() for line in listing.stdout.splitlines() if line.strip()]
    if not names:
        print("[QC-DB] WARNING: no running postgresql* service found; restart PostgreSQL "
              "manually for the LAN change to take effect.")
        return
    for name in names:
        print(f"[QC-DB] Restarting service {name}.")
        restart = subprocess.run(
            [powershell, "-NoProfile", "-Command", f"Restart-Service -Name '{name}' -Force"],
            capture_output=True, text=True, check=False,
        )
        if restart.returncode != 0:
            print(f"[QC-DB] WARNING: could not restart {name}: {restart.stderr.strip()}")


def open_lan_access(config: dict[str, Any]) -> None:
    """Opens a LOCAL PostgreSQL server to the LAN; a no-op for a remote one,
    since there is no local listen_addresses or pg_hba.conf to change for it.

    Runs after prepare_database, as the same configured user against the
    maintenance "postgres" database (autocommit: ALTER SYSTEM cannot run
    inside a transaction). listen_addresses only takes effect after a
    restart, so pg_hba.conf's reload rides along on that same restart.
    """
    import psycopg

    if not is_local_host(config["host"]):
        print(f"[QC-DB] --open-lan skipped: {config['host']!r} is not this PC.")
        return

    connection = {
        "host": config["host"],
        "port": config["port"],
        "user": config["user"],
        "password": config["password"],
        "sslmode": "require" if config["ssl"] else "prefer",
    }
    changed = False
    with psycopg.connect(dbname="postgres", autocommit=True, **connection) as maintenance:
        current = maintenance.execute("SHOW listen_addresses").fetchone()[0]
        if current != "*":
            maintenance.execute("ALTER SYSTEM SET listen_addresses = '*'")
            changed = True
        hba_path = Path(maintenance.execute("SHOW hba_file").fetchone()[0])

    # Bytes in, bytes out: the entry is ASCII, and whatever encoding the
    # server's own comments are in is left exactly as it was.
    wanted = "host all all samenet scram-sha-256"
    raw = hba_path.read_bytes()
    if not hba_has_entry(raw.decode("latin-1"), wanted):
        newline = b"\r\n" if b"\r\n" in raw else b"\n"
        if raw and not raw.endswith((b"\n", b"\r")):
            raw += newline
        hba_path.write_bytes(raw + wanted.encode("ascii") + newline)
        changed = True

    if not changed:
        print("[QC-DB] LAN access already configured; nothing to do.")
        return
    restart_postgres_service()
    print("[QC-DB] LAN access configured: listen_addresses='*', pg_hba.conf allows the local subnet.")


def self_test() -> None:
    assert strip_psql_meta("SELECT 1;\n\\restrict token\nSELECT 2;") == "SELECT 1;\nSELECT 2;"
    assert parse_boolean("k", "") is False and parse_boolean("k", "Yes") is True
    try:
        parse_boolean("dbUseSsl", "maybe")
    except RuntimeError:
        pass
    else:
        raise AssertionError("an unknown boolean word must be rejected")

    wanted = "host all all samenet scram-sha-256"
    assert hba_entry_matches("host   all  all  samenet   scram-sha-256", wanted)
    assert hba_entry_matches("  host all all samenet scram-sha-256  # trust nobody", wanted)
    assert not hba_entry_matches("# host all all samenet scram-sha-256", wanted)
    assert not hba_entry_matches("host all all samenet md5", wanted)
    assert hba_has_entry("host all all 127.0.0.1/32 md5\n" + wanted + "\n", wanted)
    assert not hba_has_entry("host all all 127.0.0.1/32 md5\n", wanted)
    assert is_local_host("localhost") and is_local_host("127.0.0.1") and is_local_host("::1")
    assert is_local_host(socket.gethostname().upper())
    assert not is_local_host("some-other-host.example.com")
    print("setup_qc_db self-test OK")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--config", type=Path, help="LWCam Admin's lwcam_node_config.json")
    source.add_argument("--server-config", type=Path, help="the QC server's config.txt")
    parser.add_argument("--database-dir", type=Path, help="folder holding the unified SQL and migrations/")
    parser.add_argument("--open-lan", action="store_true",
                         help="open a local PostgreSQL server to LAN connections after setup")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.config is None and args.server_config is None:
        parser.error("--config or --server-config is required")
    if args.database_dir is None:
        parser.error("--database-dir is required")
    try:
        config = load_node_config(args.config) if args.config else load_server_config(args.server_config)
        prepare_database(config, args.database_dir)
        if args.open_lan:
            open_lan_access(config)
    except Exception as error:
        print(f"[ERROR] {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

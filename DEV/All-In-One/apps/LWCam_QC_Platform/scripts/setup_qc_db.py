from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def load_config(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise RuntimeError(f"LWCam configuration not found: {path}") from error
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"LWCam configuration is unreadable: {path}") from error
    required = ("pgHost", "pgDatabase", "pgUser", "pgPassword")
    missing = [key for key in required if not str(data.get(key) or "").strip()]
    if missing:
        raise RuntimeError(f"LWCam configuration is missing: {', '.join(missing)}")
    return data


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

    database = str(config["pgDatabase"]).strip()
    connection = {
        "host": str(config["pgHost"]).strip(),
        "port": int(config.get("pgPort") or 5432),
        "user": str(config["pgUser"]).strip(),
        "password": str(config["pgPassword"]),
        "sslmode": "require" if config.get("pgUseSsl") else "prefer",
    }
    print(
        f"[QC-DB] Target: {connection['user']}@{connection['host']}:"
        f"{connection['port']}/{database}"
    )

    with psycopg.connect(dbname="postgres", autocommit=True, **connection) as maintenance:
        exists = maintenance.execute(
            "SELECT 1 FROM pg_database WHERE datname = %s", (database,)
        ).fetchone()
        if not exists:
            print(f"[QC-DB] Creating database {database}.")
            maintenance.execute(
                sql.SQL("CREATE DATABASE {}").format(sql.Identifier(database))
            )

    with psycopg.connect(dbname=database, autocommit=True, **connection) as target:
        has_schema = target.execute(
            "SELECT to_regclass('public.capture_folders') IS NOT NULL"
        ).fetchone()[0]
        if not has_schema:
            schemas = sorted(database_dir.glob("LWCam_database_unified_*.sql"))
            if not schemas:
                raise RuntimeError(f"No unified schema found in {database_dir}")
            execute_file(target, schemas[-1])
        else:
            for name in (
                "001_qc_platform_deltas.sql",
                "002_role_case_normalization.sql",
                "003_archive_dates_as_text.sql",
            ):
                execute_file(target, database_dir / "migrations" / name)

        ready = target.execute(
            """
            SELECT EXISTS (
                SELECT 1
                FROM information_schema.columns
                WHERE table_schema = 'public'
                  AND table_name = 'capture_folders'
                  AND column_name = 'qc_locked_by'
            )
            """
        ).fetchone()[0]
        if not ready:
            raise RuntimeError("QC schema verification failed")
    print("[QC-DB] Database ready.")


def self_test() -> None:
    assert strip_psql_meta("SELECT 1;\n\\restrict token\nSELECT 2;") == (
        "SELECT 1;\nSELECT 2;"
    )
    print("setup_qc_db self-test OK")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path)
    parser.add_argument("--database-dir", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.config is None or args.database_dir is None:
        parser.error("--config and --database-dir are required")
    try:
        prepare_database(load_config(args.config), args.database_dir)
    except Exception as error:
        print(f"[ERROR] {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

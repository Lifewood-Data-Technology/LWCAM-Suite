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
   and records its file stem in schema_migrations (created here if missing), so
   001-006 are backfilled on the first run; the schema level every part checks
   is the highest number in that table;
4. verify the columns, tables and the role the QC server cannot run without.

--app-login <name> (password from the environment variable LWCAM_APP_PASSWORD, else the
appPassword of the --server-config file; never from an argument) creates or updates the ONE login every LWCam part
uses - QC, LWIP, Upload, each capture PC's LWCAM and LWCam Admin. It gets
LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS and is made
a member of the NOLOGIN group role lwcam_app, which migration 006 creates and
008 completes; all privileges live on the group. An existing login keeps its
password unless LWCAM_APP_PASSWORD is set. The name must match [a-z_][a-z0-9_]{0,62}
and not be postgres, lwcam_app or the setup user; the password needs 12+
characters and no control characters. Passwords are never printed. The five
older per-part logins (lwcam_qc ...), where they exist, are made members of
lwcam_app by migration 006 so parts still using them keep working.
--create-roles and --reset-missing-roles are accepted and ignored (deprecated).

Migrations 006 onward run in ONE transaction (006 resets table grants and 007/008
re-grant them; separate transactions would let a running service see
"permission denied" in between).

--open-lan (the Database installer's "allow other PCs to connect" checkbox)
additionally opens a LOCAL server to the network: listen_addresses='*' and
pg_hba.conf entries that admit ONLY members of lwcam_app, to `database`, from the
local subnet and the Tailscale ranges. They are inserted BEFORE the first
non-loopback host line (first match wins). A legacy `host all all samenet` line
is removed AUTOMATICALLY, unless logins that are not members of lwcam_app are
still connected from another PC: then it is kept and a `[NOTE]` line names them
(exit 0; run again once they use the shared login). Any other broader line that
admits remote connections is reported as a WARNING only. --strict-logins is a
deprecated no-op; --force-strict removes the legacy line even with such logins
connected. Lines an earlier version wrote (the five part-login names) are
replaced by the `+lwcam_app` ones.
--close-lan takes the entries back out. pg_hba.conf is backed up first and
written atomically; only the service that owns the data directory is restarted,
and only when listen_addresses changed. After a restart or reload the script
waits (up to 60 s) for the server to accept connections with ssl on.

--open-lan also encrypts the connections: if the data directory has no
server.crt/server.key a self-signed certificate is generated there (needs the
`cryptography` package), ssl is switched on (a reload, no restart), and the
entries are written as `hostssl` so a remote part cannot log in without TLS.

Client side: a NON-loopback database host always gets sslmode=require (encrypted,
certificate not verified - it is self-signed); dbUseSsl = true forces require
for loopback too, otherwise loopback uses `prefer`. This script itself connects
with `prefer` to a host that is this PC, since it is the one that turns ssl on.
"""

from __future__ import annotations

import argparse
import functools
import ipaddress
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

_TRUE = frozenset({"true", "yes", "on", "1"})
_FALSE = frozenset({"false", "no", "off", "0"})

# What the QC server's models and login need. A database missing any of these
# answers every QC tab with a 500, which is exactly what an unapplied 004 did.
REQUIRED_COLUMNS = ("qc_locked_by", "qc_reviewed_by", "separated_from_folder_id", "upload_error")
# Tables migration 007 creates; every part checks the schema level from the first.
REQUIRED_TABLES = ("schema_migrations", "service_heartbeat")

# The group role every LWCam login belongs to; migration 006 creates it.
APP_GROUP = "lwcam_app"
# The five per-part logins earlier versions created; now only made members of the group.
MODULE_ROLES = ("lwcam_qc", "lwcam_lwip", "lwcam_upload", "lwcam_capture", "lwcam_admin")
APP_LOGIN_PATTERN = re.compile(r"[a-z_][a-z0-9_]{0,62}")
APP_PASSWORD_ENV = "LWCAM_APP_PASSWORD"
APP_PASSWORD_MIN = 12
# The local subnet plus Tailscale (IPv4 CGNAT range and its IPv6 ULA prefix).
LAN_NETWORKS = ("samenet", "100.64.0.0/10", "fd7a:115c:a1e0::/48")
LEGACY_HBA_LINE = "host all all samenet scram-sha-256"
CERT_YEARS = 10


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


def _secrets() -> Any:
    """The sibling lwcam_secrets.py (same folder as this script, whatever the cwd)."""
    here = str(Path(__file__).resolve().parent)
    if here not in sys.path:
        sys.path.insert(0, here)
    import lwcam_secrets
    return lwcam_secrets


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
    # Passwords are stored DPAPI-protected ("dpapi:..."); a plain value still works.
    # appPassword only exists in the Database installer's database.txt.
    secrets = _secrets()
    try:
        password = secrets.unprotect(values["dbPassword"], "dbPassword")
        app_password = secrets.unprotect(values["appPassword"], "appPassword") if "appPassword" in values else ""
    except secrets.SecretError as error:
        raise RuntimeError(str(error)) from error
    return {
        "host": values.get("dbHost", "localhost"),
        "port": parse_port("dbPort", values.get("dbPort")),
        "database": values["dbName"],
        "user": values["dbUser"],
        "password": password,
        "app_password": app_password,
        "ssl": parse_boolean("dbUseSsl", values.get("dbUseSsl")),
    }


def strip_psql_meta(text: str) -> str:
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("\\")
    )


def strip_transaction_control(text: str) -> str:
    """Drops the lines that are exactly `BEGIN;` / `COMMIT;` so the script can
    put several migrations in one transaction (they stay for a manual psql -f)."""
    return "\n".join(
        line for line in text.splitlines() if line.strip().upper() not in ("BEGIN;", "COMMIT;")
    )


def execute_file(connection: Any, path: Path, *, in_transaction: bool = False) -> None:
    print(f"[QC-DB] Running {path.name}")
    text = strip_psql_meta(path.read_text(encoding="utf-8"))
    if in_transaction:
        text = strip_transaction_control(text)
    connection.execute(text, prepare=False)


def migration_number(path: Path) -> int:
    return int(path.stem.split("_", 1)[0])


def migration_groups(migrations: list[Path]) -> list[list[Path]]:
    """001-005 one transaction each; 006 onward (grants that reset and re-grant)
    together. ponytail: the cut-off is a number, move it if a later file must stand alone."""
    groups: list[list[Path]] = []
    for migration in migrations:
        if migration_number(migration) < 6 or not groups or migration_number(groups[-1][0]) < 6:
            groups.append([migration])
        else:
            groups[-1].append(migration)
    return groups


def apply_migrations(target: Any, migrations: list[Path]) -> None:
    import psycopg

    for group in migration_groups(migrations):
        try:
            with target.transaction():
                target.execute("SET LOCAL lock_timeout = '30s'")
                for migration in group:
                    execute_file(target, migration, in_transaction=True)
                    target.execute(
                        "INSERT INTO public.schema_migrations (version) VALUES (%s) ON CONFLICT DO NOTHING",
                        (migration.stem,),
                    )
        except psycopg.errors.LockNotAvailable:
            raise RuntimeError(
                f"Timed out waiting for a table lock while applying {group[0].name}; another session "
                "holds a long transaction. Nothing was changed - run setup again."
            ) from None


ROLE_ATTRIBUTES = "LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS INHERIT"


def validate_app_login(name: str, setup_user: str = "") -> str:
    """The login name, or a RuntimeError saying why it cannot be used."""
    if not APP_LOGIN_PATTERN.fullmatch(name or ""):
        raise RuntimeError("The database user name must be 1-63 characters: lowercase letters, "
                           "digits and _, not starting with a digit.")
    if name in ("postgres", APP_GROUP) or (setup_user and name == setup_user):
        raise RuntimeError(f"The database user name {name!r} is reserved (the administrator login and "
                           "the group role cannot be used); choose another.")
    return name


def validate_app_password(password: str | None) -> str | None:
    """None (keep the existing password) or a password that is long enough, with no control characters."""
    if password is None or password == "":
        return None
    if len(password) < APP_PASSWORD_MIN:
        raise RuntimeError(f"The database password must be at least {APP_PASSWORD_MIN} characters.")
    if any(ord(c) < 32 or ord(c) == 127 for c in password):
        raise RuntimeError("The database password must not contain control characters.")
    return password


def app_login_exists(maintenance: Any, name: str) -> bool:
    return maintenance.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (name,)).fetchone() is not None


def ensure_app_login(admin: Any, name: str, password: str | None) -> None:
    """Creates or updates the shared login and makes it a member of lwcam_app.
    Run AFTER the migrations (006 creates the group). An existing login keeps its
    password unless `password`. Never prints or raises the password."""
    import psycopg
    from psycopg import sql

    row = admin.execute("SELECT rolsuper FROM pg_roles WHERE rolname = %s", (name,)).fetchone()
    if row is not None and row[0]:
        raise RuntimeError(f"{name} is a superuser; refusing to change it into the application login.")
    if row is None and password is None:
        raise RuntimeError(f"The login {name} does not exist and {APP_PASSWORD_ENV} is not set, so it cannot be created.")
    text = ("ALTER ROLE {} " if row is not None else "CREATE ROLE {} ") + ROLE_ATTRIBUTES
    if password is not None:
        text += " PASSWORD {}"
    try:
        admin.execute(sql.SQL(text).format(sql.Identifier(name), *([sql.Literal(password)] if password is not None else [])))
        admin.execute(sql.SQL("GRANT {} TO {}").format(sql.Identifier(APP_GROUP), sql.Identifier(name)))
    except psycopg.Error as error:
        # ponytail: the statement text holds the password, so report the server's message only.
        raise RuntimeError(f"Could not {'update' if row is not None else 'create'} login {name}: "
                           f"{error.diag.message_primary or type(error).__name__}") from None
    print(f"[QC-DB] Login {name} {'updated' if row is not None else 'created'}"
          f"{' (password set)' if password is not None else ' (password kept)'}; member of {APP_GROUP}.")


def prepare_database(config: dict[str, Any], database_dir: Path, app_login: str | None = None,
                     app_password: str | None = None) -> None:
    import psycopg
    from psycopg import sql

    migrations = sorted((database_dir / "migrations").glob("*.sql"))
    if not migrations:
        raise RuntimeError(f"No migrations found in {database_dir / 'migrations'}")

    database = config["database"]
    if app_login is not None:
        validate_app_login(app_login, config["user"])
        app_password = validate_app_password(app_password)
    connection = {
        "host": config["host"],
        "port": config["port"],
        "user": config["user"],
        "password": config["password"],
        "sslmode": setup_sslmode(config["host"], config["ssl"]),
    }
    print(f"[QC-DB] Target: {connection['user']}@{connection['host']}:{connection['port']}/{database}")

    with psycopg.connect(dbname="postgres", autocommit=True, **connection) as maintenance:
        # Fail before changing anything when the login cannot be created.
        if app_login is not None and app_password is None and not app_login_exists(maintenance, app_login):
            raise RuntimeError(f"The login {app_login} does not exist and {APP_PASSWORD_ENV} is not set, "
                               "so it cannot be created.")
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

        # 007 creates this too; it must exist first so 001-006 can be recorded.
        target.execute(
            "CREATE TABLE IF NOT EXISTS public.schema_migrations ("
            "version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())"
        )
        apply_migrations(target, migrations)
        if app_login is not None:
            ensure_app_login(target, app_login, app_password)

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
        absent = [t for t in REQUIRED_TABLES if target.execute("SELECT to_regclass(%s)", (f"public.{t}",)).fetchone()[0] is None]
        if absent:
            raise RuntimeError(f"Schema verification failed, missing tables: {', '.join(absent)}")
        if not app_login_exists(target, APP_GROUP):
            raise RuntimeError(f"Schema verification failed: the group role {APP_GROUP} is missing")
        if target.execute("SELECT 1 FROM public.roles WHERE lower(role_name) = 'qc'").fetchone() is None:
            raise RuntimeError("Schema verification failed: the qc role is missing from public.roles")
    print("[QC-DB] Database ready.")


def setup_sslmode(host: str, ssl: bool) -> str:
    """This script's own connection: `prefer` for a host that is this PC (it
    enables ssl itself, so the first run has none yet), `require` otherwise."""
    if ssl and host.strip().strip("[]").lower() in ("localhost", "127.0.0.1", "::1"):
        return "require"
    return "prefer" if is_local_host(host) else "require"


def hba_entry_matches(line: str, wanted: str) -> bool:
    """True if a pg_hba.conf `line` is the same entry as `wanted`, regardless
    of how many spaces or tabs separate its columns, or a trailing comment."""
    stripped = line.split("#", 1)[0].strip()
    return bool(stripped) and " ".join(stripped.split()) == wanted


def hba_has_entry(hba_text: str, wanted: str) -> bool:
    return any(hba_entry_matches(line, wanted) for line in hba_text.splitlines())


HBA_HOST_TYPES = ("host", "hostssl", "hostnossl", "hostgssenc", "hostnogssenc")
HBA_TLS_TYPES = ("hostssl", "hostgssenc")  # the others also let a plain connection in


def _hba_fields(line: str | bytes) -> list[str]:
    text = line.decode("latin-1") if isinstance(line, bytes) else line
    return text.split("#", 1)[0].split()


def _hba_loopback_only(fields: list[str]) -> bool:
    """True when a host line's address can only be this PC itself."""
    address = fields[3].lower() if len(fields) > 3 else ""
    if address in ("localhost", "samehost"):
        return True
    try:
        return ipaddress.ip_network(address, strict=False).is_loopback
    except ValueError:
        return False  # a keyword (all, samenet) or a host name: remote-capable


def _hba_remote_host_line(line: bytes) -> bool:
    fields = _hba_fields(line)
    return len(fields) > 3 and fields[0].lower() in HBA_HOST_TYPES and not _hba_loopback_only(fields)


def own_addresses() -> frozenset[str]:
    """Every address that names this PC: loopback plus each adapter's IPv4/IPv6."""
    found = {"127.0.0.1", "::1", *local_ipv4_addresses(), *local_ipv6_addresses()}
    return frozenset(str(ipaddress.ip_address(a.split("%")[0])) for a in found)


def is_local_address(address: str, local: frozenset[str] | None = None) -> bool:
    try:
        parsed = ipaddress.ip_address(address.strip().strip("[]").split("%")[0])
    except ValueError:
        return False
    return parsed.is_loopback or str(parsed) in (own_addresses() if local is None else local)


def broader_remote_lines(hba_text: str, database: str, ours: list[str]) -> list[tuple[str, bool]]:
    """(line, uses_tls) for every pg_hba.conf line other than `ours` that could
    admit a remote connection to `database` as one of the part logins. First
    match wins, so a plain `host` line here still lets a login in without TLS
    when ours (hostssl) does not match, and any of them admits other logins."""
    found: list[tuple[str, bool]] = []
    for line in hba_text.splitlines():
        if any(hba_entry_matches(line, entry) for entry in ours):
            continue
        fields = _hba_fields(line)
        if len(fields) < 5 or fields[0].lower() not in HBA_HOST_TYPES or _hba_loopback_only(fields):
            continue
        databases = {d.lower() for d in fields[1].split(",")}
        users = set(fields[2].split(","))
        if not (databases & {"all", "sameuser", "samerole", database.lower()}
                or any(d.startswith("@") for d in databases)):
            continue
        if not ("all" in {u.lower() for u in users} or users & set(MODULE_ROLES) or f"+{APP_GROUP}" in users
                or any(u.startswith(("+", "@")) for u in users)):
            continue
        method_at = 4
        try:  # `address mask` form: the method comes after the mask
            ipaddress.ip_address(fields[4])
            method_at = 5
        except ValueError:
            pass
        if method_at < len(fields) and fields[method_at].lower() == "reject":
            continue
        found.append((" ".join(fields), fields[0].lower() in HBA_TLS_TYPES))
    return found


def is_local_host(host: str) -> bool:
    """True when `host` names this PC: a loopback literal, this computer's name,
    or any of its own IPv4/IPv6 addresses."""
    normalized = host.strip().strip("[]").lower()
    if normalized in ("localhost", "127.0.0.1", "::1", socket.gethostname().lower()):
        return True
    try:
        if normalized == socket.getfqdn().lower():
            return True
    except OSError:
        pass
    return is_local_address(normalized)


def write_bytes_atomic(path: Path, data: bytes) -> None:
    """Temp file beside `path`, then replace: a crash never leaves a half-written file.
    ponytail: the new file gets the folder's inherited permissions, not the old file's ACL."""
    temp = path.with_name(path.name + ".tmp")
    try:
        temp.write_bytes(data)
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def rewrite_hba(raw: bytes, add: list[str], remove: list[str]) -> bytes:
    """`raw` pg_hba.conf bytes with every `remove` entry dropped and every
    missing `add` entry inserted BEFORE the first non-loopback host line (first
    match wins, so a broader line above ours would shadow it; a copy of ours that
    sits below it is moved up), in the file's own line-ending style. Bytes in,
    bytes out: the entries are ASCII and whatever encoding the server's own
    comments are in is left exactly as it was."""
    newline = b"\r\n" if b"\r\n" in raw else b"\n"

    def is_entry(line: bytes, entries: list[str]) -> bool:
        return any(hba_entry_matches(line.decode("latin-1"), entry) for entry in entries)

    lines = [line for line in raw.splitlines(keepends=True) if not is_entry(line, remove)]
    first = next((i for i, line in enumerate(lines) if not is_entry(line, add) and _hba_remote_host_line(line)),
                 len(lines))
    head = lines[:first]
    tail = [line for line in lines[first:] if not is_entry(line, add)]
    missing = [entry for entry in add if not any(hba_entry_matches(line.decode("latin-1"), entry) for line in head)]
    if missing and head and not head[-1].endswith((b"\n", b"\r")):
        head[-1] += newline
    return b"".join(head) + b"".join(entry.encode("ascii") + newline for entry in missing) + b"".join(tail)


def plan_hba(raw: bytes, database: str, *, strict: bool) -> tuple[bytes, list[tuple[str, bool]], bool]:
    """(new pg_hba.conf bytes, broader remote lines left in it, legacy line was present)."""
    ours, old = role_hba_lines(database), old_role_hba_lines(database)
    legacy_present = hba_has_entry(raw.decode("latin-1"), LEGACY_HBA_LINE)
    updated = rewrite_hba(raw, ours, old + ([LEGACY_HBA_LINE] if strict else []))
    return updated, broader_remote_lines(updated.decode("latin-1"), database, ours), legacy_present


def strict_blockers(rows: list[tuple[str, str, bool]], local: frozenset[str] | None = None) -> list[str]:
    """`user@address` for every session from another PC by a login that is not a
    member of lwcam_app (rows are (usename, host(client_addr), is_member))."""
    return sorted({
        f"{user}@{address}" for user, address, member in rows
        if not member and not is_local_address(address, local)
    })


def legacy_line_note(blockers: list[str]) -> str:
    """The [NOTE] printed when the legacy samenet line must stay."""
    who = ", ".join(blockers)
    names = ", ".join(sorted({f"'{b.split('@')[0]}'" for b in blockers}))
    return (f"[NOTE] Kept the old rule that lets {names} in from other PCs, because these are still "
            f"connected that way: {who}. Switch them to the shared login, then run LWCamDatabaseSetup "
            "again to remove it.")


def role_hba_lines(database: str) -> list[str]:
    return [f"hostssl {database} +{APP_GROUP} {network} scram-sha-256" for network in LAN_NETWORKS]


def old_role_hba_lines(database: str) -> list[str]:
    """What earlier versions wrote - the five part-login names, as `host` (TLS
    optional) or `hostssl` lines; replaced on open, dropped on close."""
    roles = ",".join(MODULE_ROLES)
    return [f"{kind} {database} {roles} {network} scram-sha-256"
            for kind in ("hostssl", "host") for network in LAN_NETWORKS]


def _require_cryptography() -> None:
    try:
        import cryptography  # noqa: F401
    except ImportError as error:
        raise RuntimeError(
            "The 'cryptography' Python package is required to create the database's TLS "
            "certificate but is not installed in this runtime; reinstall LWCam Database Setup."
        ) from error


def local_ipv4_addresses() -> list[str]:
    """Every IPv4 address of this PC's adapters, Tailscale's 100.x included."""
    found: set[str] = set()
    try:
        found.update(info[4][0] for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET))
    except OSError:
        pass
    try:
        out = subprocess.run(["ipconfig"], capture_output=True, text=True, check=False).stdout
        found.update(re.findall(r"IPv4[^:\n]*:\s*(\d{1,3}(?:\.\d{1,3}){3})", out))
    except OSError:
        pass
    return sorted(a for a in found if not a.startswith(("169.254.", "0.")))


def local_ipv6_addresses() -> list[str]:
    """Every IPv6 address of this PC's adapters (Tailscale's fd7a:... included),
    link-local ones too - callers that need routable ones filter them."""
    found: set[str] = set()
    try:
        found.update(info[4][0] for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET6))
    except OSError:
        pass
    try:
        out = subprocess.run(["ipconfig"], capture_output=True, text=True, check=False).stdout
        found.update(re.findall(r"IPv6[^:\n]*:\s*([0-9a-fA-F:]+)", out))
    except OSError:
        pass
    valid = set()
    for address in found:
        try:
            valid.add(str(ipaddress.ip_address(address.split("%")[0])))
        except ValueError:
            pass
    return sorted(valid)


def _cert_wanted(hostname: str, addresses: list[str] | None) -> tuple[set[str], set[str]]:
    names = {hostname, "localhost"}
    try:
        fqdn = socket.getfqdn()
        if fqdn:
            names.add(fqdn)
    except OSError:
        pass
    if addresses is None:
        addresses = local_ipv4_addresses() + [
            a for a in local_ipv6_addresses() if not ipaddress.ip_address(a).is_link_local
        ]
    ips = {str(ipaddress.ip_address(a)) for a in ["127.0.0.1", "::1", *addresses]}
    return names, ips


def cert_covers(crt: Path, names: set[str], ips: set[str], *, min_days: int = 30) -> bool:
    """True if the certificate names every wanted host/IP and is not about to expire."""
    import datetime as dt
    from cryptography import x509

    try:
        cert = x509.load_pem_x509_certificate(crt.read_bytes())
        san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
    except (OSError, ValueError, x509.ExtensionNotFound):
        return False
    have_names = {n.lower() for n in san.get_values_for_type(x509.DNSName)}
    have_ips = {str(a) for a in san.get_values_for_type(x509.IPAddress)}
    fresh = cert.not_valid_after_utc > dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=min_days)
    return fresh and {n.lower() for n in names} <= have_names and ips <= have_ips


def generate_server_cert(directory: Path, hostname: str | None = None, addresses: list[str] | None = None) -> bool:
    """Writes server.key + server.crt (self-signed, EC P-256, 10 years, KeyUsage
    digitalSignature+keyEncipherment, ExtendedKeyUsage serverAuth) into
    `directory`. CN = the PC name; SANs = the PC name, its FQDN, localhost, every
    local IPv4 and routable IPv6 address, 127.0.0.1 and ::1. An existing pair is
    kept while its SANs still cover all of those (and it has 30+ days left);
    otherwise it is re-issued and the old files are kept as *.bak-<time>.
    Returns True when written."""
    crt, key = directory / "server.crt", directory / "server.key"
    _require_cryptography()
    hostname = hostname or socket.gethostname()
    names, ips = _cert_wanted(hostname, addresses)
    if crt.exists() and key.exists():
        if cert_covers(crt, names, ips):
            return False
        stamp = time.strftime("%Y%m%d-%H%M%S")
        shutil.move(crt, crt.with_name(f"{crt.name}.bak-{stamp}"))
        shutil.move(key, key.with_name(f"{key.name}.bak-{stamp}"))
    import datetime as dt
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

    sans = [x509.DNSName(n) for n in sorted(names)] + [x509.IPAddress(ipaddress.ip_address(a)) for a in sorted(ips)]
    private = ec.generate_private_key(ec.SECP256R1())
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, hostname)])
    now = dt.datetime.now(dt.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject).issuer_name(subject).public_key(private.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(days=1))
        .not_valid_after(now + dt.timedelta(days=365 * CERT_YEARS))
        .add_extension(x509.SubjectAlternativeName(sans), critical=False)
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(x509.KeyUsage(
            digital_signature=True, content_commitment=False, key_encipherment=True, data_encipherment=False,
            key_agreement=False, key_cert_sign=False, crl_sign=False, encipher_only=False, decipher_only=False),
            critical=True)
        .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
        .sign(private, hashes.SHA256())
    )
    directory.mkdir(parents=True, exist_ok=True)
    key.write_bytes(private.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    crt.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    return True


_DATA_DIR_ARG = re.compile(r'-D\s+(?:"([^"]+)"|(\S+))')


def service_for_data_dir(services: list[dict[str, Any]], data_dir: str) -> str | None:
    """Name of the Windows service whose command line is `... -D "<data_dir>"`."""
    def norm(path: str) -> str:
        return os.path.normcase(os.path.normpath(path.strip()))

    for service in services:
        found = _DATA_DIR_ARG.search(str(service.get("PathName") or ""))
        if found and norm(found.group(1) or found.group(2)) == norm(data_dir):
            return str(service["Name"])
    return None


def restart_postgres_service(data_dir: str) -> bool:
    """Restarts ONLY the PostgreSQL service that owns `data_dir` (other
    stations' or apps' servers on this PC are left running), so a changed
    listen_addresses (restart-only) takes effect. False when it could not."""
    powershell = str(
        Path(os.environ.get("SystemRoot", r"C:\Windows"))
        / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"
    )
    listing = subprocess.run(
        [powershell, "-NoProfile", "-Command",
         "ConvertTo-Json -InputObject @(Get-CimInstance Win32_Service -Filter \"Name like 'postgresql%'\" "
         "| Select-Object Name, PathName)"],
        capture_output=True, text=True, check=False,
    )
    try:
        name = service_for_data_dir(json.loads(listing.stdout or "[]"), data_dir)
    except ValueError:
        name = None
    if name is None:
        print(f"[QC-DB] WARNING: no PostgreSQL service owns {data_dir}; restart PostgreSQL "
              "manually for the LAN change to take effect.")
        return False
    print(f"[QC-DB] Restarting service {name}.")
    restart = subprocess.run(
        [powershell, "-NoProfile", "-Command", f"Restart-Service -Name '{name}' -Force"],
        capture_output=True, text=True, check=False,
    )
    if restart.returncode != 0:
        print(f"[QC-DB] WARNING: could not restart {name}: {restart.stderr.strip()}")
        return False
    return True


def wait_for_server(connection: dict[str, Any], *, listen_all: bool = False, timeout: float = 60.0) -> None:
    """Waits until the server accepts connections with ssl on (and, after a
    restart for it, listen_addresses='*'); raises if that takes longer than `timeout`."""
    import psycopg

    deadline = time.monotonic() + timeout
    while True:
        try:
            with psycopg.connect(dbname="postgres", autocommit=True, connect_timeout=5, **connection) as check:
                if check.execute("SHOW ssl").fetchone()[0] != "on":
                    problem = "ssl is still off"
                elif listen_all and check.execute("SHOW listen_addresses").fetchone()[0] != "*":
                    problem = "listen_addresses is not '*' yet (a restart is needed)"
                else:
                    return
        except psycopg.Error as error:
            problem = f"no connection ({str(error).splitlines()[0] if str(error) else type(error).__name__})"
        if time.monotonic() >= deadline:
            raise RuntimeError(
                f"PostgreSQL did not come back ready within {int(timeout)} s: {problem}. Check its log "
                "(server.crt/server.key or pg_hba.conf errors); the LAN change is NOT in effect.")
        time.sleep(min(2.0, max(0.05, deadline - time.monotonic())))


def edit_lan_access(config: dict[str, Any], *, close: bool, force_strict: bool = False) -> None:
    """Opens (or, with `close`, closes) a LOCAL PostgreSQL server to the network;
    a no-op for a remote one, since there is no local listen_addresses or
    pg_hba.conf to change for it.

    Runs after prepare_database, as the same configured user against the
    maintenance "postgres" database (autocommit: ALTER SYSTEM cannot run
    inside a transaction). Opening admits only members of lwcam_app, to the one
    database, from the local subnet and Tailscale, as hostssl lines inserted
    ahead of the first non-loopback host line. The legacy blanket
    `host all all samenet` line is removed unless logins outside lwcam_app are
    connected from another PC (then it is kept and a [NOTE] says who; `force_strict`
    removes it anyway); closing removes it and our lines. Every other line that
    could admit a remote login is reported as a WARNING.
    pg_hba.conf is backed up, then written atomically. listen_addresses needs a
    restart of the owning service; a pg_hba.conf/ssl change alone is reloaded.
    Either way the script waits for the server to answer with ssl on.
    """
    import psycopg

    flag = "--close-lan" if close else "--open-lan"
    if not is_local_host(config["host"]):
        print(f"[QC-DB] {flag} skipped: {config['host']!r} is not this PC.")
        return

    if not close:
        _require_cryptography()
    connection = {
        "host": config["host"],
        "port": config["port"],
        "user": config["user"],
        "password": config["password"],
        "sslmode": setup_sslmode(config["host"], config["ssl"]),
    }
    restart_needed = False
    legacy_present = strict = False
    with psycopg.connect(dbname="postgres", autocommit=True, **connection) as maintenance:
        hba_path = Path(maintenance.execute("SHOW hba_file").fetchone()[0])
        data_dir = maintenance.execute("SHOW data_directory").fetchone()[0]
        raw = hba_path.read_bytes()
        ours, old = role_hba_lines(config["database"]), old_role_hba_lines(config["database"])

        if close:
            updated = rewrite_hba(raw, [], ours + old + [LEGACY_HBA_LINE])
        else:
            if hba_has_entry(raw.decode("latin-1"), LEGACY_HBA_LINE):
                rows = maintenance.execute(
                    "SELECT a.usename, host(a.client_addr), EXISTS (SELECT 1 FROM pg_auth_members m "
                    "JOIN pg_roles g ON g.oid = m.roleid JOIN pg_roles u ON u.oid = m.member "
                    "WHERE g.rolname = %s AND u.rolname = a.usename) FROM pg_stat_activity a "
                    "WHERE a.client_addr IS NOT NULL AND a.usename IS NOT NULL", (APP_GROUP,)).fetchall()
                blockers = strict_blockers([(str(u), str(a), bool(m)) for u, a, m in rows])
                strict = not blockers or force_strict
                if not strict:
                    print(legacy_line_note(blockers))
            updated, broader, legacy_present = plan_hba(raw, config["database"], strict=strict)
            for line, tls in broader:
                print(f"[QC-DB] WARNING: pg_hba.conf line admits remote connections"
                      f"{'' if tls else ' without TLS'}: {line}")

        ssl_changed = False
        if not close:
            if maintenance.execute("SHOW listen_addresses").fetchone()[0] != "*":
                maintenance.execute("ALTER SYSTEM SET listen_addresses = '*'")
                restart_needed = True
            if generate_server_cert(Path(data_dir)):
                print(f"[QC-DB] Created a TLS certificate (server.crt, server.key) in {data_dir}.")
                ssl_changed = True
            if maintenance.execute("SHOW ssl").fetchone()[0] != "on":
                maintenance.execute("ALTER SYSTEM SET ssl = 'on'")
                ssl_changed = True
            for name, value in KEEPALIVE_SETTINGS:
                if maintenance.execute("SELECT setting FROM pg_settings WHERE name = %s", (name,)).fetchone()[0] != str(value):
                    maintenance.execute(f"ALTER SYSTEM SET {name} = {value}")
                    ssl_changed = True  # reloadable, same reload path as ssl
        hba_changed = updated != raw
        if hba_changed:
            backup = hba_path.with_name(f"{hba_path.name}.bak-{time.strftime('%Y%m%d-%H%M%S')}")
            shutil.copy2(hba_path, backup)
            write_bytes_atomic(hba_path, updated)
            print(f"[QC-DB] pg_hba.conf updated (backup: {backup.name}).")
        reloaded = (hba_changed or ssl_changed) and not restart_needed
        if reloaded:
            maintenance.execute("SELECT pg_reload_conf()")  # ssl is reloadable (PG 10+)

    if restart_needed:
        if not restart_postgres_service(data_dir):
            raise RuntimeError("PostgreSQL was not restarted, so listen_addresses='*' is NOT in effect.")
        wait_for_server(connection, listen_all=True)
    elif reloaded and not close:
        wait_for_server(connection)
    elif not (hba_changed or ssl_changed):
        print("[QC-DB] LAN access already as requested; nothing to do.")
        return
    if strict and not close and legacy_present:
        print("[QC-DB] Removed the old rule that let any login (including postgres) in from other PCs.")
    print("[QC-DB] LAN access closed." if close else
          "[QC-DB] LAN access configured: listen_addresses='*', pg_hba.conf admits the part logins "
          "from the local subnet and Tailscale.")


def _cert_self_test() -> None:
    import ssl
    import tempfile
    _require_cryptography()
    from cryptography import x509

    with tempfile.TemporaryDirectory() as temporary:
        folder = Path(temporary)
        assert generate_server_cert(folder, "TESTPC", ["192.168.1.5", "100.64.1.2"]) is True
        assert generate_server_cert(folder, "TESTPC", ["192.168.1.5"]) is False, "a covering certificate must be kept"
        cert = x509.load_pem_x509_certificate((folder / "server.crt").read_bytes())
        san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
        assert "TESTPC" in san.get_values_for_type(x509.DNSName) and "localhost" in san.get_values_for_type(x509.DNSName)
        addresses = {str(a) for a in san.get_values_for_type(x509.IPAddress)}
        assert {"127.0.0.1", "::1", "192.168.1.5", "100.64.1.2"} <= addresses
        usage = cert.extensions.get_extension_for_class(x509.KeyUsage).value
        assert usage.digital_signature and usage.key_encipherment
        eku = cert.extensions.get_extension_for_class(x509.ExtendedKeyUsage).value
        assert x509.oid.ExtendedKeyUsageOID.SERVER_AUTH in eku
        # a new IPv4 or IPv6 address, or a new name, means the certificate is re-issued
        assert generate_server_cert(folder, "TESTPC", ["192.168.1.5", "100.64.1.2", "fd7a:115c:a1e0::7"]) is True
        assert "fd7a:115c:a1e0::7" in {str(a) for a in x509.load_pem_x509_certificate(
            (folder / "server.crt").read_bytes()).extensions.get_extension_for_class(
                x509.SubjectAlternativeName).value.get_values_for_type(x509.IPAddress)}
        assert generate_server_cert(folder, "RENAMED", ["192.168.1.5"]) is True
        assert list(folder.glob("server.crt.bak-*")), "the replaced certificate is kept as a backup"
        assert generate_server_cert(folder, "RENAMED", ["192.168.1.5"]) is False
        assert (cert.not_valid_after_utc - cert.not_valid_before_utc).days >= 365 * CERT_YEARS
        ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER).load_cert_chain(folder / "server.crt", folder / "server.key")


# Reloadable. A client PC that loses power leaves its session (and the advisory
# locks it holds) on the server until TCP notices; Linux/Windows defaults take
# hours. 60 + 10 x 6 = about 2 minutes to drop a dead client.
KEEPALIVE_SETTINGS = (("tcp_keepalives_idle", 60), ("tcp_keepalives_interval", 10), ("tcp_keepalives_count", 6))


def keepalive_statements() -> list[str]:
    return [f"ALTER SYSTEM SET {name} = {value}" for name, value in KEEPALIVE_SETTINGS]


def _secrets_self_test() -> None:
    """database.txt passwords: plain still loads; a protected value is decrypted (Windows)."""
    import tempfile
    secrets = _secrets()
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "database.txt"
        plain = "dbName = x\ndbUser = u\ndbPassword = pa=ss\nappPassword = app-secret-123\n"
        path.write_text(plain, encoding="utf-8")
        config = load_server_config(path)
        assert config["password"] == "pa=ss" and config["app_password"] == "app-secret-123"
        if sys.platform == "win32":
            path.write_text(plain.replace("pa=ss", secrets.protect("pa=ss"))
                            .replace("app-secret-123", secrets.protect("app-secret-123")), encoding="utf-8")
            assert "pa=ss" not in path.read_text(encoding="utf-8")
            config = load_server_config(path)
            assert config["password"] == "pa=ss" and config["app_password"] == "app-secret-123"


def self_test() -> None:
    assert keepalive_statements() == [
        "ALTER SYSTEM SET tcp_keepalives_idle = 60",
        "ALTER SYSTEM SET tcp_keepalives_interval = 10",
        "ALTER SYSTEM SET tcp_keepalives_count = 6",
    ]
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
    for own in (local_ipv4_addresses() + local_ipv6_addresses())[:2]:
        assert is_local_host(own), f"this PC's own address {own} must count as local"
    assert not is_local_host("203.0.113.77") and not is_local_host("2001:db8::77")
    ours = role_hba_lines("lwcam")
    assert len(ours) == 3 and ours[0] == "hostssl lwcam +lwcam_app samenet scram-sha-256"
    assert ours[1].endswith("100.64.0.0/10 scram-sha-256") and ours[2].endswith("fd7a:115c:a1e0::/48 scram-sha-256")
    # insert position: before the first NON-loopback host line, after loopback and local ones
    base = (b"# comment\r\nlocal all all scram-sha-256\r\nhost all all 127.0.0.1/32 scram-sha-256\r\n"
            b"host all all ::1/128 scram-sha-256\r\n" + LEGACY_HBA_LINE.encode() + b"\r\nhost replication all samenet md5\r\n")
    opened = rewrite_hba(base, ours, [])
    cut = base.index(LEGACY_HBA_LINE.encode())
    assert opened[:cut] == base[:cut] and opened[cut:].startswith(b"hostssl lwcam ")
    assert opened.endswith(LEGACY_HBA_LINE.encode() + b"\r\nhost replication all samenet md5\r\n")
    assert opened.count(b"\r\n") == base.count(b"\r\n") + 3 and b"\n" not in opened.replace(b"\r\n", b"")
    assert rewrite_hba(opened, ours, []) == opened, "adding twice must change nothing"
    # a copy of ours BELOW a broad line is moved above it
    late = base + "\r\n".join(ours).encode() + b"\r\n"
    moved = rewrite_hba(late, ours, [])
    assert moved.index(b"hostssl lwcam") < moved.index(LEGACY_HBA_LINE.encode()) and moved.count(b"hostssl lwcam") == 3
    strict = rewrite_hba(opened, ours, [LEGACY_HBA_LINE])
    assert LEGACY_HBA_LINE.encode() not in strict and strict.count(b"+lwcam_app") == 3
    assert rewrite_hba(opened, [], ours + [LEGACY_HBA_LINE]) == base.replace(LEGACY_HBA_LINE.encode() + b"\r\n", b"")
    assert rewrite_hba(b"local all all trust", ours[:1], []).startswith(b"local all all trust\nhostssl lwcam")
    assert rewrite_hba(b"host all all 10.0.0.0/8 md5", ours[:1], []).startswith(b"hostssl lwcam")
    assert old_role_hba_lines("lwcam")[0].startswith("hostssl lwcam lwcam_qc,") and len(old_role_hba_lines("lwcam")) == 6
    assert role_hba_lines("other_db")[1] == "hostssl other_db +lwcam_app 100.64.0.0/10 scram-sha-256", "db name is configurable"
    # an earlier version's `host` lines are replaced, not duplicated, and close drops both kinds
    old = old_role_hba_lines("lwcam")
    upgraded = rewrite_hba(base + "\r\n".join(old).encode() + b"\r\n", ours, old)
    assert upgraded.count(b"hostssl lwcam") == 3 and b"lwcam_qc" not in upgraded and b"\r\nhost lwcam" not in upgraded
    only_old = rewrite_hba(base + "\r\n".join(old_role_hba_lines("lwcam")[3:]).encode() + b"\r\n", ours, old)
    assert b"lwcam_qc" not in only_old and only_old.count(b"+lwcam_app") == 3, "old five-name host lines are replaced"
    _, kept, _ = plan_hba(base + "\r\n".join(old).encode() + b"\r\n", "lwcam", strict=False)
    assert all("lwcam_qc" not in line for line, _ in kept)
    assert rewrite_hba(upgraded, [], ours + old + [LEGACY_HBA_LINE]) == base.replace(LEGACY_HBA_LINE.encode() + b"\r\n", b"")
    # broader lines: warned about; strict fails on a non-TLS one that is not the legacy line
    def broad(text: str) -> list[tuple[str, bool]]:
        return broader_remote_lines(text, "lwcam", ours)
    assert broad("host all all 0.0.0.0/0 scram-sha-256") == [("host all all 0.0.0.0/0 scram-sha-256", False)]
    assert broad("host all all samenet md5")[0][1] is False
    assert broad("host lwcam all 10.0.0.0/8 trust")[0][1] is False
    assert broad("host all all 192.168.0.0 255.255.0.0 md5")[0][1] is False
    assert broad("hostssl all all 0.0.0.0/0 scram-sha-256") == [("hostssl all all 0.0.0.0/0 scram-sha-256", True)]
    assert broad("host all lwcam_qc,other samenet md5") and broad("host other all samenet md5") == []
    assert broad("host lwcam +lwcam_app 10.0.0.0/8 md5")[0][1] is False
    assert broad("host all postgres samenet md5") == [] and broad("host replication all samenet md5") == []
    assert broad("host all all 127.0.0.1/32 md5") == [] and broad("host all all ::1/128 md5") == []
    assert broad("host all all 0.0.0.0/0 reject") == [] and broad("# host all all 0.0.0.0/0 md5") == []
    assert broad("\n".join(ours)) == [], "our own lines are not 'broader'"
    _, kept, was_there = plan_hba(opened, "lwcam", strict=False)
    assert was_there and [line for line, _ in kept] == [LEGACY_HBA_LINE]
    _, kept, was_there = plan_hba(opened, "lwcam", strict=True)
    assert was_there and kept == [], "strict removes the legacy line, nothing else admits remote logins"
    hostile = base + b"host all all 0.0.0.0/0 md5\r\n"
    _, kept, _ = plan_hba(hostile, "lwcam", strict=True)
    assert [line for line, tls in kept if not tls] == ["host all all 0.0.0.0/0 md5"], "strict must fail on this"
    _, kept, was_there = plan_hba(b"local all all trust\n", "lwcam", strict=True)
    assert kept == [] and not was_there, "a legacy line that is not there is reported as not there"
    note = legacy_line_note(["postgres@100.90.100.64"])
    assert note == ("[NOTE] Kept the old rule that lets 'postgres' in from other PCs, because these are still "
                    "connected that way: postgres@100.90.100.64. Switch them to the shared login, then run "
                    "LWCamDatabaseSetup again to remove it.")
    # the legacy line is kept while other logins are connected from other PCs
    mine = frozenset({"192.168.0.10", "127.0.0.1", "::1"})
    rows = [("lwcam_user", "192.168.0.50", True), ("postgres", "192.168.0.10", False), ("postgres", "127.0.0.1", False),
            ("postgres", "192.168.0.99", False), ("reporter", "fd7a:115c:a1e0::9", False)]
    assert strict_blockers(rows, mine) == ["postgres@192.168.0.99", "reporter@fd7a:115c:a1e0::9"]
    assert strict_blockers(rows[:3], mine) == []
    # atomic write: replaces, keeps the bytes, leaves no temp file behind
    import tempfile
    with tempfile.TemporaryDirectory() as temporary:
        target = Path(temporary) / "pg_hba.conf"
        target.write_bytes(b"old\r\n")
        write_bytes_atomic(target, b"new\r\nlines\r\n")
        assert target.read_bytes() == b"new\r\nlines\r\n" and [f.name for f in Path(temporary).iterdir()] == ["pg_hba.conf"]
    # the server wait gives up, loudly, on a port nobody listens on
    try:
        wait_for_server({"host": "127.0.0.1", "port": 1, "user": "x", "password": "x", "sslmode": "prefer"}, timeout=0.5)
    except RuntimeError as error:
        assert "did not come back" in str(error)
    else:
        raise AssertionError("wait_for_server must raise when the server never answers")
    # app login: name and password validation
    for good in ("lwcam_user", "_x", "a" * 63):
        assert validate_app_login(good, "sa") == good
    for bad in ("postgres", "lwcam_app", "sa", "", "1abc", "Upper", "has-dash", "a b", "a" * 64, "x;drop"):
        try:
            validate_app_login(bad, "sa")
        except RuntimeError:
            pass
        else:
            raise AssertionError(f"login name {bad!r} must be refused")
    assert validate_app_password(None) is None and validate_app_password("") is None
    assert validate_app_password("twelve chars") == "twelve chars"
    for bad in ("short", "x" * 11, "twelve chars\n", "twelve\tchars!!", "twelve chars\x7f"):
        try:
            validate_app_password(bad)
        except RuntimeError as error:
            assert "twelve" not in str(error), "the error must not echo the password"
        else:
            raise AssertionError(f"password {bad!r} must be refused")
    # migrations: 001-005 alone, 006 onward together; BEGIN/COMMIT lines stripped
    names = [Path(f"{n:03d}_x.sql") for n in (1, 5, 6, 7, 8)]
    assert [[m.name[:3] for m in g] for g in migration_groups(names)] == [["001"], ["005"], ["006", "007", "008"]]
    assert strip_transaction_control("BEGIN;\r\nSELECT 1;\nDO $$ BEGIN\nEND $$;\n  commit;") == "SELECT 1;\nDO $$ BEGIN\nEND $$;"
    assert setup_sslmode("localhost", False) == "prefer" and setup_sslmode("localhost", True) == "require"
    assert setup_sslmode("db.example.com", False) == "require"
    _cert_self_test()
    services = [
        {"Name": "postgresql-x64-16", "PathName": '"C:\\PG\\16\\bin\\pg_ctl.exe" runservice -N "postgresql-x64-16" -D "C:\\PG\\16\\data" -w'},
        {"Name": "postgresql-x64-18", "PathName": '"C:\\PG\\18\\bin\\pg_ctl.exe" runservice -N "postgresql-x64-18" -D "C:/PG/18/data/" -w'},
    ]
    assert service_for_data_dir(services, "C:/PG/18/data") == "postgresql-x64-18"
    assert service_for_data_dir(services, "C:\\PG\\16\\data") == "postgresql-x64-16"
    assert service_for_data_dir(services, "C:\\other") is None
    _secrets_self_test()
    print("setup_qc_db self-test OK")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--config", type=Path, help="LWCam Admin's lwcam_node_config.json")
    source.add_argument("--server-config", type=Path, help="the QC server's config.txt")
    parser.add_argument("--database-dir", type=Path, help="folder holding the unified SQL and migrations/")
    parser.add_argument("--app-login", metavar="NAME",
                        help="create or update the ONE login every part uses and add it to lwcam_app; "
                             f"the password is read from the environment variable {APP_PASSWORD_ENV}")
    parser.add_argument("--create-roles", metavar="IGNORED", help=argparse.SUPPRESS)  # deprecated, no-op
    lan = parser.add_mutually_exclusive_group()
    lan.add_argument("--open-lan", action="store_true",
                     help="open a local PostgreSQL server to the network (part logins only) after setup")
    lan.add_argument("--close-lan", action="store_true",
                     help="remove the network entries --open-lan added, and the legacy samenet line")
    parser.add_argument("--strict-logins", action="store_true", help=argparse.SUPPRESS)  # deprecated, no-op (automatic now)
    parser.add_argument("--force-strict", action="store_true",
                        help="with --open-lan: remove the legacy samenet line although other logins are connected from other PCs")
    parser.add_argument("--reset-missing-roles", action="store_true", help=argparse.SUPPRESS)  # deprecated, no-op
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.config is None and args.server_config is None:
        parser.error("--config or --server-config is required")
    if args.database_dir is None:
        parser.error("--database-dir is required")
    if args.create_roles is not None or args.reset_missing_roles:
        print("[QC-DB] NOTE: --create-roles and --reset-missing-roles are deprecated and do nothing; "
              "use --app-login with LWCAM_APP_PASSWORD.")
    try:
        config = load_node_config(args.config) if args.config else load_server_config(args.server_config)
        # The env var wins; else the (decrypted) appPassword of the database.txt given as --server-config.
        app_password = os.environ.get(APP_PASSWORD_ENV) or config.get("app_password") or None
        prepare_database(config, args.database_dir, args.app_login, app_password)
        if args.open_lan or args.close_lan:
            edit_lan_access(config, close=args.close_lan, force_strict=args.force_strict)
    except Exception as error:
        print(f"[ERROR] {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

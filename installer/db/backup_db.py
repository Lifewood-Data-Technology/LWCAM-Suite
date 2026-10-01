"""Nightly LWCam database backup (run by the Database installer's own runtime).

    backup_db.py                 dump (+ globals file), prune, report a heartbeat
    backup_db.py --tool NAME    print the newest installed pg tool (RESTORE_DATABASE.bat)
    backup_db.py --safety-dump   one pre-restore-YYYYMMDD-HHMM.dump in the backup folder, no prune
    backup_db.py --restore FILE  safety dump, then pg_restore FILE in ONE transaction (RESTORE_DATABASE.bat)
    backup_db.py --write-pgpass  does nothing but delete an old config\\pgpass.conf

Settings: <root>\\config\\database.txt (login) and <root>\\config\\backup.txt
(backupDir, backupKeep). database.txt keeps its passwords DPAPI-protected
("dpapi:..."); they are decrypted here and reach pg_dump/pg_restore only through
the child process's environment (PGPASSWORD), never a file, a command line or the log.

Each run writes lwcam-YYYYMMDD-HHMM.dump AND lwcam-globals-YYYYMMDD-HHMM.sql
(pg_dumpall --globals-only: the roles with their password hashes, so the five
part logins survive a rebuild on a new PC). Both are pruned together.
"""
import argparse
import glob
import json
import os
import socket
import subprocess
import sys
from datetime import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lwcam_secrets  # noqa: E402  (sits beside this script)
LOG_LIMIT = 10 * 1024 * 1024


def read_kv(path):
    out = {}
    try:
        with open(path, encoding="utf-8-sig") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    out[k.strip()] = v.strip()
    except OSError:
        pass
    return out


def read_db(root):
    """database.txt with its DPAPI-protected passwords decrypted (plain ones pass through)."""
    db = read_kv(os.path.join(root, "config", "database.txt"))
    for key in ("dbPassword", "appPassword"):
        if db.get(key):
            db[key] = lwcam_secrets.unprotect(db[key], key)
    return db


def log(root, msg):
    d = os.path.join(root, "logs")
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, "backup.log")
    try:
        if os.path.getsize(p) > LOG_LIMIT:
            os.replace(p, p + ".1")
    except OSError:
        pass
    line = f"{datetime.now():%Y-%m-%d %H:%M:%S} {msg}"
    try:
        print(line)
    except UnicodeEncodeError:  # console code page cannot show it; the log file can
        print(line.encode("ascii", "replace").decode())
    with open(p, "a", encoding="utf-8") as f:
        f.write(line + "\n")


def sslmode(db):
    """TLS is required for any non-loopback database host (unverified, the
    server's certificate is self-signed); loopback may fall back to plain."""
    host = str(db.get("dbHost", "localhost")).strip().strip("[]").lower()
    use = str(db.get("dbUseSsl", "")).strip().lower() in ("true", "yes", "on", "1")
    return "require" if use or host not in ("localhost", "127.0.0.1", "::1") else "prefer"


def remove_pgpass(root):
    """Older versions wrote the password to config\\pgpass.conf; it is gone for good."""
    try:
        os.remove(os.path.join(root, "config", "pgpass.conf"))
    except OSError:
        pass


def pg_env(root, db):
    remove_pgpass(root)
    env = dict(os.environ, PGPASSWORD=db["dbPassword"], PGSSLMODE=sslmode(db))
    env.pop("PGPASSFILE", None)
    return env


def find_pg_tool(name):
    # ponytail: newest PostgreSQL under Program Files, else PATH; not the service ImagePath.
    hits = glob.glob(os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"),
                                  "PostgreSQL", "*", "bin", name + ".exe"))
    hits.sort(key=lambda p: [int(x) if x.isdigit() else 0 for x in p.split(os.sep)[-3].split(".")],
              reverse=True)
    if hits:
        return hits[0]
    for d in os.environ.get("PATH", "").split(os.pathsep):
        p = os.path.join(d, name + ".exe")
        if os.path.isfile(p):
            return p
    raise RuntimeError(f"{name}.exe not found (PostgreSQL client tools are not installed)")


def heartbeat(root, db, ok, error, backlog):
    try:
        import psycopg
        ver = "dev"
        try:
            ver = open(os.path.join(root, "VERSION.txt"), encoding="ascii").read().strip() or "dev"
        except OSError:
            pass
        with psycopg.connect(host=db.get("dbHost", "localhost"), port=int(db.get("dbPort", "5432")),
                             dbname=db.get("dbName", "lwcam"), user=db.get("dbUser", ""),
                             password=db.get("dbPassword", ""), connect_timeout=10,
                             sslmode=sslmode(db),
                             autocommit=True) as c:
            c.execute(
                """INSERT INTO service_heartbeat
                     (part, host, version, started_at, last_seen, last_ok, last_error, last_error_at, backlog)
                   VALUES ('backup', %(h)s, %(v)s, now(), now(),
                           CASE WHEN %(ok)s THEN now() END, %(e)s,
                           CASE WHEN NOT %(ok)s THEN now() END, %(b)s::jsonb)
                   ON CONFLICT (part, host) DO UPDATE SET
                     version = EXCLUDED.version, started_at = EXCLUDED.started_at, last_seen = now(),
                     last_ok = COALESCE(EXCLUDED.last_ok, service_heartbeat.last_ok),
                     last_error = EXCLUDED.last_error,
                     last_error_at = COALESCE(EXCLUDED.last_error_at, service_heartbeat.last_error_at),
                     backlog = CASE WHEN %(ok)s THEN EXCLUDED.backlog ELSE service_heartbeat.backlog END""",
                {"h": socket.gethostname(), "v": ver, "ok": ok, "e": error,
                 "b": json.dumps(backlog)})
    except Exception as e:  # the backup itself must not fail because the heartbeat did
        log(root, f"WARNING: could not write the heartbeat: {type(e).__name__}: {str(e)[:200]}")


def run_tool(cmd, env, out, label, cleanup=()):
    """Runs a pg tool; on failure removes its partial output (and cleanup files)."""
    # utf-8/replace: a localized or non-ASCII error text must not crash the log line.
    r = subprocess.run(cmd, env=env, capture_output=True, encoding="utf-8", errors="replace")
    if r.returncode != 0 or not os.path.isfile(out) or os.path.getsize(out) == 0:
        for f in (out, *cleanup):
            if os.path.isfile(f):
                os.remove(f)
        raise RuntimeError(f"{label} failed (exit {r.returncode}): {r.stderr.strip()[:300]}")


def safety_dump(root):
    """The dump RESTORE_DATABASE.bat takes first, so a wrong restore can be undone."""
    db = read_db(root)
    dest = read_kv(os.path.join(root, "config", "backup.txt")).get("backupDir", "")
    if not db.get("dbUser") or not db.get("dbPassword") or not dest:
        raise RuntimeError("config\\database.txt / backup.txt are incomplete")
    os.makedirs(dest, exist_ok=True)
    env = pg_env(root, db)
    final = os.path.join(dest, f"pre-restore-{datetime.now():%Y%m%d-%H%M}.dump")
    run_tool([find_pg_tool("pg_dump"), "-Fc", "-w", "-h", db.get("dbHost", "localhost"),
              "-p", db.get("dbPort", "5432"), "-U", db["dbUser"], "-d", db.get("dbName", "lwcam"),
              "-f", final], env, final, "pg_dump")
    log(root, f"Safety dump OK: {final}")


def restore(root, file):
    """Safety dump, then the whole dump in ONE transaction: a failed restore changes nothing.
    Exit 2 = the safety dump failed (nothing was restored), 1 = pg_restore failed."""
    try:
        safety_dump(root)
    except Exception as e:
        log(root, f"Safety dump FAILED: {type(e).__name__}: {e}"[:500])
        return 2
    try:
        db = read_db(root)
        r = subprocess.run([find_pg_tool("pg_restore"), "--clean", "--if-exists", "--single-transaction", "-w",
                            "-h", db.get("dbHost", "localhost"), "-p", db.get("dbPort", "5432"),
                            "-U", db["dbUser"], "-d", db.get("dbName", "lwcam"), file],
                           env=pg_env(root, db), capture_output=True, encoding="utf-8", errors="replace")
    except Exception as e:
        log(root, f"Restore FAILED: {type(e).__name__}: {e}"[:500])
        return 1
    if r.returncode != 0:
        log(root, f"Restore FAILED (pg_restore exit {r.returncode}): {r.stderr.strip()[:300]}")
        return 1
    log(root, f"Restore OK from {file}")
    return 0


def backup(root):
    db = read_db(root)
    cfg = read_kv(os.path.join(root, "config", "backup.txt"))
    if not db.get("dbUser") or not db.get("dbPassword"):
        raise RuntimeError("config\\database.txt has no login")
    dest = cfg.get("backupDir", "")
    keep = int(cfg.get("backupKeep", "14"))
    if not dest or not 1 <= keep <= 365:
        raise RuntimeError("config\\backup.txt needs backupDir and backupKeep (1-365)")
    os.makedirs(dest, exist_ok=True)
    env = pg_env(root, db)
    name = f"lwcam-{datetime.now():%Y%m%d-%H%M}.dump"
    tmp = os.path.join(dest, name + ".tmp")
    final = os.path.join(dest, name)
    cmd = [find_pg_tool("pg_dump"), "-Fc", "-w", "-h", db.get("dbHost", "localhost"),
           "-p", db.get("dbPort", "5432"), "-U", db["dbUser"], "-d", db.get("dbName", "lwcam"),
           "-f", tmp]
    run_tool(cmd, env, tmp, "pg_dump")
    # Roles + password hashes live outside the database dump. "-l" names the maintenance database.
    gname = "lwcam-globals-" + name[len("lwcam-"):-len(".dump")] + ".sql"
    gtmp = os.path.join(dest, gname + ".tmp")
    run_tool([find_pg_tool("pg_dumpall"), "--globals-only", "-w", "-h", db.get("dbHost", "localhost"),
              "-p", db.get("dbPort", "5432"), "-U", db["dbUser"], "-l", db.get("dbName", "lwcam"),
              "-f", gtmp], env, gtmp, "pg_dumpall", cleanup=[tmp])
    os.replace(tmp, final)
    os.replace(gtmp, os.path.join(dest, gname))
    for stale in glob.glob(os.path.join(dest, "lwcam-*.tmp")):
        try:
            os.remove(stale)
        except OSError:
            pass
    dumps = sorted(glob.glob(os.path.join(dest, "lwcam-[0-9]*.dump")))  # timestamp names sort by age
    for old in dumps[:-keep]:
        os.remove(old)
        log(root, f"Removed old backup {os.path.basename(old)}")
    for old in sorted(glob.glob(os.path.join(dest, "lwcam-globals-*.sql")))[:-keep]:
        os.remove(old)
    kept = len(dumps[-keep:])
    size_mb = round(os.path.getsize(final) / 1048576, 1)
    log(root, f"Backup OK: {final} ({size_mb} MB), keeping {kept}")
    return db, {"last_file": name, "size_mb": size_mb, "kept": kept}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--write-pgpass", action="store_true")  # kept so an old call does no harm
    ap.add_argument("--restore", metavar="FILE")
    ap.add_argument("--tool")
    ap.add_argument("--safety-dump", action="store_true")
    ap.add_argument("--root", default=ROOT)
    a = ap.parse_args()
    root = a.root
    if a.tool:
        print(find_pg_tool(a.tool))
        return 0
    if a.safety_dump:
        try:
            safety_dump(root)
        except Exception as e:
            log(root, f"Safety dump FAILED: {type(e).__name__}: {e}"[:500])
            return 1
        return 0
    if a.restore:
        return restore(root, a.restore)
    if a.write_pgpass:
        remove_pgpass(root)
        return 0
    try:
        db, backlog = backup(root)
    except Exception as e:
        msg = f"{type(e).__name__}: {e}"[:500]
        log(root, "Backup FAILED: " + msg)
        try:
            heartbeat(root, read_db(root), False, msg, {})
        except Exception:  # an undecryptable password: the failure is already in the log
            pass
        return 1
    heartbeat(root, db, True, None, backlog)
    return 0


if __name__ == "__main__":
    sys.exit(main())

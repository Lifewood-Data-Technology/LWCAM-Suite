"""Proves what the shared LWCam login can and cannot do (migrations 006-008).

Run it against a SCRATCH database that setup_qc_db.py has built:

    python check_role_grants.py --db lwcam_role_test [--config ..\\config.txt]
        [--role lwcam_app] [--login-user NAME]

Connection (host, port, superuser login) comes from the QC server's config.txt,
read the same way setup_qc_db.py reads it; --db replaces its dbName. The script
seeds a few rows as that user, then runs one statement per table/verb that must
SUCCEED and several that must be REFUSED with "permission denied", each inside a
transaction that is rolled back. Every LWCam part signs in with ONE login that is
a member of the group role lwcam_app, so the same probes cover all of them.

By default it switches to the group role with SET ROLE, which applies exactly the
group's privileges without needing a password; --role probes another role the
same way (a legacy lwcam_qc / lwcam_lwip ..., which must work through its
membership). --login-user NAME signs in as that login for real, with the
password from the environment variable LWCAM_APP_PASSWORD. Exit code 0 only if
every probe behaved.

Seed rows stay in the database it was pointed at, so never aim it at `lwcam`.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import setup_qc_db  # noqa: E402

OK, DENIED = "ok", "denied"


def seed(admin: Any) -> dict[str, Any]:
    """Rows to probe against; returns their ids and two bcrypt hashes."""
    def one(query: str, *params: Any) -> Any:
        return admin.execute(query, params).fetchone()[0]

    ids: dict[str, Any] = {}
    ids["old_hash"] = one("SELECT public.crypt('oldpw', public.gen_salt('bf', 6))")
    ids["b_hash"] = "$2b$" + ids["old_hash"][4:]  # Dart/Python write $2b$; pgcrypto made $2a$
    ids["new_hash"] = one("SELECT public.crypt('newpw', public.gen_salt('bf', 10))")
    # The function accepts bcrypt cost 10-14 only; the odd ones are format-only (cost 31 cannot be computed).
    ids["cost4"] = one("SELECT public.crypt('newpw', public.gen_salt('bf', 4))")
    ids["cost9"] = "$2a$09$" + ids["new_hash"][7:]
    ids["cost14"] = "$2a$14$" + ids["new_hash"][7:]
    ids["cost15"] = "$2a$15$" + ids["new_hash"][7:]
    ids["cost31"] = "$2a$31$" + ids["new_hash"][7:]
    ids["project"] = one(
        "INSERT INTO projects (project_id, project_key, project_name, country_location_code) "
        "VALUES ('PRB', 'probe-key', 'Probe', 'PRB') RETURNING id")
    ids["user_a"] = one(
        "INSERT INTO users (user_id, password, roles) VALUES ('probe_a', %s, 'Admin') RETURNING id",
        ids["old_hash"])
    admin.execute("INSERT INTO users (user_id, password, roles) VALUES ('probe_b', %s, 'Admin')",
                  (ids["b_hash"],))
    admin.execute("INSERT INTO users (user_id, password, roles, is_deleted) "
                  "VALUES ('probe_gone', %s, 'Admin', true)", (ids["old_hash"],))
    ids["device"] = one(
        "INSERT INTO devices (device_id, country_location_code) VALUES ('PROBE-DEV', 'PRB') RETURNING id")
    ids["box"] = one(
        "INSERT INTO capture_boxes (box_name, device_id, user_id, project_id) "
        "VALUES ('probe-box', %s, %s, %s) RETURNING box_id", ids["device"], ids["user_a"], ids["project"])
    ids["folder"] = one(
        "INSERT INTO capture_folders (folder_name, box_id, device_id, folder_seq) "
        "VALUES ('probe-folder', %s, %s, 1) RETURNING id", ids["box"], ids["device"])
    ids["image"] = one(
        "INSERT INTO capture_images (image_name, device_id, folder_id, file_format) "
        "VALUES ('probe.jpg', %s, %s, 'jpg') RETURNING id", ids["device"], ids["folder"])
    ids["role"] = one("SELECT id FROM roles ORDER BY id LIMIT 1")
    admin.execute("UPDATE capture_folders SET group_id = 'PRB-G1' WHERE id = %s", (ids["folder"],))
    admin.execute("INSERT INTO app_settings (key, value) VALUES ('superadmin_password_hash', 'secret'), "
                  "('default_temp_password_hash', 'other')")
    admin.execute("CREATE SEQUENCE IF NOT EXISTS public.lwcam_export_project_98_seq")
    return ids


def probes(i: dict[str, Any], role: str) -> list[tuple[str, str, str, str, Any]]:
    """(role, label, sql, expectation, expected scalar or None)."""
    p: list[tuple[str, str, str, str, Any]] = []
    export_no = "public.lwcam_next_export_number"

    def add(label: str, sql: str, expect: str = OK, value: Any = None) -> None:
        p.append((role, label, sql, expect, value))

    tables = ("app_settings", "capture_boxes", "capture_folders", "capture_images", "devices",
              "projects", "rework_logs", "roles", "user_projects", "users")
    f, b, d, u, im, pr, ro = (i[k] for k in ("folder", "box", "device", "user_a", "image", "project", "role"))
    new_hash = i["new_hash"]

    # ---- what QC does ------------------------------------------------------
    for t in tables:
        add(f"SELECT {t}", f"SELECT count(*) FROM {t}")
    add("INSERT users", f"INSERT INTO users (user_id, password, roles) VALUES ('probe_q', '{i['old_hash']}', 'QC')")
    add("UPDATE users(password, must_change_password, active, updated_by, last_login_at, soft delete)",
        f"UPDATE users SET password='x', must_change_password=true, active=false, updated_by={u}, "
        f"last_login_at=now(), roles='QC', is_deleted=true, deleted_at=now() WHERE id={u}")
    add("INSERT/DELETE user_projects",
        f"WITH x AS (INSERT INTO user_projects VALUES ({u}, {pr}, {ro}) RETURNING 1) "
        f"DELETE FROM user_projects WHERE user_id={u}")
    add("INSERT capture_folders (child)",
        f"INSERT INTO capture_folders (folder_name, box_id, device_id, folder_seq, separated_from_folder_id, "
        f"qc_status, client_qc_status, updated_at) VALUES ('c', {b}, {d}, 2, {f}, 'PENDING', NULL, now())")
    add("UPDATE capture_folders (review/export/metadata/paths)",
        f"UPDATE capture_folders SET qc_status='PASS', qc_locked_by='x', qc_locked_at=now(), qc_reviewed_by={u}, "
        f"client_rework=true, is_exported=true, exported_time=now(), group_id='g', is_tif_converted=true, "
        f"is_deskewed=true, is_cropped=true, is_created_thumbnail=true, updated_at=now(), source_updated_at=now(), "
        f"is_deleted=true, deleted_at=now(), folder_path='p', thumbnail_path='t', cover_tag='a', image_tags='a', "
        f"title='a', volume='a', start_date='1', end_date='2', archival_ref_no='a', record_type='a', place='a', "
        f"language='a', record_custodian='a', capture_operator_id='a', capture_operator_name='a', "
        f"digitizing_entity='a' WHERE id={f}")
    add("SELECT ... FOR UPDATE capture_folders", f"SELECT id FROM capture_folders WHERE id={f} FOR UPDATE")
    add("INSERT/UPDATE/DELETE capture_images (QC)",
        f"WITH a AS (INSERT INTO capture_images (image_name, device_id, folder_id, file_format) "
        f"VALUES ('n.jpg', {d}, {f}, 'jpg') RETURNING id), "
        f"b AS (UPDATE capture_images SET folder_id={f}, image_name='z.jpg', file_format='tif', "
        f"image_updated_at=now(), image_created_at=now() WHERE id={im} RETURNING 1) "
        f"DELETE FROM capture_images WHERE id={im}")
    add("INSERT rework_logs (QC)",
        f"INSERT INTO rework_logs (image_id, assigned_uid, folder_id, rework_comments, rework_type) "
        f"VALUES ({im}, {u}, {f}, 'c', 'QC Rework')")
    add("lwcam_next_export_number creates the sequence, first number 1", f"SELECT {export_no}(97)", OK, 1)
    add("lwcam_next_export_number: numbers increase",
        f"SELECT {export_no}(97); SELECT {export_no}(97); SELECT {export_no}(97)", OK, 3)
    add("lwcam_next_export_number: another project has its own sequence",
        f"SELECT {export_no}(97); SELECT {export_no}(97); SELECT {export_no}(95)", OK, 1)
    add("lwcam_next_export_number: existing sequence continues", f"SELECT {export_no}(98)")
    add("lwcam_next_export_number(0) rejected", f"SELECT {export_no}(0)", "error")
    add("lwcam_next_export_number(-5) rejected", f"SELECT {export_no}(-5)", "error")
    add("setval on an existing export sequence refused",
        "SELECT setval('public.lwcam_export_project_98_seq', 500)", DENIED)
    add("setval on a function-made export sequence refused (default privileges)",
        f"SELECT {export_no}(97); SELECT setval('public.lwcam_export_project_97_seq', 500)", DENIED)
    add("ALTER SEQUENCE ... RESTART refused",
        "ALTER SEQUENCE public.lwcam_export_project_98_seq RESTART WITH 1", DENIED)
    add("nextval on an existing export sequence (USAGE)", "SELECT nextval('public.lwcam_export_project_98_seq'::regclass)")
    add("advisory lock", "SELECT pg_advisory_xact_lock(hashtextextended('x', 0))")

    # ---- what LWIP does ----------------------------------------------------
    add("LWIP: SELECT users(sign-in columns)", "SELECT password, roles, active, is_deleted FROM users WHERE user_id='probe_a'")
    add("LWIP: SELECT projects(id, project_key)", "SELECT id FROM projects WHERE project_key='probe-key'")
    add("LWIP: SELECT capture_boxes(box_id, project_id, box_name)",
        f"SELECT box_id FROM capture_boxes WHERE project_id={pr} AND box_name='probe-box'")
    add("LWIP: SELECT capture_folders(id, box_id, folder_seq)", f"SELECT id FROM capture_folders WHERE box_id={b} AND folder_seq=1")
    add("LWIP: UPDATE capture_folders (report, as cloud_report.py)",
        f"UPDATE capture_folders SET is_deskewed=TRUE, is_cropped=TRUE, is_created_thumbnail=FALSE, folder_path='p', "
        f"thumbnail_path=NULL, qc_status = CASE WHEN qc_status IS NULL OR upper(qc_status) IN ('', 'PENDING', 'REWORK') "
        f"THEN 'PENDING' ELSE qc_status END WHERE id={f}")

    # ---- what Upload does --------------------------------------------------
    add("Upload: SELECT capture_folders(upload columns)",
        "SELECT id, is_ingested, ingested_time, upload_error FROM capture_folders WHERE group_id='PRB-G1'")
    add("Upload: mark folder uploaded by group_id (success)",
        "UPDATE capture_folders SET is_ingested=true, ingested_time=now(), upload_error=NULL WHERE group_id='PRB-G1'")
    add("Upload: record a permanent failure by group_id",
        "UPDATE capture_folders SET upload_error='bucket not found' WHERE group_id='PRB-G1'")

    # ---- what LWCAM (capture) does ----------------------------------------
    add("LWCAM: UPDATE users(last_login_at)", f"UPDATE users SET last_login_at=now() WHERE id={u}")
    add("LWCAM: UPDATE projects(has_data)", "UPDATE projects SET has_data = TRUE WHERE project_key='probe-key'")
    add("LWCAM: INSERT devices ... ON CONFLICT DO UPDATE(user_id, login_at) (device sign-in)",
        "INSERT INTO devices (device_id, country_location_code, user_id, login_at) "
        "SELECT 'PROBE-DEV', 'PRB', u.id, now() FROM (SELECT 1) one LEFT JOIN users u ON u.user_id = 'probe_a' "
        "WHERE EXISTS (SELECT 1 FROM projects WHERE country_location_code = 'PRB') "
        "ON CONFLICT (device_id) DO UPDATE SET user_id = EXCLUDED.user_id, login_at = now()")
    add("LWCAM: INSERT capture_boxes ... ON CONFLICT DO UPDATE",
        f"INSERT INTO capture_boxes (box_name, device_id, status, user_id, project_id, created_at, transfer_start_at, "
        f"transfer_end_at, transferred_to) VALUES ('probe-box', {d}, 'OPEN', {u}, {pr}, now(), NULL, NULL, NULL) "
        f"ON CONFLICT (project_id, box_name) DO UPDATE SET device_id = EXCLUDED.device_id, status = EXCLUDED.status, "
        f"user_id = EXCLUDED.user_id, transfer_start_at = EXCLUDED.transfer_start_at, "
        f"transfer_end_at = EXCLUDED.transfer_end_at, transferred_to = EXCLUDED.transferred_to, "
        f"is_deleted = FALSE, deleted_at = NULL WHERE capture_boxes.device_id = EXCLUDED.device_id RETURNING box_id")
    add("LWCAM: UPDATE capture_boxes(box_name, is_deleted)",
        f"UPDATE capture_boxes SET box_name='r', is_deleted = TRUE, deleted_at = now() WHERE box_id={b}")
    add("LWCAM: INSERT capture_folders ... ON CONFLICT DO UPDATE",
        f"INSERT INTO capture_folders (folder_name, box_id, device_id, folder_seq, cover_tag, image_tags, title, volume, "
        f"archival_ref_no, record_type, place, language, record_custodian, capture_operator_id, capture_operator_name, "
        f"digitizing_entity, start_date, end_date, source_created_at, source_updated_at) "
        f"VALUES ('probe-folder', {b}, {d}, 1, 'a','a','a','a','a','a','a','a','a','a','a','a','1','2', now(), now()) "
        f"ON CONFLICT (box_id, folder_seq) DO UPDATE SET folder_name = EXCLUDED.folder_name, device_id = EXCLUDED.device_id, "
        f"cover_tag = EXCLUDED.cover_tag, title = EXCLUDED.title, start_date = EXCLUDED.start_date, "
        f"source_updated_at = EXCLUDED.source_updated_at, source_created_at = EXCLUDED.source_created_at, "
        f"is_deleted = FALSE, deleted_at = NULL "
        f"WHERE capture_folders.device_id = EXCLUDED.device_id RETURNING id")
    add("LWCAM: UPDATE capture_folders (processing flags, paths, status)",
        f"UPDATE capture_folders SET is_deskewed = TRUE, is_cropped = TRUE, is_created_thumbnail = TRUE, folder_path='p', "
        f"thumbnail_path='t', qc_status = 'PENDING' WHERE id={f}")
    add("LWCAM: UPDATE capture_folders (soft delete)", f"UPDATE capture_folders SET is_deleted = TRUE, deleted_at = now() WHERE id={f}")
    add("LWCAM: INSERT capture_images ... ON CONFLICT DO UPDATE",
        f"INSERT INTO capture_images (image_name, device_id, folder_id, file_format, image_created_at) "
        f"VALUES ('probe.jpg', {d}, {f}, 'jpg', now()) ON CONFLICT (folder_id, image_name) DO UPDATE SET "
        f"file_format = EXCLUDED.file_format, image_updated_at = now()")
    add("LWCAM: UPDATE/DELETE capture_images",
        f"WITH a AS (UPDATE capture_images SET image_name='renamed.jpg' WHERE id={im} RETURNING 1) "
        f"DELETE FROM capture_images WHERE folder_id={f}")
    add("LWCAM: INSERT rework_logs",
        f"INSERT INTO rework_logs (image_id, assigned_uid, folder_id, rework_comments, rework_status, rework_type) "
        f"VALUES ({im}, {u}, {f}, 'c', 'CLOSED', 'Recapture')")

    # ---- the password function ---------------------------------------------
    add("lwcam_change_own_password: right old password -> true",
        f"SELECT public.lwcam_change_own_password('probe_a', 'oldpw', '{new_hash}')", OK, True)
    add("lwcam_change_own_password: $2b$ hash accepted",
        f"SELECT public.lwcam_change_own_password('probe_b', 'oldpw', '{new_hash}')", OK, True)
    add("lwcam_change_own_password: wrong old password -> false",
        f"SELECT public.lwcam_change_own_password('probe_a', 'WRONG', '{new_hash}')", OK, False)
    add("lwcam_change_own_password: deleted user -> false",
        f"SELECT public.lwcam_change_own_password('probe_gone', 'oldpw', '{new_hash}')", OK, False)
    for label, key, want in (("cost 04", "cost4", False), ("cost 09", "cost9", False), ("cost 10", "new_hash", True),
                             ("cost 14", "cost14", True), ("cost 15", "cost15", False), ("cost 31", "cost31", False)):
        add(f"lwcam_change_own_password: new hash of {label} -> {str(want).lower()}",
            f"SELECT public.lwcam_change_own_password('probe_a', 'oldpw', '{i[key]}')", OK, want)
    if i.get("set_role"):
        # A login that could plant a same-named function in public used to run it as the setup user
        # (search_path public, pg_temp). The planted one is a bomb; the function must never reach it.
        # DISCARD PLANS: an earlier probe on this connection cached the function's plan (it would not
        # notice a function created afterwards), and a real attacker plants before the first call.
        plant = ("RESET ROLE; CREATE FUNCTION public.regexp_replace(varchar, text, text) RETURNS text "
                 "LANGUAGE sql AS 'SELECT (1/0)::text'; DISCARD PLANS; ")
        add("control: the planted regexp_replace(varchar,...) really is a bomb",
            plant + "SELECT public.regexp_replace('a'::varchar, 'b', 'c')", "error")
        add("planted public.regexp_replace does NOT hijack lwcam_change_own_password",
            plant + f"SET LOCAL ROLE {role}; SELECT public.lwcam_change_own_password('probe_a', 'oldpw', '{new_hash}')",
            OK, True)
        add("planted public.regexp_replace: wrong old password still -> false",
            plant + f"SET LOCAL ROLE {role}; SELECT public.lwcam_change_own_password('probe_a', 'WRONG', "
            f"'{new_hash}')", OK, False)
    add("lwcam_change_own_password: plaintext new value -> false",
        "SELECT public.lwcam_change_own_password('probe_a', 'oldpw', 'plaintext')", OK, False)
    add("lwcam_change_own_password really changes the row",
        f"SELECT public.lwcam_change_own_password('probe_a', 'oldpw', '{new_hash}'); "
        f"SELECT password = '{new_hash}' AND NOT must_change_password FROM users WHERE user_id='probe_a'", OK, True)

    # ---- what LWCam Admin does ---------------------------------------------
    add("Admin: INSERT users ... ON CONFLICT DO UPDATE",
        f"INSERT INTO users (user_id, password, active, must_change_password, roles, device_id, created_at) "
        f"VALUES ('probe_a', 'x', true, true, 'QC', 'd', clock_timestamp()) ON CONFLICT (user_id) DO UPDATE SET "
        f"active = EXCLUDED.active, roles = EXCLUDED.roles, device_id = EXCLUDED.device_id, is_deleted = FALSE, "
        f"deleted_at = NULL WHERE users.active IS DISTINCT FROM EXCLUDED.active OR users.roles IS DISTINCT FROM EXCLUDED.roles")
    add("Admin: UPDATE users(password, must_change_password, created_by, soft delete)",
        f"UPDATE users SET password='x', must_change_password=TRUE, created_by={u}, is_deleted=TRUE, deleted_at=now(), "
        f"active=FALSE WHERE id={u}")
    add("Admin: INSERT projects ... ON CONFLICT DO UPDATE",
        "INSERT INTO projects (project_key, project_id, project_name, country_location_code, start_date, has_data, template) "
        "VALUES ('probe-key', 'PRB2', 'n', 'PRB', NULL, false, NULL) ON CONFLICT (project_key) DO UPDATE SET "
        "project_id = EXCLUDED.project_id, project_name = EXCLUDED.project_name, "
        "country_location_code = EXCLUDED.country_location_code, start_date = EXCLUDED.start_date, "
        "has_data = projects.has_data OR EXCLUDED.has_data, template = EXCLUDED.template, is_deleted = FALSE, "
        "deleted_at = NULL WHERE projects.project_id IS DISTINCT FROM EXCLUDED.project_id")
    add("Admin: soft-delete a project whose device references its code (FK cascade)",
        "UPDATE projects SET is_deleted = TRUE, deleted_at = now(), country_location_code = '~deleted~' || id "
        "WHERE project_key = 'probe-key'")
    add("Admin: INSERT roles", "INSERT INTO roles (role_name) VALUES ('ProbeRole') ON CONFLICT (role_name) DO NOTHING")
    add("Admin: INSERT app_settings ... ON CONFLICT DO UPDATE(value)",
        "INSERT INTO app_settings (key, value) VALUES ('superadmin_password_hash', 'n') ON CONFLICT (key) DO UPDATE "
        "SET value = EXCLUDED.value WHERE app_settings.value IS DISTINCT FROM EXCLUDED.value")
    add("Admin: UPDATE devices(country_location_code)", f"UPDATE devices SET country_location_code = 'PRB' WHERE id={d}")
    add("sees the SuperAdmin password setting (no row security)",
        "SELECT count(*) FROM app_settings WHERE key='superadmin_password_hash'", OK, 1)
    add("row security is off on app_settings",
        "SELECT NOT relrowsecurity FROM pg_class WHERE oid = 'public.app_settings'::regclass", OK, True)
    add("no app_settings policies left", "SELECT count(*) FROM pg_policies WHERE tablename = 'app_settings'", OK, 0)

    # ---- heartbeat, schema level, upload_error -----------------------------
    beat = ("INSERT INTO service_heartbeat (part, host, version, started_at, last_seen, last_ok, last_error, "
            "last_error_at, backlog) VALUES ('{part}', 'PROBE-HOST', '1.1.0', now(), now(), now(), NULL, NULL, "
            "'{{\"pending\": 1}}') ON CONFLICT (part, host) DO UPDATE SET version=EXCLUDED.version, "
            "last_seen=now(), last_ok=now(), last_error=EXCLUDED.last_error, "
            "last_error_at=EXCLUDED.last_error_at, backlog=EXCLUDED.backlog")
    for part in ("qc", "lwip", "upload", "capture"):
        add(f"upsert own service_heartbeat row ({part})", beat.format(part=part))
        add(f"upsert twice ({part}): insert then ON CONFLICT update", beat.format(part=part) + "; " + beat.format(part=part))
    add("DELETE service_heartbeat row (forget a PC)",
        beat.format(part="qc") + "; DELETE FROM service_heartbeat WHERE host = 'PROBE-HOST'")
    add("SELECT service_heartbeat", "SELECT count(*) FROM service_heartbeat")
    add("read the schema level",
        "SELECT coalesce(max(substring(version from '^[0-9]+')::int), 0) FROM schema_migrations", OK, 8)
    add("INSERT schema_migrations refused", "INSERT INTO schema_migrations (version) VALUES ('999_evil')", DENIED)
    add("UPDATE schema_migrations refused", "UPDATE schema_migrations SET version = 'x'", DENIED)
    add("SELECT capture_folders(upload_error)", "SELECT upload_error FROM capture_folders")

    # ---- refused: structure, execution, identity columns -------------------
    add("DROP TABLE users refused", "DROP TABLE users", DENIED)
    add("ALTER TABLE users refused", "ALTER TABLE users ADD COLUMN x int", DENIED)
    add("TRUNCATE capture_folders refused", "TRUNCATE capture_folders", DENIED)
    add("COPY ... TO PROGRAM refused", "COPY (SELECT 1) TO PROGRAM 'cmd /c echo hi'", DENIED)
    add("CREATE ROLE refused", "CREATE ROLE probe_evil", DENIED)
    add("ALTER ROLE postgres refused", "ALTER ROLE postgres PASSWORD 'hijack'", DENIED)
    add("DELETE FROM users refused", "DELETE FROM users", DENIED)
    add("DELETE FROM capture_folders refused", "DELETE FROM capture_folders", DENIED)
    add("DELETE FROM projects refused", "DELETE FROM projects", DENIED)
    add("DELETE FROM capture_boxes refused", "DELETE FROM capture_boxes", DENIED)
    add("CREATE FUNCTION in public refused",
        "CREATE FUNCTION public.regexp_replace(varchar, text, text) RETURNS text LANGUAGE sql AS 'select 1'", DENIED)
    add("CREATE SEQUENCE in public refused", "CREATE SEQUENCE public.probe_seq", DENIED)
    add("CREATE TABLE refused", "CREATE TABLE probe_t (a int)", DENIED)
    add("UPDATE users(user_id) refused", f"UPDATE users SET user_id='hijack' WHERE id={u}", DENIED)
    add("UPDATE capture_folders(box_id) refused", f"UPDATE capture_folders SET box_id={b} WHERE id={f}", DENIED)
    add("UPDATE capture_folders(folder_seq) refused", f"UPDATE capture_folders SET folder_seq=99 WHERE id={f}", DENIED)
    add("UPDATE projects(project_key) refused", "UPDATE projects SET project_key='x'", DENIED)
    add("UPDATE app_settings(key) refused", "UPDATE app_settings SET key = 'x'", DENIED)
    add("UPDATE roles refused", "UPDATE roles SET role_name = 'x'", DENIED)
    add("UPDATE rework_logs refused", "UPDATE rework_logs SET rework_comments = 'x'", DENIED)
    return p


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--db", required=True, help="scratch database to probe (NEVER the real one)")
    parser.add_argument("--config", type=Path, default=Path(__file__).resolve().parents[1] / "config.txt",
                        help="the QC server's config.txt (superuser login)")
    parser.add_argument("--role", default=setup_qc_db.APP_GROUP,
                        help="role to SET ROLE to (default the group lwcam_app; a legacy lwcam_qc ... also works)")
    parser.add_argument("--login-user", metavar="NAME",
                        help=f"sign in as this login for real; password from ${setup_qc_db.APP_PASSWORD_ENV}")
    args = parser.parse_args()
    if args.db.lower() == "lwcam":
        parser.error("refusing to seed probe rows into the real database")
    setup_qc_db.validate_app_login(args.role) if args.role != setup_qc_db.APP_GROUP else None

    import psycopg

    config = setup_qc_db.load_server_config(args.config)
    base = dict(host=config["host"], port=config["port"], dbname=args.db)
    real_password = os.environ.get(setup_qc_db.APP_PASSWORD_ENV) if args.login_user else None
    if args.login_user and not real_password:
        parser.error(f"--login-user needs {setup_qc_db.APP_PASSWORD_ENV} in the environment")

    with psycopg.connect(user=config["user"], password=config["password"], autocommit=True, **base) as admin:
        ids = seed(admin)
    ids["set_role"] = not args.login_user  # the planted-function probe switches roles mid-transaction
    label = args.login_user or args.role
    failures = 0
    conn = (psycopg.connect(user=args.login_user, password=real_password, **base) if args.login_user
            else psycopg.connect(user=config["user"], password=config["password"], **base))
    try:
        for role, text, sql, expect, value in probes(ids, args.role):
            outcome, detail = "", ""
            try:
                if not args.login_user:
                    conn.execute(f'SET LOCAL ROLE "{role}"')
                for part in sql.split("; "):
                    cursor = conn.execute(part)
                got = cursor.fetchone()[0] if cursor.description else None
                outcome = OK
                if value is not None and got != value:
                    outcome, detail = "wrong value", f"got {got!r}, wanted {value!r}"
            except psycopg.errors.InsufficientPrivilege as error:
                outcome, detail = DENIED, str(error).splitlines()[0]
            except psycopg.Error as error:
                outcome, detail = "error", str(error).splitlines()[0]
            finally:
                conn.rollback()
            good = outcome == expect
            failures += not good
            print(f"{'PASS' if good else 'FAIL'} {label:14} {text} -> {outcome}" + (f"  [{detail}]" if detail else ""))
    finally:
        conn.close()
    total = len(probes(ids, args.role))
    print(f"\n{total - failures}/{total} probes behaved as expected" + ("" if not failures else f", {failures} FAILED"))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())

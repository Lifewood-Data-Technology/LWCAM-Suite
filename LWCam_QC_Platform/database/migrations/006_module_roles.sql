-- 006_module_roles.sql
--
-- ONE group role, lwcam_app, that holds everything the LWCam parts need. Until
-- now every part signed in as `postgres`, which can drop the database or run
-- programs on the server.
--
-- lwcam_app is NOLOGIN. The operator's chosen login (LWCamDatabaseSetup asks for
-- database, user and password) is made a member by setup_qc_db.py --app-login,
-- and QC, LWIP, Upload, every capture PC's LWCAM and LWCam Admin all sign in
-- with that one login. Its privileges are the UNION of what the five earlier
-- per-part logins (lwcam_qc, lwcam_lwip, lwcam_upload, lwcam_capture,
-- lwcam_admin) were given, measured from the code, column by column:
--   QC             routers/qc.py, admin.py, auth.py, services/export.py
--   LWIP           deskew_crop_tool/cloud_report.py, service.py (console sign-in)
--   Upload         lwcam_upload/console.py (console sign-in)
--   LWCAM          lib/services/pg_statements.dart, device_registry.dart
--   LWCam Admin    lib/services/admin_pg_statements.dart, device_registry.dart
-- UPDATE is granted per column; every UPDATE / ON CONFLICT DO UPDATE also needs
-- SELECT on what it reads, which lwcam_app has. updated_at is set by the
-- lwcam_set_updated_at() trigger, which needs no grant.
--
-- The five old logins, when they exist (a site set up before this change), are
-- made members of lwcam_app, so parts configured with them keep working. Their
-- old direct grants are left alone.
--
-- Still true, for the group and so for every member: no CREATE on schema public
-- (008 adds public.lwcam_next_export_number, a SECURITY DEFINER function that
-- makes the export sequences instead), USAGE only on those sequences (no
-- setval), no ownership, no superuser / createdb / createrole / replication /
-- bypassrls. The password function lwcam_change_own_password is created by 008.
--
-- The row-level security an earlier 006 put on app_settings (it hid
-- superadmin_password_hash from capture PCs) is REMOVED here: one login cannot
-- tell the parts apart, and LWCam Admin needs that row.
--
-- setup_qc_db.py runs 006, 007 and 008 in ONE transaction, so the table-grant
-- reset below is never visible to a running service half done.
--
--   psql -h <host> -U <user> -d <dbname> -v ON_ERROR_STOP=1 -f 006_module_roles.sql

BEGIN;

-- The unified dump ends with an EMPTY search_path on the same connection, so
-- say where things live.
SET LOCAL search_path = public;

CREATE EXTENSION IF NOT EXISTS pgcrypto SCHEMA public;

-- Nobody but the setup user gets to build in the schema (already the default
-- from PostgreSQL 15; older servers grant it to PUBLIC).
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

DO $group$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lwcam_app') THEN
        CREATE ROLE lwcam_app;
    END IF;
    ALTER ROLE lwcam_app NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
END
$group$;

-- The row security an earlier version of this file switched on.
DROP POLICY IF EXISTS lwcam_app_settings_full ON app_settings;
DROP POLICY IF EXISTS lwcam_app_settings_capture ON app_settings;
ALTER TABLE app_settings DISABLE ROW LEVEL SECURITY;

DO $roles$
DECLARE
    r text;
    s record;
BEGIN
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO lwcam_app', current_database());
    GRANT USAGE ON SCHEMA public TO lwcam_app;
    -- Re-runnable: start from a clean slate. Safe for running services only
    -- because setup runs 006-008 as one transaction.
    REVOKE ALL ON ALL TABLES IN SCHEMA public FROM lwcam_app;

    -- Sites set up with the five per-part logins keep working through the group.
    FOREACH r IN ARRAY ARRAY['lwcam_qc', 'lwcam_lwip', 'lwcam_upload', 'lwcam_capture', 'lwcam_admin'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('GRANT lwcam_app TO %I', r);
        END IF;
    END LOOP;

    GRANT SELECT ON app_settings, capture_boxes, capture_folders, capture_images, devices,
                    projects, rework_logs, roles, user_projects, users TO lwcam_app;
    GRANT INSERT ON users, user_projects, capture_folders, capture_images, rework_logs,
                    devices, capture_boxes, projects, roles, app_settings TO lwcam_app;
    GRANT DELETE ON user_projects, capture_images TO lwcam_app;
    -- No table-level UPDATE anywhere; user_id, box_id, folder_seq, project_key and
    -- the other identity columns stay unchangeable.
    GRANT UPDATE (password, must_change_password, roles, active, is_deleted, deleted_at,
                  updated_by, last_login_at, device_id, created_by) ON users TO lwcam_app;
    GRANT UPDATE (project_id, project_name, country_location_code, start_date, has_data,
                  template, is_deleted, deleted_at) ON projects TO lwcam_app;
    GRANT UPDATE (user_id, login_at, country_location_code) ON devices TO lwcam_app;
    GRANT UPDATE (box_name, device_id, status, user_id, transfer_start_at, transfer_end_at,
                  transferred_to, is_deleted, deleted_at) ON capture_boxes TO lwcam_app;
    GRANT UPDATE (qc_status, qc_locked_by, qc_locked_at, qc_reviewed_by, client_rework,
                  is_exported, exported_time, group_id, is_tif_converted, is_deskewed,
                  is_cropped, is_created_thumbnail, updated_at, source_created_at,
                  source_updated_at, is_deleted, deleted_at, folder_path, thumbnail_path,
                  folder_name, device_id,
                  cover_tag, image_tags, title, volume, start_date, end_date,
                  archival_ref_no, record_type, place, language, record_custodian,
                  capture_operator_id, capture_operator_name, digitizing_entity)
          ON capture_folders TO lwcam_app;
    GRANT UPDATE (folder_id, image_name, file_format, image_updated_at, image_created_at)
          ON capture_images TO lwcam_app;
    GRANT UPDATE (value) ON app_settings TO lwcam_app;

    -- Export numbers: 008's lwcam_next_export_number creates
    -- lwcam_export_project_<id>_seq (owned by the setup user). The group gets
    -- USAGE only - no UPDATE, so no setval. Sequences an older version let
    -- lwcam_qc create are handed back to the setup user by 008.
    FOR s IN SELECT relname FROM pg_class
              WHERE relkind = 'S' AND relnamespace = 'public'::regnamespace
                AND relname LIKE 'lwcam\_export\_project\_%' LOOP
        EXECUTE format('REVOKE ALL ON SEQUENCE public.%I FROM lwcam_app', s.relname);
        EXECUTE format('GRANT USAGE ON SEQUENCE public.%I TO lwcam_app', s.relname);
    END LOOP;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE SELECT, UPDATE ON SEQUENCES FROM lwcam_app;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE ON SEQUENCES TO lwcam_app;
END
$roles$;

COMMIT;

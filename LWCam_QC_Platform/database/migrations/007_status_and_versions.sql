-- 007_status_and_versions.sql
--
-- Phase 3: every part reports whether it is alive, and refuses to run against a
-- database older than itself.
--
--   schema_migrations  one row per applied migration file (setup_qc_db.py
--                      inserts them, 001-006 included on the first run). The
--                      schema level is the highest number in it.
--   service_heartbeat  one row per (part, PC), upserted by each part every 60 s.
--   capture_folders.upload_error
--                      why the Upload service gave up on a package; NULL = fine.
--
-- Grants go to the group role lwcam_app that 006 creates.
--
--   psql -h <host> -U <user> -d <dbname> -v ON_ERROR_STOP=1 -f 007_status_and_versions.sql

BEGIN;

SET LOCAL search_path = public;

CREATE TABLE IF NOT EXISTS public.schema_migrations (
    version    text PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.service_heartbeat (
    part          text NOT NULL,
    host          text NOT NULL,
    version       text,
    started_at    timestamptz,
    last_seen     timestamptz NOT NULL DEFAULT now(),
    last_ok       timestamptz,
    last_error    text,
    last_error_at timestamptz,
    backlog       jsonb NOT NULL DEFAULT '{}',
    PRIMARY KEY (part, host)
);

ALTER TABLE public.capture_folders ADD COLUMN IF NOT EXISTS upload_error text;

-- One group role for every part (006). 006, which runs first, revokes every
-- table grant from lwcam_app, so this file re-grants what it owns each run
-- (setup runs 006-008 in one transaction, so nobody sees the gap).
GRANT SELECT ON public.schema_migrations TO lwcam_app;
-- Every part reports its heartbeat; QC's status page can forget a PC that has
-- been retired (DELETE); LWCam Admin reads it.
GRANT SELECT, INSERT, UPDATE, DELETE ON public.service_heartbeat TO lwcam_app;

-- Upload marks a package's folder uploaded, by Group ID. (lwcam_app already has
-- SELECT on the whole capture_folders table, which covers the new column.)
GRANT UPDATE (is_ingested, ingested_time, upload_error) ON public.capture_folders TO lwcam_app;

COMMIT;

-- Check: the new objects exist.
SELECT to_regclass('public.schema_migrations') IS NOT NULL AS schema_migrations,
       to_regclass('public.service_heartbeat') IS NOT NULL AS service_heartbeat,
       EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'capture_folders'
                  AND column_name = 'upload_error') AS upload_error;

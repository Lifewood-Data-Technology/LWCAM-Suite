-- 001_qc_platform_deltas.sql
--
-- Brings a database created from LWCam_database_20260720.sql up to what the QC
-- platform backend requires. Apply once, against the shared LWCam database:
--
--   psql -h <host> -U <user> -d lwcam -v ON_ERROR_STOP=1 -f 001_qc_platform_deltas.sql
--
-- Idempotent — safe to re-run. Adds nothing LWCAM/LWCamAdmin read or write, so
-- it cannot affect the capture apps.


BEGIN;

-- ---------------------------------------------------------------------------
-- 1. QC task claim/lock columns
-- ---------------------------------------------------------------------------
-- Required by backend/app/models/capture.py; a QC operator claims a folder and
-- these record who holds it. Without them every QC endpoint fails on first
-- query. qc_locked_by stores users.user_id (the username) rather than the
-- BIGINT id — matching the backend's model, which compares it against
-- User.user_id and is deliberately not an FK.

ALTER TABLE public.capture_folders
    ADD COLUMN IF NOT EXISTS qc_locked_by VARCHAR(255),
    ADD COLUMN IF NOT EXISTS qc_locked_at TIMESTAMPTZ(3);

-- The admin task screen lists only claimed folders (WHERE qc_locked_by IS NOT
-- NULL, ordered by qc_locked_at). Partial index: claimed rows are the small
-- minority, so this stays tiny while the table grows.
CREATE INDEX IF NOT EXISTS idx_capture_folders_qc_locked
    ON public.capture_folders (qc_locked_at, qc_locked_by)
    WHERE qc_locked_by IS NOT NULL;


-- ---------------------------------------------------------------------------
-- 2. QC role registry row
-- ---------------------------------------------------------------------------
-- LWCam_database_20260720.sql ships no seed data, and LWCamAdmin only seeds its
-- own roles ('admin', 'capture' — lowercase, from its UserRole enum). The QC
-- backend resolves roles.role_name -> roles.id when it writes user_projects for
-- a QC account, so creating or editing a QC user 400s without this row.
-- Lowercase to match LWCamAdmin's convention; the backend's lookup is
-- case-insensitive either way.

INSERT INTO public.roles (role_name)
VALUES ('qc')
ON CONFLICT (role_name) DO NOTHING;

COMMIT;


-- ---------------------------------------------------------------------------
-- 3. Post-migration checks (read-only — nothing below changes data)
-- ---------------------------------------------------------------------------

-- 3a. Columns and role row landed?
SELECT
    (SELECT count(*) FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'capture_folders'
        AND column_name IN ('qc_locked_by', 'qc_locked_at'))       AS lock_columns_expect_2,
    (SELECT count(*) FROM public.roles WHERE lower(role_name) = 'qc') AS qc_role_expect_1;

-- 3b. Accounts still holding a pre-bcrypt MD5 hash.
-- The QC backend used MD5 before this changeover; LWCAM/LWCamAdmin have always
-- used bcrypt ($2a$/$2b$/$2y$, 60 chars). Any row listed here can log into
-- NEITHER app and must have its password reset from LWCamAdmin (capture/admin
-- accounts) or the QC admin UI (qc accounts). Expect zero rows on a database
-- that only ever saw the Flutter apps.
SELECT id, user_id, roles, length(password) AS hash_len
FROM public.users
WHERE is_deleted IS NOT TRUE
  AND password NOT LIKE '$2a$%'
  AND password NOT LIKE '$2b$%'
  AND password NOT LIKE '$2y$%'
ORDER BY user_id;

-- 3c. Folders the QC queue will surface, and whether their paths are reachable
-- by the backend. folder_path is written by LWCAM as an absolute WINDOWS path,
-- and the backend opens it verbatim — so the backend must run somewhere that
-- can resolve these exact strings. If this returns Windows paths, do not run
-- the backend in a Linux container.
SELECT qc_status, count(*) AS folders, min(folder_path) AS sample_path
FROM public.capture_folders
WHERE is_deleted IS NOT TRUE
GROUP BY qc_status
ORDER BY qc_status;

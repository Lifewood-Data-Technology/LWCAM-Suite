-- 004_capture_folders_reviewed_by.sql
--
-- Adds capture_folders.qc_reviewed_by: the id of the reviewer who moved a
-- folder to PASS or REWORK. The dashboard's reviewer-workload aggregate needs
-- to answer "who reviewed this folder", and nothing else on the schema can:
--
--   - qc_locked_by is the CURRENT claimant, not a history. Both approve and
--     reject null it out on the same commit that sets qc_status, so by the
--     time a folder is PASS or REWORK the actor is already gone.
--   - rework_logs.assigned_uid is NOT the rejecting reviewer - app/routers/
--     qc.py sets it to folder.box.user_id, the capture operator who now owns
--     the fix. It answers "who must recapture", never "who rejected".
--   - The QC audit trail (app/services/qc_audit.py) records the acting user,
--     but to a per-day JSONL file keyed by display name, not a foreign key,
--     and write_qc_audit() swallows its own exceptions (best-effort by
--     design). Not a foundation to aggregate a dashboard number from, and not
--     backfilled from here either - a folder reviewed before this column
--     existed just has qc_reviewed_by NULL, permanently and honestly.
--
-- qc_status already distinguishes PASS from REWORK, so this is the one column
-- needed - not a second one recording which action fired.
--
--   psql -h <host> -U <user> -d lwcam -v ON_ERROR_STOP=1 -f 004_capture_folders_reviewed_by.sql
--
-- Idempotent - ADD COLUMN IF NOT EXISTS is a no-op on a database already
-- migrated. Additive only: one nullable column, no rewrite of existing rows,
-- nothing LWCAM/LWCamAdmin read or write, so it cannot affect the capture
-- apps. No ON DELETE behavior is set - users are soft-deleted (users.is_deleted)
-- everywhere else in this schema, so a real DELETE FROM users is not a case
-- this column needs to plan for.

BEGIN;

ALTER TABLE public.capture_folders
    ADD COLUMN IF NOT EXISTS qc_reviewed_by BIGINT NULL
        REFERENCES public.users(id) ON DELETE RESTRICT ON UPDATE CASCADE;

COMMIT;

-- Check: the column exists, is nullable, and points at users.id.
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'capture_folders'
  AND column_name = 'qc_reviewed_by';

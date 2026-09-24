-- 005_capture_folders_separated_from.sql
--
-- Adds capture_folders.separated_from_folder_id: which folder a child was
-- split OUT OF by Separation. Self-referencing, nullable, points at another
-- row in this same table.
--
-- Why this exists now: LWCAM's rework loop (rework_service.dart,
-- inputFileFor) is path arithmetic, not a database link. It takes a folder's
-- OUTPUT path (under 2.Batches), computes it relative to the output root,
-- and joins that onto the INPUT root (1.Images) to find the folder to
-- recapture. Separation creates children only in the OUTPUT tree - a child's
-- output path implies an input folder that was never created, because the
-- images it was split from all still live under the ORIGINAL folder's input
-- path. Rejecting a page in a separated child therefore computes a recapture
-- target that does not exist: best case LWCAM refuses, worst case it creates
-- a stray input folder that LWIP then processes as a brand-new capture,
-- producing a duplicate instead of reworking the child.
--
-- This column is the stop-gap that lets the QC engine refuse that rejection
-- outright (see routers/qc.py reject_task) rather than let it reach LWCAM.
-- It is also the same column the proper fix will need later: resolving
-- rework through the ORIGINATING folder instead of through path arithmetic.
-- Built as that permanent link, not a throwaway boolean flag.
--
--   psql -h <host> -U <user> -d lwcam -v ON_ERROR_STOP=1 -f 005_capture_folders_separated_from.sql
--
-- Idempotent - ADD COLUMN IF NOT EXISTS is a no-op on a database already
-- migrated. Additive only: one nullable column, no rewrite of existing rows,
-- nothing LWCAM/LWCamAdmin currently read or write, so it cannot affect the
-- capture apps. Folders separated before this column existed simply have it
-- NULL, permanently and honestly - same convention as 004's qc_reviewed_by,
-- and deliberately not backfilled (the parent each of those children was
-- split from is not reliably reconstructable after the fact).
--
-- ON DELETE/UPDATE follows 004's qc_reviewed_by convention exactly, for the
-- same reason: rows in this table are soft-deleted (capture_folders.is_deleted),
-- so a real DELETE FROM capture_folders reaching a row referenced here is not
-- a case this needs to plan for, and RESTRICT is what stops it from being one
-- by accident.

BEGIN;

ALTER TABLE public.capture_folders
    ADD COLUMN IF NOT EXISTS separated_from_folder_id BIGINT NULL
        REFERENCES public.capture_folders(id) ON DELETE RESTRICT ON UPDATE CASCADE;

COMMIT;

-- Check: the column exists, is nullable, and points at capture_folders.id.
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'capture_folders'
  AND column_name = 'separated_from_folder_id';

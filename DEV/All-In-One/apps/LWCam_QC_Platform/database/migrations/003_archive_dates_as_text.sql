-- 003_archive_dates_as_text.sql
--
-- capture_folders.start_date / end_date become TEXT, holding the archive date
-- exactly as the operator keyed it: "1914", "1914-06", "1877-Mar-05" - whatever
-- the project's records carry. FamilySearch takes the value verbatim.
--
-- They were timestamptz, and a timestamp cannot hold a partial date. Every
-- layer therefore faked one: "1914" was pinned to 1 January, "1914-06" to the
-- 1st, and readers guessed the precision back from day==1 (so a genuine
-- 1914-01-01 read as "1914"). The type also dragged in time zones: a folder
-- dated 1877 came back from psycopg in Asia/Kuala_Lumpur local mean time,
-- +06:55:25, an offset Pydantic refuses, and the Completed tab returned 400
-- (see DEV\2026-09-09-completed-tab-pre-1901-date-validation.md).
--
--   psql -h <host> -U <user> -d lwcam -v ON_ERROR_STOP=1 -f 003_archive_dates_as_text.sql
--
-- Idempotent: the DO block only alters a column that is still timestamptz.
-- Existing values are rendered with the same day==1 heuristic the apps already
-- displayed them with, so nothing an operator sees changes:
--   Jan 1  -> "YYYY"      1st of month -> "YYYY-MM"      else -> "YYYY-MM-DD"
-- Anything with a time-of-day component is not an archive date and is kept
-- whole as ISO-8601 rather than silently truncated.
--
-- projects.start_date is a different column (the project's own start) and is
-- deliberately NOT touched.

BEGIN;

DO $$
DECLARE
    col text;
BEGIN
    FOREACH col IN ARRAY ARRAY['start_date', 'end_date'] LOOP
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'public'
              AND table_name = 'capture_folders'
              AND column_name = col
              AND data_type <> 'text'
        ) THEN
            EXECUTE format($sql$
                ALTER TABLE public.capture_folders
                ALTER COLUMN %1$I TYPE text USING (
                    CASE
                        WHEN %1$I IS NULL THEN NULL
                        WHEN (%1$I AT TIME ZONE 'UTC')::time <> '00:00:00'
                            THEN to_char(%1$I AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                        WHEN extract(month FROM %1$I AT TIME ZONE 'UTC') = 1
                         AND extract(day   FROM %1$I AT TIME ZONE 'UTC') = 1
                            THEN to_char(%1$I AT TIME ZONE 'UTC', 'YYYY')
                        WHEN extract(day FROM %1$I AT TIME ZONE 'UTC') = 1
                            THEN to_char(%1$I AT TIME ZONE 'UTC', 'YYYY-MM')
                        ELSE to_char(%1$I AT TIME ZONE 'UTC', 'YYYY-MM-DD')
                    END
                )
            $sql$, col);
        END IF;
    END LOOP;
END
$$;

COMMIT;

-- Check: both columns must now be text.
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'capture_folders'
  AND column_name IN ('start_date', 'end_date')
ORDER BY column_name;

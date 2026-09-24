-- 002_role_case_normalization.sql
--
-- The QC backend used to write 'QC' and 'Admin' into the shared users.roles
-- column. LWCAM and LWCamAdmin parse that column with an exact lowercase match
-- (UserRole.fromJson), so those values read as "no role" in the capture apps and
-- were pushed back as an empty string, revoking the account. The backend now
-- writes 'qc'/'admin'; this brings existing rows into line.
--
--   psql -h <host> -U <user> -d lwcam -v ON_ERROR_STOP=1 -f 002_role_case_normalization.sql
--
-- Idempotent. Exact-match only: the QC platform only ever wrote a single role
-- per row, so there is no comma-list to pick apart, and nothing else in the
-- column can be touched by these two statements. Check 3 below reports anything
-- that did not fit that assumption instead of guessing at it.


BEGIN;

UPDATE public.users SET roles = 'qc'    WHERE roles = 'QC';
UPDATE public.users SET roles = 'admin' WHERE roles = 'Admin';

COMMIT;


-- ---------------------------------------------------------------------------
-- Checks (read-only)
-- ---------------------------------------------------------------------------

-- 1. Role distribution as the capture apps will now parse it.
SELECT roles, count(*) AS accounts
FROM public.users
WHERE is_deleted IS NOT TRUE
GROUP BY roles
ORDER BY roles;

-- 2. Accounts with no usable role at all. These can log into nothing — most
-- likely victims of the revoke described above, and they need their role set
-- again from LWCamAdmin (admin/capture/qc) or the QC admin UI (admin/qc).
SELECT id, user_id, roles
FROM public.users
WHERE is_deleted IS NOT TRUE
  AND btrim(COALESCE(roles, '')) = ''
ORDER BY user_id;

-- 3. Anything still carrying a capitalised managed role — i.e. a comma-list this
-- migration deliberately did not rewrite. Expect zero rows. If any appear, fix
-- them by hand: lowercase ONLY the 'qc'/'admin' tokens and leave the rest alone.
SELECT id, user_id, roles
FROM public.users
WHERE is_deleted IS NOT TRUE
  AND roles <> lower(roles)
  AND lower(roles) ~ '(^|,)\s*(qc|admin)\s*($|,)'
ORDER BY user_id;

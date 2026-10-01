-- 008_hardening.sql
--
-- Two SECURITY DEFINER functions, both with a fixed search_path (pg_catalog,
-- pg_temp) and every object schema-qualified, so nothing a login plants in
-- `public` (a function or operator of the same name) can hijack them:
--
--   public.lwcam_change_own_password(user, old password, new hash)
--       replaces the version 006 used to create (search_path public, pg_temp,
--       while lwcam_qc could CREATE in public: a planted regexp_replace ran as
--       the setup user). New hashes must be bcrypt cost 10-14 (what the Dart and
--       Python hashers write is 10), never plaintext or junk. pgcrypto's crypt()
--       is looked up in whatever schema the extension lives in.
--   public.lwcam_next_export_number(project id) -> bigint
--       makes lwcam_export_project_<id>_seq when missing (the exact definition
--       export.py used to run itself) and returns its nextval, so lwcam_qc no
--       longer needs CREATE on the schema or UPDATE on the sequences.
--
-- Also: lwcam_qc (an old per-part login) loses CREATE on schema public; export
-- sequences an older version let it create are handed back to the setup user;
-- the group role lwcam_app (006) gets EXECUTE on both functions and USAGE only
-- on the export sequences.
--
-- setup_qc_db.py runs this in the same transaction as 006 and 007.
--
--   psql -h <host> -U <user> -d <dbname> -v ON_ERROR_STOP=1 -f 008_hardening.sql

BEGIN;

SET LOCAL search_path = public;

CREATE EXTENSION IF NOT EXISTS pgcrypto SCHEMA public;

REVOKE CREATE ON SCHEMA public FROM PUBLIC;

DO $hardening$
DECLARE
    crypt_schema text;
    s record;
BEGIN
    -- pgcrypto may already live elsewhere (CREATE ... IF NOT EXISTS then leaves it).
    SELECT n.nspname INTO crypt_schema
      FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
     WHERE e.extname = 'pgcrypto';
    IF crypt_schema IS NULL THEN
        RAISE EXCEPTION 'pgcrypto is not installed';
    END IF;

    EXECUTE format($def$
        CREATE OR REPLACE FUNCTION public.lwcam_change_own_password(
            p_user_id text, p_old_password text, p_new_hash text
        ) RETURNS boolean
        LANGUAGE plpgsql
        SECURITY DEFINER
        SET search_path = pg_catalog, pg_temp
        AS $body$
        DECLARE
            changed integer;
        BEGIN
            -- Only a real bcrypt hash of cost 10-14 may be stored.
            IF p_new_hash IS NULL
               OR p_new_hash::text !~ '^\$2[aby]\$1[0-4]\$[./A-Za-z0-9]{53}$' THEN
                RETURN false;
            END IF;
            UPDATE public.users u
               SET password = p_new_hash::text, must_change_password = false
             WHERE u.user_id::text = p_user_id::text
               AND u.active AND NOT u.is_deleted
               AND %1$I.crypt(p_old_password::text,
                              pg_catalog.regexp_replace(u.password::text, '^\$2[by]\$'::text, '$2a$'::text))
                   = pg_catalog.regexp_replace(u.password::text, '^\$2[by]\$'::text, '$2a$'::text);
            GET DIAGNOSTICS changed = ROW_COUNT;
            RETURN changed = 1;
        END;
        $body$
    $def$, crypt_schema);

    -- Export numbers. The caller (export.py) holds an advisory lock around this.
    CREATE OR REPLACE FUNCTION public.lwcam_next_export_number(p_project_id bigint)
    RETURNS bigint
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, pg_temp
    AS $body$
    DECLARE
        seq_name text;
        next_number bigint;
    BEGIN
        IF p_project_id IS NULL OR p_project_id <= 0 THEN
            RAISE EXCEPTION 'project id must be a positive number';
        END IF;
        seq_name := pg_catalog.format('lwcam_export_project_%s_seq', p_project_id);
        EXECUTE pg_catalog.format(
            'CREATE SEQUENCE IF NOT EXISTS public.%I AS BIGINT START WITH 1 INCREMENT BY 1 MAXVALUE 999999 NO CYCLE',
            seq_name);
        EXECUTE pg_catalog.format('SELECT pg_catalog.nextval(%L::pg_catalog.regclass)', 'public.' || seq_name)
            INTO next_number;
        RETURN next_number;
    END;
    $body$;

    REVOKE ALL ON FUNCTION public.lwcam_change_own_password(text, text, text) FROM PUBLIC;
    REVOKE ALL ON FUNCTION public.lwcam_next_export_number(bigint) FROM PUBLIC;

    -- Every part signs in as a member of the group role 006 creates.
    GRANT EXECUTE ON FUNCTION public.lwcam_change_own_password(text, text, text) TO lwcam_app;
    GRANT EXECUTE ON FUNCTION public.lwcam_next_export_number(bigint) TO lwcam_app;

    -- A site set up with the per-part logins: lwcam_qc could once create in the
    -- schema, and sequences made that way are its own (an owner can setval).
    -- Hand them back to the setup user; nobody keeps CREATE.
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lwcam_qc') THEN
        REVOKE CREATE ON SCHEMA public FROM lwcam_qc;
    END IF;
    FOR s IN SELECT c.relname, pg_get_userbyid(c.relowner) AS owner FROM pg_class c
              WHERE c.relkind = 'S' AND c.relnamespace = 'public'::regnamespace
                AND c.relname LIKE 'lwcam\_export\_project\_%' LOOP
        IF s.owner IN ('lwcam_qc', 'lwcam_lwip', 'lwcam_upload', 'lwcam_capture', 'lwcam_admin', 'lwcam_app') THEN
            BEGIN
                EXECUTE format('ALTER SEQUENCE public.%I OWNER TO %I', s.relname, current_user);
            EXCEPTION WHEN insufficient_privilege THEN
                RAISE WARNING 'could not take ownership of %; run setup as a superuser', s.relname;
            END;
        END IF;
        EXECUTE format('REVOKE ALL ON SEQUENCE public.%I FROM lwcam_app', s.relname);
        EXECUTE format('GRANT USAGE ON SEQUENCE public.%I TO lwcam_app', s.relname);
    END LOOP;
END
$hardening$;

COMMIT;

-- Check: both functions exist, run as their owner, have a fixed search_path,
-- and the group role may run them.
SELECT p.proname, p.prosecdef AS security_definer, p.proconfig AS settings,
       has_function_privilege('lwcam_app', p.oid, 'EXECUTE') AS app_may_run
FROM pg_proc p
WHERE p.proname IN ('lwcam_change_own_password', 'lwcam_next_export_number')
  AND p.pronamespace = 'public'::regnamespace;

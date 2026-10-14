
-- ======================================================
-- GYM PRO SAAS
-- PHASE A - STEP A-F6.25
--
-- SECURE SESSION REVOCATION
--
-- Creates:
-- security.revoke_tenant_session(uuid, bytea)
--
-- Security:
-- - Requires matching session ID and token hash.
-- - Revokes only the matching active session.
-- - Returns boolean.
-- - Does not expose the stored token hash.
-- - Does not grant direct table access to gympro_auth.
-- - Does not enable session creation.
--
-- DEVELOPMENT DATABASE
-- ======================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

-- ------------------------------------------------------
-- 1. Verify the expected environment.
-- ------------------------------------------------------

DO $gympro$
BEGIN
    IF current_database() <> 'gympro_saas' THEN
        RAISE EXCEPTION
            'STOP: Wrong database';
    END IF;

    IF current_user <> 'postgres' THEN
        RAISE EXCEPTION
            'STOP: Run using postgres administrator';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = 'gympro_session_owner'
          AND rolcanlogin = false
          AND rolsuper = false
          AND rolbypassrls = false
    ) THEN
        RAISE EXCEPTION
            'STOP: Session function owner invalid';
    END IF;
END
$gympro$;

-- ------------------------------------------------------
-- 2. Grant function owner minimal update privileges.
--
-- Only revoked_at may be updated.
-- Required columns may be read for matching.
-- ------------------------------------------------------

GRANT SELECT (
    id,
    session_token_hash,
    revoked_at
)
ON security.tenant_sessions
TO gympro_session_owner;

GRANT UPDATE (
    revoked_at
)
ON security.tenant_sessions
TO gympro_session_owner;

-- ------------------------------------------------------
-- 3. Prevent accidentally replacing an existing
--    function with unreviewed behavior.
-- ------------------------------------------------------

DO $gympro$
BEGIN
    IF to_regprocedure(
        'security.revoke_tenant_session(uuid,bytea)'
    ) IS NOT NULL THEN
        RAISE EXCEPTION
            'STOP: Session revocation function already exists';
    END IF;
END
$gympro$;

-- ------------------------------------------------------
-- 4. Create the protected revocation function.
-- ------------------------------------------------------

CREATE FUNCTION security.revoke_tenant_session(
    p_session_id uuid,
    p_token_hash bytea
)
RETURNS boolean

LANGUAGE plpgsql

SECURITY DEFINER

SET search_path = pg_catalog, pg_temp

AS $function$
DECLARE
    v_revoked_id uuid;
BEGIN
    -- Invalid input must not revoke anything.

    IF p_session_id IS NULL
       OR p_token_hash IS NULL
       OR octet_length(p_token_hash) <> 32
    THEN
        RETURN false;
    END IF;

    -- Both session ID and token hash must match.
    -- An already-revoked session is not updated again.

    UPDATE security.tenant_sessions AS s
    SET revoked_at = CURRENT_TIMESTAMP
    WHERE s.id = p_session_id
      AND s.session_token_hash = p_token_hash
      AND s.revoked_at IS NULL
    RETURNING s.id INTO v_revoked_id;

    RETURN v_revoked_id IS NOT NULL;
END;
$function$;

-- ------------------------------------------------------
-- 5. Assign restricted function ownership.
-- ------------------------------------------------------

ALTER FUNCTION security.revoke_tenant_session(
    uuid, bytea
)
OWNER TO gympro_session_owner;

-- ------------------------------------------------------
-- 6. Restrict execution.
-- ------------------------------------------------------

REVOKE ALL
ON FUNCTION security.revoke_tenant_session(
    uuid, bytea
)
FROM PUBLIC;

GRANT EXECUTE
ON FUNCTION security.revoke_tenant_session(
    uuid, bytea
)
TO gympro_auth;

-- ------------------------------------------------------
-- 7. Verify role permissions.
-- ------------------------------------------------------

DO $gympro$
DECLARE
    v_function_owner text;
    v_security_definer boolean;
    v_function_settings text[];
BEGIN

    SELECT
        pg_catalog.pg_get_userbyid(p.proowner),
        p.prosecdef,
        p.proconfig
    INTO
        v_function_owner,
        v_security_definer,
        v_function_settings
    FROM pg_catalog.pg_proc AS p
    WHERE p.oid =
        'security.revoke_tenant_session(uuid,bytea)'
            ::pg_catalog.regprocedure;

    IF v_function_owner IS DISTINCT FROM
        'gympro_session_owner'
       OR v_security_definer IS DISTINCT FROM true
       OR NOT (
           'search_path=pg_catalog, pg_temp'
           = ANY(v_function_settings)
       )
    THEN
        RAISE EXCEPTION
            'FAIL: Session revocation function configuration';
    END IF;

    IF NOT pg_catalog.has_function_privilege(
        'gympro_auth',
        'security.revoke_tenant_session(uuid,bytea)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'FAIL: Auth role cannot revoke sessions';
    END IF;

    IF pg_catalog.has_function_privilege(
        'gympro_app',
        'security.revoke_tenant_session(uuid,bytea)',
        'EXECUTE'
    )
    OR pg_catalog.has_function_privilege(
        'gympro_session',
        'security.revoke_tenant_session(uuid,bytea)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'FAIL: Unauthorized role can revoke sessions';
    END IF;

    IF pg_catalog.has_table_privilege(
        'gympro_auth',
        'security.tenant_sessions',
        'UPDATE'
    ) THEN
        RAISE EXCEPTION
            'FAIL: Auth role has direct session UPDATE';
    END IF;

    RAISE NOTICE
        'PASS: Session revocation privileges verified';
END
$gympro$;

-- ------------------------------------------------------
-- 8. Negative tests with nonexistent session IDs.
--    These do not change any existing session.
-- ------------------------------------------------------

DO $gympro$
DECLARE
    v_result boolean;
BEGIN

    SELECT security.revoke_tenant_session(
        '00000000-0000-4000-8000-000000000001',
        decode(repeat('00', 32), 'hex')
    )
    INTO v_result;

    IF v_result IS DISTINCT FROM false THEN
        RAISE EXCEPTION
            'FAIL: Unknown session unexpectedly revoked';
    END IF;

    SELECT security.revoke_tenant_session(
        NULL,
        decode(repeat('00', 32), 'hex')
    )
    INTO v_result;

    IF v_result IS DISTINCT FROM false THEN
        RAISE EXCEPTION
            'FAIL: Null session ID accepted';
    END IF;

    SELECT security.revoke_tenant_session(
        '00000000-0000-4000-8000-000000000001',
        decode('0000', 'hex')
    )
    INTO v_result;

    IF v_result IS DISTINCT FROM false THEN
        RAISE EXCEPTION
            'FAIL: Invalid hash length accepted';
    END IF;

    RAISE NOTICE
        'PASS: Invalid revocation requests rejected';
END
$gympro$;

-- ------------------------------------------------------
-- 9. Commit after security verification.
-- ------------------------------------------------------

COMMIT;

-- ------------------------------------------------------
-- 10. Display final permissions.
-- ------------------------------------------------------

SELECT
    r.rolname AS role_name,

    pg_catalog.has_function_privilege(
        r.rolname,
        'security.revoke_tenant_session(uuid,bytea)',
        'EXECUTE'
    ) AS can_revoke,

    pg_catalog.has_table_privilege(
        r.rolname,
        'security.tenant_sessions',
        'UPDATE'
    ) AS direct_table_update

FROM pg_catalog.pg_roles AS r

WHERE r.rolname IN (
    'gympro_app',
    'gympro_auth',
    'gympro_session',
    'gympro_session_owner'
)

ORDER BY r.rolname;

SELECT
    'A-F6.25 SESSION REVOCATION FUNCTION CREATED'
        AS final_result;

-- ======================================================
-- END OF STEP A-F6.25
-- ======================================================


-- =====================================================
-- GYM PRO SAAS
-- PHASE A - STEP A-F6.21
--
-- CONTROLLED SESSION DATABASE ACTIVATION
-- DEVELOPMENT ENVIRONMENT ONLY
--
-- Grants:
--   gympro_session -> USAGE ON security
--   gympro_session -> EXECUTE create_tenant_session
--
-- Does NOT:
--   Enable NestJS session persistence policy
--   Grant direct session-table access
--   Change user or membership status
--   Create a session
-- =====================================================

\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

-- =====================================================
-- 1. Verify database and execution identity
-- =====================================================

DO $gympro$
BEGIN

    IF current_database() <> 'gympro_saas' THEN
        RAISE EXCEPTION
            'STOP: Wrong database';
    END IF;

    IF current_user <> 'postgres' THEN
        RAISE EXCEPTION
            'STOP: Run as postgres administrator';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = 'gympro_session'
          AND rolcanlogin = true
          AND rolsuper = false
    ) THEN
        RAISE EXCEPTION
            'STOP: Session role configuration invalid';
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

-- =====================================================
-- 2. Verify protected function configuration
-- =====================================================

DO $gympro$
DECLARE
    v_owner text;
    v_definer boolean;
    v_settings text[];
BEGIN

    SELECT
        pg_catalog.pg_get_userbyid(p.proowner),
        p.prosecdef,
        p.proconfig
    INTO
        v_owner,
        v_definer,
        v_settings
    FROM pg_catalog.pg_proc AS p
    WHERE p.oid =
        'security.create_tenant_session(uuid,bytea)'
            ::pg_catalog.regprocedure;

    IF v_owner IS DISTINCT FROM 'gympro_session_owner'
       OR v_definer IS DISTINCT FROM true
       OR NOT (
           'search_path=pg_catalog, pg_temp'
           = ANY(v_settings)
       )
    THEN
        RAISE EXCEPTION
            'STOP: Protected function configuration invalid';
    END IF;

    RAISE NOTICE
        'PASS: Protected function ownership verified';

END
$gympro$;

-- =====================================================
-- 3. Ensure PUBLIC cannot execute the function
-- =====================================================

REVOKE ALL
ON FUNCTION security.create_tenant_session(uuid, bytea)
FROM PUBLIC;

-- =====================================================
-- 4. Grant only required session privileges
-- =====================================================

GRANT USAGE
ON SCHEMA security
TO gympro_session;

GRANT EXECUTE
ON FUNCTION security.create_tenant_session(uuid, bytea)
TO gympro_session;

-- =====================================================
-- 5. Verify no direct table privileges
-- =====================================================

DO $gympro$
BEGIN

    IF NOT pg_catalog.has_schema_privilege(
        'gympro_session',
        'security',
        'USAGE'
    ) THEN
        RAISE EXCEPTION
            'FAIL: Missing security schema usage';
    END IF;

    IF NOT pg_catalog.has_function_privilege(
        'gympro_session',
        'security.create_tenant_session(uuid,bytea)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'FAIL: Missing session function execute';
    END IF;

    IF pg_catalog.has_table_privilege(
        'gympro_session',
        'security.tenant_sessions',
        'SELECT'
    )
    OR pg_catalog.has_table_privilege(
        'gympro_session',
        'security.tenant_sessions',
        'INSERT'
    )
    OR pg_catalog.has_table_privilege(
        'gympro_session',
        'security.tenant_sessions',
        'UPDATE'
    )
    OR pg_catalog.has_table_privilege(
        'gympro_session',
        'security.tenant_sessions',
        'DELETE'
    ) THEN
        RAISE EXCEPTION
            'FAIL: Direct session-table privileges detected';
    END IF;

    RAISE NOTICE
        'PASS: Session role has function-only access';

END
$gympro$;

-- =====================================================
-- 6. Verify other application roles remain denied
-- =====================================================

DO $gympro$
BEGIN

    IF pg_catalog.has_function_privilege(
        'gympro_app',
        'security.create_tenant_session(uuid,bytea)',
        'EXECUTE'
    )
    OR pg_catalog.has_function_privilege(
        'gympro_auth',
        'security.create_tenant_session(uuid,bytea)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'FAIL: Unauthorized role has session creation access';
    END IF;

    RAISE NOTICE
        'PASS: Other application roles remain denied';

END
$gympro$;

-- =====================================================
-- 7. Commit database permission activation
-- =====================================================

COMMIT;

-- =====================================================
-- 8. Display final permissions
-- =====================================================

SELECT
    r.rolname AS role_name,

    pg_catalog.has_schema_privilege(
        r.oid,
        'security',
        'USAGE'
    ) AS schema_usage,

    pg_catalog.has_function_privilege(
        r.oid,
        'security.create_tenant_session(uuid,bytea)',
        'EXECUTE'
    ) AS can_create_session,

    pg_catalog.has_table_privilege(
        r.oid,
        'security.tenant_sessions',
        'INSERT'
    ) AS direct_session_insert

FROM pg_catalog.pg_roles AS r

WHERE r.rolname IN (
    'gympro_app',
    'gympro_auth',
    'gympro_session',
    'gympro_session_owner'
)

ORDER BY r.rolname;

SELECT
    'A-F6.21 DATABASE PERMISSION ACTIVATION PASSED'
        AS final_result;

-- =====================================================
-- END OF STEP A-F6.21
-- =====================================================

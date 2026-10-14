
-- =====================================================
-- GYM PRO SAAS
-- PHASE A - STEP A-F6.3
-- SESSION DATABASE GRANT REHEARSAL
--
-- Runs privilege changes inside a transaction.
-- ALWAYS ROLLS BACK AT THE END.
--
-- Must run as an authorized database administrator.
-- =====================================================

\set ON_ERROR_STOP on

BEGIN;

-- 1. Verify correct database and existing role setup.

DO $gympro$
DECLARE
    v_function_oid oid;
    v_function_owner text;
    v_security_definer boolean;
    v_settings text[];
BEGIN
    IF current_database() <> 'gympro_saas' THEN
        RAISE EXCEPTION 'Wrong database';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = 'gympro_session'
          AND rolcanlogin = true
          AND rolsuper = false
    ) THEN
        RAISE EXCEPTION
            'Expected gympro_session role not found';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = 'gympro_session_owner'
          AND rolcanlogin = false
          AND rolsuper = false
    ) THEN
        RAISE EXCEPTION
            'Expected session function owner not found';
    END IF;

    SELECT
        p.oid,
        pg_catalog.pg_get_userbyid(p.proowner),
        p.prosecdef,
        p.proconfig
    INTO
        v_function_oid,
        v_function_owner,
        v_security_definer,
        v_settings
    FROM pg_catalog.pg_proc AS p
    WHERE p.oid =
        'security.create_tenant_session(uuid,bytea)'
            ::pg_catalog.regprocedure;

    IF v_function_owner <> 'gympro_session_owner'
       OR v_security_definer IS DISTINCT FROM true
       OR NOT (
           'search_path=pg_catalog, pg_temp'
           = ANY(v_settings)
       )
    THEN
        RAISE EXCEPTION
            'Session function security configuration invalid';
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
    THEN
        RAISE EXCEPTION
            'Session role has unexpected table privileges';
    END IF;

    RAISE NOTICE
        'PASS: Database identity and function ownership';
END
$gympro$;

-- 2. Simulate narrowly scoped session permissions.
-- Changes are transactional and will be rolled back.

REVOKE ALL ON FUNCTION
    security.create_tenant_session(uuid, bytea)
FROM PUBLIC;

GRANT USAGE
ON SCHEMA security
TO gympro_session;

GRANT EXECUTE
ON FUNCTION security.create_tenant_session(uuid, bytea)
TO gympro_session;

-- 3. Verify effective permissions during rehearsal.

DO $gympro$
BEGIN
    IF NOT pg_catalog.has_schema_privilege(
        'gympro_session',
        'security',
        'USAGE'
    ) THEN
        RAISE EXCEPTION
            'FAIL: Session schema access missing';
    END IF;

    IF NOT pg_catalog.has_function_privilege(
        'gympro_session',
        'security.create_tenant_session(uuid,bytea)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'FAIL: Session function execution missing';
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
    ) THEN
        RAISE EXCEPTION
            'FAIL: Session role has direct table access';
    END IF;

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
            'FAIL: Other application role can create sessions';
    END IF;

    RAISE NOTICE
        'PASS: Proposed function permissions verified';
END
$gympro$;

-- 4. Show rehearsal privilege state.

SELECT
    r.rolname AS role_name,
    pg_catalog.has_schema_privilege(
        r.rolname,
        'security',
        'USAGE'
    ) AS schema_usage,
    pg_catalog.has_function_privilege(
        r.rolname,
        'security.create_tenant_session(uuid,bytea)',
        'EXECUTE'
    ) AS function_execute
FROM pg_catalog.pg_roles AS r
WHERE r.rolname IN (
    'gympro_app',
    'gympro_auth',
    'gympro_session',
    'gympro_session_owner'
)
ORDER BY r.rolname;

-- 5. DO NOT COMMIT.
-- Restore all privileges to their previous state.

ROLLBACK;

-- 6. Verify rollback restored restricted permissions.

DO $gympro$
BEGIN
    IF pg_catalog.has_schema_privilege(
        'gympro_session',
        'security',
        'USAGE'
    )
    OR pg_catalog.has_function_privilege(
        'gympro_session',
        'security.create_tenant_session(uuid,bytea)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'FAIL: Session role permissions not restored';
    END IF;

    RAISE NOTICE
        'PASS: All simulated grants rolled back';
END
$gympro$;

SELECT
    CASE
        WHEN NOT pg_catalog.has_schema_privilege(
            'gympro_session',
            'security',
            'USAGE'
        )
        AND NOT pg_catalog.has_function_privilege(
            'gympro_session',
            'security.create_tenant_session(uuid,bytea)',
            'EXECUTE'
        )
        THEN 'A-F6.3 REHEARSAL PASSED'
        ELSE 'A-F6.3 REHEARSAL FAILED'
    END AS final_result;

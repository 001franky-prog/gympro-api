
-- =====================================================
-- GYM PRO SAAS
-- PHASE A - STEP A-F6.40.1
--
-- CORRECTED SESSION ROLE BOUNDARY AUDIT
--
-- READ ONLY
-- No session creation
-- No grants or revocations
-- No application activation
-- =====================================================

\set ON_ERROR_STOP on
\pset pager off

-- 1. Confirm environment.

SELECT
    current_database() AS database_name,
    current_user AS connected_role;

-- 2. Inspect function configuration.

SELECT
    p.oid::regprocedure AS function_name,
    owner.rolname AS function_owner,
    owner.rolcanlogin AS owner_can_login,
    p.prosecdef AS security_definer,
    p.proacl AS explicit_function_acl
FROM pg_catalog.pg_proc AS p
JOIN pg_catalog.pg_namespace AS n
    ON n.oid = p.pronamespace
JOIN pg_catalog.pg_roles AS owner
    ON owner.oid = p.proowner
WHERE p.oid = pg_catalog.to_regprocedure(
    'security.create_tenant_session(uuid,bytea)'
);

-- 3. Check effective Gym Pro role privileges.

SELECT
    r.rolname AS role_name,
    r.rolcanlogin AS can_login,
    r.rolsuper AS is_superuser,

    pg_catalog.has_schema_privilege(
        r.oid,
        'security',
        'USAGE'
    ) AS security_schema_usage,

    pg_catalog.has_function_privilege(
        r.oid,
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

-- 4. Correct PUBLIC privilege inspection.
--
-- PostgreSQL PUBLIC is represented by grantee = 0
-- in the function's ACL, not by a pg_roles entry.
-- COALESCE handles functions without explicit ACL.

SELECT
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM pg_catalog.pg_proc AS p
            CROSS JOIN LATERAL pg_catalog.aclexplode(
                COALESCE(
                    p.proacl,
                    pg_catalog.acldefault(
                        'f',
                        p.proowner
                    )
                )
            ) AS a
            WHERE p.oid =
                pg_catalog.to_regprocedure(
                    'security.create_tenant_session(uuid,bytea)'
                )
              AND a.grantee = 0
              AND a.privilege_type = 'EXECUTE'
        )
        THEN 'FAIL - PUBLIC CAN EXECUTE'
        ELSE 'PASS - PUBLIC EXECUTE DENIED'
    END AS public_privilege_check;

-- 5. Show all explicitly/effectively granted
-- EXECUTE permissions for this function.

SELECT
    CASE
        WHEN a.grantee = 0
        THEN 'PUBLIC'
        ELSE COALESCE(
            r.rolname,
            '(unknown role)'
        )
    END AS grantee,

    a.privilege_type,
    a.is_grantable

FROM pg_catalog.pg_proc AS p

CROSS JOIN LATERAL pg_catalog.aclexplode(
    COALESCE(
        p.proacl,
        pg_catalog.acldefault(
            'f',
            p.proowner
        )
    )
) AS a

LEFT JOIN pg_catalog.pg_roles AS r
    ON r.oid = a.grantee

WHERE p.oid =
    pg_catalog.to_regprocedure(
        'security.create_tenant_session(uuid,bytea)'
    )

ORDER BY grantee;

-- 6. Inspect indirect PostgreSQL role membership.

SELECT
    member.rolname AS member_role,
    parent.rolname AS granted_role,
    m.admin_option

FROM pg_catalog.pg_auth_members AS m

JOIN pg_catalog.pg_roles AS member
    ON member.oid = m.member

JOIN pg_catalog.pg_roles AS parent
    ON parent.oid = m.roleid

WHERE member.rolname LIKE 'gympro_%'
   OR parent.rolname LIKE 'gympro_%'

ORDER BY
    member.rolname,
    parent.rolname;

-- 7. Inspect login and administrative capabilities.

SELECT
    rolname AS role_name,
    rolcanlogin AS login_allowed,
    rolsuper AS superuser,
    rolcreatedb AS can_create_db,
    rolcreaterole AS can_create_roles,
    rolreplication AS replication_allowed

FROM pg_catalog.pg_roles

WHERE rolname IN (
    'gympro_app',
    'gympro_auth',
    'gympro_session',
    'gympro_session_owner'
)

ORDER BY rolname;

-- 8. Inspect PostgreSQL listening settings.
--
-- This does not verify operating-system firewall
-- policies or remote network reachability.

SELECT
    name,
    setting
FROM pg_catalog.pg_settings
WHERE name IN (
    'listen_addresses',
    'port',
    'ssl'
)
ORDER BY name;

-- 9. Final audit marker.

SELECT
    'A-F6.40.1 ROLE BOUNDARY AUDIT COMPLETED'
        AS final_result;

-- =====================================================
-- END OF CORRECTED SECURITY AUDIT
-- =====================================================

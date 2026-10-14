\set ON_ERROR_STOP on
\connect gympro_saas postgres
\pset pager off

-- Save the inspection results to a text file.
\o 'C:/Projects/gympro-api/b4-registration-security.txt'

SELECT
    current_database() AS database_name,
    current_user AS connected_user;

-- Existing Gym Pro database roles.
SELECT
    rolname AS role_name,
    rolcanlogin AS can_login,
    rolsuper AS is_superuser,
    rolbypassrls AS bypasses_rls,
    rolinherit AS inherits_privileges
FROM pg_roles
WHERE rolname LIKE 'gympro%'
ORDER BY rolname;

-- Role memberships.
SELECT
    parent.rolname AS granted_role,
    member.rolname AS member_role
FROM pg_auth_members AS m
JOIN pg_roles AS parent
    ON parent.oid = m.roleid
JOIN pg_roles AS member
    ON member.oid = m.member
WHERE parent.rolname LIKE 'gympro%'
   OR member.rolname LIKE 'gympro%'
ORDER BY parent.rolname, member.rolname;

-- Existing security-function signatures and ownership.
SELECT
    p.oid::regprocedure AS function_signature,
    pg_get_userbyid(p.proowner) AS function_owner,
    p.prosecdef AS security_definer,
    p.proconfig AS function_settings,
    p.proacl AS function_privileges
FROM pg_proc AS p
JOIN pg_namespace AS n
    ON n.oid = p.pronamespace
WHERE n.nspname = 'security'
  AND p.proname IN (
      'verify_tenant_session',
      'has_tenant_permission'
  )
ORDER BY p.proname, p.oid;

-- Full definitions to preserve the existing security contract.
SELECT
    pg_get_functiondef(p.oid) AS function_definition
FROM pg_proc AS p
JOIN pg_namespace AS n
    ON n.oid = p.pronamespace
WHERE n.nspname = 'security'
  AND p.proname IN (
      'verify_tenant_session',
      'has_tenant_permission'
  )
ORDER BY p.proname, p.oid;

-- Existing member and branch table privileges.
SELECT
    r.rolname AS role_name,
    n.nspname AS schema_name,
    c.relname AS table_name,
    has_table_privilege(r.oid, c.oid, 'SELECT') AS can_select,
    has_table_privilege(r.oid, c.oid, 'INSERT') AS can_insert,
    has_table_privilege(r.oid, c.oid, 'UPDATE') AS can_update,
    has_table_privilege(r.oid, c.oid, 'DELETE') AS can_delete
FROM pg_roles AS r
CROSS JOIN pg_class AS c
JOIN pg_namespace AS n
    ON n.oid = c.relnamespace
WHERE r.rolname LIKE 'gympro%'
  AND n.nspname = 'app'
  AND c.relname IN ('members', 'branches')
ORDER BY r.rolname, c.relname;

-- Existing RLS policies affecting registration.
SELECT
    schemaname,
    tablename,
    policyname,
    permissive,
    roles,
    cmd,
    qual,
    with_check
FROM pg_policies
WHERE schemaname = 'app'
  AND tablename IN ('members', 'branches')
ORDER BY tablename, policyname;

-- Existing member permission definitions.
SELECT
    permission_code,
    module_code,
    resource_code,
    action_code,
    is_active
FROM app.permissions
WHERE module_code = 'gym'
  AND resource_code = 'members'
ORDER BY permission_code;

\o
\echo Inspection saved to C:/Projects/gympro-api/b4-registration-security.txt
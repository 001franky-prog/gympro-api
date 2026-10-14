\set ON_ERROR_STOP on
\connect gympro_saas postgres
\pset pager off

BEGIN;

DO $$
BEGIN
    IF to_regprocedure(
        'security.register_member(bytea,uuid,uuid,text,text,text)'
    ) IS NULL THEN
        RAISE EXCEPTION 'Registration function is missing.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM app.roles) THEN
        RAISE EXCEPTION 'An existing role-code template is required.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM app.permissions
        WHERE permission_code = 'gym.members.create'
          AND is_active = true
    ) THEN
        RAISE EXCEPTION 'Active member-create permission is missing.';
    END IF;
END
$$;

-- Unique identifiers and synthetic session hashes for this test.
CREATE TEMP TABLE b4_test_context AS
SELECT
    gen_random_uuid() AS tenant_a,
    gen_random_uuid() AS tenant_b,
    gen_random_uuid() AS branch_a1,
    gen_random_uuid() AS branch_a2,
    gen_random_uuid() AS branch_b1,
    gen_random_uuid() AS user_admin,
    gen_random_uuid() AS user_branch,
    gen_random_uuid() AS user_denied,
    gen_random_uuid() AS membership_admin,
    gen_random_uuid() AS membership_branch,
    gen_random_uuid() AS membership_denied,
    gen_random_uuid() AS role_id,
    gen_random_uuid() AS session_admin,
    gen_random_uuid() AS session_branch,
    gen_random_uuid() AS session_denied,
    decode(replace(
        gen_random_uuid()::text || gen_random_uuid()::text,
        '-', ''
    ), 'hex') AS hash_admin,
    decode(replace(
        gen_random_uuid()::text || gen_random_uuid()::text,
        '-', ''
    ), 'hex') AS hash_branch,
    decode(replace(
        gen_random_uuid()::text || gen_random_uuid()::text,
        '-', ''
    ), 'hex') AS hash_denied,
    decode(replace(
        gen_random_uuid()::text || gen_random_uuid()::text,
        '-', ''
    ), 'hex') AS hash_unknown,
    ARRAY[]::uuid[] AS created_member_ids;

CREATE TEMP TABLE b4_test_results (
    test_name TEXT PRIMARY KEY,
    result TEXT NOT NULL
);

-- Temporary tenants.
INSERT INTO platform.tenants (
    id, tenant_code, tenant_name, status
)
SELECT
    x.id,
    'B4-' || left(replace(x.id::text, '-', ''), 24),
    x.name,
    'active'
FROM b4_test_context AS c
CROSS JOIN LATERAL (
    VALUES
        (c.tenant_a, 'B4 Verification Tenant A'),
        (c.tenant_b, 'B4 Verification Tenant B')
) AS x(id, name);

-- Temporary branches.
INSERT INTO app.branches (
    id, tenant_id, branch_code, branch_name, status
)
SELECT x.id, x.tenant_id, x.code, x.name, 'active'
FROM b4_test_context AS c
CROSS JOIN LATERAL (
    VALUES
        (c.branch_a1, c.tenant_a, 'B4-A1', 'B4 Branch A1'),
        (c.branch_a2, c.tenant_a, 'B4-A2', 'B4 Branch A2'),
        (c.branch_b1, c.tenant_b, 'B4-B1', 'B4 Branch B1')
) AS x(id, tenant_id, code, name);

-- Temporary active users.
INSERT INTO app.users (
    id, email, full_name, status
)
SELECT
    x.id,
    'b4-' || x.id::text || '@example.invalid',
    x.name,
    'active'
FROM b4_test_context AS c
CROSS JOIN LATERAL (
    VALUES
        (c.user_admin, 'B4 Tenant Registrar'),
        (c.user_branch, 'B4 Branch Registrar'),
        (c.user_denied, 'B4 User Without Permission')
) AS x(id, name);

INSERT INTO app.tenant_memberships (
    id, tenant_id, user_id, status, joined_at
)
SELECT x.id, c.tenant_a, x.user_id, 'active', CURRENT_TIMESTAMP
FROM b4_test_context AS c
CROSS JOIN LATERAL (
    VALUES
        (c.membership_admin, c.user_admin),
        (c.membership_branch, c.user_branch),
        (c.membership_denied, c.user_denied)
) AS x(id, user_id);

-- Reuse an accepted role-code format in a new test tenant.
INSERT INTO app.roles (
    id, tenant_id, role_code, role_name, is_system_role, status
)
SELECT
    c.role_id,
    c.tenant_a,
    template.role_code,
    'B4 Verification Registrar',
    false,
    'active'
FROM b4_test_context AS c
CROSS JOIN LATERAL (
    SELECT role_code
    FROM app.roles
    ORDER BY id
    LIMIT 1
) AS template;

-- Grant only the member-create permission to the test role.
INSERT INTO app.role_permissions (
    tenant_id, role_id, permission_id
)
SELECT c.tenant_a, c.role_id, p.id
FROM b4_test_context AS c
JOIN app.permissions AS p
    ON p.permission_code = 'gym.members.create'
   AND p.is_active = true;

-- One tenant-wide assignment and one branch-only assignment.
INSERT INTO app.role_assignments (
    tenant_id, membership_id, role_id, scope_type, branch_id
)
SELECT c.tenant_a, x.membership_id, c.role_id, x.scope_type, x.branch_id
FROM b4_test_context AS c
CROSS JOIN LATERAL (
    VALUES
        (c.membership_admin, 'tenant', NULL::uuid),
        (c.membership_branch, 'branch', c.branch_a1)
) AS x(membership_id, scope_type, branch_id);

-- Synthetic sessions for database-function testing.
INSERT INTO security.tenant_sessions (
    id, tenant_id, membership_id, session_token_hash, expires_at
)
SELECT
    x.id,
    c.tenant_a,
    x.membership_id,
    x.token_hash,
    CURRENT_TIMESTAMP + INTERVAL '8 hours'
FROM b4_test_context AS c
CROSS JOIN LATERAL (
    VALUES
        (c.session_admin, c.membership_admin, c.hash_admin),
        (c.session_branch, c.membership_branch, c.hash_branch),
        (c.session_denied, c.membership_denied, c.hash_denied)
) AS x(id, membership_id, token_hash);

DO $$
DECLARE
    c RECORD;
    created app.members%ROWTYPE;
    test_case RECORD;
    actual_state TEXT;
    passed TEXT[] := ARRAY[]::text[];
    created_ids UUID[] := ARRAY[]::uuid[];
BEGIN
    SELECT * INTO STRICT c FROM pg_temp.b4_test_context;

    -- Ensure the unknown hash does not match any stored session.
    WHILE EXISTS (
        SELECT 1 FROM security.tenant_sessions
        WHERE session_token_hash = c.hash_unknown
    ) LOOP
        c.hash_unknown := decode(replace(
            gen_random_uuid()::text || gen_random_uuid()::text,
            '-', ''
        ), 'hex');
    END LOOP;

    EXECUTE 'SET LOCAL ROLE gympro_app';

    IF current_user <> 'gympro_app' THEN
        RAISE EXCEPTION 'Tests are not running as gympro_app.';
    END IF;

    -- 01: Tenant-wide registration and normalization.
    SELECT * INTO STRICT created
    FROM security.register_member(
        c.hash_admin, c.tenant_a, NULL,
        '  B4 Tenant Test  ',
        '+959000000000',
        '  B4-TEST@EXAMPLE.INVALID  '
    );

    IF created.tenant_id <> c.tenant_a
       OR created.branch_id IS NOT NULL
       OR created.full_name <> 'B4 Tenant Test'
       OR created.email <> 'b4-test@example.invalid'
       OR created.status <> 'pending'
       OR created.member_number !~ '^GP-[0-9]{10}$'
       OR created.created_at IS NULL
       OR created.updated_at IS NULL THEN
        RAISE EXCEPTION 'Tenant registration defaults or normalization failed.';
    END IF;

    created_ids := array_append(created_ids, created.id);
    passed := array_append(passed, '01_tenant_registration_and_defaults');

    -- 02: Tenant-wide registrar can register at another tenant branch.
    SELECT * INTO STRICT created
    FROM security.register_member(
        c.hash_admin, c.tenant_a, c.branch_a2,
        'B4 Tenant Branch Test', '+959000000000', NULL
    );

    IF created.tenant_id <> c.tenant_a
       OR created.branch_id IS DISTINCT FROM c.branch_a2 THEN
        RAISE EXCEPTION 'Tenant-wide branch registration failed.';
    END IF;

    created_ids := array_append(created_ids, created.id);
    passed := array_append(passed, '02_tenant_wide_branch_registration');

    -- 03: Branch-only registrar can register at the assigned branch.
    SELECT * INTO STRICT created
    FROM security.register_member(
        c.hash_branch, c.tenant_a, c.branch_a1,
        'B4 Branch Test', '+959000000000', NULL
    );

    IF created.tenant_id <> c.tenant_a
       OR created.branch_id IS DISTINCT FROM c.branch_a1 THEN
        RAISE EXCEPTION 'Assigned-branch registration failed.';
    END IF;

    created_ids := array_append(created_ids, created.id);
    passed := array_append(passed, '03_assigned_branch_registration');

    -- 04-10: Requests that must be rejected.
    FOR test_case IN
        SELECT * FROM (
            VALUES
                ('04_wrong_tenant',
                 c.hash_admin, c.tenant_b, NULL::uuid, '42501'),

                ('05_other_tenant_branch',
                 c.hash_admin, c.tenant_a, c.branch_b1, '42501'),

                ('06_unassigned_branch',
                 c.hash_branch, c.tenant_a, c.branch_a2, '42501'),

                ('07_branch_role_without_branch',
                 c.hash_branch, c.tenant_a, NULL::uuid, '42501'),

                ('08_missing_permission',
                 c.hash_denied, c.tenant_a, NULL::uuid, '42501'),

                ('09_unknown_session',
                 c.hash_unknown, c.tenant_a, NULL::uuid, '28000'),

                ('10_missing_contact',
                 c.hash_admin, c.tenant_a, NULL::uuid, '22023')
        ) AS cases(test_name, token_hash, tenant_id, branch_id, expected_state)
    LOOP
        BEGIN
            PERFORM *
            FROM security.register_member(
                test_case.token_hash,
                test_case.tenant_id,
                test_case.branch_id,
                'B4 Rejected Request',
                CASE
                    WHEN test_case.test_name = '10_missing_contact'
                    THEN NULL::text
                    ELSE '+959000000000'
                END,
                NULL::text
            );

            RAISE EXCEPTION
                'Expected rejection for %, but registration was accepted.',
                test_case.test_name;
        EXCEPTION
            WHEN OTHERS THEN
                GET STACKED DIAGNOSTICS actual_state = RETURNED_SQLSTATE;
                IF actual_state <> test_case.expected_state THEN
                    RAISE;
                END IF;
        END;

        passed := array_append(passed, test_case.test_name);
    END LOOP;

    -- 11: Direct table reading must be denied.
    BEGIN
        PERFORM 1 FROM app.members LIMIT 1;
        RAISE EXCEPTION 'Direct member SELECT was allowed.';
    EXCEPTION
        WHEN insufficient_privilege THEN NULL;
    END;

    passed := array_append(passed, '11_direct_select_denied');

    -- 12: Direct table insertion must be denied.
    BEGIN
        INSERT INTO app.members (tenant_id, full_name, phone)
        VALUES (c.tenant_a, 'B4 Direct Insert Test', '+959000000000');

        RAISE EXCEPTION 'Direct member INSERT was allowed.';
    EXCEPTION
        WHEN insufficient_privilege THEN NULL;
    END;

    passed := array_append(passed, '12_direct_insert_denied');

    -- 13-14: Revoke and expire only the synthetic admin session.
    FOR test_case IN
        SELECT * FROM (
            VALUES
                ('13_revoked_session', true),
                ('14_expired_session', false)
        ) AS cases(test_name, revoke_session)
    LOOP
        EXECUTE 'RESET ROLE';

        IF test_case.revoke_session THEN
            UPDATE security.tenant_sessions
            SET revoked_at = CURRENT_TIMESTAMP
            WHERE id = c.session_admin;
        ELSE
            UPDATE security.tenant_sessions
            SET revoked_at = NULL,
                created_at = CURRENT_TIMESTAMP - INTERVAL '9 hours',
                expires_at = CURRENT_TIMESTAMP - INTERVAL '1 hour'
            WHERE id = c.session_admin;
        END IF;

        EXECUTE 'SET LOCAL ROLE gympro_app';

        BEGIN
            PERFORM *
            FROM security.register_member(
                c.hash_admin, c.tenant_a, NULL,
                'B4 Rejected Session Test', '+959000000000', NULL
            );

            RAISE EXCEPTION
                'Expected rejection for %, but registration was accepted.',
                test_case.test_name;
        EXCEPTION
            WHEN SQLSTATE '28000' THEN NULL;
        END;

        passed := array_append(passed, test_case.test_name);
    END LOOP;

    EXECUTE 'RESET ROLE';

    UPDATE pg_temp.b4_test_context
    SET created_member_ids = created_ids;

    INSERT INTO pg_temp.b4_test_results (test_name, result)
    SELECT test_name, 'PASS'
    FROM unnest(passed) AS names(test_name);

EXCEPTION
    WHEN OTHERS THEN
        EXECUTE 'RESET ROLE';
        RAISE;
END
$$;

-- Save identifiers for the post-rollback cleanup check.
SELECT
    ARRAY[tenant_a, tenant_b] AS tenant_ids,
    ARRAY[user_admin, user_branch, user_denied] AS user_ids,
    ARRAY[session_admin, session_branch, session_denied] AS session_ids,
    created_member_ids AS member_ids
FROM b4_test_context
\gset b4_

SELECT test_name, result
FROM b4_test_results
ORDER BY test_name;

ROLLBACK;

-- Every fixture row must have disappeared.
SELECT
    (SELECT COUNT(*) FROM platform.tenants
     WHERE id = ANY(:'b4_tenant_ids'::uuid[]))
    +
    (SELECT COUNT(*) FROM app.branches
     WHERE tenant_id = ANY(:'b4_tenant_ids'::uuid[]))
    +
    (SELECT COUNT(*) FROM app.users
     WHERE id = ANY(:'b4_user_ids'::uuid[]))
    +
    (SELECT COUNT(*) FROM app.tenant_memberships
     WHERE tenant_id = ANY(:'b4_tenant_ids'::uuid[]))
    +
    (SELECT COUNT(*) FROM app.roles
     WHERE tenant_id = ANY(:'b4_tenant_ids'::uuid[]))
    +
    (SELECT COUNT(*) FROM app.role_permissions
     WHERE tenant_id = ANY(:'b4_tenant_ids'::uuid[]))
    +
    (SELECT COUNT(*) FROM app.role_assignments
     WHERE tenant_id = ANY(:'b4_tenant_ids'::uuid[]))
    +
    (SELECT COUNT(*) FROM security.tenant_sessions
     WHERE id = ANY(:'b4_session_ids'::uuid[]))
    +
    (SELECT COUNT(*) FROM app.members
     WHERE tenant_id = ANY(:'b4_tenant_ids'::uuid[])
        OR id = ANY(:'b4_member_ids'::uuid[]))
    AS remaining_fixture_rows;
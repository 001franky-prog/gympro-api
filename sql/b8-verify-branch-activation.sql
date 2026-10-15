\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

CREATE TEMP TABLE b8_context AS
SELECT
    gen_random_uuid() AS user_id,
    gen_random_uuid() AS membership_id,
    gen_random_uuid() AS role_id,
    gen_random_uuid() AS session_id,
    gen_random_uuid() AS admin_session_id,
    gen_random_uuid() AS branch_id,
    gen_random_uuid() AS other_branch_id,
    gen_random_uuid() AS member_id,
    gen_random_uuid() AS other_member_id,
    gen_random_uuid() AS tenant_member_id,
    decode(md5(gen_random_uuid()::text) ||
           md5(gen_random_uuid()::text), 'hex') AS token_hash,
    decode(md5(gen_random_uuid()::text) ||
           md5(gen_random_uuid()::text), 'hex') AS admin_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid AS tenant_id,
    '838d86b2-9665-414d-865a-8f5fb559e39c'::uuid AS plan_id,
    'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid AS price_id;

CREATE TEMP TABLE b8_results (
    test_name text PRIMARY KEY,
    result text NOT NULL
);

INSERT INTO app.users(id, email, full_name, status)
SELECT user_id, user_id::text || '@example.invalid',
       'B8 branch staff fixture', 'active'
FROM b8_context;

INSERT INTO app.tenant_memberships (
    id, tenant_id, user_id, status, joined_at
)
SELECT membership_id, tenant_id, user_id, 'active', CURRENT_TIMESTAMP
FROM b8_context;

INSERT INTO app.branches (
    id, tenant_id, branch_code, branch_name, status
)
SELECT f.id, c.tenant_id,
       'B8_' || left(upper(replace(f.id::text, '-', '')), 16),
       'B8 branch fixture', 'active'
FROM b8_context c
CROSS JOIN LATERAL (
    VALUES (c.branch_id), (c.other_branch_id)
) f(id);

INSERT INTO app.roles (
    id, tenant_id, role_code, role_name, is_system_role, status
)
SELECT role_id, tenant_id,
       'B8_' || left(upper(replace(role_id::text, '-', '')), 16),
       'B8 branch-only fixture role', false, 'active'
FROM b8_context;

INSERT INTO app.role_permissions (
    tenant_id, role_id, permission_id
)
SELECT c.tenant_id, c.role_id, p.id
FROM b8_context c
JOIN app.permissions p
    ON p.permission_code = 'gym.memberships.manage'
   AND p.is_active;

INSERT INTO app.role_assignments (
    tenant_id, membership_id, role_id, scope_type, branch_id
)
SELECT tenant_id, membership_id, role_id, 'branch', branch_id
FROM b8_context;

INSERT INTO security.tenant_sessions (
    id, tenant_id, membership_id, session_token_hash, expires_at
)
SELECT session_id, tenant_id, membership_id,
       token_hash, CURRENT_TIMESTAMP + interval '30 minutes'
FROM b8_context
UNION ALL
SELECT admin_session_id, tenant_id,
       '3b318e89-f3bc-4ac5-a04d-09fdb3d626de'::uuid,
       admin_hash, CURRENT_TIMESTAMP + interval '30 minutes'
FROM b8_context;

INSERT INTO app.members (
    id, tenant_id, branch_id, full_name, email
)
SELECT f.id, c.tenant_id, f.branch_id,
       'B8 member fixture', f.id::text || '@example.invalid'
FROM b8_context c
CROSS JOIN LATERAL (
    VALUES
        (c.member_id, c.branch_id),
        (c.other_member_id, c.other_branch_id),
        (c.tenant_member_id, NULL::uuid)
) f(id, branch_id);

DO $$
DECLARE
    v record;
BEGIN
    SELECT * INTO v FROM b8_context;

    IF security.has_tenant_permission(
        v.tenant_id, v.membership_id,
        'gym.memberships.manage', NULL
    ) IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'Branch role unexpectedly has tenant-wide access.';
    END IF;
    INSERT INTO b8_results VALUES ('01_branch_role_has_no_tenant_scope', 'PASS');

    IF security.has_tenant_permission(
        v.tenant_id, v.membership_id,
        'gym.memberships.manage', v.branch_id
    ) IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Assigned branch permission is missing.';
    END IF;
    INSERT INTO b8_results VALUES ('02_assigned_branch_permission', 'PASS');

    IF security.has_tenant_permission(
        v.tenant_id, v.membership_id,
        'gym.memberships.manage', v.other_branch_id
    ) IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'Unassigned branch permission unexpectedly allowed.';
    END IF;
    INSERT INTO b8_results VALUES ('03_unassigned_branch_permission_denied', 'PASS');
END;
$$;

GRANT SELECT ON b8_context TO gympro_app;
GRANT SELECT, INSERT ON b8_results TO gympro_app;

SET LOCAL ROLE gympro_app;

DO $$
DECLARE
    v record;
    v_case record;
    v_state text;
    v_subscription record;
BEGIN
    SELECT * INTO v FROM pg_temp.b8_context;

    FOR v_case IN
        SELECT *
        FROM (VALUES
            ('04_unknown_session', 'session', '28000'),
            ('05_wrong_tenant', 'tenant', '42501'),
            ('06_missing_branch', 'null_branch', '42501'),
            ('07_unassigned_branch', 'unassigned', '42501'),
            ('08_member_route_branch_mismatch', 'mismatch', '42501'),
            ('09_tenant_member_on_branch_route', 'tenant_member', '42501'),
            ('10_admin_cannot_use_wrong_branch_route', 'admin_mismatch', '42501')
        ) cases(test_name, kind, expected_state)
    LOOP
        v_state := NULL;
        BEGIN
            PERFORM * FROM security.activate_branch_member_subscription(
                CASE WHEN v_case.kind = 'session'
                     THEN decode(repeat('00', 32), 'hex')
                     WHEN v_case.kind = 'admin_mismatch' THEN v.admin_hash
                     ELSE v.token_hash END,
                CASE WHEN v_case.kind = 'tenant'
                     THEN 'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc'::uuid
                     ELSE v.tenant_id END,
                CASE WHEN v_case.kind = 'null_branch' THEN NULL
                     WHEN v_case.kind IN ('unassigned', 'admin_mismatch')
                     THEN v.other_branch_id ELSE v.branch_id END,
                CASE WHEN v_case.kind IN ('unassigned', 'mismatch')
                     THEN v.other_member_id
                     WHEN v_case.kind = 'tenant_member' THEN v.tenant_member_id
                     ELSE v.member_id END,
                v.plan_id, v.price_id
            );
        EXCEPTION
            WHEN OTHERS THEN
                GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
        END;

        IF v_state IS DISTINCT FROM v_case.expected_state THEN
            RAISE EXCEPTION 'Test %: expected %, received %',
                v_case.test_name, v_case.expected_state, v_state;
        END IF;

        INSERT INTO pg_temp.b8_results
        VALUES (v_case.test_name, 'PASS');
    END LOOP;

    SELECT * INTO STRICT v_subscription
    FROM security.activate_branch_member_subscription(
        v.token_hash, v.tenant_id, v.branch_id,
        v.member_id, v.plan_id, v.price_id
    );

    IF v_subscription.tenant_id <> v.tenant_id
       OR v_subscription.member_id <> v.member_id
       OR v_subscription.branch_id <> v.branch_id
       OR v_subscription.status <> 'active'
       OR v_subscription.agreed_price_amount <> 50000 THEN
        RAISE EXCEPTION 'Branch activation result mismatch.';
    END IF;

    INSERT INTO pg_temp.b8_results
    VALUES ('11_branch_only_staff_activation', 'PASS');
END;
$$;

RESET ROLE;

DO $$
DECLARE
    v record;
BEGIN
    SELECT * INTO v FROM b8_context;

    IF (
        SELECT count(*) FROM app.member_subscriptions
        WHERE member_id IN (
            v.member_id, v.other_member_id, v.tenant_member_id
        )
    ) <> 1 OR EXISTS (
        SELECT 1 FROM app.members
        WHERE id IN (v.other_member_id, v.tenant_member_id)
          AND status <> 'pending'
    ) THEN
        RAISE EXCEPTION 'Rejected branch requests changed other members.';
    END IF;

    INSERT INTO b8_results
    VALUES ('12_rejections_saved_no_other_subscriptions', 'PASS');
END;
$$;

UPDATE app.branches
SET status = 'inactive'
WHERE id = (SELECT branch_id FROM b8_context);

SET LOCAL ROLE gympro_app;

DO $$
DECLARE
    v record;
    v_state text;
BEGIN
    SELECT * INTO v FROM pg_temp.b8_context;

    BEGIN
        PERFORM * FROM security.activate_branch_member_subscription(
            v.token_hash, v.tenant_id, v.branch_id,
            v.member_id, v.plan_id, v.price_id
        );
    EXCEPTION
        WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    END;

    IF v_state IS DISTINCT FROM '42501' THEN
        RAISE EXCEPTION 'Inactive branch was not denied.';
    END IF;

    INSERT INTO pg_temp.b8_results
    VALUES ('13_inactive_branch_denied', 'PASS');
END;
$$;

RESET ROLE;

UPDATE security.tenant_sessions
SET revoked_at = statement_timestamp()
WHERE id = (SELECT session_id FROM b8_context);

SET LOCAL ROLE gympro_app;

DO $$
DECLARE
    v record;
    v_state text;
BEGIN
    SELECT * INTO v FROM pg_temp.b8_context;

    BEGIN
        PERFORM * FROM security.activate_branch_member_subscription(
            v.token_hash, v.tenant_id, v.branch_id,
            v.member_id, v.plan_id, v.price_id
        );
    EXCEPTION
        WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    END;

    IF v_state IS DISTINCT FROM '28000' THEN
        RAISE EXCEPTION 'Revoked session was not denied.';
    END IF;

    INSERT INTO pg_temp.b8_results
    VALUES ('14_revoked_session_denied', 'PASS');
END;
$$;

RESET ROLE;

SELECT test_name, result FROM b8_results ORDER BY test_name;

SELECT
    user_id::text AS user_id,
    membership_id::text AS membership_id,
    role_id::text AS role_id,
    session_id::text AS session_id,
    admin_session_id::text AS admin_session_id,
    branch_id::text AS branch_id,
    other_branch_id::text AS other_branch_id,
    member_id::text AS member_id,
    other_member_id::text AS other_member_id,
    tenant_member_id::text AS tenant_member_id
FROM b8_context
\gset b8_

ROLLBACK;

SELECT 'branch_activation_fixture_rollback' AS test_name,
    CASE WHEN
        NOT EXISTS (
            SELECT 1 FROM app.users WHERE id = :'b8_user_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.tenant_memberships
            WHERE id = :'b8_membership_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.roles WHERE id = :'b8_role_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM security.tenant_sessions
            WHERE id IN (
                :'b8_session_id'::uuid, :'b8_admin_session_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.branches
            WHERE id IN (
                :'b8_branch_id'::uuid, :'b8_other_branch_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.members
            WHERE id IN (
                :'b8_member_id'::uuid,
                :'b8_other_member_id'::uuid,
                :'b8_tenant_member_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.member_subscriptions
            WHERE member_id = :'b8_member_id'::uuid
        )
    THEN 'PASS' ELSE 'FAIL' END AS result;
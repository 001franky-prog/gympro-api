\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

CREATE TEMP TABLE b8r_context AS
SELECT
    gen_random_uuid() AS user_id,
    gen_random_uuid() AS membership_id,
    gen_random_uuid() AS role_id,
    gen_random_uuid() AS session_id,
    gen_random_uuid() AS branch_id,
    gen_random_uuid() AS other_branch_id,
    gen_random_uuid() AS member_id,
    gen_random_uuid() AS other_member_id,
    gen_random_uuid() AS subscription_id,
    gen_random_uuid() AS other_subscription_id,
    gen_random_uuid() AS request_id,
    decode(md5(gen_random_uuid()::text) ||
           md5(gen_random_uuid()::text), 'hex') AS token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid AS tenant_id,
    '838d86b2-9665-414d-865a-8f5fb559e39c'::uuid AS plan_id,
    'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid AS price_id,
    (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Yangon')::date AS today;

CREATE TEMP TABLE b8r_results (
    test_name text PRIMARY KEY,
    result text NOT NULL
);

INSERT INTO app.users(id, email, full_name, status)
SELECT user_id, user_id::text || '@example.invalid',
       'B8 renewal staff fixture', 'active'
FROM b8r_context;

INSERT INTO app.tenant_memberships (
    id, tenant_id, user_id, status, joined_at
)
SELECT membership_id, tenant_id, user_id, 'active', CURRENT_TIMESTAMP
FROM b8r_context;

INSERT INTO app.branches (
    id, tenant_id, branch_code, branch_name, status
)
SELECT f.id, c.tenant_id,
       'B8R_' || left(upper(replace(f.id::text, '-', '')), 16),
       'B8 renewal branch fixture', 'active'
FROM b8r_context c
CROSS JOIN LATERAL (
    VALUES (c.branch_id), (c.other_branch_id)
) f(id);

INSERT INTO app.roles (
    id, tenant_id, role_code, role_name, is_system_role, status
)
SELECT role_id, tenant_id,
       'B8R_' || left(upper(replace(role_id::text, '-', '')), 16),
       'B8 renewal branch-only role', false, 'active'
FROM b8r_context;

INSERT INTO app.role_permissions (
    tenant_id, role_id, permission_id
)
SELECT c.tenant_id, c.role_id, p.id
FROM b8r_context c
JOIN app.permissions p
    ON p.permission_code = 'gym.memberships.manage'
   AND p.is_active;

INSERT INTO app.role_assignments (
    tenant_id, membership_id, role_id, scope_type, branch_id
)
SELECT tenant_id, membership_id, role_id, 'branch', branch_id
FROM b8r_context;

INSERT INTO security.tenant_sessions (
    id, tenant_id, membership_id, session_token_hash, expires_at
)
SELECT session_id, tenant_id, membership_id,
       token_hash, CURRENT_TIMESTAMP + interval '30 minutes'
FROM b8r_context;

INSERT INTO app.members (
    id, tenant_id, branch_id, full_name, email, status
)
SELECT f.id, c.tenant_id, f.branch_id,
       'B8 renewal member fixture', f.id::text || '@example.invalid',
       'active'
FROM b8r_context c
CROSS JOIN LATERAL (
    VALUES
        (c.member_id, c.branch_id),
        (c.other_member_id, c.other_branch_id)
) f(id, branch_id);

INSERT INTO app.member_subscriptions (
    id, tenant_id, member_id, branch_id, plan_id, plan_price_id,
    duration_value, duration_unit, agreed_price_amount, currency_code,
    status, starts_on, ends_on, activated_at
)
SELECT f.id, c.tenant_id, f.member_id, f.branch_id,
       c.plan_id, c.price_id, 1, 'months', 50000, 'MMK',
       'active', c.today, (c.today + interval '1 month')::date,
       statement_timestamp()
FROM b8r_context c
CROSS JOIN LATERAL (
    VALUES
        (c.subscription_id, c.member_id, c.branch_id),
        (c.other_subscription_id, c.other_member_id, c.other_branch_id)
) f(id, member_id, branch_id);

-- Administrative inspection stays under postgres.
DO $$
DECLARE
    v record;
BEGIN
    SELECT * INTO v FROM b8r_context;

    IF security.has_tenant_permission(
        v.tenant_id, v.membership_id,
        'gym.memberships.manage', NULL
    ) IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'Branch staff unexpectedly has tenant-wide access.';
    END IF;

    IF security.has_tenant_permission(
        v.tenant_id, v.membership_id,
        'gym.memberships.manage', v.branch_id
    ) IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Assigned branch permission is missing.';
    END IF;

    INSERT INTO b8r_results
    VALUES ('01_branch_staff_has_no_tenant_scope', 'PASS');
END;
$$;

GRANT SELECT ON b8r_context TO gympro_app;
GRANT SELECT, INSERT ON b8r_results TO gympro_app;

-- Purchase calls are tested as the restricted runtime role.
SET LOCAL ROLE gympro_app;

DO $$
DECLARE
    v record;
    v_case record;
    v_state text;
    v_receipt record;
    v_retry record;
BEGIN
    SELECT * INTO v FROM pg_temp.b8r_context;

    FOR v_case IN
        SELECT *
        FROM (VALUES
            ('02_unknown_session', 'session', '28000'),
            ('03_wrong_tenant', 'tenant', '42501'),
            ('04_missing_branch', 'branch_null', '42501'),
            ('05_unassigned_branch', 'unassigned', '42501'),
            ('06_subscription_route_mismatch', 'mismatch', '42501'),
            ('07_missing_request', 'request_null', '22023')
        ) cases(test_name, kind, expected_state)
    LOOP
        v_state := NULL;

        BEGIN
            PERFORM * FROM security.renew_branch_member_subscription(
                CASE WHEN v_case.kind = 'session'
                     THEN decode(repeat('00', 32), 'hex')
                     ELSE v.token_hash END,
                CASE WHEN v_case.kind = 'tenant'
                     THEN 'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc'::uuid
                     ELSE v.tenant_id END,
                CASE WHEN v_case.kind = 'branch_null' THEN NULL
                     WHEN v_case.kind = 'unassigned' THEN v.other_branch_id
                     ELSE v.branch_id END,
                CASE WHEN v_case.kind IN ('unassigned', 'mismatch')
                     THEN v.other_subscription_id
                     ELSE v.subscription_id END,
                v.price_id,
                CASE WHEN v_case.kind = 'request_null'
                     THEN NULL ELSE gen_random_uuid() END
            );
        EXCEPTION
            WHEN OTHERS THEN
                GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
        END;

        IF v_state IS DISTINCT FROM v_case.expected_state THEN
            RAISE EXCEPTION 'Test %: expected %, received %',
                v_case.test_name, v_case.expected_state, v_state;
        END IF;

        INSERT INTO pg_temp.b8r_results
        VALUES (v_case.test_name, 'PASS');
    END LOOP;

    SELECT * INTO STRICT v_receipt
    FROM security.renew_branch_member_subscription(
        v.token_hash, v.tenant_id, v.branch_id,
        v.subscription_id, v.price_id, v.request_id
    );

    IF v_receipt.subscription_id <> v.subscription_id
       OR v_receipt.request_id <> v.request_id
       OR v_receipt.agreed_price_amount <> 50000
       OR v_receipt.previous_ends_on <>
            (v.today + interval '1 month')::date
       OR v_receipt.renewal_starts_on <> v_receipt.previous_ends_on
       OR v_receipt.renewal_ends_on <>
            (v_receipt.renewal_starts_on + interval '1 month')::date THEN
        RAISE EXCEPTION 'Branch renewal receipt or coverage mismatch.';
    END IF;

    INSERT INTO pg_temp.b8r_results
    VALUES ('08_branch_only_staff_renewal', 'PASS');

    SELECT * INTO STRICT v_retry
    FROM security.renew_branch_member_subscription(
        v.token_hash, v.tenant_id, v.branch_id,
        v.subscription_id, v.price_id, v.request_id
    );

    IF to_jsonb(v_retry) IS DISTINCT FROM to_jsonb(v_receipt) THEN
        RAISE EXCEPTION 'Retry changed the original receipt.';
    END IF;

    INSERT INTO pg_temp.b8r_results
    VALUES ('09_retry_returns_original_receipt', 'PASS');
END;
$$;

RESET ROLE;

DO $$
DECLARE
    v record;
BEGIN
    SELECT * INTO v FROM b8r_context;

    IF (
        SELECT count(*) FROM app.subscription_renewals
        WHERE subscription_id IN (
            v.subscription_id, v.other_subscription_id
        )
    ) <> 1 OR NOT EXISTS (
        SELECT 1
        FROM app.member_subscriptions s
        JOIN app.subscription_renewals r
          ON r.tenant_id = s.tenant_id AND r.subscription_id = s.id
        WHERE s.id = v.subscription_id
          AND s.ends_on = r.renewal_ends_on
          AND r.request_id = v.request_id
    ) OR NOT EXISTS (
        SELECT 1 FROM app.member_subscriptions
        WHERE id = v.other_subscription_id
          AND ends_on = (v.today + interval '1 month')::date
          AND agreed_price_amount = 50000
    ) THEN
        RAISE EXCEPTION 'Retry or rejected requests changed purchase state.';
    END IF;

    INSERT INTO b8r_results
    VALUES ('10_saved_once_and_other_branch_unchanged', 'PASS');
END;
$$;

UPDATE security.tenant_sessions
SET revoked_at = statement_timestamp()
WHERE id = (SELECT session_id FROM b8r_context);

SET LOCAL ROLE gympro_app;

DO $$
DECLARE
    v record;
    v_state text;
BEGIN
    SELECT * INTO v FROM pg_temp.b8r_context;

    BEGIN
        PERFORM * FROM security.renew_branch_member_subscription(
            v.token_hash, v.tenant_id, v.branch_id,
            v.subscription_id, v.price_id, v.request_id
        );
    EXCEPTION
        WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    END;

    IF v_state IS DISTINCT FROM '28000' THEN
        RAISE EXCEPTION 'Revoked session renewal was not rejected.';
    END IF;

    INSERT INTO pg_temp.b8r_results
    VALUES ('11_revoked_session_retry_rejected', 'PASS');
END;
$$;

RESET ROLE;

SELECT test_name, result FROM b8r_results ORDER BY test_name;

SELECT
    user_id::text AS user_id,
    membership_id::text AS membership_id,
    role_id::text AS role_id,
    session_id::text AS session_id,
    branch_id::text AS branch_id,
    other_branch_id::text AS other_branch_id,
    member_id::text AS member_id,
    other_member_id::text AS other_member_id,
    subscription_id::text AS subscription_id,
    other_subscription_id::text AS other_subscription_id
FROM b8r_context
\gset b8r_

ROLLBACK;

SELECT 'branch_renewal_fixture_rollback' AS test_name,
    CASE WHEN
        NOT EXISTS (
            SELECT 1 FROM app.users WHERE id = :'b8r_user_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.tenant_memberships
            WHERE id = :'b8r_membership_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.roles WHERE id = :'b8r_role_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM security.tenant_sessions
            WHERE id = :'b8r_session_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.branches
            WHERE id IN (
                :'b8r_branch_id'::uuid, :'b8r_other_branch_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.members
            WHERE id IN (
                :'b8r_member_id'::uuid, :'b8r_other_member_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.member_subscriptions
            WHERE id IN (
                :'b8r_subscription_id'::uuid,
                :'b8r_other_subscription_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.subscription_renewals
            WHERE subscription_id IN (
                :'b8r_subscription_id'::uuid,
                :'b8r_other_subscription_id'::uuid
            )
        )
    THEN 'PASS' ELSE 'FAIL' END AS result;

\unset b8r_user_id
\unset b8r_membership_id
\unset b8r_role_id
\unset b8r_session_id
\unset b8r_branch_id
\unset b8r_other_branch_id
\unset b8r_member_id
\unset b8r_other_member_id
\unset b8r_subscription_id
\unset b8r_other_subscription_id
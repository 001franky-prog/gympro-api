\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

DO $$
BEGIN
    IF current_user <> 'postgres' THEN
        RAISE EXCEPTION 'Run verification as postgres.';
    END IF;

    IF (
        SELECT count(*)
        FROM app.members
        WHERE tenant_id =
            'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid
          AND id IN (
              '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid,
              '41f45bd6-114c-4241-9be0-0a949dc5f2b6'::uuid
          )
          AND status = 'pending'
    ) <> 2 THEN
        RAISE EXCEPTION 'Expected two pending API test members.';
    END IF;
END;
$$;

CREATE TEMP TABLE b5_activation_fixture AS
SELECT
    gen_random_uuid() AS plan_id,
    gen_random_uuid() AS inactive_plan_id,
    gen_random_uuid() AS price_id,
    gen_random_uuid() AS branch_price_id,
    gen_random_uuid() AS inactive_price_id,
    gen_random_uuid() AS session_id,
    sha256(convert_to(gen_random_uuid()::text, 'UTF8')) AS token_hash,
    gen_random_uuid() AS denied_user_id,
    gen_random_uuid() AS denied_membership_id,
    gen_random_uuid() AS denied_session_id,
    sha256(convert_to(gen_random_uuid()::text, 'UTF8')) AS denied_token_hash;

SELECT
    plan_id::text,
    inactive_plan_id::text,
    session_id::text,
    denied_session_id::text,
    denied_user_id::text,
    denied_membership_id::text
FROM b5_activation_fixture
\gset b5_activation_

CREATE TEMP TABLE b5_original_members AS
SELECT id, status, updated_at
FROM app.members
WHERE id IN (
    '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid,
    '41f45bd6-114c-4241-9be0-0a949dc5f2b6'::uuid
);

CREATE TEMP TABLE b5_activation_results (
    test_name text PRIMARY KEY,
    result text NOT NULL CHECK (result = 'PASS')
);

INSERT INTO app.membership_plans (
    id, tenant_id, plan_code, plan_name,
    duration_value, duration_unit, status
)
SELECT
    plan_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    'ACT-' || left(plan_id::text, 8),
    'Activation Verification Plan',
    1, 'months', 'active'
FROM b5_activation_fixture
UNION ALL
SELECT
    inactive_plan_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    'ACT-' || left(inactive_plan_id::text, 8),
    'Inactive Verification Plan',
    1, 'months', 'inactive'
FROM b5_activation_fixture;

INSERT INTO app.plan_prices (
    id, tenant_id, plan_id, branch_id, price_amount, status
)
SELECT
    price_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    plan_id, NULL::uuid, 50000, 'active'
FROM b5_activation_fixture
UNION ALL
SELECT
    branch_price_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    plan_id,
    'fa534b44-c8c6-44f5-bcc3-3ed14ace6e2c'::uuid,
    45000, 'active'
FROM b5_activation_fixture
UNION ALL
SELECT
    inactive_price_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    plan_id, NULL::uuid, 40000, 'inactive'
FROM b5_activation_fixture;

INSERT INTO app.users (id, full_name, email, status)
SELECT
    denied_user_id,
    'Activation Permission Test',
    'b5-' || denied_user_id::text || '@example.invalid',
    'active'
FROM b5_activation_fixture;

INSERT INTO app.tenant_memberships (
    id, tenant_id, user_id, status
)
SELECT
    denied_membership_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    denied_user_id,
    'active'
FROM b5_activation_fixture;

INSERT INTO security.tenant_sessions (
    id, tenant_id, membership_id,
    session_token_hash, expires_at
)
SELECT
    session_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    '3b318e89-f3bc-4ac5-a04d-09fdb3d626de'::uuid,
    token_hash,
    CURRENT_TIMESTAMP + INTERVAL '1 hour'
FROM b5_activation_fixture
UNION ALL
SELECT
    denied_session_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    denied_membership_id,
    denied_token_hash,
    CURRENT_TIMESTAMP + INTERVAL '1 hour'
FROM b5_activation_fixture;

GRANT SELECT ON b5_activation_fixture TO gympro_app;
GRANT INSERT ON b5_activation_results TO gympro_app;

CREATE FUNCTION pg_temp.b5_activation_rejected(
    p_name text,
    p_hash bytea,
    p_tenant uuid,
    p_member uuid,
    p_plan uuid,
    p_price uuid,
    p_expected_state text,
    p_expected_message text
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_state text;
    v_message text;
BEGIN
    BEGIN
        PERFORM *
        FROM security.activate_member_subscription(
            p_hash, p_tenant, p_member, p_plan, p_price
        );
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS
            v_state = RETURNED_SQLSTATE,
            v_message = MESSAGE_TEXT;

        IF v_state <> p_expected_state
           OR v_message <> p_expected_message THEN
            RAISE EXCEPTION
                'Test %: unexpected error %, %',
                p_name, v_state, v_message;
        END IF;

        INSERT INTO b5_activation_results VALUES (p_name, 'PASS');
        RETURN;
    END;

    RAISE EXCEPTION 'Test %: request was unexpectedly accepted.', p_name;
END;
$$;

SET LOCAL ROLE gympro_app;

SELECT pg_temp.b5_activation_rejected(
    '01_unknown_session',
    decode(repeat('00', 32), 'hex'),
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid,
    plan_id, price_id,
    '28000', 'Invalid or expired session'
)
FROM b5_activation_fixture;

SELECT pg_temp.b5_activation_rejected(
    '02_wrong_tenant',
    token_hash,
    'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc'::uuid,
    '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid,
    plan_id, price_id,
    '42501', 'Tenant access denied'
)
FROM b5_activation_fixture;

SELECT pg_temp.b5_activation_rejected(
    '03_unknown_member',
    token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    gen_random_uuid(),
    plan_id, price_id,
    '42501', 'Member access denied'
)
FROM b5_activation_fixture;

SELECT pg_temp.b5_activation_rejected(
    '04_missing_permission',
    denied_token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid,
    plan_id, price_id,
    '42501', 'Membership management permission denied'
)
FROM b5_activation_fixture;

SELECT pg_temp.b5_activation_rejected(
    '05_inactive_plan',
    token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid,
    inactive_plan_id, price_id,
    '22023', 'Active membership plan not found'
)
FROM b5_activation_fixture;

SELECT pg_temp.b5_activation_rejected(
    '06_inactive_price',
    token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid,
    plan_id, inactive_price_id,
    '22023', 'Active plan price not found'
)
FROM b5_activation_fixture;

SELECT pg_temp.b5_activation_rejected(
    '07_branch_price_for_unassigned_member',
    token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid,
    plan_id, branch_price_id,
    '22023', 'Plan price does not apply to the member branch'
)
FROM b5_activation_fixture;

-- First successful activation: member without a branch.
SELECT s.id AS tenant_subscription_id
FROM b5_activation_fixture AS f
CROSS JOIN LATERAL security.activate_member_subscription(
    f.token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid,
    f.plan_id,
    f.price_id
) AS s
\gset b5_activation_

SELECT pg_temp.b5_activation_rejected(
    '09_duplicate_activation',
    token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid,
    plan_id, price_id,
    '22023', 'Member already has a current subscription'
)
FROM b5_activation_fixture;

-- Second successful activation: member at BR001.
SELECT s.id AS branch_subscription_id
FROM b5_activation_fixture AS f
CROSS JOIN LATERAL security.activate_member_subscription(
    f.token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    '41f45bd6-114c-4241-9be0-0a949dc5f2b6'::uuid,
    f.plan_id,
    f.branch_price_id
) AS s
\gset b5_activation_

DO $$
BEGIN
    BEGIN
        PERFORM 1 FROM app.member_subscriptions LIMIT 1;
    EXCEPTION WHEN insufficient_privilege THEN
        INSERT INTO b5_activation_results
        VALUES ('11_direct_select_denied', 'PASS');
    END;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_class
        WHERE oid = 'app.member_subscriptions'::regclass
          AND relrowsecurity
          AND relforcerowsecurity
    ) THEN
        RAISE EXCEPTION 'Subscription RLS configuration changed.';
    END IF;
END;
$$;

RESET ROLE;

DO $$
DECLARE
    v_today date := (
        statement_timestamp() AT TIME ZONE 'Asia/Yangon'
    )::date;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM app.member_subscriptions AS s
        JOIN b5_activation_fixture AS f ON f.plan_id = s.plan_id
        JOIN app.members AS m
          ON m.tenant_id = s.tenant_id AND m.id = s.member_id
        WHERE s.member_id =
            '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid
          AND s.branch_id IS NULL
          AND s.status = 'active'
          AND m.status = 'active'
          AND s.duration_value = 1
          AND s.duration_unit = 'months'
          AND s.agreed_price_amount = 50000
          AND s.currency_code = 'MMK'
          AND s.starts_on = v_today
          AND s.ends_on = (v_today + INTERVAL '1 month')::date
          AND s.activated_at IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Tenant activation result is incorrect.';
    END IF;

    INSERT INTO b5_activation_results
    VALUES ('08_tenant_activation_and_snapshots', 'PASS');

    IF NOT EXISTS (
        SELECT 1
        FROM app.member_subscriptions AS s
        JOIN b5_activation_fixture AS f ON f.plan_id = s.plan_id
        JOIN app.members AS m
          ON m.tenant_id = s.tenant_id AND m.id = s.member_id
        WHERE s.member_id =
            '41f45bd6-114c-4241-9be0-0a949dc5f2b6'::uuid
          AND s.branch_id =
            'fa534b44-c8c6-44f5-bcc3-3ed14ace6e2c'::uuid
          AND s.plan_price_id = f.branch_price_id
          AND s.agreed_price_amount = 45000
          AND s.status = 'active'
          AND m.status = 'active'
          AND s.starts_on = v_today
          AND s.ends_on = (v_today + INTERVAL '1 month')::date
    ) THEN
        RAISE EXCEPTION 'Branch activation result is incorrect.';
    END IF;

    INSERT INTO b5_activation_results
    VALUES ('10_branch_activation_and_price', 'PASS');

    IF NOT EXISTS (
        SELECT 1 FROM b5_activation_results
        WHERE test_name = '11_direct_select_denied'
    ) THEN
        RAISE EXCEPTION 'Runtime direct SELECT was not denied.';
    END IF;

    IF has_table_privilege(
        'gympro_app', 'app.member_subscriptions', 'INSERT'
    )
    OR has_table_privilege(
        'gympro_app', 'app.member_subscriptions', 'UPDATE'
    )
    OR has_table_privilege(
        'gympro_app', 'app.member_subscriptions', 'DELETE'
    ) THEN
        RAISE EXCEPTION 'Unexpected runtime write privileges.';
    END IF;

    INSERT INTO b5_activation_results
    VALUES ('12_direct_write_privileges_denied', 'PASS');
END;
$$;

SELECT test_name, result
FROM b5_activation_results
ORDER BY test_name;

ROLLBACK;

SELECT
    CASE
        WHEN NOT EXISTS (
            SELECT 1
            FROM app.member_subscriptions
            WHERE id IN (
                :'b5_activation_tenant_subscription_id'::uuid,
                :'b5_activation_branch_subscription_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.membership_plans
            WHERE id IN (
                :'b5_activation_plan_id'::uuid,
                :'b5_activation_inactive_plan_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM security.tenant_sessions
            WHERE id IN (
                :'b5_activation_session_id'::uuid,
                :'b5_activation_denied_session_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.users
            WHERE id = :'b5_activation_denied_user_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.tenant_memberships
            WHERE id = :'b5_activation_denied_membership_id'::uuid
        )
        AND (
            SELECT count(*)
            FROM app.members
            WHERE id IN (
                '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid,
                '41f45bd6-114c-4241-9be0-0a949dc5f2b6'::uuid
            )
              AND status = 'pending'
        ) = 2
        THEN 'PASS'
        ELSE 'FAIL'
    END AS activation_fixture_rollback_test;
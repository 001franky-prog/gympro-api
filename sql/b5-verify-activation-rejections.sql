\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

DO $$
BEGIN
    IF current_user <> 'postgres' THEN
        RAISE EXCEPTION 'Run verification as postgres.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM app.members
        WHERE id = '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid
          AND tenant_id =
              'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid
          AND status = 'pending'
    ) THEN
        RAISE EXCEPTION 'Expected pending test member is missing.';
    END IF;
END;
$$;

CREATE TEMP TABLE b5_rejection_fixture AS
SELECT
    gen_random_uuid() AS plan_id,
    gen_random_uuid() AS other_plan_id,
    gen_random_uuid() AS price_id,
    gen_random_uuid() AS session_id,
    sha256(convert_to(gen_random_uuid()::text, 'UTF8')) AS token_hash;

SELECT
    plan_id::text,
    other_plan_id::text,
    price_id::text,
    session_id::text
FROM b5_rejection_fixture
\gset b5_rejection_

CREATE TEMP TABLE b5_rejection_results (
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
    'REJ-' || left(plan_id::text, 8),
    'Activation Rejection Plan',
    1, 'months', 'active'
FROM b5_rejection_fixture
UNION ALL
SELECT
    other_plan_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    'REJ-' || left(other_plan_id::text, 8),
    'Other Active Rejection Plan',
    1, 'months', 'active'
FROM b5_rejection_fixture;

INSERT INTO app.plan_prices (
    id, tenant_id, plan_id, price_amount, status
)
SELECT
    price_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    plan_id, 50000, 'active'
FROM b5_rejection_fixture;

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
FROM b5_rejection_fixture;

GRANT SELECT ON b5_rejection_fixture TO gympro_app;
GRANT INSERT ON b5_rejection_results TO gympro_app;

CREATE FUNCTION pg_temp.b5_rejection_test(
    p_name text,
    p_hash bytea,
    p_plan uuid,
    p_expected_state text,
    p_expected_message text
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_fixture record;
    v_state text;
    v_message text;
BEGIN
    SELECT * INTO STRICT v_fixture
    FROM b5_rejection_fixture;

    BEGIN
        PERFORM *
        FROM security.activate_member_subscription(
            p_hash,
            'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
            '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid,
            p_plan,
            v_fixture.price_id
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

        INSERT INTO b5_rejection_results
        VALUES (p_name, 'PASS');

        RETURN;
    END;

    RAISE EXCEPTION 'Test %: activation was unexpectedly accepted.', p_name;
END;
$$;

SET LOCAL ROLE gympro_app;

SELECT pg_temp.b5_rejection_test(
    '01_invalid_hash_length',
    decode('00', 'hex'),
    plan_id,
    '28000',
    'Invalid or expired session'
)
FROM b5_rejection_fixture;

SELECT pg_temp.b5_rejection_test(
    '02_price_belongs_to_different_active_plan',
    token_hash,
    other_plan_id,
    '22023',
    'Active plan price not found'
)
FROM b5_rejection_fixture;

RESET ROLE;

UPDATE security.tenant_sessions
SET revoked_at = CURRENT_TIMESTAMP
WHERE id = :'b5_rejection_session_id'::uuid;

SET LOCAL ROLE gympro_app;

SELECT pg_temp.b5_rejection_test(
    '03_revoked_session',
    token_hash,
    plan_id,
    '28000',
    'Invalid or expired session'
)
FROM b5_rejection_fixture;

RESET ROLE;

UPDATE security.tenant_sessions
SET
    revoked_at = NULL,
    created_at = CURRENT_TIMESTAMP - INTERVAL '2 hours',
    expires_at = CURRENT_TIMESTAMP - INTERVAL '1 hour'
WHERE id = :'b5_rejection_session_id'::uuid;

SET LOCAL ROLE gympro_app;

SELECT pg_temp.b5_rejection_test(
    '04_expired_session',
    token_hash,
    plan_id,
    '28000',
    'Invalid or expired session'
)
FROM b5_rejection_fixture;

RESET ROLE;

UPDATE security.tenant_sessions
SET
    created_at = CURRENT_TIMESTAMP,
    expires_at = CURRENT_TIMESTAMP + INTERVAL '1 hour'
WHERE id = :'b5_rejection_session_id'::uuid;

UPDATE app.members
SET status = 'inactive'
WHERE id = '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid;

SET LOCAL ROLE gympro_app;

SELECT pg_temp.b5_rejection_test(
    '05_inactive_member',
    token_hash,
    plan_id,
    '22023',
    'Member is not eligible for activation'
)
FROM b5_rejection_fixture;

RESET ROLE;

UPDATE app.members
SET status = 'blacklisted'
WHERE id = '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid;

SET LOCAL ROLE gympro_app;

SELECT pg_temp.b5_rejection_test(
    '06_blacklisted_member',
    token_hash,
    plan_id,
    '22023',
    'Member is not eligible for activation'
)
FROM b5_rejection_fixture;

RESET ROLE;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM app.member_subscriptions AS s
        JOIN b5_rejection_fixture AS f
          ON s.plan_id IN (f.plan_id, f.other_plan_id)
    ) THEN
        RAISE EXCEPTION 'Rejected activation saved a subscription.';
    END IF;

    INSERT INTO b5_rejection_results
    VALUES ('07_rejections_saved_no_subscriptions', 'PASS');
END;
$$;

SELECT test_name, result
FROM b5_rejection_results
ORDER BY test_name;

ROLLBACK;

SELECT
    CASE
        WHEN NOT EXISTS (
            SELECT 1 FROM app.membership_plans
            WHERE id IN (
                :'b5_rejection_plan_id'::uuid,
                :'b5_rejection_other_plan_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.plan_prices
            WHERE id = :'b5_rejection_price_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM security.tenant_sessions
            WHERE id = :'b5_rejection_session_id'::uuid
        )
        AND EXISTS (
            SELECT 1 FROM app.members
            WHERE id =
                '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid
              AND status = 'pending'
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS rejection_fixture_rollback_test;
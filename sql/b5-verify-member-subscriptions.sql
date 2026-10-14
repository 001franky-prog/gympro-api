\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE rolname = current_user
          AND rolsuper
    ) THEN
        RAISE EXCEPTION 'Run this verification as postgres.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM app.members
        WHERE id = '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid
          AND tenant_id =
              'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid
    ) THEN
        RAISE EXCEPTION 'Expected GYM001 test member is missing.';
    END IF;
END;
$$;

CREATE TEMP TABLE b5_fixture AS
SELECT
    gen_random_uuid() AS plan_id,
    gen_random_uuid() AS other_plan_id,
    gen_random_uuid() AS price_id,
    gen_random_uuid() AS subscription_id;

SELECT
    plan_id::text,
    other_plan_id::text,
    price_id::text,
    subscription_id::text
FROM b5_fixture
\gset b5_

CREATE TEMP TABLE b5_results (
    test_name text PRIMARY KEY,
    result text NOT NULL CHECK (result = 'PASS')
);

INSERT INTO app.membership_plans (
    id,
    tenant_id,
    plan_code,
    plan_name,
    duration_value,
    duration_unit,
    status
)
SELECT
    plan_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    'B5-' || left(plan_id::text, 8),
    'B5 Verification Plan',
    1,
    'months',
    'active'
FROM b5_fixture
UNION ALL
SELECT
    other_plan_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    'B5-' || left(other_plan_id::text, 8),
    'B5 Other Verification Plan',
    1,
    'months',
    'active'
FROM b5_fixture;

INSERT INTO app.plan_prices (
    id,
    tenant_id,
    plan_id,
    price_amount,
    status
)
SELECT
    price_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    plan_id,
    50000,
    'active'
FROM b5_fixture;

INSERT INTO app.member_subscriptions (
    id,
    tenant_id,
    member_id,
    plan_id,
    plan_price_id,
    duration_value,
    duration_unit,
    agreed_price_amount
)
SELECT
    subscription_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid,
    plan_id,
    price_id,
    1,
    'months',
    50000
FROM b5_fixture;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM app.member_subscriptions AS s
        JOIN b5_fixture AS f ON f.subscription_id = s.id
        WHERE s.status = 'pending'
          AND s.currency_code = 'MMK'
          AND s.branch_id IS NULL
          AND s.starts_on IS NULL
          AND s.ends_on IS NULL
          AND s.activated_at IS NULL
          AND s.suspended_at IS NULL
          AND s.created_at = s.updated_at
    ) THEN
        RAISE EXCEPTION 'Subscription defaults failed.';
    END IF;

    INSERT INTO b5_results
    VALUES ('01_subscription_defaults', 'PASS');
END;
$$;

-- Copies the valid fixture, applies one invalid change,
-- and requires the exact expected database constraint.
CREATE FUNCTION pg_temp.b5_expect_rejection(
    p_test_name text,
    p_changes jsonb,
    p_sqlstate text,
    p_constraint text
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_record app.member_subscriptions%ROWTYPE;
    v_state text;
    v_constraint text;
BEGIN
    SELECT (
        jsonb_populate_record(
            NULL::app.member_subscriptions,
            to_jsonb(s)
            || jsonb_build_object('id', gen_random_uuid())
            || p_changes
        )
    ).*
    INTO v_record
    FROM app.member_subscriptions AS s
    JOIN b5_fixture AS f ON f.subscription_id = s.id;

    BEGIN
        INSERT INTO app.member_subscriptions
        SELECT (v_record).*;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS
            v_state = RETURNED_SQLSTATE,
            v_constraint = CONSTRAINT_NAME;

        IF v_state <> p_sqlstate
           OR v_constraint IS DISTINCT FROM p_constraint THEN
            RAISE EXCEPTION
                'Test %: unexpected error %, constraint %',
                p_test_name, v_state, v_constraint;
        END IF;

        INSERT INTO b5_results VALUES (p_test_name, 'PASS');
        RETURN;
    END;

    RAISE EXCEPTION 'Test %: invalid insert was accepted.', p_test_name;
END;
$$;

SELECT pg_temp.b5_expect_rejection(
    '02_negative_price_rejected',
    '{"agreed_price_amount": -1}'::jsonb,
    '23514',
    'chk_member_subscriptions_price'
);

SELECT pg_temp.b5_expect_rejection(
    '03_invalid_duration_rejected',
    '{"duration_value": 0}'::jsonb,
    '23514',
    'chk_member_subscriptions_duration_value'
);

SELECT pg_temp.b5_expect_rejection(
    '04_reversed_dates_rejected',
    '{"starts_on": "2026-10-14", "ends_on": "2026-10-13"}'::jsonb,
    '23514',
    'chk_member_subscriptions_dates'
);

SELECT pg_temp.b5_expect_rejection(
    '05_partial_dates_rejected',
    '{"starts_on": "2026-10-14"}'::jsonb,
    '23514',
    'chk_member_subscriptions_dates'
);

SELECT pg_temp.b5_expect_rejection(
    '06_activation_without_dates_rejected',
    jsonb_build_object(
        'status', 'active',
        'activated_at', CURRENT_TIMESTAMP
    ),
    '23514',
    'chk_member_subscriptions_activation'
);

CREATE TEMP TABLE b5_other_tenant_member AS
WITH inserted_member AS (
    INSERT INTO app.members (
        tenant_id,
        full_name,
        email
    )
    VALUES (
        'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc'::uuid,
        'B5 Other Tenant Verification Member',
        'b5-other-tenant-test@example.invalid'
    )
    RETURNING id
)
SELECT id FROM inserted_member;

SELECT pg_temp.b5_expect_rejection(
    '07_other_tenant_member_rejected',
    jsonb_build_object(
        'member_id',
        (
            SELECT id
            FROM b5_other_tenant_member
        )
    ),
    '23503',
    'fk_member_subscriptions_member'
);

SELECT pg_temp.b5_expect_rejection(
    '08_price_from_other_plan_rejected',
    jsonb_build_object(
        'plan_id',
        (SELECT other_plan_id FROM b5_fixture)
    ),
    '23503',
    'fk_member_subscriptions_price'
);

UPDATE app.member_subscriptions
SET
    status = 'active',
    starts_on = DATE '2026-10-14',
    ends_on = DATE '2026-11-14',
    activated_at = CURRENT_TIMESTAMP,
    updated_at = CURRENT_TIMESTAMP
WHERE id = :'b5_subscription_id'::uuid;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM app.member_subscriptions AS s
        JOIN b5_fixture AS f ON f.subscription_id = s.id
        WHERE s.status = 'active'
          AND s.starts_on = DATE '2026-10-14'
          AND s.ends_on = DATE '2026-11-14'
    ) THEN
        RAISE EXCEPTION 'Active subscription storage failed.';
    END IF;

    INSERT INTO b5_results
    VALUES ('09_active_subscription_storage', 'PASS');
END;
$$;

SELECT pg_temp.b5_expect_rejection(
    '10_duplicate_current_subscription_rejected',
    '{}'::jsonb,
    '23505',
    'uq_member_subscriptions_current_member'
);

SELECT pg_temp.b5_expect_rejection(
    '11_suspension_without_timestamp_rejected',
    '{"status": "suspended"}'::jsonb,
    '23514',
    'chk_member_subscriptions_suspension'
);

UPDATE app.member_subscriptions
SET
    status = 'suspended',
    suspended_at = CURRENT_TIMESTAMP,
    updated_at = CURRENT_TIMESTAMP
WHERE id = :'b5_subscription_id'::uuid;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM app.member_subscriptions AS s
        JOIN b5_fixture AS f ON f.subscription_id = s.id
        WHERE s.status = 'suspended'
          AND s.suspended_at IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Suspended subscription storage failed.';
    END IF;

    INSERT INTO b5_results
    VALUES ('12_suspended_subscription_storage', 'PASS');
END;
$$;

SELECT pg_temp.b5_expect_rejection(
    '13_suspended_subscription_blocks_second_current',
    jsonb_build_object(
        'status', 'active',
        'suspended_at', NULL
    ),
    '23505',
    'uq_member_subscriptions_current_member'
);

SELECT test_name, result
FROM b5_results
ORDER BY test_name;

ROLLBACK;

SELECT
    CASE
        WHEN NOT EXISTS (
            SELECT 1 FROM app.member_subscriptions
            WHERE id = :'b5_subscription_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.plan_prices
            WHERE id = :'b5_price_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.membership_plans
            WHERE id IN (
                :'b5_plan_id'::uuid,
                :'b5_other_plan_id'::uuid
            )
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS fixture_rollback_test;
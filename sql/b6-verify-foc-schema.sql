\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

DO $$
BEGIN
    IF current_user <> 'postgres' THEN
        RAISE EXCEPTION 'Run verification as postgres.';
    END IF;
END;
$$;

CREATE TEMP TABLE b6_foc_fixture AS
SELECT
    gen_random_uuid() AS subscription_id,
    gen_random_uuid() AS second_subscription_id,
    gen_random_uuid() AS grant_id,
    gen_random_uuid() AS request_id;

SELECT
    subscription_id::text,
    second_subscription_id::text,
    grant_id::text,
    request_id::text
FROM b6_foc_fixture
\gset b6_foc_

CREATE TEMP TABLE b6_foc_results (
    test_name text PRIMARY KEY,
    result text NOT NULL CHECK (result = 'PASS')
);

-- Pending subscriptions are schema fixtures only.
-- No actual complimentary membership is activated.
INSERT INTO app.member_subscriptions (
    id, tenant_id, member_id, plan_id, plan_price_id,
    duration_value, duration_unit, agreed_price_amount,
    membership_kind
)
SELECT
    x.id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid,
    '838d86b2-9665-414d-865a-8f5fb559e39c'::uuid,
    'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid,
    1, 'months', 0, 'foc'
FROM b6_foc_fixture AS f
CROSS JOIN LATERAL (
    VALUES (f.subscription_id), (f.second_subscription_id)
) AS x(id);

INSERT INTO app.subscription_foc_grants (
    id, tenant_id, subscription_id, request_id,
    reason, listed_price_amount, previous_member_snapshot
)
SELECT
    f.grant_id,
    m.tenant_id,
    f.subscription_id,
    f.request_id,
    'FOC schema verification',
    50000.00,
    to_jsonb(m)
FROM app.members AS m
CROSS JOIN b6_foc_fixture AS f
WHERE m.id = '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid;

DO $$
DECLARE
    v_rejected boolean;
    v_constraint text;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM app.subscription_foc_grants AS h
        JOIN b6_foc_fixture AS f ON f.grant_id = h.id
        JOIN app.member_subscriptions AS s
          ON s.tenant_id = h.tenant_id AND s.id = h.subscription_id
        WHERE s.membership_kind = 'foc'
          AND s.agreed_price_amount = 0
          AND s.status = 'pending'
          AND h.listed_price_amount = 50000.00
          AND h.currency_code = 'MMK'
          AND isfinite(h.granted_at)
    ) THEN
        RAISE EXCEPTION 'FOC defaults failed.';
    END IF;

    INSERT INTO b6_foc_results
    VALUES ('01_foc_zero_price_and_history_defaults', 'PASS');

    v_rejected := false;

    BEGIN
        UPDATE app.member_subscriptions AS s
        SET agreed_price_amount = 1
        FROM b6_foc_fixture AS f
        WHERE s.id = f.subscription_id;
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;

        IF v_constraint <> 'chk_member_subscriptions_foc_price' THEN
            RAISE;
        END IF;

        v_rejected := true;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'Nonzero FOC price was accepted.';
    END IF;

    INSERT INTO b6_foc_results
    VALUES ('02_nonzero_foc_price_rejected', 'PASS');

    v_rejected := false;

    BEGIN
        UPDATE app.member_subscriptions AS s
        SET membership_kind = 'invalid'
        FROM b6_foc_fixture AS f
        WHERE s.id = f.subscription_id;
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;

        IF v_constraint <> 'chk_member_subscriptions_kind' THEN
            RAISE;
        END IF;

        v_rejected := true;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'Invalid membership kind was accepted.';
    END IF;

    INSERT INTO b6_foc_results
    VALUES ('03_invalid_membership_kind_rejected', 'PASS');
END;
$$;

CREATE FUNCTION pg_temp.b6_foc_rejected(
    p_name text,
    p_changes jsonb,
    p_expected_state text,
    p_expected_constraint text
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_record app.subscription_foc_grants%ROWTYPE;
    v_state text;
    v_constraint text;
BEGIN
    SELECT (
        jsonb_populate_record(
            NULL::app.subscription_foc_grants,
            to_jsonb(h)
            || jsonb_build_object(
                'id', gen_random_uuid(),
                'request_id', gen_random_uuid(),
                'subscription_id', f.second_subscription_id
            )
            || p_changes
        )
    ).*
    INTO STRICT v_record
    FROM app.subscription_foc_grants AS h
    JOIN b6_foc_fixture AS f ON f.grant_id = h.id;

    BEGIN
        INSERT INTO app.subscription_foc_grants
        SELECT (v_record).*;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS
            v_state = RETURNED_SQLSTATE,
            v_constraint = CONSTRAINT_NAME;

        IF v_state <> p_expected_state
           OR v_constraint IS DISTINCT FROM p_expected_constraint THEN
            RAISE EXCEPTION
                'Test %: unexpected error %, constraint %',
                p_name, v_state, v_constraint;
        END IF;

        INSERT INTO b6_foc_results VALUES (p_name, 'PASS');
        RETURN;
    END;

    RAISE EXCEPTION 'Test %: invalid grant history was accepted.', p_name;
END;
$$;

SELECT pg_temp.b6_foc_rejected(
    '04_duplicate_request_rejected',
    jsonb_build_object(
        'request_id', (SELECT request_id FROM b6_foc_fixture)
    ),
    '23505', 'uq_subscription_foc_grants_request'
);

SELECT pg_temp.b6_foc_rejected(
    '05_duplicate_subscription_grant_rejected',
    jsonb_build_object(
        'subscription_id', (SELECT subscription_id FROM b6_foc_fixture)
    ),
    '23505', 'uq_subscription_foc_grants_subscription'
);

SELECT pg_temp.b6_foc_rejected(
    '06_blank_reason_rejected',
    '{"reason": ""}'::jsonb,
    '23514', 'chk_subscription_foc_grants_reason'
);

SELECT pg_temp.b6_foc_rejected(
    '07_negative_listed_price_rejected',
    '{"listed_price_amount": -1}'::jsonb,
    '23514', 'chk_subscription_foc_grants_listed_price'
);

SELECT pg_temp.b6_foc_rejected(
    '08_invalid_currency_rejected',
    '{"currency_code": "USD"}'::jsonb,
    '23514', 'chk_subscription_foc_grants_currency'
);

SELECT pg_temp.b6_foc_rejected(
    '09_empty_snapshot_rejected',
    '{"previous_member_snapshot": {}}'::jsonb,
    '23514', 'chk_subscription_foc_grants_snapshot'
);

SELECT pg_temp.b6_foc_rejected(
    '10_unknown_subscription_rejected',
    jsonb_build_object('subscription_id', gen_random_uuid()),
    '23503', 'fk_subscription_foc_grants_subscription'
);

DO $$
BEGIN
    IF has_table_privilege(
        'gympro_app', 'app.subscription_foc_grants', 'SELECT'
    )
    OR has_table_privilege(
        'gympro_app', 'app.subscription_foc_grants', 'INSERT'
    )
    OR has_table_privilege(
        'gympro_app', 'app.subscription_foc_grants', 'UPDATE'
    )
    OR has_table_privilege(
        'gympro_app', 'app.subscription_foc_grants', 'DELETE'
    ) THEN
        RAISE EXCEPTION 'Unexpected runtime FOC history access.';
    END IF;

    INSERT INTO b6_foc_results
    VALUES ('11_runtime_history_access_denied', 'PASS');

    IF EXISTS (
        SELECT 1
        FROM app.role_permissions AS rp
        JOIN app.permissions AS p ON p.id = rp.permission_id
        WHERE p.permission_code = 'gym.memberships.grant_foc'
    ) THEN
        RAISE EXCEPTION 'FOC permission has already been assigned; inspect assignments.';
    END IF;

    INSERT INTO b6_foc_results
    VALUES ('12_foc_permission_not_implicitly_assigned', 'PASS');
END;
$$;

SELECT test_name, result
FROM b6_foc_results
ORDER BY test_name;

ROLLBACK;

SELECT
    CASE
        WHEN NOT EXISTS (
            SELECT 1 FROM app.member_subscriptions
            WHERE id IN (
                :'b6_foc_subscription_id'::uuid,
                :'b6_foc_second_subscription_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.subscription_foc_grants
            WHERE subscription_id IN (
                :'b6_foc_subscription_id'::uuid,
                :'b6_foc_second_subscription_id'::uuid
            )
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS foc_schema_rollback_test;
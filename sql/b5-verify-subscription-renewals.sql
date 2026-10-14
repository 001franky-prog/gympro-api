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
        SELECT 1
        FROM app.member_subscriptions
        WHERE id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
          AND tenant_id =
              'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid
          AND status = 'active'
          AND ends_on = DATE '2026-11-14'
    ) THEN
        RAISE EXCEPTION 'Expected active demo subscription is missing or changed.';
    END IF;
END;
$$;

CREATE TEMP TABLE b5_renewal_fixture AS
SELECT
    gen_random_uuid() AS renewal_id,
    gen_random_uuid() AS request_id;

SELECT
    renewal_id::text,
    request_id::text
FROM b5_renewal_fixture
\gset b5_renewal_

CREATE TEMP TABLE b5_renewal_results (
    test_name text PRIMARY KEY,
    result text NOT NULL CHECK (result = 'PASS')
);

INSERT INTO app.subscription_renewals (
    id,
    tenant_id,
    subscription_id,
    request_id,
    plan_id,
    plan_price_id,
    previous_ends_on,
    renewal_starts_on,
    renewal_ends_on,
    duration_value,
    duration_unit,
    agreed_price_amount,
    previous_subscription_snapshot
)
SELECT
    f.renewal_id,
    s.tenant_id,
    s.id,
    f.request_id,
    s.plan_id,
    s.plan_price_id,
    s.ends_on,
    s.ends_on,
    (s.ends_on + INTERVAL '1 month')::date,
    1,
    'months',
    50000.00,
    to_jsonb(s)
FROM app.member_subscriptions AS s
CROSS JOIN b5_renewal_fixture AS f
WHERE s.id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM app.subscription_renewals AS r
        JOIN b5_renewal_fixture AS f ON f.renewal_id = r.id
        JOIN app.member_subscriptions AS s
          ON s.tenant_id = r.tenant_id
         AND s.id = r.subscription_id
        WHERE r.currency_code = 'MMK'
          AND r.previous_ends_on = DATE '2026-11-14'
          AND r.renewal_starts_on = DATE '2026-11-14'
          AND r.renewal_ends_on = DATE '2026-12-14'
          AND r.previous_subscription_snapshot = to_jsonb(s)
          AND r.created_at IS NOT NULL
          AND s.ends_on = DATE '2026-11-14'
    ) THEN
        RAISE EXCEPTION 'Renewal history defaults or snapshot failed.';
    END IF;

    INSERT INTO b5_renewal_results
    VALUES ('01_defaults_and_snapshot', 'PASS');
END;
$$;

CREATE FUNCTION pg_temp.b5_renewal_rejected(
    p_name text,
    p_changes jsonb,
    p_expected_state text,
    p_expected_constraint text
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_record app.subscription_renewals%ROWTYPE;
    v_state text;
    v_constraint text;
BEGIN
    SELECT (
        jsonb_populate_record(
            NULL::app.subscription_renewals,
            to_jsonb(r)
            || jsonb_build_object(
                'id', gen_random_uuid(),
                'request_id', gen_random_uuid()
            )
            || p_changes
        )
    ).*
    INTO STRICT v_record
    FROM app.subscription_renewals AS r
    JOIN b5_renewal_fixture AS f ON f.renewal_id = r.id;

    BEGIN
        INSERT INTO app.subscription_renewals
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

        INSERT INTO b5_renewal_results VALUES (p_name, 'PASS');
        RETURN;
    END;

    RAISE EXCEPTION 'Test %: invalid history insert was accepted.', p_name;
END;
$$;

SELECT pg_temp.b5_renewal_rejected(
    '02_duplicate_request_rejected',
    jsonb_build_object(
        'request_id',
        (SELECT request_id FROM b5_renewal_fixture)
    ),
    '23505',
    'uq_subscription_renewals_request'
);

SELECT pg_temp.b5_renewal_rejected(
    '03_negative_price_rejected',
    '{"agreed_price_amount": -1}'::jsonb,
    '23514',
    'chk_subscription_renewals_price'
);

SELECT pg_temp.b5_renewal_rejected(
    '04_zero_duration_rejected',
    '{"duration_value": 0}'::jsonb,
    '23514',
    'chk_subscription_renewals_duration_value'
);

SELECT pg_temp.b5_renewal_rejected(
    '05_invalid_currency_rejected',
    '{"currency_code": "USD"}'::jsonb,
    '23514',
    'chk_subscription_renewals_currency'
);

SELECT pg_temp.b5_renewal_rejected(
    '06_reversed_period_rejected',
    '{"renewal_ends_on": "2026-11-13"}'::jsonb,
    '23514',
    'chk_subscription_renewals_dates'
);

SELECT pg_temp.b5_renewal_rejected(
    '07_overlapping_period_rejected',
    '{"renewal_starts_on": "2026-11-13"}'::jsonb,
    '23514',
    'chk_subscription_renewals_dates'
);

SELECT pg_temp.b5_renewal_rejected(
    '08_empty_snapshot_rejected',
    '{"previous_subscription_snapshot": {}}'::jsonb,
    '23514',
    'chk_subscription_renewals_snapshot'
);

SELECT pg_temp.b5_renewal_rejected(
    '09_array_snapshot_rejected',
    '{"previous_subscription_snapshot": []}'::jsonb,
    '23514',
    'chk_subscription_renewals_snapshot'
);

SELECT pg_temp.b5_renewal_rejected(
    '10_unknown_subscription_rejected',
    jsonb_build_object('subscription_id', gen_random_uuid()),
    '23503',
    'fk_subscription_renewals_subscription'
);

SELECT pg_temp.b5_renewal_rejected(
    '11_unknown_price_rejected',
    jsonb_build_object('plan_price_id', gen_random_uuid()),
    '23503',
    'fk_subscription_renewals_price'
);

DO $$
BEGIN
    IF has_table_privilege(
        'gympro_app', 'app.subscription_renewals', 'SELECT'
    )
    OR has_table_privilege(
        'gympro_app', 'app.subscription_renewals', 'INSERT'
    )
    OR has_table_privilege(
        'gympro_app', 'app.subscription_renewals', 'UPDATE'
    )
    OR has_table_privilege(
        'gympro_app', 'app.subscription_renewals', 'DELETE'
    ) THEN
        RAISE EXCEPTION 'Unexpected runtime access to renewal history.';
    END IF;

    INSERT INTO b5_renewal_results
    VALUES ('12_runtime_history_access_denied', 'PASS');
END;
$$;

SELECT test_name, result
FROM b5_renewal_results
ORDER BY test_name;

ROLLBACK;

SELECT
    CASE
        WHEN NOT EXISTS (
            SELECT 1
            FROM app.subscription_renewals
            WHERE id = :'b5_renewal_renewal_id'::uuid
               OR (
                   tenant_id =
                       'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid
                   AND request_id = :'b5_renewal_request_id'::uuid
               )
        )
        AND EXISTS (
            SELECT 1
            FROM app.member_subscriptions
            WHERE id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
              AND status = 'active'
              AND ends_on = DATE '2026-11-14'
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS renewal_fixture_rollback_test;
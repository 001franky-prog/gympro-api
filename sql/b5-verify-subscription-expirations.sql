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

SELECT to_jsonb(s)::text AS original_subscription
FROM app.member_subscriptions AS s
WHERE id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
\gset b5_eh_

CREATE TEMP TABLE b5_eh_fixture AS
SELECT
    gen_random_uuid() AS expiration_id,
    (statement_timestamp() AT TIME ZONE 'Asia/Yangon')::date AS today;

SELECT expiration_id::text
FROM b5_eh_fixture
\gset b5_eh_

CREATE TEMP TABLE b5_eh_results (
    test_name text PRIMARY KEY,
    result text NOT NULL CHECK (result = 'PASS')
);

-- Simulated history only: no subscription update is performed.
INSERT INTO app.subscription_expirations (
    id,
    tenant_id,
    subscription_id,
    coverage_starts_on,
    coverage_ends_on,
    processed_on,
    previous_subscription_snapshot
)
SELECT
    f.expiration_id,
    s.tenant_id,
    s.id,
    f.today - 30,
    f.today,
    f.today,
    to_jsonb(s) || jsonb_build_object(
        'starts_on', f.today - 30,
        'ends_on', f.today
    )
FROM app.member_subscriptions AS s
CROSS JOIN b5_eh_fixture AS f
WHERE s.id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM app.subscription_expirations AS h
        JOIN b5_eh_fixture AS f ON f.expiration_id = h.id
        WHERE h.coverage_starts_on = f.today - 30
          AND h.coverage_ends_on = f.today
          AND h.processed_on = f.today
          AND isfinite(h.expired_at)
          AND h.created_at IS NOT NULL
          AND (
              h.previous_subscription_snapshot ->> 'ends_on'
          )::date = f.today
    ) THEN
        RAISE EXCEPTION 'Expiration history defaults failed.';
    END IF;

    INSERT INTO b5_eh_results
    VALUES ('01_defaults_and_due_date', 'PASS');
END;
$$;

CREATE FUNCTION pg_temp.b5_eh_rejected(
    p_name text,
    p_changes jsonb,
    p_expected_state text,
    p_expected_constraint text
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_record app.subscription_expirations%ROWTYPE;
    v_state text;
    v_constraint text;
BEGIN
    SELECT (
        jsonb_populate_record(
            NULL::app.subscription_expirations,
            to_jsonb(h)
            || jsonb_build_object(
                'id', gen_random_uuid(),
                'coverage_starts_on', h.coverage_starts_on - 1,
                'coverage_ends_on', h.coverage_ends_on - 1
            )
            || p_changes
        )
    ).*
    INTO STRICT v_record
    FROM app.subscription_expirations AS h
    JOIN b5_eh_fixture AS f ON f.expiration_id = h.id;

    BEGIN
        INSERT INTO app.subscription_expirations
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

        INSERT INTO b5_eh_results VALUES (p_name, 'PASS');
        RETURN;
    END;

    RAISE EXCEPTION 'Test %: invalid history was accepted.', p_name;
END;
$$;

SELECT pg_temp.b5_eh_rejected(
    '02_duplicate_coverage_period_rejected',
    jsonb_build_object(
        'coverage_starts_on', today - 30,
        'coverage_ends_on', today
    ),
    '23505',
    'uq_subscription_expirations_period'
)
FROM b5_eh_fixture;

SELECT pg_temp.b5_eh_rejected(
    '03_processing_before_end_rejected',
    jsonb_build_object('processed_on', today - 2),
    '23514',
    'chk_subscription_expirations_dates'
)
FROM b5_eh_fixture;

SELECT pg_temp.b5_eh_rejected(
    '04_reversed_coverage_rejected',
    jsonb_build_object('coverage_ends_on', today - 32),
    '23514',
    'chk_subscription_expirations_dates'
)
FROM b5_eh_fixture;

SELECT pg_temp.b5_eh_rejected(
    '05_infinite_date_rejected',
    '{"processed_on": "infinity"}'::jsonb,
    '23514',
    'chk_subscription_expirations_dates'
);

SELECT pg_temp.b5_eh_rejected(
    '06_infinite_timestamp_rejected',
    '{"expired_at": "infinity"}'::jsonb,
    '23514',
    'chk_subscription_expirations_timestamp'
);

SELECT pg_temp.b5_eh_rejected(
    '07_empty_snapshot_rejected',
    '{"previous_subscription_snapshot": {}}'::jsonb,
    '23514',
    'chk_subscription_expirations_snapshot'
);

SELECT pg_temp.b5_eh_rejected(
    '08_array_snapshot_rejected',
    '{"previous_subscription_snapshot": []}'::jsonb,
    '23514',
    'chk_subscription_expirations_snapshot'
);

SELECT pg_temp.b5_eh_rejected(
    '09_unknown_subscription_rejected',
    jsonb_build_object('subscription_id', gen_random_uuid()),
    '23503',
    'fk_subscription_expirations_subscription'
);

DO $$
BEGIN
    IF has_table_privilege(
        'gympro_app', 'app.subscription_expirations', 'SELECT'
    )
    OR has_table_privilege(
        'gympro_app', 'app.subscription_expirations', 'INSERT'
    )
    OR has_table_privilege(
        'gympro_app', 'app.subscription_expirations', 'UPDATE'
    )
    OR has_table_privilege(
        'gympro_app', 'app.subscription_expirations', 'DELETE'
    ) THEN
        RAISE EXCEPTION 'Unexpected direct runtime expiration history access.';
    END IF;

    INSERT INTO b5_eh_results
    VALUES ('10_runtime_history_access_denied', 'PASS');
END;
$$;

SELECT test_name, result
FROM b5_eh_results
ORDER BY test_name;

ROLLBACK;

SELECT
    CASE
        WHEN NOT EXISTS (
            SELECT 1 FROM app.subscription_expirations
            WHERE id = :'b5_eh_expiration_id'::uuid
        )
        AND (
            SELECT to_jsonb(s)
            FROM app.member_subscriptions AS s
            WHERE id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
        ) = :'b5_eh_original_subscription'::jsonb
        THEN 'PASS'
        ELSE 'FAIL'
    END AS expiration_history_rollback_test;
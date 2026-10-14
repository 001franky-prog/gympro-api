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
        SELECT 1 FROM app.member_subscriptions
        WHERE id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
          AND status = 'active'
    ) THEN
        RAISE EXCEPTION 'Expected active demo subscription.';
    END IF;
END;
$$;

SELECT to_jsonb(s)::text AS original_subscription
FROM app.member_subscriptions AS s
WHERE id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
\gset b5_sh_

CREATE TEMP TABLE b5_sh_fixture AS
SELECT
    gen_random_uuid() AS suspension_id,
    gen_random_uuid() AS request_id;

SELECT suspension_id::text, request_id::text
FROM b5_sh_fixture
\gset b5_sh_

CREATE TEMP TABLE b5_sh_results (
    test_name text PRIMARY KEY,
    result text NOT NULL CHECK (result = 'PASS')
);

INSERT INTO app.subscription_suspensions (
    id,
    tenant_id,
    subscription_id,
    request_id,
    reason,
    previous_subscription_snapshot
)
SELECT
    f.suspension_id,
    s.tenant_id,
    s.id,
    f.request_id,
    'Temporary suspension history verification',
    to_jsonb(s)
FROM app.member_subscriptions AS s
CROSS JOIN b5_sh_fixture AS f
WHERE s.id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM app.subscription_suspensions AS h
        JOIN b5_sh_fixture AS f ON f.suspension_id = h.id
        JOIN app.member_subscriptions AS s
          ON s.tenant_id = h.tenant_id
         AND s.id = h.subscription_id
        WHERE h.suspended_at IS NOT NULL
          AND isfinite(h.suspended_at)
          AND h.created_at IS NOT NULL
          AND h.previous_subscription_snapshot = to_jsonb(s)
          AND s.status = 'active'
          AND s.suspended_at IS NULL
    ) THEN
        RAISE EXCEPTION 'History defaults or snapshot verification failed.';
    END IF;

    INSERT INTO b5_sh_results
    VALUES ('01_defaults_and_snapshot', 'PASS');
END;
$$;

CREATE FUNCTION pg_temp.b5_sh_rejected(
    p_name text,
    p_changes jsonb,
    p_expected_state text,
    p_expected_constraint text
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_record app.subscription_suspensions%ROWTYPE;
    v_state text;
    v_constraint text;
BEGIN
    SELECT (
        jsonb_populate_record(
            NULL::app.subscription_suspensions,
            to_jsonb(h)
            || jsonb_build_object(
                'id', gen_random_uuid(),
                'request_id', gen_random_uuid()
            )
            || p_changes
        )
    ).*
    INTO STRICT v_record
    FROM app.subscription_suspensions AS h
    JOIN b5_sh_fixture AS f ON f.suspension_id = h.id;

    BEGIN
        INSERT INTO app.subscription_suspensions
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

        INSERT INTO b5_sh_results VALUES (p_name, 'PASS');
        RETURN;
    END;

    RAISE EXCEPTION 'Test %: invalid history was accepted.', p_name;
END;
$$;

SELECT pg_temp.b5_sh_rejected(
    '02_duplicate_request_rejected',
    jsonb_build_object(
        'request_id',
        (SELECT request_id FROM b5_sh_fixture)
    ),
    '23505',
    'uq_subscription_suspensions_request'
);

SELECT pg_temp.b5_sh_rejected(
    '03_blank_reason_rejected',
    '{"reason": ""}'::jsonb,
    '23514',
    'chk_subscription_suspensions_reason'
);

SELECT pg_temp.b5_sh_rejected(
    '04_padded_reason_rejected',
    '{"reason": "  Test reason  "}'::jsonb,
    '23514',
    'chk_subscription_suspensions_reason'
);

SELECT pg_temp.b5_sh_rejected(
    '05_whitespace_reason_rejected',
    jsonb_build_object('reason', E'\t\t'),
    '23514',
    'chk_subscription_suspensions_reason'
);

SELECT pg_temp.b5_sh_rejected(
    '06_short_reason_rejected',
    '{"reason": "A"}'::jsonb,
    '23514',
    'chk_subscription_suspensions_reason'
);

SELECT pg_temp.b5_sh_rejected(
    '07_infinite_timestamp_rejected',
    '{"suspended_at": "infinity"}'::jsonb,
    '23514',
    'chk_subscription_suspensions_timestamp'
);

SELECT pg_temp.b5_sh_rejected(
    '08_empty_snapshot_rejected',
    '{"previous_subscription_snapshot": {}}'::jsonb,
    '23514',
    'chk_subscription_suspensions_snapshot'
);

SELECT pg_temp.b5_sh_rejected(
    '09_array_snapshot_rejected',
    '{"previous_subscription_snapshot": []}'::jsonb,
    '23514',
    'chk_subscription_suspensions_snapshot'
);

SELECT pg_temp.b5_sh_rejected(
    '10_unknown_subscription_rejected',
    jsonb_build_object('subscription_id', gen_random_uuid()),
    '23503',
    'fk_subscription_suspensions_subscription'
);

DO $$
BEGIN
    IF has_table_privilege(
        'gympro_app', 'app.subscription_suspensions', 'SELECT'
    )
    OR has_table_privilege(
        'gympro_app', 'app.subscription_suspensions', 'INSERT'
    )
    OR has_table_privilege(
        'gympro_app', 'app.subscription_suspensions', 'UPDATE'
    )
    OR has_table_privilege(
        'gympro_app', 'app.subscription_suspensions', 'DELETE'
    ) THEN
        RAISE EXCEPTION 'Unexpected direct runtime history access.';
    END IF;

    INSERT INTO b5_sh_results
    VALUES ('11_runtime_history_access_denied', 'PASS');
END;
$$;

SELECT test_name, result
FROM b5_sh_results
ORDER BY test_name;

ROLLBACK;

SELECT
    CASE
        WHEN NOT EXISTS (
            SELECT 1 FROM app.subscription_suspensions
            WHERE id = :'b5_sh_suspension_id'::uuid
               OR (
                   tenant_id =
                       'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid
                   AND request_id = :'b5_sh_request_id'::uuid
               )
        )
        AND (
            SELECT to_jsonb(s)
            FROM app.member_subscriptions AS s
            WHERE id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
        ) = :'b5_sh_original_subscription'::jsonb
        THEN 'PASS'
        ELSE 'FAIL'
    END AS suspension_history_rollback_test;
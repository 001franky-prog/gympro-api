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
          AND status = 'active'
          AND ends_on >
              (statement_timestamp() AT TIME ZONE 'Asia/Yangon')::date
    ) THEN
        RAISE EXCEPTION 'Expected unexpired active demo subscription.';
    END IF;
END;
$$;

SELECT
    to_jsonb(s)::text AS original_subscription,
    to_jsonb(m)::text AS original_member
FROM app.member_subscriptions AS s
JOIN app.members AS m
    ON m.tenant_id = s.tenant_id
   AND m.id = s.member_id
WHERE s.id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
\gset b5_rf_

CREATE TEMP TABLE b5_rf_fixture AS
SELECT
    gen_random_uuid() AS session_id,
    sha256(convert_to(gen_random_uuid()::text, 'UTF8')) AS token_hash,
    gen_random_uuid() AS request_id,
    gen_random_uuid() AS second_request_id;

SELECT
    session_id::text,
    request_id::text,
    second_request_id::text
FROM b5_rf_fixture
\gset b5_rf_

CREATE TEMP TABLE b5_rf_receipts (
    label text PRIMARY KEY,
    receipt jsonb NOT NULL
);

CREATE TEMP TABLE b5_rf_results (
    test_name text PRIMARY KEY,
    result text NOT NULL CHECK (result = 'PASS')
);

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
FROM b5_rf_fixture;

GRANT SELECT ON b5_rf_fixture TO gympro_app;
GRANT INSERT ON b5_rf_receipts, b5_rf_results TO gympro_app;

CREATE FUNCTION pg_temp.b5_rf_rejected(
    p_name text,
    p_hash bytea,
    p_tenant uuid,
    p_price uuid,
    p_request uuid,
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
        FROM security.renew_member_subscription(
            p_hash,
            p_tenant,
            '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid,
            p_price,
            p_request
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

        INSERT INTO b5_rf_results VALUES (p_name, 'PASS');
        RETURN;
    END;

    RAISE EXCEPTION 'Test %: request was unexpectedly accepted.', p_name;
END;
$$;

SET LOCAL ROLE gympro_app;

INSERT INTO b5_rf_receipts (label, receipt)
SELECT 'first', to_jsonb(r)
FROM b5_rf_fixture AS f
CROSS JOIN LATERAL security.renew_member_subscription(
    f.token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid,
    'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid,
    f.request_id
) AS r;

INSERT INTO b5_rf_receipts (label, receipt)
SELECT 'retry', to_jsonb(r)
FROM b5_rf_fixture AS f
CROSS JOIN LATERAL security.renew_member_subscription(
    f.token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid,
    'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid,
    f.request_id
) AS r;

SELECT pg_temp.b5_rf_rejected(
    '05_wrong_tenant',
    token_hash,
    'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc'::uuid,
    'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid,
    gen_random_uuid(),
    '42501', 'Tenant access denied'
)
FROM b5_rf_fixture;

SELECT pg_temp.b5_rf_rejected(
    '06_unknown_session',
    decode(repeat('00', 32), 'hex'),
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid,
    gen_random_uuid(),
    '28000', 'Invalid or expired session'
)
FROM b5_rf_fixture;

SELECT pg_temp.b5_rf_rejected(
    '07_request_reuse_with_different_price',
    token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    gen_random_uuid(),
    request_id,
    '22023', 'Request ID already belongs to another renewal request'
)
FROM b5_rf_fixture;

RESET ROLE;

DO $$
DECLARE
    v_subscription app.member_subscriptions%ROWTYPE;
    v_first jsonb;
    v_retry jsonb;
BEGIN
    SELECT * INTO STRICT v_subscription
    FROM app.member_subscriptions
    WHERE id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid;

    SELECT receipt INTO STRICT v_first
    FROM b5_rf_receipts WHERE label = 'first';

    SELECT receipt INTO STRICT v_retry
    FROM b5_rf_receipts WHERE label = 'retry';

    IF v_subscription.ends_on <> DATE '2026-12-14'
       OR v_subscription.starts_on <> DATE '2026-10-14'
       OR v_subscription.status <> 'active'
       OR (v_first ->> 'previous_ends_on')::date <> DATE '2026-11-14'
       OR (v_first ->> 'renewal_starts_on')::date <> DATE '2026-11-14'
       OR (v_first ->> 'renewal_ends_on')::date <> DATE '2026-12-14' THEN
        RAISE EXCEPTION 'First renewal dates are incorrect.';
    END IF;

    INSERT INTO b5_rf_results
    VALUES ('01_renewal_extends_from_existing_end', 'PASS');

    IF (v_first ->> 'agreed_price_amount')::numeric <> 50000.00
       OR v_first ->> 'currency_code' <> 'MMK'
       OR (v_first ->> 'duration_value')::integer <> 1
       OR v_first ->> 'duration_unit' <> 'months'
       OR v_first #>> '{previous_subscription_snapshot,ends_on}'
           <> '2026-11-14'
       OR v_first #>> '{previous_subscription_snapshot,renewed_by_membership_id}'
           <> '3b318e89-f3bc-4ac5-a04d-09fdb3d626de' THEN
        RAISE EXCEPTION 'Renewal price, duration, or actor snapshot is incorrect.';
    END IF;

    INSERT INTO b5_rf_results
    VALUES ('02_agreed_values_and_actor_snapshot', 'PASS');

    IF v_first IS DISTINCT FROM v_retry THEN
        RAISE EXCEPTION 'Retry did not return the original receipt.';
    END IF;

    INSERT INTO b5_rf_results
    VALUES ('03_retry_returns_original_receipt', 'PASS');

    IF (
        SELECT count(*)
        FROM app.subscription_renewals AS r
        JOIN b5_rf_fixture AS f
          ON r.request_id = f.request_id
        WHERE r.tenant_id =
            'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid
    ) <> 1 THEN
        RAISE EXCEPTION 'Retry created duplicate history.';
    END IF;

    INSERT INTO b5_rf_results
    VALUES ('04_retry_creates_no_second_extension', 'PASS');
END;
$$;

SET LOCAL ROLE gympro_app;

INSERT INTO b5_rf_receipts (label, receipt)
SELECT 'second', to_jsonb(r)
FROM b5_rf_fixture AS f
CROSS JOIN LATERAL security.renew_member_subscription(
    f.token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid,
    'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid,
    f.second_request_id
) AS r;

RESET ROLE;

DO $$
DECLARE
    v_second jsonb;
BEGIN
    SELECT receipt INTO STRICT v_second
    FROM b5_rf_receipts WHERE label = 'second';

    IF (v_second ->> 'renewal_starts_on')::date <> DATE '2026-12-14'
       OR (v_second ->> 'renewal_ends_on')::date <> DATE '2027-01-14'
       OR v_second #>> '{previous_subscription_snapshot,ends_on}'
           <> '2026-12-14'
       OR NOT EXISTS (
           SELECT 1 FROM app.member_subscriptions
           WHERE id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
             AND ends_on = DATE '2027-01-14'
       ) THEN
        RAISE EXCEPTION 'Second distinct renewal is incorrect.';
    END IF;

    INSERT INTO b5_rf_results
    VALUES ('08_new_request_extends_again', 'PASS');

    IF has_table_privilege(
        'gympro_app', 'app.subscription_renewals', 'SELECT'
    )
    OR has_table_privilege(
        'gympro_app', 'app.subscription_renewals', 'INSERT'
    )
    OR has_table_privilege(
        'gympro_app', 'app.member_subscriptions', 'UPDATE'
    ) THEN
        RAISE EXCEPTION 'Unexpected direct runtime table privileges.';
    END IF;

    INSERT INTO b5_rf_results
    VALUES ('09_runtime_function_only_access', 'PASS');
END;
$$;

SELECT test_name, result
FROM b5_rf_results
ORDER BY test_name;

ROLLBACK;

SELECT
    CASE
        WHEN (
            SELECT to_jsonb(s)
            FROM app.member_subscriptions AS s
            WHERE id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
        ) = :'b5_rf_original_subscription'::jsonb
        AND (
            SELECT to_jsonb(m)
            FROM app.members AS m
            WHERE id = '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid
        ) = :'b5_rf_original_member'::jsonb
        AND NOT EXISTS (
            SELECT 1 FROM app.subscription_renewals
            WHERE tenant_id =
                'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid
              AND request_id IN (
                  :'b5_rf_request_id'::uuid,
                  :'b5_rf_second_request_id'::uuid
              )
        )
        AND NOT EXISTS (
            SELECT 1 FROM security.tenant_sessions
            WHERE id = :'b5_rf_session_id'::uuid
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS renewal_function_rollback_test;
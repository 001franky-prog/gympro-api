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
        FROM app.member_subscriptions AS s
        JOIN app.members AS m
          ON m.tenant_id = s.tenant_id
         AND m.id = s.member_id
        WHERE s.id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
          AND s.status = 'active'
          AND m.status = 'active'
          AND s.starts_on <=
              (statement_timestamp() AT TIME ZONE 'Asia/Yangon')::date
          AND s.ends_on >
              (statement_timestamp() AT TIME ZONE 'Asia/Yangon')::date
    ) THEN
        RAISE EXCEPTION 'Expected active, unexpired demo subscription.';
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
\gset b5_sf_

CREATE TEMP TABLE b5_sf_fixture AS
SELECT
    gen_random_uuid() AS session_id,
    sha256(convert_to(gen_random_uuid()::text, 'UTF8')) AS token_hash,
    gen_random_uuid() AS request_id,
    gen_random_uuid() AS denied_user_id,
    gen_random_uuid() AS denied_membership_id,
    gen_random_uuid() AS denied_session_id,
    sha256(convert_to(gen_random_uuid()::text, 'UTF8')) AS denied_token_hash;

SELECT
    session_id::text,
    request_id::text,
    denied_user_id::text,
    denied_membership_id::text,
    denied_session_id::text
FROM b5_sf_fixture
\gset b5_sf_

CREATE TEMP TABLE b5_sf_receipts (
    label text PRIMARY KEY,
    receipt jsonb NOT NULL
);

CREATE TEMP TABLE b5_sf_results (
    test_name text PRIMARY KEY,
    result text NOT NULL CHECK (result = 'PASS')
);

CREATE TEMP TABLE b5_sf_original_history AS
SELECT id
FROM app.subscription_suspensions
WHERE subscription_id =
    '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid;

INSERT INTO app.users (id, full_name, email, status)
SELECT
    denied_user_id,
    'Suspension Permission Test',
    'b5-suspend-' || denied_user_id::text || '@example.invalid',
    'active'
FROM b5_sf_fixture;

INSERT INTO app.tenant_memberships (
    id, tenant_id, user_id, status
)
SELECT
    denied_membership_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    denied_user_id,
    'active'
FROM b5_sf_fixture;

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
FROM b5_sf_fixture
UNION ALL
SELECT
    denied_session_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    denied_membership_id,
    denied_token_hash,
    CURRENT_TIMESTAMP + INTERVAL '1 hour'
FROM b5_sf_fixture;

GRANT SELECT ON b5_sf_fixture TO gympro_app;
GRANT INSERT ON b5_sf_receipts, b5_sf_results TO gympro_app;

CREATE FUNCTION pg_temp.b5_sf_rejected(
    p_name text,
    p_hash bytea,
    p_tenant uuid,
    p_reason text,
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
        FROM security.suspend_member_subscription(
            p_hash,
            p_tenant,
            '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid,
            p_reason,
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

        INSERT INTO b5_sf_results VALUES (p_name, 'PASS');
        RETURN;
    END;

    RAISE EXCEPTION 'Test %: request was unexpectedly accepted.', p_name;
END;
$$;

SET LOCAL ROLE gympro_app;

SELECT pg_temp.b5_sf_rejected(
    '01_unknown_session',
    decode(repeat('00', 32), 'hex'),
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    'Verification pause',
    gen_random_uuid(),
    '28000', 'Invalid or expired session'
);

SELECT pg_temp.b5_sf_rejected(
    '02_wrong_tenant',
    token_hash,
    'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc'::uuid,
    'Verification pause',
    gen_random_uuid(),
    '42501', 'Tenant access denied'
)
FROM b5_sf_fixture;

SELECT pg_temp.b5_sf_rejected(
    '03_missing_permission',
    denied_token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    'Verification pause',
    gen_random_uuid(),
    '42501', 'Membership management permission denied'
)
FROM b5_sf_fixture;

SELECT pg_temp.b5_sf_rejected(
    '04_blank_reason',
    token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    '   ',
    gen_random_uuid(),
    '22023', 'A suspension reason of 2 to 500 characters is required'
)
FROM b5_sf_fixture;

SELECT pg_temp.b5_sf_rejected(
    '05_long_reason',
    token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    repeat('A', 501),
    gen_random_uuid(),
    '22023', 'A suspension reason of 2 to 500 characters is required'
)
FROM b5_sf_fixture;

RESET ROLE;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM app.subscription_suspensions AS h
        WHERE h.subscription_id =
            '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
          AND NOT EXISTS (
              SELECT 1 FROM b5_sf_original_history AS o
              WHERE o.id = h.id
          )
    ) THEN
        RAISE EXCEPTION 'Rejected suspension created history.';
    END IF;

    INSERT INTO b5_sf_results
    VALUES ('06_rejections_created_no_history', 'PASS');
END;
$$;

SET LOCAL ROLE gympro_app;

INSERT INTO b5_sf_receipts (label, receipt)
SELECT 'first', to_jsonb(h)
FROM b5_sf_fixture AS f
CROSS JOIN LATERAL security.suspend_member_subscription(
    f.token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid,
    '  Verification pause  ',
    f.request_id
) AS h;

INSERT INTO b5_sf_receipts (label, receipt)
SELECT 'retry', to_jsonb(h)
FROM b5_sf_fixture AS f
CROSS JOIN LATERAL security.suspend_member_subscription(
    f.token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid,
    'Verification pause',
    f.request_id
) AS h;

SELECT pg_temp.b5_sf_rejected(
    '10_request_reuse_with_different_reason',
    token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    'Different reason',
    request_id,
    '22023', 'Request ID already belongs to another suspension request'
)
FROM b5_sf_fixture;

SELECT pg_temp.b5_sf_rejected(
    '11_second_suspension_request_rejected',
    token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    'Verification pause',
    gen_random_uuid(),
    '22023', 'Subscription is not eligible for suspension'
)
FROM b5_sf_fixture;

RESET ROLE;

DO $$
DECLARE
    v_first jsonb;
    v_retry jsonb;
BEGIN
    SELECT receipt INTO STRICT v_first
    FROM b5_sf_receipts WHERE label = 'first';

    SELECT receipt INTO STRICT v_retry
    FROM b5_sf_receipts WHERE label = 'retry';

    IF NOT EXISTS (
        SELECT 1
        FROM app.member_subscriptions AS s
        JOIN app.members AS m
          ON m.tenant_id = s.tenant_id AND m.id = s.member_id
        WHERE s.id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
          AND s.status = 'suspended'
          AND s.suspended_at = (v_first ->> 'suspended_at')::timestamptz
          AND m.status = 'active'
    )
    OR v_first ->> 'reason' <> 'Verification pause'
    OR v_first #>> '{previous_subscription_snapshot,status}' <> 'active'
    OR v_first #>> '{previous_subscription_snapshot,suspended_by_membership_id}'
        <> '3b318e89-f3bc-4ac5-a04d-09fdb3d626de' THEN
        RAISE EXCEPTION 'Suspension or audit snapshot is incorrect.';
    END IF;

    INSERT INTO b5_sf_results
    VALUES ('07_suspension_reason_and_actor_snapshot', 'PASS');

    IF NOT EXISTS (
        SELECT 1 FROM app.member_subscriptions
        WHERE id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
          AND starts_on =
              (v_first #>> '{previous_subscription_snapshot,starts_on}')::date
          AND ends_on =
              (v_first #>> '{previous_subscription_snapshot,ends_on}')::date
    ) THEN
        RAISE EXCEPTION 'Suspension changed membership dates.';
    END IF;

    INSERT INTO b5_sf_results
    VALUES ('08_membership_dates_preserved', 'PASS');

    IF v_first IS DISTINCT FROM v_retry
       OR (
           SELECT count(*)
           FROM app.subscription_suspensions AS h
           JOIN b5_sf_fixture AS f ON f.request_id = h.request_id
           WHERE h.tenant_id =
               'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid
       ) <> 1 THEN
        RAISE EXCEPTION 'Retry created another record or changed the receipt.';
    END IF;

    INSERT INTO b5_sf_results
    VALUES ('09_retry_returns_same_history_once', 'PASS');
END;
$$;

SELECT test_name, result
FROM b5_sf_results
ORDER BY test_name;

ROLLBACK;

SELECT
    CASE
        WHEN (
            SELECT to_jsonb(s)
            FROM app.member_subscriptions AS s
            WHERE id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
        ) = :'b5_sf_original_subscription'::jsonb
        AND (
            SELECT to_jsonb(m)
            FROM app.members AS m
            WHERE id = '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid
        ) = :'b5_sf_original_member'::jsonb
        AND NOT EXISTS (
            SELECT 1 FROM app.subscription_suspensions
            WHERE tenant_id =
                'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid
              AND request_id = :'b5_sf_request_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM security.tenant_sessions
            WHERE id IN (
                :'b5_sf_session_id'::uuid,
                :'b5_sf_denied_session_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.users
            WHERE id = :'b5_sf_denied_user_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.tenant_memberships
            WHERE id = :'b5_sf_denied_membership_id'::uuid
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS suspension_function_rollback_test;
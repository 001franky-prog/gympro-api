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

CREATE TEMP TABLE b5_ef_fixture AS
SELECT
    gen_random_uuid() AS active_member_id,
    gen_random_uuid() AS suspended_member_id,
    gen_random_uuid() AS active_subscription_id,
    gen_random_uuid() AS suspended_subscription_id,
    gen_random_uuid() AS session_id,
    sha256(convert_to(gen_random_uuid()::text, 'UTF8')) AS token_hash,
    gen_random_uuid() AS denied_user_id,
    gen_random_uuid() AS denied_membership_id,
    gen_random_uuid() AS denied_session_id,
    sha256(convert_to(gen_random_uuid()::text, 'UTF8')) AS denied_token_hash,
    (statement_timestamp() AT TIME ZONE 'Asia/Yangon')::date AS today;

SELECT
    active_member_id::text,
    suspended_member_id::text,
    active_subscription_id::text,
    suspended_subscription_id::text,
    session_id::text,
    denied_user_id::text,
    denied_membership_id::text,
    denied_session_id::text
FROM b5_ef_fixture
\gset b5_ef_

CREATE TEMP TABLE b5_ef_results (
    test_name text PRIMARY KEY,
    result text NOT NULL CHECK (result = 'PASS')
);

CREATE TEMP TABLE b5_ef_receipts (
    label text PRIMARY KEY,
    receipt jsonb NOT NULL
);

INSERT INTO app.members (id, tenant_id, full_name, email, status)
SELECT
    active_member_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    'Expiration Active Test',
    'b5-exp-' || active_member_id::text || '@example.invalid',
    'active'
FROM b5_ef_fixture
UNION ALL
SELECT
    suspended_member_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    'Expiration Blacklisted Test',
    'b5-exp-' || suspended_member_id::text || '@example.invalid',
    'blacklisted'
FROM b5_ef_fixture;

INSERT INTO app.member_subscriptions (
    id, tenant_id, member_id, plan_id, plan_price_id,
    duration_value, duration_unit, agreed_price_amount,
    status, starts_on, ends_on, activated_at, suspended_at
)
SELECT
    active_subscription_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    active_member_id,
    '838d86b2-9665-414d-865a-8f5fb559e39c'::uuid,
    'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid,
    1, 'months', 50000,
    'active', today - 30, today + 1,
    statement_timestamp() - INTERVAL '30 days',
    NULL::timestamptz
FROM b5_ef_fixture
UNION ALL
SELECT
    suspended_subscription_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    suspended_member_id,
    '838d86b2-9665-414d-865a-8f5fb559e39c'::uuid,
    'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid,
    1, 'months', 50000,
    'suspended', today - 30, today,
    statement_timestamp() - INTERVAL '30 days',
    statement_timestamp() - INTERVAL '1 day'
FROM b5_ef_fixture;

INSERT INTO app.users (id, full_name, email, status)
SELECT
    denied_user_id,
    'Expiration Permission Test',
    'b5-exp-user-' || denied_user_id::text || '@example.invalid',
    'active'
FROM b5_ef_fixture;

INSERT INTO app.tenant_memberships (id, tenant_id, user_id, status)
SELECT
    denied_membership_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    denied_user_id,
    'active'
FROM b5_ef_fixture;

INSERT INTO security.tenant_sessions (
    id, tenant_id, membership_id, session_token_hash, expires_at
)
SELECT
    session_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    '3b318e89-f3bc-4ac5-a04d-09fdb3d626de'::uuid,
    token_hash,
    CURRENT_TIMESTAMP + INTERVAL '1 hour'
FROM b5_ef_fixture
UNION ALL
SELECT
    denied_session_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    denied_membership_id,
    denied_token_hash,
    CURRENT_TIMESTAMP + INTERVAL '1 hour'
FROM b5_ef_fixture;

GRANT SELECT ON b5_ef_fixture TO gympro_app;
GRANT INSERT ON b5_ef_results, b5_ef_receipts TO gympro_app;

CREATE FUNCTION pg_temp.b5_ef_rejected(
    p_name text,
    p_hash bytea,
    p_tenant uuid,
    p_subscription uuid,
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
        FROM security.expire_member_subscription(
            p_hash, p_tenant, p_subscription
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

        INSERT INTO b5_ef_results VALUES (p_name, 'PASS');
        RETURN;
    END;

    RAISE EXCEPTION 'Test %: expiration was unexpectedly accepted.', p_name;
END;
$$;

SET LOCAL ROLE gympro_app;

SELECT pg_temp.b5_ef_rejected(
    '01_unknown_session',
    decode(repeat('00', 32), 'hex'),
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    active_subscription_id,
    '28000', 'Invalid or expired session'
)
FROM b5_ef_fixture;

SELECT pg_temp.b5_ef_rejected(
    '02_wrong_tenant',
    token_hash,
    'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc'::uuid,
    active_subscription_id,
    '42501', 'Tenant access denied'
)
FROM b5_ef_fixture;

SELECT pg_temp.b5_ef_rejected(
    '03_missing_permission',
    denied_token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    active_subscription_id,
    '42501', 'Membership management permission denied'
)
FROM b5_ef_fixture;

SELECT pg_temp.b5_ef_rejected(
    '04_future_end_date_rejected',
    token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    active_subscription_id,
    '22023', 'Subscription is not due for expiration'
)
FROM b5_ef_fixture;

RESET ROLE;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM app.subscription_expirations AS h
        JOIN b5_ef_fixture AS f
          ON h.subscription_id IN (
              f.active_subscription_id,
              f.suspended_subscription_id
          )
    ) THEN
        RAISE EXCEPTION 'Rejected expiration created history.';
    END IF;

    INSERT INTO b5_ef_results
    VALUES ('05_rejections_created_no_history', 'PASS');
END;
$$;

UPDATE app.member_subscriptions AS s
SET ends_on = f.today
FROM b5_ef_fixture AS f
WHERE s.id = f.active_subscription_id;

SET LOCAL ROLE gympro_app;

INSERT INTO b5_ef_receipts
SELECT 'active', to_jsonb(h)
FROM b5_ef_fixture AS f
CROSS JOIN LATERAL security.expire_member_subscription(
    f.token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    f.active_subscription_id
) AS h;

INSERT INTO b5_ef_receipts
SELECT 'retry', to_jsonb(h)
FROM b5_ef_fixture AS f
CROSS JOIN LATERAL security.expire_member_subscription(
    f.token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    f.active_subscription_id
) AS h;

INSERT INTO b5_ef_receipts
SELECT 'suspended', to_jsonb(h)
FROM b5_ef_fixture AS f
CROSS JOIN LATERAL security.expire_member_subscription(
    f.token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    f.suspended_subscription_id
) AS h;

RESET ROLE;

DO $$
DECLARE
    v_fixture record;
    v_active jsonb;
    v_retry jsonb;
    v_suspended jsonb;
BEGIN
    SELECT * INTO STRICT v_fixture FROM b5_ef_fixture;
    SELECT receipt INTO STRICT v_active
    FROM b5_ef_receipts WHERE label = 'active';
    SELECT receipt INTO STRICT v_retry
    FROM b5_ef_receipts WHERE label = 'retry';
    SELECT receipt INTO STRICT v_suspended
    FROM b5_ef_receipts WHERE label = 'suspended';

    IF NOT EXISTS (
        SELECT 1
        FROM app.member_subscriptions AS s
        JOIN app.members AS m ON m.id = s.member_id
        WHERE s.id = v_fixture.active_subscription_id
          AND s.status = 'expired'
          AND s.suspended_at IS NULL
          AND m.status = 'inactive'
          AND s.starts_on = v_fixture.today - 30
          AND s.ends_on = v_fixture.today
    ) THEN
        RAISE EXCEPTION 'Active subscription expiration failed.';
    END IF;

    INSERT INTO b5_ef_results
    VALUES ('06_active_expiration_and_member_inactivation', 'PASS');

    IF v_active IS DISTINCT FROM v_retry
       OR (
           SELECT count(*) FROM app.subscription_expirations
           WHERE subscription_id = v_fixture.active_subscription_id
       ) <> 1 THEN
        RAISE EXCEPTION 'Repeated expiration created another record.';
    END IF;

    INSERT INTO b5_ef_results
    VALUES ('07_retry_returns_original_receipt_once', 'PASS');

    IF NOT EXISTS (
        SELECT 1
        FROM app.member_subscriptions AS s
        JOIN app.members AS m ON m.id = s.member_id
        WHERE s.id = v_fixture.suspended_subscription_id
          AND s.status = 'expired'
          AND s.suspended_at IS NULL
          AND m.status = 'blacklisted'
          AND s.starts_on = v_fixture.today - 30
          AND s.ends_on = v_fixture.today
    )
    OR v_suspended #>> '{previous_subscription_snapshot,status}'
        <> 'suspended'
    OR v_suspended #>> '{previous_subscription_snapshot,suspended_at}'
        IS NULL THEN
        RAISE EXCEPTION 'Suspended expiration or blacklist preservation failed.';
    END IF;

    INSERT INTO b5_ef_results
    VALUES ('08_suspended_expiration_preserves_blacklist', 'PASS');

    IF (v_active ->> 'processed_on')::date <> v_fixture.today
       OR (v_active ->> 'coverage_ends_on')::date <> v_fixture.today
       OR v_active #>> '{previous_subscription_snapshot,expired_by_membership_id}'
           <> '3b318e89-f3bc-4ac5-a04d-09fdb3d626de' THEN
        RAISE EXCEPTION 'Server date or audit actor is incorrect.';
    END IF;

    INSERT INTO b5_ef_results
    VALUES ('09_server_date_and_audit_actor', 'PASS');
END;
$$;

SELECT test_name, result
FROM b5_ef_results
ORDER BY test_name;

ROLLBACK;

SELECT
    CASE
        WHEN NOT EXISTS (
            SELECT 1 FROM app.members
            WHERE id IN (
                :'b5_ef_active_member_id'::uuid,
                :'b5_ef_suspended_member_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.member_subscriptions
            WHERE id IN (
                :'b5_ef_active_subscription_id'::uuid,
                :'b5_ef_suspended_subscription_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.subscription_expirations
            WHERE subscription_id IN (
                :'b5_ef_active_subscription_id'::uuid,
                :'b5_ef_suspended_subscription_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM security.tenant_sessions
            WHERE id IN (
                :'b5_ef_session_id'::uuid,
                :'b5_ef_denied_session_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.users
            WHERE id = :'b5_ef_denied_user_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.tenant_memberships
            WHERE id = :'b5_ef_denied_membership_id'::uuid
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS expiration_function_rollback_test;
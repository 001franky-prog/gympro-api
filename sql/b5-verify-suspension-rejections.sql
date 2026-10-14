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
\gset b5_sr_

CREATE TEMP TABLE b5_sr_fixture AS
SELECT
    gen_random_uuid() AS session_id,
    gen_random_uuid() AS request_id,
    sha256(convert_to(gen_random_uuid()::text, 'UTF8')) AS token_hash;

SELECT session_id::text, request_id::text
FROM b5_sr_fixture
\gset b5_sr_

CREATE TEMP TABLE b5_sr_results (
    test_name text PRIMARY KEY,
    result text NOT NULL CHECK (result = 'PASS')
);

INSERT INTO security.tenant_sessions (
    id, tenant_id, membership_id,
    session_token_hash, expires_at, revoked_at
)
SELECT
    session_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    '3b318e89-f3bc-4ac5-a04d-09fdb3d626de'::uuid,
    token_hash,
    CURRENT_TIMESTAMP + INTERVAL '1 hour',
    CURRENT_TIMESTAMP
FROM b5_sr_fixture;

GRANT SELECT ON b5_sr_fixture TO gympro_app;
GRANT INSERT ON b5_sr_results TO gympro_app;

CREATE FUNCTION pg_temp.b5_sr_rejected(
    p_name text,
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
    SELECT * INTO STRICT v_fixture FROM b5_sr_fixture;

    BEGIN
        PERFORM *
        FROM security.suspend_member_subscription(
            v_fixture.token_hash,
            'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
            '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid,
            'Rejection verification',
            v_fixture.request_id
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

        INSERT INTO b5_sr_results VALUES (p_name, 'PASS');
        RETURN;
    END;

    RAISE EXCEPTION 'Test %: request was unexpectedly accepted.', p_name;
END;
$$;

SET LOCAL ROLE gympro_app;

SELECT pg_temp.b5_sr_rejected(
    '01_revoked_session',
    '28000',
    'Invalid or expired session'
);

RESET ROLE;

UPDATE security.tenant_sessions
SET
    revoked_at = NULL,
    created_at = CURRENT_TIMESTAMP - INTERVAL '2 hours',
    expires_at = CURRENT_TIMESTAMP - INTERVAL '1 hour'
WHERE id = :'b5_sr_session_id'::uuid;

SET LOCAL ROLE gympro_app;

SELECT pg_temp.b5_sr_rejected(
    '02_expired_session',
    '28000',
    'Invalid or expired session'
);

RESET ROLE;

UPDATE security.tenant_sessions
SET
    created_at = CURRENT_TIMESTAMP,
    expires_at = CURRENT_TIMESTAMP + INTERVAL '1 hour'
WHERE id = :'b5_sr_session_id'::uuid;

-- Elapsed dates must be rejected even if expiry processing
-- has not yet changed the stored status from active.
UPDATE app.member_subscriptions
SET
    starts_on =
        (statement_timestamp() AT TIME ZONE 'Asia/Yangon')::date - 30,
    ends_on =
        (statement_timestamp() AT TIME ZONE 'Asia/Yangon')::date,
    activated_at = statement_timestamp() - INTERVAL '30 days'
WHERE id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid;

SET LOCAL ROLE gympro_app;

SELECT pg_temp.b5_sr_rejected(
    '03_elapsed_active_subscription',
    '22023',
    'Subscription is not eligible for suspension'
);

RESET ROLE;

UPDATE app.member_subscriptions
SET status = 'expired'
WHERE id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid;

SET LOCAL ROLE gympro_app;

SELECT pg_temp.b5_sr_rejected(
    '04_expired_subscription',
    '22023',
    'Subscription is not eligible for suspension'
);

RESET ROLE;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM app.subscription_suspensions AS h
        JOIN b5_sr_fixture AS f ON f.request_id = h.request_id
        WHERE h.tenant_id =
            'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid
    ) THEN
        RAISE EXCEPTION 'Rejected request saved suspension history.';
    END IF;

    INSERT INTO b5_sr_results
    VALUES ('05_rejections_saved_no_history', 'PASS');
END;
$$;

SELECT test_name, result
FROM b5_sr_results
ORDER BY test_name;

ROLLBACK;

SELECT
    CASE
        WHEN (
            SELECT to_jsonb(s)
            FROM app.member_subscriptions AS s
            WHERE id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
        ) = :'b5_sr_original_subscription'::jsonb
        AND NOT EXISTS (
            SELECT 1 FROM security.tenant_sessions
            WHERE id = :'b5_sr_session_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.subscription_suspensions
            WHERE tenant_id =
                'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid
              AND request_id = :'b5_sr_request_id'::uuid
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS suspension_rejection_rollback_test;
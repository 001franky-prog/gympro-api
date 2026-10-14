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

SELECT
    to_jsonb(s)::text AS original_subscription,
    to_jsonb(m)::text AS original_member
FROM app.member_subscriptions AS s
JOIN app.members AS m
    ON m.tenant_id = s.tenant_id
   AND m.id = s.member_id
WHERE s.id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
\gset b5_rl_

CREATE TEMP TABLE b5_rl_fixture AS
SELECT
    gen_random_uuid() AS session_id,
    sha256(convert_to(gen_random_uuid()::text, 'UTF8')) AS token_hash,
    gen_random_uuid() AS request_id,
    (statement_timestamp() AT TIME ZONE 'Asia/Yangon')::date AS today;

SELECT
    session_id::text,
    request_id::text
FROM b5_rl_fixture
\gset b5_rl_

CREATE TEMP TABLE b5_rl_results (
    test_name text PRIMARY KEY,
    result text NOT NULL CHECK (result = 'PASS')
);

CREATE TEMP TABLE b5_rl_receipt (
    receipt jsonb NOT NULL
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
FROM b5_rl_fixture;

GRANT SELECT ON b5_rl_fixture TO gympro_app;
GRANT INSERT ON b5_rl_results, b5_rl_receipt TO gympro_app;

CREATE FUNCTION pg_temp.b5_rl_rejected(
    p_name text,
    p_hash bytea,
    p_price uuid,
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
            'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
            '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid,
            p_price,
            gen_random_uuid()
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

        INSERT INTO b5_rl_results VALUES (p_name, 'PASS');
        RETURN;
    END;

    RAISE EXCEPTION 'Test %: request was unexpectedly accepted.', p_name;
END;
$$;

CREATE TEMP TABLE b5_rl_original_history AS
SELECT id
FROM app.subscription_renewals
WHERE subscription_id =
    '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid;

UPDATE app.member_subscriptions
SET
    status = 'suspended',
    suspended_at = greatest(statement_timestamp(), activated_at)
WHERE id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid;

SET LOCAL ROLE gympro_app;

SELECT pg_temp.b5_rl_rejected(
    '01_suspended_subscription_rejected',
    token_hash,
    'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid,
    '22023',
    'Subscription is not eligible for renewal'
)
FROM b5_rl_fixture;

RESET ROLE;

UPDATE app.member_subscriptions
SET status = 'active', suspended_at = NULL
WHERE id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid;

UPDATE app.members
SET status = 'blacklisted'
WHERE id = '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid;

SET LOCAL ROLE gympro_app;

SELECT pg_temp.b5_rl_rejected(
    '02_blacklisted_member_rejected',
    token_hash,
    'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid,
    '22023',
    'Member is not eligible for renewal'
)
FROM b5_rl_fixture;

RESET ROLE;

UPDATE app.members
SET status = 'active'
WHERE id = '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid;

UPDATE security.tenant_sessions
SET revoked_at = CURRENT_TIMESTAMP
WHERE id = :'b5_rl_session_id'::uuid;

SET LOCAL ROLE gympro_app;

SELECT pg_temp.b5_rl_rejected(
    '03_revoked_session_rejected',
    token_hash,
    'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid,
    '28000',
    'Invalid or expired session'
)
FROM b5_rl_fixture;

RESET ROLE;

UPDATE security.tenant_sessions
SET
    revoked_at = NULL,
    created_at = CURRENT_TIMESTAMP - INTERVAL '2 hours',
    expires_at = CURRENT_TIMESTAMP - INTERVAL '1 hour'
WHERE id = :'b5_rl_session_id'::uuid;

SET LOCAL ROLE gympro_app;

SELECT pg_temp.b5_rl_rejected(
    '04_expired_session_rejected',
    token_hash,
    'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid,
    '28000',
    'Invalid or expired session'
)
FROM b5_rl_fixture;

RESET ROLE;

UPDATE security.tenant_sessions
SET
    created_at = CURRENT_TIMESTAMP,
    expires_at = CURRENT_TIMESTAMP + INTERVAL '1 hour'
WHERE id = :'b5_rl_session_id'::uuid;

SET LOCAL ROLE gympro_app;

SELECT pg_temp.b5_rl_rejected(
    '05_unknown_price_rejected',
    token_hash,
    gen_random_uuid(),
    '22023',
    'Active plan price not found'
)
FROM b5_rl_fixture;

RESET ROLE;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM app.subscription_renewals AS r
        WHERE r.subscription_id =
            '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
          AND NOT EXISTS (
              SELECT 1 FROM b5_rl_original_history AS o
              WHERE o.id = r.id
          )
    ) THEN
        RAISE EXCEPTION 'Rejected renewal created history.';
    END IF;

    INSERT INTO b5_rl_results
    VALUES ('06_rejected_requests_created_no_history', 'PASS');
END;
$$;

-- Simulate an expired membership with an inactive member.
UPDATE app.member_subscriptions
SET
    status = 'expired',
    starts_on = (
        (SELECT today FROM b5_rl_fixture) - INTERVAL '2 months'
    )::date,
    ends_on = (
        (SELECT today FROM b5_rl_fixture) - INTERVAL '1 month'
    )::date,
    activated_at = statement_timestamp() - INTERVAL '2 months'
WHERE id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid;

UPDATE app.members
SET status = 'inactive'
WHERE id = '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid;

SET LOCAL ROLE gympro_app;

INSERT INTO b5_rl_receipt (receipt)
SELECT to_jsonb(r)
FROM b5_rl_fixture AS f
CROSS JOIN LATERAL security.renew_member_subscription(
    f.token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid,
    'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid,
    f.request_id
) AS r;

RESET ROLE;

DO $$
DECLARE
    v_today date;
    v_receipt jsonb;
BEGIN
    SELECT today INTO STRICT v_today FROM b5_rl_fixture;
    SELECT receipt INTO STRICT v_receipt FROM b5_rl_receipt;

    IF NOT EXISTS (
        SELECT 1
        FROM app.member_subscriptions AS s
        JOIN app.members AS m
          ON m.tenant_id = s.tenant_id AND m.id = s.member_id
        WHERE s.id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
          AND s.status = 'active'
          AND m.status = 'active'
          AND s.starts_on = v_today
          AND s.ends_on = (v_today + INTERVAL '1 month')::date
    )
    OR (v_receipt ->> 'renewal_starts_on')::date <> v_today
    OR (v_receipt ->> 'previous_ends_on')::date <>
        (v_today - INTERVAL '1 month')::date
    OR v_receipt #>> '{previous_subscription_snapshot,status}'
        <> 'expired' THEN
        RAISE EXCEPTION 'Expired renewal did not restart correctly.';
    END IF;

    INSERT INTO b5_rl_results
    VALUES ('07_expired_membership_restarts_today', 'PASS');
END;
$$;

SELECT test_name, result
FROM b5_rl_results
ORDER BY test_name;

ROLLBACK;

SELECT
    CASE
        WHEN (
            SELECT to_jsonb(s)
            FROM app.member_subscriptions AS s
            WHERE id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
        ) = :'b5_rl_original_subscription'::jsonb
        AND (
            SELECT to_jsonb(m)
            FROM app.members AS m
            WHERE id = '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid
        ) = :'b5_rl_original_member'::jsonb
        AND NOT EXISTS (
            SELECT 1 FROM security.tenant_sessions
            WHERE id = :'b5_rl_session_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.subscription_renewals
            WHERE tenant_id =
                'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid
              AND request_id = :'b5_rl_request_id'::uuid
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS renewal_lifecycle_rollback_test;
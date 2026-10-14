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
\gset b5_es_

CREATE TEMP TABLE b5_es_fixture AS
SELECT
    gen_random_uuid() AS session_id,
    sha256(convert_to(gen_random_uuid()::text, 'UTF8')) AS token_hash;

SELECT session_id::text
FROM b5_es_fixture
\gset b5_es_

CREATE TEMP TABLE b5_es_results (
    test_name text PRIMARY KEY,
    result text NOT NULL CHECK (result = 'PASS')
);

CREATE TEMP TABLE b5_es_original_history AS
SELECT id
FROM app.subscription_expirations
WHERE subscription_id =
    '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid;

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
FROM b5_es_fixture;

GRANT SELECT ON b5_es_fixture TO gympro_app;
GRANT INSERT ON b5_es_results TO gympro_app;

CREATE FUNCTION pg_temp.b5_es_rejected(p_name text)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_hash bytea;
    v_rejected boolean := false;
    v_message text;
BEGIN
    SELECT token_hash INTO STRICT v_hash FROM b5_es_fixture;

    BEGIN
        PERFORM *
        FROM security.expire_member_subscription(
            v_hash,
            'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
            '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
        );
    EXCEPTION WHEN SQLSTATE '28000' THEN
        GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;

        IF v_message <> 'Invalid or expired session' THEN
            RAISE EXCEPTION 'Unexpected denial: %', v_message;
        END IF;

        v_rejected := true;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'Invalid session was accepted.';
    END IF;

    INSERT INTO b5_es_results VALUES (p_name, 'PASS');
END;
$$;

SET LOCAL ROLE gympro_app;

SELECT pg_temp.b5_es_rejected('01_revoked_session_rejected');

RESET ROLE;

UPDATE security.tenant_sessions
SET
    revoked_at = NULL,
    created_at = CURRENT_TIMESTAMP - INTERVAL '2 hours',
    expires_at = CURRENT_TIMESTAMP - INTERVAL '1 hour'
WHERE id = :'b5_es_session_id'::uuid;

SET LOCAL ROLE gympro_app;

SELECT pg_temp.b5_es_rejected('02_expired_session_rejected');

RESET ROLE;

SELECT test_name, result
FROM b5_es_results
ORDER BY test_name;

SELECT
    CASE
        WHEN (
            SELECT to_jsonb(s)
            FROM app.member_subscriptions AS s
            WHERE id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
        ) = :'b5_es_original_subscription'::jsonb
        AND NOT EXISTS (
            SELECT 1
            FROM app.subscription_expirations AS h
            WHERE h.subscription_id =
                '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
              AND NOT EXISTS (
                  SELECT 1 FROM b5_es_original_history AS o
                  WHERE o.id = h.id
              )
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS rejected_sessions_changed_nothing;

ROLLBACK;

SELECT
    CASE
        WHEN NOT EXISTS (
            SELECT 1 FROM security.tenant_sessions
            WHERE id = :'b5_es_session_id'::uuid
        )
        AND (
            SELECT to_jsonb(s)
            FROM app.member_subscriptions AS s
            WHERE id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
        ) = :'b5_es_original_subscription'::jsonb
        THEN 'PASS'
        ELSE 'FAIL'
    END AS expiration_session_rollback_test;
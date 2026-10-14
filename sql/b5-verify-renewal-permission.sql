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
\gset b5_rp_

CREATE TEMP TABLE b5_rp_fixture AS
SELECT
    gen_random_uuid() AS user_id,
    gen_random_uuid() AS membership_id,
    gen_random_uuid() AS session_id,
    gen_random_uuid() AS request_id,
    sha256(convert_to(gen_random_uuid()::text, 'UTF8')) AS token_hash;

SELECT
    user_id::text,
    membership_id::text,
    session_id::text,
    request_id::text
FROM b5_rp_fixture
\gset b5_rp_

CREATE TEMP TABLE b5_rp_results (
    test_name text PRIMARY KEY,
    result text NOT NULL CHECK (result = 'PASS')
);

INSERT INTO app.users (id, full_name, email, status)
SELECT
    user_id,
    'Renewal Permission Test',
    'b5-renew-' || user_id::text || '@example.invalid',
    'active'
FROM b5_rp_fixture;

INSERT INTO app.tenant_memberships (
    id, tenant_id, user_id, status
)
SELECT
    membership_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    user_id,
    'active'
FROM b5_rp_fixture;

INSERT INTO security.tenant_sessions (
    id, tenant_id, membership_id,
    session_token_hash, expires_at
)
SELECT
    session_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    membership_id,
    token_hash,
    CURRENT_TIMESTAMP + INTERVAL '1 hour'
FROM b5_rp_fixture;

GRANT SELECT ON b5_rp_fixture TO gympro_app;
GRANT INSERT ON b5_rp_results TO gympro_app;

SET LOCAL ROLE gympro_app;

DO $$
DECLARE
    v_fixture record;
    v_rejected boolean := false;
    v_message text;
BEGIN
    SELECT * INTO STRICT v_fixture FROM b5_rp_fixture;

    BEGIN
        PERFORM *
        FROM security.renew_member_subscription(
            v_fixture.token_hash,
            'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
            '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid,
            'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid,
            v_fixture.request_id
        );
    EXCEPTION WHEN SQLSTATE '42501' THEN
        GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;

        IF v_message <> 'Membership management permission denied' THEN
            RAISE EXCEPTION 'Unexpected denial: %', v_message;
        END IF;

        v_rejected := true;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'Renewal without permission was accepted.';
    END IF;

    INSERT INTO b5_rp_results
    VALUES ('01_missing_management_permission_rejected', 'PASS');
END;
$$;

RESET ROLE;

SELECT
    CASE
        WHEN (
            SELECT to_jsonb(s)
            FROM app.member_subscriptions AS s
            WHERE id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
        ) = :'b5_rp_original_subscription'::jsonb
        AND NOT EXISTS (
            SELECT 1 FROM app.subscription_renewals
            WHERE tenant_id =
                'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid
              AND request_id = :'b5_rp_request_id'::uuid
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS denied_renewal_changed_nothing;

SELECT test_name, result FROM b5_rp_results;

ROLLBACK;

SELECT
    CASE
        WHEN NOT EXISTS (
            SELECT 1 FROM app.users
            WHERE id = :'b5_rp_user_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.tenant_memberships
            WHERE id = :'b5_rp_membership_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM security.tenant_sessions
            WHERE id = :'b5_rp_session_id'::uuid
        )
        AND (
            SELECT to_jsonb(s)
            FROM app.member_subscriptions AS s
            WHERE id = '8a28fa97-e41f-4053-be61-8162ff3d387d'::uuid
        ) = :'b5_rp_original_subscription'::jsonb
        THEN 'PASS'
        ELSE 'FAIL'
    END AS permission_fixture_rollback_test;
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

CREATE TEMP TABLE b6_be_fixture AS
SELECT
    gen_random_uuid() AS member_id,
    gen_random_uuid() AS subscription_id,
    gen_random_uuid() AS session_id,
    sha256(convert_to(gen_random_uuid()::text, 'UTF8')) AS token_hash;

SELECT member_id::text, subscription_id::text, session_id::text
FROM b6_be_fixture
\gset b6_be_

CREATE TEMP TABLE b6_be_results (
    test_name text PRIMARY KEY,
    result text NOT NULL CHECK (result = 'PASS')
);

INSERT INTO app.members (id, tenant_id, full_name, email, status)
SELECT
    member_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    'B6 Blacklist Edge Test',
    'b6-edge-' || member_id::text || '@example.invalid',
    'active'
FROM b6_be_fixture;

INSERT INTO app.member_subscriptions (
    id, tenant_id, member_id, plan_id, plan_price_id,
    duration_value, duration_unit, agreed_price_amount,
    status, starts_on, ends_on, activated_at, suspended_at
)
SELECT
    subscription_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    member_id,
    '838d86b2-9665-414d-865a-8f5fb559e39c'::uuid,
    'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid,
    1, 'months', 50000,
    'suspended',
    (statement_timestamp() AT TIME ZONE 'Asia/Yangon')::date - 1,
    (statement_timestamp() AT TIME ZONE 'Asia/Yangon')::date + 29,
    statement_timestamp() - INTERVAL '1 day',
    statement_timestamp()
FROM b6_be_fixture;

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
FROM b6_be_fixture;

CREATE FUNCTION pg_temp.b6_be_call(
    p_action text,
    p_request uuid,
    p_expected_state text DEFAULT NULL,
    p_expected_message text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    f record;
    v_receipt jsonb;
    v_state text;
    v_message text;
BEGIN
    SELECT * INTO STRICT f FROM b6_be_fixture;

    BEGIN
        EXECUTE 'SET LOCAL ROLE gympro_app';

        SELECT to_jsonb(h) INTO STRICT v_receipt
        FROM security.change_member_blacklist(
            f.token_hash,
            'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
            f.member_id,
            p_action,
            'Edge verification',
            p_request
        ) AS h;

        EXECUTE 'RESET ROLE';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS
            v_state = RETURNED_SQLSTATE,
            v_message = MESSAGE_TEXT;

        EXECUTE 'RESET ROLE';

        IF p_expected_state IS NULL
           OR v_state <> p_expected_state
           OR v_message IS DISTINCT FROM p_expected_message THEN
            RAISE EXCEPTION 'Unexpected error %, %', v_state, v_message;
        END IF;

        RETURN NULL;
    END;

    IF p_expected_state IS NOT NULL THEN
        RAISE EXCEPTION 'Invalid request was accepted.';
    END IF;

    RETURN v_receipt;
END;
$$;

DO $$
BEGIN
    PERFORM pg_temp.b6_be_call(
        'blacklist', gen_random_uuid(),
        '28000', 'Invalid or expired session'
    );

    INSERT INTO b6_be_results
    VALUES ('01_revoked_session_rejected', 'PASS');
END;
$$;

UPDATE security.tenant_sessions
SET
    revoked_at = NULL,
    created_at = CURRENT_TIMESTAMP - INTERVAL '2 hours',
    expires_at = CURRENT_TIMESTAMP - INTERVAL '1 hour'
WHERE id = :'b6_be_session_id'::uuid;

DO $$
BEGIN
    PERFORM pg_temp.b6_be_call(
        'blacklist', gen_random_uuid(),
        '28000', 'Invalid or expired session'
    );

    INSERT INTO b6_be_results
    VALUES ('02_expired_session_rejected', 'PASS');
END;
$$;

UPDATE security.tenant_sessions
SET
    created_at = CURRENT_TIMESTAMP,
    expires_at = CURRENT_TIMESTAMP + INTERVAL '1 hour'
WHERE id = :'b6_be_session_id'::uuid;

DO $$
DECLARE
    f record;
    v_blacklist_request uuid := gen_random_uuid();
    v_removal_request uuid := gen_random_uuid();
    v_blacklist jsonb;
    v_removed jsonb;
    v_retry jsonb;
BEGIN
    SELECT * INTO STRICT f FROM b6_be_fixture;

    v_blacklist := pg_temp.b6_be_call(
        'blacklist', v_blacklist_request
    );

    v_removed := pg_temp.b6_be_call(
        'unblacklist', v_removal_request
    );

    IF v_removed ->> 'resulting_status' <> 'inactive'
       OR NOT EXISTS (
           SELECT 1 FROM app.members
           WHERE id = f.member_id AND status = 'inactive'
       ) THEN
        RAISE EXCEPTION 'Suspended coverage incorrectly restored active status.';
    END IF;

    INSERT INTO b6_be_results
    VALUES ('03_suspended_coverage_restores_inactive', 'PASS');

    v_retry := pg_temp.b6_be_call(
        'unblacklist', v_removal_request
    );

    IF v_retry IS DISTINCT FROM v_removed THEN
        RAISE EXCEPTION 'Removal retry changed its receipt.';
    END IF;

    INSERT INTO b6_be_results
    VALUES ('04_removal_retry_returns_original_receipt', 'PASS');

    v_retry := pg_temp.b6_be_call(
        'blacklist', v_blacklist_request
    );

    IF v_retry IS DISTINCT FROM v_blacklist
       OR NOT EXISTS (
           SELECT 1 FROM app.members
           WHERE id = f.member_id AND status = 'inactive'
       ) THEN
        RAISE EXCEPTION 'Old blacklist retry reapplied the blacklist.';
    END IF;

    INSERT INTO b6_be_results
    VALUES ('05_old_retry_does_not_reapply_blacklist', 'PASS');

    -- Elapsed coverage must not reactivate a member even when
    -- its stored subscription status still says active.
    UPDATE app.member_subscriptions
    SET
        status = 'active',
        suspended_at = NULL,
        starts_on =
            (statement_timestamp() AT TIME ZONE 'Asia/Yangon')::date - 30,
        ends_on =
            (statement_timestamp() AT TIME ZONE 'Asia/Yangon')::date
    WHERE id = f.subscription_id;

    PERFORM pg_temp.b6_be_call('blacklist', gen_random_uuid());

    v_removed := pg_temp.b6_be_call(
        'unblacklist', gen_random_uuid()
    );

    IF v_removed ->> 'resulting_status' <> 'inactive'
       OR NOT EXISTS (
           SELECT 1 FROM app.members
           WHERE id = f.member_id AND status = 'inactive'
       ) THEN
        RAISE EXCEPTION 'Elapsed coverage incorrectly restored active status.';
    END IF;

    INSERT INTO b6_be_results
    VALUES ('06_elapsed_coverage_restores_inactive', 'PASS');

    IF (
        SELECT count(*) FROM app.member_blacklist_events
        WHERE member_id = f.member_id
    ) <> 4 THEN
        RAISE EXCEPTION 'Retries created duplicate audit events.';
    END IF;

    INSERT INTO b6_be_results
    VALUES ('07_retries_created_no_duplicate_events', 'PASS');
END;
$$;

SELECT test_name, result
FROM b6_be_results
ORDER BY test_name;

ROLLBACK;

SELECT
    CASE
        WHEN NOT EXISTS (
            SELECT 1 FROM app.members
            WHERE id = :'b6_be_member_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.member_blacklist_events
            WHERE member_id = :'b6_be_member_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.member_subscriptions
            WHERE id = :'b6_be_subscription_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM security.tenant_sessions
            WHERE id = :'b6_be_session_id'::uuid
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS blacklist_edge_rollback_test;
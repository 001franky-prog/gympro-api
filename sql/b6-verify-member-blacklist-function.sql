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

CREATE TEMP TABLE b6_bf_fixture AS
SELECT
    gen_random_uuid() AS pending_member_id,
    gen_random_uuid() AS covered_member_id,
    gen_random_uuid() AS uncovered_member_id,
    gen_random_uuid() AS subscription_id,
    gen_random_uuid() AS session_id,
    sha256(convert_to(gen_random_uuid()::text, 'UTF8')) AS token_hash,
    gen_random_uuid() AS denied_user_id,
    gen_random_uuid() AS denied_membership_id,
    gen_random_uuid() AS denied_session_id,
    sha256(convert_to(gen_random_uuid()::text, 'UTF8')) AS denied_token_hash;

SELECT
    pending_member_id::text,
    covered_member_id::text,
    uncovered_member_id::text,
    subscription_id::text,
    session_id::text,
    denied_user_id::text,
    denied_membership_id::text,
    denied_session_id::text
FROM b6_bf_fixture
\gset b6_bf_

CREATE TEMP TABLE b6_bf_results (
    test_name text PRIMARY KEY,
    result text NOT NULL CHECK (result = 'PASS')
);

INSERT INTO app.members (id, tenant_id, full_name, email, status)
SELECT
    x.id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    x.name,
    'b6-blacklist-' || x.id::text || '@example.invalid',
    x.status
FROM b6_bf_fixture AS f
CROSS JOIN LATERAL (
    VALUES
        (f.pending_member_id, 'B6 Pending Test', 'pending'),
        (f.covered_member_id, 'B6 Covered Test', 'active'),
        (f.uncovered_member_id, 'B6 Uncovered Test', 'active')
) AS x(id, name, status);

INSERT INTO app.member_subscriptions (
    id, tenant_id, member_id, plan_id, plan_price_id,
    duration_value, duration_unit, agreed_price_amount,
    status, starts_on, ends_on, activated_at
)
SELECT
    subscription_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    covered_member_id,
    '838d86b2-9665-414d-865a-8f5fb559e39c'::uuid,
    'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid,
    1, 'months', 50000,
    'active',
    (statement_timestamp() AT TIME ZONE 'Asia/Yangon')::date,
    (
        (statement_timestamp() AT TIME ZONE 'Asia/Yangon')::date
        + INTERVAL '1 month'
    )::date,
    statement_timestamp()
FROM b6_bf_fixture;

CREATE TEMP TABLE b6_bf_subscription_before AS
SELECT to_jsonb(s) AS snapshot
FROM app.member_subscriptions AS s
JOIN b6_bf_fixture AS f ON f.subscription_id = s.id;

INSERT INTO app.users (id, full_name, email, status)
SELECT
    denied_user_id,
    'B6 Permission Test',
    'b6-user-' || denied_user_id::text || '@example.invalid',
    'active'
FROM b6_bf_fixture;

INSERT INTO app.tenant_memberships (id, tenant_id, user_id, status)
SELECT
    denied_membership_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    denied_user_id,
    'active'
FROM b6_bf_fixture;

INSERT INTO security.tenant_sessions (
    id, tenant_id, membership_id, session_token_hash, expires_at
)
SELECT
    session_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    '3b318e89-f3bc-4ac5-a04d-09fdb3d626de'::uuid,
    token_hash,
    CURRENT_TIMESTAMP + INTERVAL '1 hour'
FROM b6_bf_fixture
UNION ALL
SELECT
    denied_session_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    denied_membership_id,
    denied_token_hash,
    CURRENT_TIMESTAMP + INTERVAL '1 hour'
FROM b6_bf_fixture;

-- Calls the protected function as gympro_app, then restores
-- postgres before recording results in the temporary table.
CREATE FUNCTION pg_temp.b6_bf_call(
    p_name text,
    p_hash bytea,
    p_tenant uuid,
    p_member uuid,
    p_action text,
    p_reason text,
    p_request uuid,
    p_expected_state text DEFAULT NULL,
    p_expected_message text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
    v_receipt jsonb;
    v_state text;
    v_message text;
BEGIN
    BEGIN
        EXECUTE 'SET LOCAL ROLE gympro_app';

        SELECT to_jsonb(h) INTO STRICT v_receipt
        FROM security.change_member_blacklist(
            p_hash, p_tenant, p_member,
            p_action, p_reason, p_request
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
            RAISE EXCEPTION
                'Test %: unexpected error %, %',
                p_name, v_state, v_message;
        END IF;

        INSERT INTO b6_bf_results VALUES (p_name, 'PASS');
        RETURN NULL;
    END;

    IF p_expected_state IS NOT NULL THEN
        RAISE EXCEPTION 'Test %: request was unexpectedly accepted.', p_name;
    END IF;

    INSERT INTO b6_bf_results VALUES (p_name, 'PASS');
    RETURN v_receipt;
END;
$$;

DO $$
DECLARE
    f record;
    v_tenant uuid := 'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b';
    v_request uuid := gen_random_uuid();
    v_first jsonb;
    v_retry jsonb;
    v_removed jsonb;
BEGIN
    SELECT * INTO STRICT f FROM b6_bf_fixture;

    PERFORM pg_temp.b6_bf_call(
        '01_unknown_session',
        decode(repeat('00', 32), 'hex'),
        v_tenant, f.pending_member_id,
        'blacklist', 'Verification reason', gen_random_uuid(),
        '28000', 'Invalid or expired session'
    );

    PERFORM pg_temp.b6_bf_call(
        '02_wrong_tenant',
        f.token_hash,
        'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc'::uuid,
        f.pending_member_id,
        'blacklist', 'Verification reason', gen_random_uuid(),
        '42501', 'Tenant access denied'
    );

    PERFORM pg_temp.b6_bf_call(
        '03_missing_permission',
        f.denied_token_hash,
        v_tenant, f.pending_member_id,
        'blacklist', 'Verification reason', gen_random_uuid(),
        '42501', 'Member blacklist permission denied'
    );

    PERFORM pg_temp.b6_bf_call(
        '04_blank_reason',
        f.token_hash, v_tenant, f.pending_member_id,
        'blacklist', '   ', gen_random_uuid(),
        '22023', 'A blacklist reason of 2 to 500 characters is required'
    );

    PERFORM pg_temp.b6_bf_call(
        '05_invalid_action',
        f.token_hash, v_tenant, f.pending_member_id,
        'invalid', 'Verification reason', gen_random_uuid(),
        '22023', 'Valid member, action, and request ID are required'
    );

    v_first := pg_temp.b6_bf_call(
        '06_pending_member_blacklisted',
        f.token_hash, v_tenant, f.pending_member_id,
        'blacklist', '  Verification reason  ', v_request
    );

    IF v_first ->> 'reason' <> 'Verification reason'
       OR v_first ->> 'previous_status' <> 'pending'
       OR v_first ->> 'resulting_status' <> 'blacklisted'
       OR v_first #>> '{previous_member_snapshot,changed_by_membership_id}'
           <> '3b318e89-f3bc-4ac5-a04d-09fdb3d626de'
       OR NOT EXISTS (
           SELECT 1 FROM app.members
           WHERE id = f.pending_member_id AND status = 'blacklisted'
       ) THEN
        RAISE EXCEPTION 'Blacklist status or audit snapshot is incorrect.';
    END IF;

    v_retry := pg_temp.b6_bf_call(
        '07_retry_returns_original_receipt',
        f.token_hash, v_tenant, f.pending_member_id,
        'blacklist', 'Verification reason', v_request
    );

    IF v_first IS DISTINCT FROM v_retry
       OR (
           SELECT count(*) FROM app.member_blacklist_events
           WHERE tenant_id = v_tenant AND request_id = v_request
       ) <> 1 THEN
        RAISE EXCEPTION 'Retry created another event or changed the receipt.';
    END IF;

    PERFORM pg_temp.b6_bf_call(
        '08_request_reuse_conflict',
        f.token_hash, v_tenant, f.pending_member_id,
        'blacklist', 'Different reason', v_request,
        '22023', 'Request ID already belongs to another blacklist request'
    );

    PERFORM pg_temp.b6_bf_call(
        '09_second_blacklist_rejected',
        f.token_hash, v_tenant, f.pending_member_id,
        'blacklist', 'Verification reason', gen_random_uuid(),
        '22023', 'Member is already blacklisted'
    );

    v_removed := pg_temp.b6_bf_call(
        '10_pending_status_restored',
        f.token_hash, v_tenant, f.pending_member_id,
        'unblacklist', 'Verification removal', gen_random_uuid()
    );

    IF v_removed ->> 'resulting_status' <> 'pending'
       OR NOT EXISTS (
           SELECT 1 FROM app.members
           WHERE id = f.pending_member_id AND status = 'pending'
       ) THEN
        RAISE EXCEPTION 'Pending member status was not restored.';
    END IF;

    PERFORM pg_temp.b6_bf_call(
        '11_removal_without_blacklist_rejected',
        f.token_hash, v_tenant, f.pending_member_id,
        'unblacklist', 'Verification removal', gen_random_uuid(),
        '22023', 'Member is not blacklisted'
    );

    PERFORM pg_temp.b6_bf_call(
        '12_covered_member_blacklisted',
        f.token_hash, v_tenant, f.covered_member_id,
        'blacklist', 'Verification reason', gen_random_uuid()
    );

    v_removed := pg_temp.b6_bf_call(
        '13_active_coverage_restores_active_status',
        f.token_hash, v_tenant, f.covered_member_id,
        'unblacklist', 'Verification removal', gen_random_uuid()
    );

    IF v_removed ->> 'resulting_status' <> 'active'
       OR NOT EXISTS (
           SELECT 1 FROM app.members
           WHERE id = f.covered_member_id AND status = 'active'
       ) THEN
        RAISE EXCEPTION 'Valid active coverage did not restore active status.';
    END IF;

    PERFORM pg_temp.b6_bf_call(
        '14_uncovered_member_blacklisted',
        f.token_hash, v_tenant, f.uncovered_member_id,
        'blacklist', 'Verification reason', gen_random_uuid()
    );

    v_removed := pg_temp.b6_bf_call(
        '15_no_coverage_restores_inactive_status',
        f.token_hash, v_tenant, f.uncovered_member_id,
        'unblacklist', 'Verification removal', gen_random_uuid()
    );

    IF v_removed ->> 'resulting_status' <> 'inactive'
       OR NOT EXISTS (
           SELECT 1 FROM app.members
           WHERE id = f.uncovered_member_id AND status = 'inactive'
       ) THEN
        RAISE EXCEPTION 'Uncovered member was incorrectly activated.';
    END IF;
END;
$$;

DO $$
BEGIN
    IF (
        SELECT to_jsonb(s)
        FROM app.member_subscriptions AS s
        JOIN b6_bf_fixture AS f ON f.subscription_id = s.id
    ) IS DISTINCT FROM (
        SELECT snapshot FROM b6_bf_subscription_before
    ) THEN
        RAISE EXCEPTION 'Blacklist operations changed the subscription.';
    END IF;

    INSERT INTO b6_bf_results
    VALUES ('16_subscription_unchanged', 'PASS');
END;
$$;

SELECT test_name, result
FROM b6_bf_results
ORDER BY test_name;

ROLLBACK;

SELECT
    CASE
        WHEN NOT EXISTS (
            SELECT 1 FROM app.members
            WHERE id IN (
                :'b6_bf_pending_member_id'::uuid,
                :'b6_bf_covered_member_id'::uuid,
                :'b6_bf_uncovered_member_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.member_blacklist_events
            WHERE member_id IN (
                :'b6_bf_pending_member_id'::uuid,
                :'b6_bf_covered_member_id'::uuid,
                :'b6_bf_uncovered_member_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.member_subscriptions
            WHERE id = :'b6_bf_subscription_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM security.tenant_sessions
            WHERE id IN (
                :'b6_bf_session_id'::uuid,
                :'b6_bf_denied_session_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.users
            WHERE id = :'b6_bf_denied_user_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.tenant_memberships
            WHERE id = :'b6_bf_denied_membership_id'::uuid
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS blacklist_function_rollback_test;
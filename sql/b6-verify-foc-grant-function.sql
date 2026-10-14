\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

DO $$
BEGIN
    IF current_user <> 'postgres' THEN
        RAISE EXCEPTION 'Run verification as postgres.';
    END IF;

    IF security.has_tenant_permission(
        'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
        '3b318e89-f3bc-4ac5-a04d-09fdb3d626de'::uuid,
        'gym.memberships.grant_foc',
        NULL::uuid
    ) THEN
        RAISE EXCEPTION 'Demo administrator already has FOC permission.';
    END IF;
END;
$$;

CREATE TEMP TABLE b6_fg_fixture AS
SELECT
    gen_random_uuid() AS member_id,
    gen_random_uuid() AS branch_member_id,
    gen_random_uuid() AS plan_id,
    gen_random_uuid() AS price_id,
    gen_random_uuid() AS branch_price_id,
    gen_random_uuid() AS session_id,
    gen_random_uuid() AS request_id,
    gen_random_uuid() AS branch_request_id,
    sha256(convert_to(gen_random_uuid()::text, 'UTF8')) AS token_hash;

SELECT
    member_id::text,
    branch_member_id::text,
    plan_id::text,
    session_id::text,
    request_id::text,
    branch_request_id::text
FROM b6_fg_fixture
\gset b6_fg_

CREATE TEMP TABLE b6_fg_results (
    test_name text PRIMARY KEY,
    result text NOT NULL CHECK (result = 'PASS')
);

INSERT INTO app.members (
    id, tenant_id, branch_id, full_name, email, status
)
SELECT
    member_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    NULL::uuid,
    'B6 FOC General Test',
    'b6-foc-' || member_id::text || '@example.invalid',
    'pending'
FROM b6_fg_fixture
UNION ALL
SELECT
    branch_member_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    'fa534b44-c8c6-44f5-bcc3-3ed14ace6e2c'::uuid,
    'B6 FOC Branch Test',
    'b6-foc-' || branch_member_id::text || '@example.invalid',
    'pending'
FROM b6_fg_fixture;

INSERT INTO app.membership_plans (
    id, tenant_id, plan_code, plan_name,
    duration_value, duration_unit, status
)
SELECT
    plan_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    'FOC-' || left(plan_id::text, 8),
    'B6 FOC Verification Plan',
    1, 'months', 'active'
FROM b6_fg_fixture;

INSERT INTO app.plan_prices (
    id, tenant_id, plan_id, branch_id, price_amount, status
)
SELECT
    price_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    plan_id, NULL::uuid, 50000, 'active'
FROM b6_fg_fixture
UNION ALL
SELECT
    branch_price_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    plan_id,
    'fa534b44-c8c6-44f5-bcc3-3ed14ace6e2c'::uuid,
    45000, 'active'
FROM b6_fg_fixture;

INSERT INTO security.tenant_sessions (
    id, tenant_id, membership_id, session_token_hash, expires_at
)
SELECT
    session_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    '3b318e89-f3bc-4ac5-a04d-09fdb3d626de'::uuid,
    token_hash,
    CURRENT_TIMESTAMP + INTERVAL '1 hour'
FROM b6_fg_fixture;

CREATE FUNCTION pg_temp.b6_fg_call(
    p_name text,
    p_hash bytea,
    p_tenant uuid,
    p_member uuid,
    p_plan uuid,
    p_price uuid,
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
        FROM security.grant_foc_membership(
            p_hash, p_tenant, p_member, p_plan, p_price,
            p_reason, p_request
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

        INSERT INTO b6_fg_results VALUES (p_name, 'PASS');
        RETURN NULL;
    END;

    IF p_expected_state IS NOT NULL THEN
        RAISE EXCEPTION 'Test %: request was unexpectedly accepted.', p_name;
    END IF;

    INSERT INTO b6_fg_results VALUES (p_name, 'PASS');
    RETURN v_receipt;
END;
$$;

SELECT pg_temp.b6_fg_call(
    '01_management_permission_does_not_authorize_foc',
    token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    member_id, plan_id, price_id,
    'Verification reason', gen_random_uuid(),
    '42501', 'Complimentary membership permission denied'
)
FROM b6_fg_fixture;

-- Temporary assignment, visible only inside this transaction.
DO $$
DECLARE
    v_role uuid;
    v_permission uuid;
BEGIN
    SELECT ra.role_id INTO v_role
    FROM app.role_assignments AS ra
    JOIN app.roles AS r
      ON r.tenant_id = ra.tenant_id AND r.id = ra.role_id
    WHERE ra.tenant_id =
        'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid
      AND ra.membership_id =
        '3b318e89-f3bc-4ac5-a04d-09fdb3d626de'::uuid
      AND ra.scope_type = 'tenant'
      AND ra.branch_id IS NULL
      AND r.status = 'active'
    ORDER BY ra.id
    LIMIT 1;

    IF v_role IS NULL THEN
        RAISE EXCEPTION 'Active tenant-wide administrator role was not found.';
    END IF;

    SELECT id INTO STRICT v_permission
    FROM app.permissions
    WHERE permission_code = 'gym.memberships.grant_foc'
      AND is_active;

    INSERT INTO app.role_permissions (
        tenant_id, role_id, permission_id
    )
    VALUES (
        'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
        v_role,
        v_permission
    );

    IF NOT security.has_tenant_permission(
        'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
        '3b318e89-f3bc-4ac5-a04d-09fdb3d626de'::uuid,
        'gym.memberships.grant_foc',
        NULL::uuid
    ) THEN
        RAISE EXCEPTION 'Temporary FOC permission did not take effect.';
    END IF;
END;
$$;

DO $$
DECLARE
    f record;
    v_tenant uuid := 'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b';
BEGIN
    SELECT * INTO STRICT f FROM b6_fg_fixture;

    PERFORM pg_temp.b6_fg_call(
        '02_unknown_session',
        decode(repeat('00', 32), 'hex'),
        v_tenant, f.member_id, f.plan_id, f.price_id,
        'Verification reason', gen_random_uuid(),
        '28000', 'Invalid or expired session'
    );

    PERFORM pg_temp.b6_fg_call(
        '03_wrong_tenant',
        f.token_hash,
        'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc'::uuid,
        f.member_id, f.plan_id, f.price_id,
        'Verification reason', gen_random_uuid(),
        '42501', 'Tenant access denied'
    );

    PERFORM pg_temp.b6_fg_call(
        '04_blank_reason',
        f.token_hash, v_tenant, f.member_id, f.plan_id, f.price_id,
        '   ', gen_random_uuid(),
        '22023', 'An FOC reason of 2 to 500 characters is required'
    );

    UPDATE app.members SET status = 'blacklisted'
    WHERE id = f.member_id;

    PERFORM pg_temp.b6_fg_call(
        '05_blacklisted_member_rejected',
        f.token_hash, v_tenant, f.member_id, f.plan_id, f.price_id,
        'Verification reason', gen_random_uuid(),
        '22023', 'Member is not eligible for complimentary membership'
    );

    UPDATE app.members SET status = 'pending'
    WHERE id = f.member_id;

    UPDATE app.membership_plans SET status = 'inactive'
    WHERE id = f.plan_id;

    PERFORM pg_temp.b6_fg_call(
        '06_inactive_plan_rejected',
        f.token_hash, v_tenant, f.member_id, f.plan_id, f.price_id,
        'Verification reason', gen_random_uuid(),
        '22023', 'Active membership plan not found'
    );

    UPDATE app.membership_plans SET status = 'active'
    WHERE id = f.plan_id;

    UPDATE app.plan_prices SET status = 'inactive'
    WHERE id = f.price_id;

    PERFORM pg_temp.b6_fg_call(
        '07_inactive_price_rejected',
        f.token_hash, v_tenant, f.member_id, f.plan_id, f.price_id,
        'Verification reason', gen_random_uuid(),
        '22023', 'Active plan price not found'
    );

    UPDATE app.plan_prices SET status = 'active'
    WHERE id = f.price_id;

    PERFORM pg_temp.b6_fg_call(
        '08_branch_price_mismatch_rejected',
        f.token_hash, v_tenant, f.member_id, f.plan_id, f.branch_price_id,
        'Verification reason', gen_random_uuid(),
        '22023', 'Plan price does not apply to the member branch'
    );

    UPDATE security.tenant_sessions SET revoked_at = CURRENT_TIMESTAMP
    WHERE id = f.session_id;

    PERFORM pg_temp.b6_fg_call(
        '09_revoked_session_rejected',
        f.token_hash, v_tenant, f.member_id, f.plan_id, f.price_id,
        'Verification reason', gen_random_uuid(),
        '28000', 'Invalid or expired session'
    );

    UPDATE security.tenant_sessions
    SET
        revoked_at = NULL,
        created_at = CURRENT_TIMESTAMP - INTERVAL '2 hours',
        expires_at = CURRENT_TIMESTAMP - INTERVAL '1 hour'
    WHERE id = f.session_id;

    PERFORM pg_temp.b6_fg_call(
        '10_expired_session_rejected',
        f.token_hash, v_tenant, f.member_id, f.plan_id, f.price_id,
        'Verification reason', gen_random_uuid(),
        '28000', 'Invalid or expired session'
    );

    UPDATE security.tenant_sessions
    SET
        created_at = CURRENT_TIMESTAMP,
        expires_at = CURRENT_TIMESTAMP + INTERVAL '1 hour'
    WHERE id = f.session_id;

    IF EXISTS (
        SELECT 1 FROM app.member_subscriptions
        WHERE member_id IN (f.member_id, f.branch_member_id)
    ) THEN
        RAISE EXCEPTION 'Rejected FOC request created a subscription.';
    END IF;

    INSERT INTO b6_fg_results
    VALUES ('11_rejections_created_no_subscriptions', 'PASS');
END;
$$;

DO $$
DECLARE
    f record;
    v_tenant uuid := 'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b';
    v_first jsonb;
    v_retry jsonb;
    v_branch jsonb;
    v_message text;
    v_denied boolean := false;
    v_today date :=
        (statement_timestamp() AT TIME ZONE 'Asia/Yangon')::date;
BEGIN
    SELECT * INTO STRICT f FROM b6_fg_fixture;

    v_first := pg_temp.b6_fg_call(
        '12_general_foc_grant',
        f.token_hash, v_tenant, f.member_id, f.plan_id, f.price_id,
        '  Verification reason  ', f.request_id
    );

    v_retry := pg_temp.b6_fg_call(
        '13_retry_returns_original_receipt',
        f.token_hash, v_tenant, f.member_id, f.plan_id, f.price_id,
        'Verification reason', f.request_id
    );

    IF v_first IS DISTINCT FROM v_retry
       OR (v_first ->> 'listed_price_amount')::numeric <> 50000
       OR v_first ->> 'reason' <> 'Verification reason'
       OR v_first #>> '{previous_member_snapshot,granted_by_membership_id}'
           <> '3b318e89-f3bc-4ac5-a04d-09fdb3d626de'
       OR NOT EXISTS (
           SELECT 1
           FROM app.member_subscriptions AS s
           JOIN app.members AS m ON m.id = s.member_id
           WHERE s.id = (v_first ->> 'subscription_id')::uuid
             AND s.member_id = f.member_id
             AND s.membership_kind = 'foc'
             AND s.agreed_price_amount = 0
             AND s.status = 'active'
             AND m.status = 'active'
             AND s.starts_on = v_today
             AND s.ends_on = (v_today + INTERVAL '1 month')::date
       ) THEN
        RAISE EXCEPTION 'FOC subscription, receipt, or audit is incorrect.';
    END IF;

    INSERT INTO b6_fg_results
    VALUES ('14_zero_price_dates_and_audit_preserved', 'PASS');

    PERFORM pg_temp.b6_fg_call(
        '15_request_reuse_conflict',
        f.token_hash, v_tenant, f.member_id, f.plan_id, f.price_id,
        'Different reason', f.request_id,
        '22023', 'Request ID already belongs to another FOC request'
    );

    PERFORM pg_temp.b6_fg_call(
        '16_second_current_subscription_rejected',
        f.token_hash, v_tenant, f.member_id, f.plan_id, f.price_id,
        'Verification reason', gen_random_uuid(),
        '22023', 'Member already has a current subscription'
    );

    v_branch := pg_temp.b6_fg_call(
        '17_branch_foc_grant',
        f.token_hash, v_tenant, f.branch_member_id,
        f.plan_id, f.branch_price_id,
        'Branch verification', f.branch_request_id
    );

    IF (v_branch ->> 'listed_price_amount')::numeric <> 45000
       OR NOT EXISTS (
           SELECT 1 FROM app.member_subscriptions
           WHERE id = (v_branch ->> 'subscription_id')::uuid
             AND member_id = f.branch_member_id
             AND branch_id =
                 'fa534b44-c8c6-44f5-bcc3-3ed14ace6e2c'::uuid
             AND membership_kind = 'foc'
             AND agreed_price_amount = 0
       ) THEN
        RAISE EXCEPTION 'Branch FOC values are incorrect.';
    END IF;

    INSERT INTO b6_fg_results
    VALUES ('18_branch_and_listed_price_preserved', 'PASS');

    BEGIN
        EXECUTE 'SET LOCAL ROLE gympro_app';

        PERFORM *
        FROM security.renew_member_subscription(
            f.token_hash,
            v_tenant,
            (v_first ->> 'subscription_id')::uuid,
            f.price_id,
            gen_random_uuid()
        );

        EXECUTE 'RESET ROLE';
    EXCEPTION WHEN SQLSTATE '22023' THEN
        GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;
        EXECUTE 'RESET ROLE';

        IF v_message <>
            'FOC subscriptions require dedicated complimentary authorization' THEN
            RAISE EXCEPTION 'Unexpected renewal rejection: %', v_message;
        END IF;

        v_denied := true;
    END;

    IF NOT v_denied THEN
        RAISE EXCEPTION 'Ordinary renewal bypassed FOC protection.';
    END IF;

    INSERT INTO b6_fg_results
    VALUES ('19_ordinary_foc_renewal_rejected', 'PASS');

    IF (
        SELECT count(*) FROM app.member_subscriptions
        WHERE member_id IN (f.member_id, f.branch_member_id)
    ) <> 2
    OR (
        SELECT count(*)
        FROM app.subscription_foc_grants AS h
        JOIN app.member_subscriptions AS s
          ON s.tenant_id = h.tenant_id AND s.id = h.subscription_id
        WHERE s.member_id IN (f.member_id, f.branch_member_id)
    ) <> 2 THEN
        RAISE EXCEPTION 'Retries or rejected requests created extra records.';
    END IF;

    INSERT INTO b6_fg_results
    VALUES ('20_exactly_two_subscriptions_and_grants', 'PASS');
END;
$$;

SELECT test_name, result
FROM b6_fg_results
ORDER BY test_name;

ROLLBACK;

SELECT
    CASE
        WHEN NOT EXISTS (
            SELECT 1 FROM app.members
            WHERE id IN (
                :'b6_fg_member_id'::uuid,
                :'b6_fg_branch_member_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.member_subscriptions
            WHERE member_id IN (
                :'b6_fg_member_id'::uuid,
                :'b6_fg_branch_member_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.subscription_foc_grants
            WHERE request_id IN (
                :'b6_fg_request_id'::uuid,
                :'b6_fg_branch_request_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.membership_plans
            WHERE id = :'b6_fg_plan_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM security.tenant_sessions
            WHERE id = :'b6_fg_session_id'::uuid
        )
        AND NOT security.has_tenant_permission(
            'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
            '3b318e89-f3bc-4ac5-a04d-09fdb3d626de'::uuid,
            'gym.memberships.grant_foc',
            NULL::uuid
        )
        THEN 'PASS'
        ELSE 'FAIL'
    END AS foc_function_and_permission_rollback_test;
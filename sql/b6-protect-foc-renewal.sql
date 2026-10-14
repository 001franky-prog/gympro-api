\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

DO $$
DECLARE
    v_function oid;
    v_definition text;
    v_marker text :=
        '    -- A retry returns the original purchase record.';
    v_guard text := $guard$
    IF v_subscription.membership_kind <> 'standard' THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = 'FOC subscriptions require dedicated complimentary authorization';
    END IF;

$guard$;
    v_owner oid;
    v_acl aclitem[];
    v_config text[];
BEGIN
    IF current_database() <> 'gympro_saas'
       OR current_user <> 'postgres' THEN
        RAISE EXCEPTION 'Run installation in gympro_saas as postgres.';
    END IF;

    v_function := to_regprocedure(
        'security.renew_member_subscription(bytea,uuid,uuid,uuid,uuid)'
    );

    IF v_function IS NULL THEN
        RAISE EXCEPTION 'Required renewal function is missing.';
    END IF;

    SELECT
        pg_get_functiondef(oid),
        proowner,
        proacl,
        proconfig
    INTO v_definition, v_owner, v_acl, v_config
    FROM pg_proc
    WHERE oid = v_function;

    IF v_owner <> (
        SELECT oid FROM pg_roles
        WHERE rolname = 'gympro_membership_owner'
    ) THEN
        RAISE EXCEPTION 'Unexpected renewal function owner.';
    END IF;

    IF position(
        'FOC subscriptions require dedicated complimentary authorization'
        IN v_definition
    ) > 0 THEN
        RAISE EXCEPTION 'FOC renewal protection is already installed.';
    END IF;

    IF (
        length(v_definition)
        - length(replace(v_definition, v_marker, ''))
    ) <> length(v_marker) THEN
        RAISE EXCEPTION
            'Expected renewal insertion point was not found exactly once. Nothing changed.';
    END IF;

    -- Preserve the existing function and add only this guard.
    EXECUTE replace(
        v_definition,
        v_marker,
        v_guard || v_marker
    );

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc
        WHERE oid = v_function
          AND proowner = v_owner
          AND proacl IS NOT DISTINCT FROM v_acl
          AND proconfig IS NOT DISTINCT FROM v_config
          AND prosecdef
    ) THEN
        RAISE EXCEPTION 'Renewal security configuration changed unexpectedly.';
    END IF;
END;
$$;

SAVEPOINT foc_verification;

CREATE TEMP TABLE b6_fr_fixture AS
SELECT
    gen_random_uuid() AS foc_member,
    gen_random_uuid() AS standard_member,
    gen_random_uuid() AS foc_subscription,
    gen_random_uuid() AS standard_subscription,
    gen_random_uuid() AS session_id,
    sha256(convert_to(gen_random_uuid()::text, 'UTF8')) AS token_hash,
    (statement_timestamp() AT TIME ZONE 'Asia/Yangon')::date AS today;

CREATE TEMP TABLE b6_fr_results (
    test_name text PRIMARY KEY,
    result text NOT NULL CHECK (result = 'PASS')
);

INSERT INTO app.members (id, tenant_id, full_name, email, status)
SELECT
    x.id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    'B6 Renewal Guard Test',
    'b6-renew-guard-' || x.id::text || '@example.invalid',
    'active'
FROM b6_fr_fixture AS f
CROSS JOIN LATERAL (
    VALUES (f.foc_member), (f.standard_member)
) AS x(id);

INSERT INTO app.member_subscriptions (
    id, tenant_id, member_id, plan_id, plan_price_id,
    duration_value, duration_unit, agreed_price_amount,
    membership_kind, status, starts_on, ends_on, activated_at
)
SELECT
    x.subscription_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    x.member_id,
    '838d86b2-9665-414d-865a-8f5fb559e39c'::uuid,
    'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid,
    1, 'months', x.amount,
    x.kind, 'active', f.today,
    (f.today + INTERVAL '1 month')::date,
    statement_timestamp()
FROM b6_fr_fixture AS f
CROSS JOIN LATERAL (
    VALUES
        (f.foc_subscription, f.foc_member, 0, 'foc'),
        (f.standard_subscription, f.standard_member, 50000, 'standard')
) AS x(subscription_id, member_id, amount, kind);

INSERT INTO security.tenant_sessions (
    id, tenant_id, membership_id, session_token_hash, expires_at
)
SELECT
    session_id,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
    '3b318e89-f3bc-4ac5-a04d-09fdb3d626de'::uuid,
    token_hash,
    CURRENT_TIMESTAMP + INTERVAL '1 hour'
FROM b6_fr_fixture;

DO $$
DECLARE
    f record;
    v_message text;
    v_denied boolean := false;
    v_receipt jsonb;
BEGIN
    SELECT * INTO STRICT f FROM b6_fr_fixture;

    BEGIN
        EXECUTE 'SET LOCAL ROLE gympro_app';

        PERFORM *
        FROM security.renew_member_subscription(
            f.token_hash,
            'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
            f.foc_subscription,
            'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid,
            gen_random_uuid()
        );

        EXECUTE 'RESET ROLE';
    EXCEPTION WHEN SQLSTATE '22023' THEN
        GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;
        EXECUTE 'RESET ROLE';

        IF v_message <>
            'FOC subscriptions require dedicated complimentary authorization' THEN
            RAISE EXCEPTION 'Unexpected rejection: %', v_message;
        END IF;

        v_denied := true;
    END;

    IF NOT v_denied THEN
        RAISE EXCEPTION 'Ordinary renewal accepted an FOC subscription.';
    END IF;

    INSERT INTO b6_fr_results
    VALUES ('01_ordinary_foc_renewal_rejected', 'PASS');

    IF EXISTS (
        SELECT 1 FROM app.subscription_renewals
        WHERE subscription_id = f.foc_subscription
    )
    OR NOT EXISTS (
        SELECT 1 FROM app.member_subscriptions
        WHERE id = f.foc_subscription
          AND membership_kind = 'foc'
          AND agreed_price_amount = 0
          AND ends_on = (f.today + INTERVAL '1 month')::date
    ) THEN
        RAISE EXCEPTION 'Denied FOC renewal changed data.';
    END IF;

    INSERT INTO b6_fr_results
    VALUES ('02_denied_foc_renewal_changed_nothing', 'PASS');

    EXECUTE 'SET LOCAL ROLE gympro_app';

    SELECT to_jsonb(r) INTO STRICT v_receipt
    FROM security.renew_member_subscription(
        f.token_hash,
        'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid,
        f.standard_subscription,
        'f1017c52-3518-4e13-9fd8-f4cc647771b1'::uuid,
        gen_random_uuid()
    ) AS r;

    EXECUTE 'RESET ROLE';

    IF NOT EXISTS (
        SELECT 1 FROM app.member_subscriptions
        WHERE id = f.standard_subscription
          AND membership_kind = 'standard'
          AND status = 'active'
          AND agreed_price_amount = 50000
          AND ends_on = (
              (f.today + INTERVAL '1 month')::date
              + INTERVAL '1 month'
          )::date
    ) THEN
        RAISE EXCEPTION 'Standard renewal regression detected.';
    END IF;

    INSERT INTO b6_fr_results
    VALUES ('03_standard_renewal_still_works', 'PASS');
END;
$$;

SELECT test_name, result
FROM b6_fr_results
ORDER BY test_name;

ROLLBACK TO SAVEPOINT foc_verification;
RELEASE SAVEPOINT foc_verification;

COMMIT;

SELECT
    'renewal_guard_installed' AS check_name,
    position(
        'FOC subscriptions require dedicated complimentary authorization'
        IN p.prosrc
    ) > 0 AS passed
FROM pg_proc AS p
WHERE p.oid = to_regprocedure(
    'security.renew_member_subscription(bytea,uuid,uuid,uuid,uuid)'
)

UNION ALL

SELECT
    'verification_fixtures_removed',
    to_regclass('pg_temp.b6_fr_fixture') IS NULL;
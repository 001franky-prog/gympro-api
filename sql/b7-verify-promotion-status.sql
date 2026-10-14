\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

CREATE TEMP TABLE b7_status_context AS
SELECT
    gen_random_uuid() AS session_id,
    gen_random_uuid() AS role_id,
    gen_random_uuid() AS promotion_id,
    gen_random_uuid() AS ended_promotion_id,
    decode(
        md5(gen_random_uuid()::text) ||
        md5(gen_random_uuid()::text), 'hex'
    ) AS token_hash,
    'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid AS tenant_id,
    '3b318e89-f3bc-4ac5-a04d-09fdb3d626de'::uuid AS membership_id,
    'B7S_' || left(
        upper(replace(gen_random_uuid()::text, '-', '')), 20
    ) AS code;

CREATE TEMP TABLE b7_status_results (
    test_name text PRIMARY KEY,
    result text NOT NULL
);

INSERT INTO security.tenant_sessions (
    id, tenant_id, membership_id, session_token_hash, expires_at
)
SELECT session_id, tenant_id, membership_id,
       token_hash, CURRENT_TIMESTAMP + interval '30 minutes'
FROM b7_status_context;

INSERT INTO app.membership_promotions (
    id, tenant_id, promotion_code, promotion_name,
    discount_kind, discount_value, starts_on, ends_on
)
SELECT promotion_id, tenant_id, code, 'B7 status fixture',
       'percentage', 10,
       (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Yangon')::date,
       (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Yangon')::date + 30
FROM b7_status_context
UNION ALL
SELECT ended_promotion_id, tenant_id, code || '_E',
       'B7 ended fixture', 'percentage', 10,
       (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Yangon')::date - 30,
       (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Yangon')::date
FROM b7_status_context;

GRANT SELECT ON b7_status_context TO gympro_app;
GRANT SELECT, INSERT ON b7_status_results TO gympro_app;

SET LOCAL ROLE gympro_app;

DO $$
DECLARE
    v record;
    v_rejected boolean := false;
BEGIN
    SELECT * INTO v FROM pg_temp.b7_status_context;

    BEGIN
        PERFORM * FROM security.set_membership_promotion_status(
            v.token_hash, v.tenant_id, v.promotion_id, 'active'
        );
    EXCEPTION
        WHEN insufficient_privilege THEN
            IF SQLERRM <> 'Promotion management permission denied' THEN
                RAISE;
            END IF;
            v_rejected := true;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'Missing permission was not rejected.';
    END IF;

    INSERT INTO pg_temp.b7_status_results
    VALUES ('01_missing_permission_rejected', 'PASS');
END;
$$;

RESET ROLE;

INSERT INTO app.roles (
    id, tenant_id, role_code, role_name, is_system_role, status
)
SELECT role_id, tenant_id, code,
       'B7 temporary status role', false, 'active'
FROM b7_status_context;

INSERT INTO app.role_permissions (
    tenant_id, role_id, permission_id
)
SELECT c.tenant_id, c.role_id, p.id
FROM b7_status_context c
JOIN app.permissions p
    ON p.permission_code = 'gym.promotions.manage'
   AND p.is_active;

INSERT INTO app.role_assignments (
    tenant_id, membership_id, role_id, scope_type, branch_id
)
SELECT tenant_id, membership_id, role_id, 'tenant', NULL
FROM b7_status_context;

SET LOCAL ROLE gympro_app;

DO $$
DECLARE
    v record;
    v_first app.membership_promotions%ROWTYPE;
    v_repeat app.membership_promotions%ROWTYPE;
    v_case record;
    v_state text;
BEGIN
    SELECT * INTO v FROM pg_temp.b7_status_context;

    SELECT * INTO STRICT v_first
    FROM security.set_membership_promotion_status(
        v.token_hash, v.tenant_id, v.promotion_id, 'active'
    );

    IF v_first.status <> 'active'
       OR v_first.id <> v.promotion_id
       OR v_first.tenant_id <> v.tenant_id THEN
        RAISE EXCEPTION 'Activation result mismatch.';
    END IF;

    INSERT INTO pg_temp.b7_status_results
    VALUES ('02_draft_activated', 'PASS');

    SELECT * INTO STRICT v_repeat
    FROM security.set_membership_promotion_status(
        v.token_hash, v.tenant_id, v.promotion_id, 'active'
    );

    IF to_jsonb(v_first) IS DISTINCT FROM to_jsonb(v_repeat) THEN
        RAISE EXCEPTION 'Repeated activation changed the promotion.';
    END IF;

    INSERT INTO pg_temp.b7_status_results
    VALUES ('03_activation_retry_preserves_receipt', 'PASS');

    SELECT * INTO STRICT v_first
    FROM security.set_membership_promotion_status(
        v.token_hash, v.tenant_id, v.promotion_id, 'inactive'
    );

    IF v_first.status <> 'inactive' THEN
        RAISE EXCEPTION 'Deactivation failed.';
    END IF;

    INSERT INTO pg_temp.b7_status_results
    VALUES ('04_active_deactivated', 'PASS');

    SELECT * INTO STRICT v_repeat
    FROM security.set_membership_promotion_status(
        v.token_hash, v.tenant_id, v.promotion_id, 'inactive'
    );

    IF to_jsonb(v_first) IS DISTINCT FROM to_jsonb(v_repeat) THEN
        RAISE EXCEPTION 'Repeated deactivation changed the promotion.';
    END IF;

    INSERT INTO pg_temp.b7_status_results
    VALUES ('05_deactivation_retry_preserves_receipt', 'PASS');

    FOR v_case IN
        SELECT *
        FROM (VALUES
            ('06_unknown_session', 'session', '28000'),
            ('07_wrong_tenant', 'tenant', '42501'),
            ('08_unknown_promotion', 'unknown', '22023'),
            ('09_invalid_status', 'status', '22023'),
            ('10_ended_promotion', 'ended', '22023')
        ) AS cases(test_name, kind, expected_state)
    LOOP
        v_state := NULL;
        BEGIN
            PERFORM * FROM security.set_membership_promotion_status(
                CASE WHEN v_case.kind = 'session'
                     THEN decode(repeat('00', 32), 'hex')
                     ELSE v.token_hash END,
                CASE WHEN v_case.kind = 'tenant'
                     THEN 'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc'::uuid
                     ELSE v.tenant_id END,
                CASE WHEN v_case.kind = 'unknown' THEN gen_random_uuid()
                     WHEN v_case.kind = 'ended' THEN v.ended_promotion_id
                     ELSE v.promotion_id END,
                CASE WHEN v_case.kind = 'status'
                     THEN 'draft' ELSE 'active' END
            );
        EXCEPTION
            WHEN OTHERS THEN
                GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
        END;

        IF v_state IS DISTINCT FROM v_case.expected_state THEN
            RAISE EXCEPTION 'Test %: expected %, received %',
                v_case.test_name, v_case.expected_state, v_state;
        END IF;

        INSERT INTO pg_temp.b7_status_results
        VALUES (v_case.test_name, 'PASS');
    END LOOP;

    BEGIN
        UPDATE app.membership_promotions
        SET status = 'active'
        WHERE id = v.promotion_id;
        RAISE EXCEPTION 'Direct runtime UPDATE unexpectedly succeeded.';
    EXCEPTION
        WHEN insufficient_privilege THEN
            INSERT INTO pg_temp.b7_status_results
            VALUES ('11_direct_update_denied', 'PASS');
    END;
END;
$$;

RESET ROLE;

DO $$
DECLARE
    v record;
BEGIN
    SELECT * INTO v FROM pg_temp.b7_status_context;

    IF NOT EXISTS (
        SELECT 1 FROM app.membership_promotions
        WHERE id = v.promotion_id
          AND status = 'inactive'
          AND discount_value = 10
          AND discount_kind = 'percentage'
    ) OR NOT EXISTS (
        SELECT 1 FROM app.membership_promotions
        WHERE id = v.ended_promotion_id
          AND status = 'draft'
    ) THEN
        RAISE EXCEPTION 'Rejected requests changed promotion state.';
    END IF;

    INSERT INTO pg_temp.b7_status_results
    VALUES ('12_rejections_preserved_state_and_discount', 'PASS');
END;
$$;

SELECT test_name, result
FROM b7_status_results
ORDER BY test_name;

SELECT
    promotion_id::text AS promotion_id,
    ended_promotion_id::text AS ended_id,
    role_id::text AS role_id,
    session_id::text AS session_id
FROM b7_status_context
\gset b7s_

ROLLBACK;

SELECT
    'promotion_status_fixture_rollback' AS test_name,
    CASE WHEN
        NOT EXISTS (
            SELECT 1 FROM app.membership_promotions
            WHERE id IN (
                :'b7s_promotion_id'::uuid,
                :'b7s_ended_id'::uuid
            )
        )
        AND NOT EXISTS (
            SELECT 1 FROM app.roles
            WHERE id = :'b7s_role_id'::uuid
        )
        AND NOT EXISTS (
            SELECT 1 FROM security.tenant_sessions
            WHERE id = :'b7s_session_id'::uuid
        )
    THEN 'PASS' ELSE 'FAIL' END AS result;

\unset b7s_promotion_id
\unset b7s_ended_id
\unset b7s_role_id
\unset b7s_session_id
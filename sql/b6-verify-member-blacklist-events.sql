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
        SELECT 1 FROM app.members
        WHERE id = '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid
          AND tenant_id =
              'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid
          AND status = 'active'
    ) THEN
        RAISE EXCEPTION 'Expected active demo member.';
    END IF;
END;
$$;

SELECT to_jsonb(m)::text AS original_member
FROM app.members AS m
WHERE id = '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid
\gset b6_bh_

CREATE TEMP TABLE b6_bh_fixture AS
SELECT
    gen_random_uuid() AS event_id,
    gen_random_uuid() AS request_id;

SELECT event_id::text, request_id::text
FROM b6_bh_fixture
\gset b6_bh_

CREATE TEMP TABLE b6_bh_results (
    test_name text PRIMARY KEY,
    result text NOT NULL CHECK (result = 'PASS')
);

INSERT INTO app.member_blacklist_events (
    id, tenant_id, member_id, request_id,
    event_type, reason,
    previous_status, resulting_status,
    previous_member_snapshot
)
SELECT
    f.event_id,
    m.tenant_id,
    m.id,
    f.request_id,
    'blacklist',
    'Blacklist history verification',
    'active',
    'blacklisted',
    to_jsonb(m)
FROM app.members AS m
CROSS JOIN b6_bh_fixture AS f
WHERE m.id = '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM app.member_blacklist_events AS h
        JOIN b6_bh_fixture AS f ON f.event_id = h.id
        JOIN app.members AS m
          ON m.tenant_id = h.tenant_id AND m.id = h.member_id
        WHERE h.event_type = 'blacklist'
          AND h.previous_status = 'active'
          AND h.resulting_status = 'blacklisted'
          AND h.previous_member_snapshot = to_jsonb(m)
          AND isfinite(h.recorded_at)
          AND h.created_at IS NOT NULL
          AND m.status = 'active'
    ) THEN
        RAISE EXCEPTION 'Blacklist history defaults failed.';
    END IF;

    INSERT INTO b6_bh_results
    VALUES ('01_blacklist_history_defaults', 'PASS');
END;
$$;

-- Simulated removal history only; the real member remains active.
INSERT INTO app.member_blacklist_events (
    tenant_id, member_id, request_id,
    event_type, reason,
    previous_status, resulting_status,
    previous_member_snapshot
)
SELECT
    m.tenant_id,
    m.id,
    gen_random_uuid(),
    'unblacklist',
    'Blacklist removal history verification',
    'blacklisted',
    'inactive',
    to_jsonb(m) || jsonb_build_object('status', 'blacklisted')
FROM app.members AS m
WHERE m.id = '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid;

INSERT INTO b6_bh_results
VALUES ('02_valid_unblacklist_transition', 'PASS');

CREATE FUNCTION pg_temp.b6_bh_rejected(
    p_name text,
    p_changes jsonb,
    p_expected_state text,
    p_expected_constraint text
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_record app.member_blacklist_events%ROWTYPE;
    v_state text;
    v_constraint text;
BEGIN
    SELECT (
        jsonb_populate_record(
            NULL::app.member_blacklist_events,
            to_jsonb(h)
            || jsonb_build_object(
                'id', gen_random_uuid(),
                'request_id', gen_random_uuid()
            )
            || p_changes
        )
    ).*
    INTO STRICT v_record
    FROM app.member_blacklist_events AS h
    JOIN b6_bh_fixture AS f ON f.event_id = h.id;

    BEGIN
        INSERT INTO app.member_blacklist_events
        SELECT (v_record).*;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS
            v_state = RETURNED_SQLSTATE,
            v_constraint = CONSTRAINT_NAME;

        IF v_state <> p_expected_state
           OR v_constraint IS DISTINCT FROM p_expected_constraint THEN
            RAISE EXCEPTION
                'Test %: unexpected error %, constraint %',
                p_name, v_state, v_constraint;
        END IF;

        INSERT INTO b6_bh_results VALUES (p_name, 'PASS');
        RETURN;
    END;

    RAISE EXCEPTION 'Test %: invalid history was accepted.', p_name;
END;
$$;

SELECT pg_temp.b6_bh_rejected(
    '03_duplicate_request_rejected',
    jsonb_build_object(
        'request_id', (SELECT request_id FROM b6_bh_fixture)
    ),
    '23505', 'uq_member_blacklist_events_request'
);

SELECT pg_temp.b6_bh_rejected(
    '04_blank_reason_rejected',
    '{"reason": ""}'::jsonb,
    '23514', 'chk_member_blacklist_events_reason'
);

SELECT pg_temp.b6_bh_rejected(
    '05_padded_reason_rejected',
    '{"reason": "  Test reason  "}'::jsonb,
    '23514', 'chk_member_blacklist_events_reason'
);

SELECT pg_temp.b6_bh_rejected(
    '06_whitespace_reason_rejected',
    jsonb_build_object('reason', E'\t\t'),
    '23514', 'chk_member_blacklist_events_reason'
);

SELECT pg_temp.b6_bh_rejected(
    '07_invalid_blacklist_transition',
    '{"resulting_status": "active"}'::jsonb,
    '23514', 'chk_member_blacklist_events_transition'
);

SELECT pg_temp.b6_bh_rejected(
    '08_invalid_unblacklist_transition',
    '{"event_type": "unblacklist", "previous_status": "active", "resulting_status": "inactive"}'::jsonb,
    '23514', 'chk_member_blacklist_events_transition'
);

SELECT pg_temp.b6_bh_rejected(
    '09_empty_snapshot_rejected',
    '{"previous_member_snapshot": {}}'::jsonb,
    '23514', 'chk_member_blacklist_events_snapshot'
);

SELECT pg_temp.b6_bh_rejected(
    '10_array_snapshot_rejected',
    '{"previous_member_snapshot": []}'::jsonb,
    '23514', 'chk_member_blacklist_events_snapshot'
);

SELECT pg_temp.b6_bh_rejected(
    '11_infinite_timestamp_rejected',
    '{"recorded_at": "infinity"}'::jsonb,
    '23514', 'chk_member_blacklist_events_timestamp'
);

SELECT pg_temp.b6_bh_rejected(
    '12_unknown_member_rejected',
    jsonb_build_object('member_id', gen_random_uuid()),
    '23503', 'fk_member_blacklist_events_member'
);

DO $$
BEGIN
    IF has_table_privilege(
        'gympro_app', 'app.member_blacklist_events', 'SELECT'
    )
    OR has_table_privilege(
        'gympro_app', 'app.member_blacklist_events', 'INSERT'
    )
    OR has_table_privilege(
        'gympro_app', 'app.member_blacklist_events', 'UPDATE'
    )
    OR has_table_privilege(
        'gympro_app', 'app.member_blacklist_events', 'DELETE'
    ) THEN
        RAISE EXCEPTION 'Unexpected runtime history access.';
    END IF;

    INSERT INTO b6_bh_results
    VALUES ('13_runtime_history_access_denied', 'PASS');
END;
$$;

SELECT test_name, result
FROM b6_bh_results
ORDER BY test_name;

ROLLBACK;

SELECT
    CASE
        WHEN NOT EXISTS (
            SELECT 1 FROM app.member_blacklist_events
            WHERE id = :'b6_bh_event_id'::uuid
               OR (
                   tenant_id =
                       'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b'::uuid
                   AND request_id = :'b6_bh_request_id'::uuid
               )
        )
        AND (
            SELECT to_jsonb(m)
            FROM app.members AS m
            WHERE id = '3113ab9f-8edd-41f4-afe6-c8f03e291f89'::uuid
        ) = :'b6_bh_original_member'::jsonb
        THEN 'PASS'
        ELSE 'FAIL'
    END AS blacklist_history_rollback_test;
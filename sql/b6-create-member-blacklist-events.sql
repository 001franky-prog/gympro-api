\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

DO $$
BEGIN
    IF current_database() <> 'gympro_saas'
       OR current_user <> 'postgres' THEN
        RAISE EXCEPTION 'Run this migration in gympro_saas as postgres.';
    END IF;

    IF to_regclass('app.members') IS NULL THEN
        RAISE EXCEPTION 'Required member table is missing.';
    END IF;

    IF to_regclass('app.member_blacklist_events') IS NOT NULL THEN
        RAISE EXCEPTION
            'member_blacklist_events already exists. Inspect before retrying.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM app.permissions
        WHERE permission_code = 'gym.members.update'
          AND is_active
    ) THEN
        RAISE EXCEPTION 'Active gym.members.update permission is missing.';
    END IF;
END;
$$;

CREATE TABLE app.member_blacklist_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tenant_id uuid NOT NULL,
    member_id uuid NOT NULL,
    request_id uuid NOT NULL,

    event_type varchar(20) NOT NULL,
    reason varchar(500) NOT NULL,

    previous_status varchar(20) NOT NULL,
    resulting_status varchar(20) NOT NULL,

    previous_member_snapshot jsonb NOT NULL,

    recorded_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_member_blacklist_events_tenant_id
        UNIQUE (tenant_id, id),

    CONSTRAINT uq_member_blacklist_events_request
        UNIQUE (tenant_id, request_id),

    CONSTRAINT fk_member_blacklist_events_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES platform.tenants (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_member_blacklist_events_member
        FOREIGN KEY (tenant_id, member_id)
        REFERENCES app.members (tenant_id, id)
        ON DELETE RESTRICT,

    CONSTRAINT chk_member_blacklist_events_type
        CHECK (event_type IN ('blacklist', 'unblacklist')),

    CONSTRAINT chk_member_blacklist_events_reason
        CHECK (
            reason = btrim(reason)
            AND length(reason) BETWEEN 2 AND 500
            AND reason ~ '[^[:space:]]'
        ),

    CONSTRAINT chk_member_blacklist_events_previous_status
        CHECK (
            previous_status IN (
                'pending', 'active', 'inactive', 'blacklisted'
            )
        ),

    CONSTRAINT chk_member_blacklist_events_resulting_status
        CHECK (
            resulting_status IN (
                'pending', 'active', 'inactive', 'blacklisted'
            )
        ),

    CONSTRAINT chk_member_blacklist_events_transition
        CHECK (
            (
                event_type = 'blacklist'
                AND previous_status IN ('pending', 'active', 'inactive')
                AND resulting_status = 'blacklisted'
            )
            OR (
                event_type = 'unblacklist'
                AND previous_status = 'blacklisted'
                AND resulting_status IN ('pending', 'active', 'inactive')
            )
        ),

    CONSTRAINT chk_member_blacklist_events_snapshot
        CHECK (
            jsonb_typeof(previous_member_snapshot) = 'object'
            AND previous_member_snapshot <> '{}'::jsonb
        ),

    CONSTRAINT chk_member_blacklist_events_timestamp
        CHECK (isfinite(recorded_at))
);

CREATE INDEX idx_member_blacklist_events_member
    ON app.member_blacklist_events (
        tenant_id,
        member_id,
        recorded_at DESC
    );

ALTER TABLE app.member_blacklist_events
    ENABLE ROW LEVEL SECURITY;

ALTER TABLE app.member_blacklist_events
    FORCE ROW LEVEL SECURITY;

REVOKE ALL PRIVILEGES
    ON TABLE app.member_blacklist_events
    FROM PUBLIC, gympro_app;

COMMIT;

SELECT
    n.nspname AS schema_name,
    c.relname AS table_name,
    c.relrowsecurity AS rls_enabled,
    c.relforcerowsecurity AS rls_forced,
    has_table_privilege(
        'gympro_app', c.oid, 'SELECT'
    ) AS runtime_can_select,
    has_table_privilege(
        'gympro_app', c.oid, 'INSERT'
    ) AS runtime_can_insert,
    has_table_privilege(
        'gympro_app', c.oid, 'UPDATE'
    ) AS runtime_can_update,
    has_table_privilege(
        'gympro_app', c.oid, 'DELETE'
    ) AS runtime_can_delete
FROM pg_class AS c
JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE n.nspname = 'app'
  AND c.relname = 'member_blacklist_events';
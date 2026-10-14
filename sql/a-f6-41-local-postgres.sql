
-- GYM PRO SAAS
-- A-F6.41 - PostgreSQL Local Network Restriction
--
-- ONLY for an isolated local development instance.
-- Requires PostgreSQL administrator.
-- No session writes or application flags changed.

\set ON_ERROR_STOP on
\pset pager off

DO $check$
BEGIN
    IF current_database() <> 'gympro_saas'
       OR current_user <> 'postgres' THEN
        RAISE EXCEPTION
            'STOP: Expected gympro_saas as postgres';
    END IF;
END
$check$;

-- Show the configuration file and existing setting.
SHOW config_file;

SELECT
    name,
    setting,
    source,
    pending_restart
FROM pg_catalog.pg_settings
WHERE name = 'listen_addresses';

-- Configure loopback-only listening.
ALTER SYSTEM SET listen_addresses = 'localhost';

-- Reload configuration metadata.
-- A PostgreSQL service restart is still required.
SELECT pg_catalog.pg_reload_conf()
    AS configuration_reloaded;

-- Verify the pending configuration setting.
SELECT
    name,
    setting,
    source,
    pending_restart
FROM pg_catalog.pg_settings
WHERE name = 'listen_addresses';

SELECT
    'A-F6.41 CONFIGURATION COMMAND COMPLETED'
    AS result;

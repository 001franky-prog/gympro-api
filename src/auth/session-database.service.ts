import {
  Injectable,
  OnModuleInit,
  OnModuleDestroy,
  ServiceUnavailableException,
} from '@nestjs/common';

import { ConfigService } from '@nestjs/config';
import pg from 'pg';

import {
  isSessionPersistenceEnabled,
} from './session-security-policy.js';

const { Pool } = pg;

interface SessionDatabaseIdentity {
  database_name: string;
  database_user: string;
}

interface SessionPrivilegeResult {
  database_name: string;
  database_user: string;
  schema_found: boolean;
  function_found: boolean;
  table_found: boolean;
  can_use_security_schema: boolean | null;
  can_create_session: boolean | null;
  can_read_sessions: boolean | null;
  can_insert_sessions: boolean | null;
  can_update_sessions: boolean | null;
  can_delete_sessions: boolean | null;
}

interface CreatedSessionRecord {
  session_id: string;
}

/**
 * Gym Pro SaaS
 * Phase A - Session Database Service
 *
 * PostgreSQL role: gympro_session
 *
 * Security:
 * - Dedicated session connection.
 * - Database identity checked at startup.
 * - Function-only session creation privileges.
 * - No direct session table access.
 * - Session writes disabled by application policy.
 */

@Injectable()
export class SessionDatabaseService
  implements OnModuleInit, OnModuleDestroy
{
  private readonly pool: pg.Pool;

  constructor(
    private readonly configService: ConfigService,
  ) {
    const databaseUrl =
      this.configService.get<string>(
        'SESSION_DATABASE_URL',
      );

    if (!databaseUrl) {
      throw new Error(
        'SESSION_DATABASE_URL is not configured',
      );
    }

    this.pool = new Pool({
      connectionString: databaseUrl,
      max: 5,
      idleTimeoutMillis: 30000,
      connectionTimeoutMillis: 5000,
    });

    this.pool.on('error', () => {
      console.error('Session database pool error');
    });
  }

  async onModuleInit(): Promise<void> {
    const result =
      await this.pool.query<SessionDatabaseIdentity>(
        `
          SELECT
            current_database() AS database_name,
            current_user AS database_user
        `,
      );

    const identity = result.rows[0];

    if (
      result.rows.length !== 1 ||
      identity?.database_name !== 'gympro_saas' ||
      identity?.database_user !== 'gympro_session'
    ) {
      throw new Error(
        'Session database connection verification failed',
      );
    }
  }

  /**
   * Verify the current approved development
   * session database permission state.
   *
   * Expected:
   * - security schema usage: true
   * - create_tenant_session EXECUTE: true
   * - session table SELECT/INSERT/UPDATE/DELETE: false
   *
   * This method checks DB privileges, not whether
   * password authentication occurred.
   */
  async verifySessionPrivileges(): Promise<boolean> {
    const result =
      await this.pool.query<SessionPrivilegeResult>(
        `
          WITH protected_objects AS (
            SELECT
              n.oid AS schema_oid,
              (
                SELECT p.oid
                FROM pg_catalog.pg_proc AS p
                WHERE p.pronamespace = n.oid
                  AND p.proname = 'create_tenant_session'
                  AND p.pronargs = 2
                  AND p.proargtypes[0] =
                      'pg_catalog.uuid'::regtype
                  AND p.proargtypes[1] =
                      'pg_catalog.bytea'::regtype
                LIMIT 1
              ) AS function_oid,
              (
                SELECT c.oid
                FROM pg_catalog.pg_class AS c
                WHERE c.relnamespace = n.oid
                  AND c.relname = 'tenant_sessions'
                  AND c.relkind IN ('r', 'p')
                LIMIT 1
              ) AS table_oid
            FROM pg_catalog.pg_namespace AS n
            WHERE n.nspname = 'security'
          )
          SELECT
            current_database() AS database_name,
            current_user AS database_user,
            po.schema_oid IS NOT NULL AS schema_found,
            po.function_oid IS NOT NULL AS function_found,
            po.table_oid IS NOT NULL AS table_found,

            pg_catalog.has_schema_privilege(
              current_user,
              po.schema_oid,
              'USAGE'
            ) AS can_use_security_schema,

            pg_catalog.has_function_privilege(
              current_user,
              po.function_oid,
              'EXECUTE'
            ) AS can_create_session,

            pg_catalog.has_table_privilege(
              current_user,
              po.table_oid,
              'SELECT'
            ) AS can_read_sessions,

            pg_catalog.has_table_privilege(
              current_user,
              po.table_oid,
              'INSERT'
            ) AS can_insert_sessions,

            pg_catalog.has_table_privilege(
              current_user,
              po.table_oid,
              'UPDATE'
            ) AS can_update_sessions,

            pg_catalog.has_table_privilege(
              current_user,
              po.table_oid,
              'DELETE'
            ) AS can_delete_sessions
          FROM protected_objects AS po
        `,
      );

    const row = result.rows[0];

    if (
      result.rows.length !== 1 ||
      !row
    ) {
      return false;
    }

    return (
      row.database_name === 'gympro_saas' &&
      row.database_user === 'gympro_session' &&
      row.schema_found === true &&
      row.function_found === true &&
      row.table_found === true &&
      row.can_use_security_schema === true &&
      row.can_create_session === true &&
      row.can_read_sessions === false &&
      row.can_insert_sessions === false &&
      row.can_update_sessions === false &&
      row.can_delete_sessions === false
    );
  }

  /**
   * Create a session only when the application
   * security policy has been approved and enabled.
   *
   * IMPORTANT:
   * Passing a membership ID is not password proof.
   * The trusted issuance boundary must be tested
   * before changing the security policy.
   */
  async createTenantSession(
    membershipId: string,
    tokenHash: Buffer,
  ): Promise<string> {
    const unavailable = () =>
      new ServiceUnavailableException(
        'Session database writes are not enabled',
      );

    const uuidPattern =
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

    if (
      typeof membershipId !== 'string' ||
      !uuidPattern.test(membershipId) ||
      !Buffer.isBuffer(tokenHash) ||
      tokenHash.length !== 32
    ) {
      throw unavailable();
    }

    if (!isSessionPersistenceEnabled()) {
      throw unavailable();
    }

    if (!(await this.verifySessionPrivileges())) {
      throw unavailable();
    }

    const result =
      await this.pool.query<CreatedSessionRecord>(
        `
          SELECT
            security.create_tenant_session(
              $1::uuid,
              $2::bytea
            ) AS session_id
        `,
        [membershipId, tokenHash],
      );

    const sessionId = result.rows[0]?.session_id;

    if (
      result.rows.length !== 1 ||
      typeof sessionId !== 'string' ||
      !uuidPattern.test(sessionId)
    ) {
      throw unavailable();
    }

    return sessionId;
  }

  async onModuleDestroy(): Promise<void> {
    await this.pool.end();
  }
}
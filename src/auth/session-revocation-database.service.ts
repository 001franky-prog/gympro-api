import {
  Injectable,
  OnModuleDestroy,
  OnModuleInit,
} from '@nestjs/common';

import { ConfigService } from '@nestjs/config';
import pg from 'pg';

const { Pool } = pg;

interface DatabaseIdentity {
  database_name: string;
  database_user: string;
}

interface RevocationResult {
  revoked: boolean;
}

/**
 * Gym Pro SaaS
 * Phase A â€” Session Revocation Database Service
 *
 * Uses dedicated gympro_auth database credentials.
 *
 * Security:
 * - Validates session UUID and token hash.
 * - Calls only the protected revocation function.
 * - Uses parameterized SQL.
 * - Does not accept passwords or raw bearer tokens.
 * - Does not grant direct session-table access.
 * - Does not create authentication sessions.
 *
 * Call only after an authenticated session guard
 * has established the actual session identity.
 */
@Injectable()
export class SessionRevocationDatabaseService
  implements OnModuleInit, OnModuleDestroy
{
  private readonly pool: pg.Pool;

  private readonly uuidPattern =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

  constructor(
    private readonly configService: ConfigService,
  ) {
    const databaseUrl =
      this.configService.get<string>(
        'AUTH_DATABASE_URL',
      );

    if (!databaseUrl) {
      throw new Error(
        'AUTH_DATABASE_URL is not configured',
      );
    }

    this.pool = new Pool({
      connectionString: databaseUrl,
      max: 5,
      idleTimeoutMillis: 30000,
      connectionTimeoutMillis: 5000,
    });

    this.pool.on('error', () => {
      console.error(
        'Session revocation database pool error',
      );
    });
  }

  /**
   * Fail application startup if the wrong database
   * or an unexpectedly privileged account is used.
   */
  async onModuleInit(): Promise<void> {
    const result =
      await this.pool.query<DatabaseIdentity>(
        `
          SELECT
            current_database() AS database_name,
            current_user AS database_user
        `,
      );

    if (
      result.rows.length !== 1 ||
      result.rows[0]?.database_name !== 'gympro_saas' ||
      result.rows[0]?.database_user !== 'gympro_auth'
    ) {
      throw new Error(
        'Session revocation database identity verification failed',
      );
    }
  }

  /**
   * Revoke the exact authenticated session.
   *
   * Input must originate from:
   * - Verified session ID returned by PostgreSQL.
   * - SHA-256 hash of the presented bearer token.
   *
   * Returns:
   * true  -> matching session was newly revoked.
   * false -> invalid input, missing session,
   *          wrong hash, or previously revoked.
   *
   * Database operational errors propagate.
   * They must not be treated as successful logout.
   */
  async revokeSession(
    sessionId: string,
    tokenHash: Buffer,
  ): Promise<boolean> {
    if (
      typeof sessionId !== 'string' ||
      !this.uuidPattern.test(sessionId) ||
      !Buffer.isBuffer(tokenHash) ||
      tokenHash.length !== 32
    ) {
      return false;
    }

    const result =
      await this.pool.query<RevocationResult>(
        `
          SELECT
            security.revoke_tenant_session(
              $1::uuid,
              $2::bytea
            ) AS revoked
        `,
        [sessionId, tokenHash],
      );

    if (
      result.rows.length !== 1 ||
      typeof result.rows[0]?.revoked !== 'boolean'
    ) {
      throw new Error(
        'Invalid session revocation database response',
      );
    }

    return result.rows[0].revoked;
  }

  async onModuleDestroy(): Promise<void> {
    await this.pool.end();
  }
}
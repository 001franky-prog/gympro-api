
import {
  Injectable,
  OnModuleInit,
  OnModuleDestroy,
} from '@nestjs/common';

import { ConfigService } from '@nestjs/config';
import pg from 'pg';

const { Pool } = pg;

/**
 * Gym Pro SaaS
 * Phase A — Authentication Database Service
 *
 * UUID validation is module-scoped rather than
 * instance-scoped so it is available to methods
 * even when unit tests mock service instances
 * without invoking the normal constructor.
 *
 * Standard PostgreSQL UUID structure:
 * 8-4-4-4-12
 */
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface UserCredentialRecord {
  user_id: string;
  account_status: string;
  password_hash: string | null;
}

interface SessionVerificationRecord {
  session_id: string;
  tenant_id: string;
  membership_id: string;
  user_id: string;
}

export interface VerifiedTenantSession {
  readonly sessionId: string;
  readonly tenantId: string;
  readonly membershipId: string;
  readonly userId: string;
}

/**
 * Gym Pro SaaS
 * Authentication Database Service
 *
 * Database role: gympro_auth
 *
 * Responsibilities:
 * 1. Verify the database connection identity.
 * 2. Retrieve protected user credentials.
 * 3. Verify active tenant membership.
 * 4. Revalidate session identity.
 * 5. Verify database-backed bearer-token sessions.
 *
 * Does not create or revoke sessions.
 */
@Injectable()
export class AuthDatabaseService
  implements OnModuleInit, OnModuleDestroy
{
  private readonly pool: pg.Pool;

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
        'Authentication database pool error',
      );
    });
  }

  /**
   * Verify connection identity during startup.
   */
  async onModuleInit(): Promise<void> {
    const result = await this.pool.query<{
      database_name: string;
      database_user: string;
    }>(
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
        'Authentication database connection verification failed',
      );
    }
  }

  /**
   * Retrieve protected credentials.
   *
   * The password hash must never be returned
   * in an HTTP response or application log.
   */
  async findUserCredentials(
    email: string,
  ): Promise<UserCredentialRecord | null> {
    if (typeof email !== 'string') {
      return null;
    }

    const normalizedEmail =
      email.trim().toLowerCase();

    if (
      !normalizedEmail ||
      normalizedEmail.length > 255
    ) {
      return null;
    }

    const result =
      await this.pool.query<UserCredentialRecord>(
        `
          SELECT
            user_id,
            account_status,
            password_hash
          FROM security.get_user_credentials(
            $1::text
          )
        `,
        [normalizedEmail],
      );

    return result.rows[0] ?? null;
  }

  /**
   * Check the active user-to-tenant membership.
   *
   * This is a membership authorization check,
   * not independent password authentication.
   */
  async verifyActiveTenantMembership(
    userId: string,
    tenantId: string,
  ): Promise<string | null> {
    if (
      typeof userId !== 'string' ||
      typeof tenantId !== 'string' ||
      !UUID_PATTERN.test(userId) ||
      !UUID_PATTERN.test(tenantId)
    ) {
      return null;
    }

    const result = await this.pool.query<{
      membership_id: string | null;
    }>(
      `
        SELECT
          security.get_active_tenant_membership(
            $1::uuid,
            $2::uuid
          ) AS membership_id
      `,
      [userId, tenantId],
    );

    return result.rows[0]?.membership_id ?? null;
  }

  /**
   * Confirm that the supplied membership is
   * still the user's active membership in
   * the requested tenant.
   *
   * Runtime validation must work independently
   * of whether the class constructor was used
   * to create a test instance.
   */
  async revalidateSessionIdentity(
    userId: string,
    tenantId: string,
    membershipId: string,
  ): Promise<boolean> {
    if (
      typeof userId !== 'string' ||
      typeof tenantId !== 'string' ||
      typeof membershipId !== 'string' ||
      !UUID_PATTERN.test(userId) ||
      !UUID_PATTERN.test(tenantId) ||
      !UUID_PATTERN.test(membershipId)
    ) {
      return false;
    }

    const activeMembershipId =
      await this.verifyActiveTenantMembership(
        userId,
        tenantId,
      );

    if (!activeMembershipId) {
      return false;
    }

    return (
      activeMembershipId.toLowerCase() ===
      membershipId.toLowerCase()
    );
  }

  /**
   * Verify a SHA-256 bearer-token hash.
   *
   * PostgreSQL checks:
   * - Session existence
   * - Expiration
   * - Revocation
   * - Active user
   * - Active tenant membership
   * - Active tenant
   *
   * Returns null when the session is unknown.
   * Operational database errors propagate.
   */
  async verifySessionTokenHash(
    tokenHash: Buffer,
  ): Promise<VerifiedTenantSession | null> {
    if (
      !Buffer.isBuffer(tokenHash) ||
      tokenHash.length !== 32
    ) {
      return null;
    }

    const result =
      await this.pool.query<SessionVerificationRecord>(
        `
          SELECT
            session_id,
            tenant_id,
            membership_id,
            user_id
          FROM security.verify_tenant_session(
            $1::bytea
          )
        `,
        [tokenHash],
      );

    if (result.rows.length === 0) {
      return null;
    }

    if (result.rows.length !== 1) {
      throw new Error(
        'Unexpected session verification result',
      );
    }

    const row = result.rows[0];

    if (
      !row ||
      typeof row.session_id !== 'string' ||
      typeof row.tenant_id !== 'string' ||
      typeof row.membership_id !== 'string' ||
      typeof row.user_id !== 'string' ||
      !UUID_PATTERN.test(row.session_id) ||
      !UUID_PATTERN.test(row.tenant_id) ||
      !UUID_PATTERN.test(row.membership_id) ||
      !UUID_PATTERN.test(row.user_id)
    ) {
      throw new Error(
        'Invalid session verification result',
      );
    }

    return {
      sessionId: row.session_id,
      tenantId: row.tenant_id,
      membershipId: row.membership_id,
      userId: row.user_id,
    };
  }

  async onModuleDestroy(): Promise<void> {
    await this.pool.end();
  }
}

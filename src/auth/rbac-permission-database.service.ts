
import {
  Injectable,
  OnModuleDestroy,
  OnModuleInit,
} from '@nestjs/common';

import {
  ConfigService,
} from '@nestjs/config';

import pg from 'pg';

const { Pool } = pg;

export interface RbacPermissionRequest {
  readonly tenantId: string;
  readonly membershipId: string;
  readonly permissionCode: string;
  readonly branchId?: string | null;
}

interface PermissionResult {
  allowed: boolean;
}

interface DatabaseIdentity {
  database_name: string;
  database_user: string;
}

/**
 * Gym Pro SaaS
 * Phase A - RBAC Permission Database Service
 *
 * PostgreSQL account: gympro_auth
 *
 * Security:
 * - Validate request identifiers.
 * - Call only the approved RBAC function.
 * - Use parameterized SQL.
 * - Deny invalid request data.
 * - Propagate database operational failures.
 * - Never expose direct RBAC table queries.
 * - Never create authentication sessions.
 */

@Injectable()
export class RbacPermissionDatabaseService
  implements OnModuleInit, OnModuleDestroy
{
  private readonly pool: pg.Pool;

  // Standard UUID: 8-4-4-4-12.
  private readonly uuidPattern =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

  private readonly permissionPattern =
    /^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/;

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
      console.error('RBAC database pool error');
    });
  }

  async onModuleInit(): Promise<void> {
    const result =
      await this.pool.query<DatabaseIdentity>(
        `
          SELECT
            current_database() AS database_name,
            current_user AS database_user
        `,
      );

    const row = result.rows[0];

    if (
      result.rows.length !== 1 ||
      row?.database_name !== 'gympro_saas' ||
      row?.database_user !== 'gympro_auth'
    ) {
      throw new Error(
        'RBAC database identity verification failed',
      );
    }
  }

  async hasTenantPermission(
    request: RbacPermissionRequest,
  ): Promise<boolean> {
    if (
      !request ||
      typeof request !== 'object'
    ) {
      return false;
    }

    const {
      tenantId,
      membershipId,
      permissionCode,
      branchId = null,
    } = request;

    if (
      typeof tenantId !== 'string' ||
      !this.uuidPattern.test(tenantId) ||
      typeof membershipId !== 'string' ||
      !this.uuidPattern.test(membershipId)
    ) {
      return false;
    }

    if (
      typeof permissionCode !== 'string' ||
      permissionCode.length === 0 ||
      permissionCode.length > 128 ||
      !this.permissionPattern.test(permissionCode)
    ) {
      return false;
    }

    if (
      branchId !== null &&
      (
        typeof branchId !== 'string' ||
        !this.uuidPattern.test(branchId)
      )
    ) {
      return false;
    }

    const result =
      await this.pool.query<PermissionResult>(
        `
          SELECT
            security.has_tenant_permission(
              $1::uuid,
              $2::uuid,
              $3::text,
              $4::uuid
            ) AS allowed
        `,
        [
          tenantId,
          membershipId,
          permissionCode,
          branchId,
        ],
      );

    if (
      result.rows.length !== 1 ||
      typeof result.rows[0]?.allowed !== 'boolean'
    ) {
      throw new Error(
        'Invalid RBAC database response',
      );
    }

    return result.rows[0].allowed;
  }

  async onModuleDestroy(): Promise<void> {
    await this.pool.end();
  }
}

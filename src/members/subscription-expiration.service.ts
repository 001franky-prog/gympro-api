import {
  BadRequestException,
  ForbiddenException,
  Injectable,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';

import type {
  OnModuleDestroy,
  OnModuleInit,
} from '@nestjs/common';

import { ConfigService } from '@nestjs/config';
import pg from 'pg';

import {
  SessionBearerTokenService,
} from '../auth/session-bearer-token.service.js';

import type {
  GymProAuthenticatedRequest,
} from '../auth/authenticated-session.guard.js';

import type {
  SubscriptionExpiration,
} from './subscription-expiration.js';

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface RuntimeIdentity {
  database_name: string;
  database_user: string;
  is_superuser: boolean;
  bypasses_rls: boolean;
  schema_usage: boolean;
  can_execute: boolean;
  history_select: boolean;
  history_insert: boolean;
  history_update: boolean;
  history_delete: boolean;
  subscription_select: boolean;
  subscription_insert: boolean;
  subscription_update: boolean;
  subscription_delete: boolean;
}

interface ExpirationRow {
  id: string;
  tenant_id: string;
  subscription_id: string;
  coverage_starts_on: string;
  coverage_ends_on: string;
  processed_on: string;
  expired_at: Date;
  created_at: Date;
}

@Injectable()
export class SubscriptionExpirationService
  implements OnModuleInit, OnModuleDestroy
{
  private readonly pool: pg.Pool;
  private runtimeVerified = false;

  constructor(
    config: ConfigService,
    private readonly bearerTokenService: SessionBearerTokenService,
  ) {
    const databaseUrl = config.get<string>('DATABASE_URL');

    if (!databaseUrl) {
      throw new Error('DATABASE_URL is required');
    }

    this.pool = new pg.Pool({
      connectionString: databaseUrl,
      max: 5,
      idleTimeoutMillis: 30000,
      connectionTimeoutMillis: 5000,
    });

    this.pool.on('error', () => {
      console.error('Subscription expiration database pool error');
    });
  }

  async onModuleInit(): Promise<void> {
    this.runtimeVerified = false;

    let result: pg.QueryResult<RuntimeIdentity>;

    try {
      result = await this.pool.query<RuntimeIdentity>(`
        SELECT
          current_database() AS database_name,
          current_user AS database_user,
          r.rolsuper AS is_superuser,
          r.rolbypassrls AS bypasses_rls,
          has_schema_privilege(
            current_user, 'security', 'USAGE'
          ) AS schema_usage,
          has_function_privilege(
            current_user,
            to_regprocedure(
              'security.expire_member_subscription(bytea,uuid,uuid)'
            ),
            'EXECUTE'
          ) AND has_function_privilege(current_user,
            to_regprocedure('security.expire_branch_member_subscription(bytea,uuid,uuid,uuid)'), 'EXECUTE'
          ) AS can_execute,
          has_table_privilege(
            current_user, 'app.subscription_expirations', 'SELECT'
          ) AS history_select,
          has_table_privilege(
            current_user, 'app.subscription_expirations', 'INSERT'
          ) AS history_insert,
          has_table_privilege(
            current_user, 'app.subscription_expirations', 'UPDATE'
          ) AS history_update,
          has_table_privilege(
            current_user, 'app.subscription_expirations', 'DELETE'
          ) AS history_delete,
          has_table_privilege(
            current_user, 'app.member_subscriptions', 'SELECT'
          ) AS subscription_select,
          has_table_privilege(
            current_user, 'app.member_subscriptions', 'INSERT'
          ) AS subscription_insert,
          has_table_privilege(
            current_user, 'app.member_subscriptions', 'UPDATE'
          ) AS subscription_update,
          has_table_privilege(
            current_user, 'app.member_subscriptions', 'DELETE'
          ) AS subscription_delete
        FROM pg_roles AS r
        WHERE r.rolname = current_user
      `);
    } catch {
      throw new Error(
        'Subscription expiration database verification unavailable',
      );
    }

    const row = result.rows[0];

    if (
      result.rows.length !== 1 ||
      !row ||
      row.database_name !== 'gympro_saas' ||
      row.database_user !== 'gympro_app' ||
      row.is_superuser !== false ||
      row.bypasses_rls !== false ||
      row.schema_usage !== true ||
      row.can_execute !== true ||
      row.history_select !== false ||
      row.history_insert !== false ||
      row.history_update !== false ||
      row.history_delete !== false ||
      row.subscription_select !== false ||
      row.subscription_insert !== false ||
      row.subscription_update !== false ||
      row.subscription_delete !== false
    ) {
      throw new Error(
        'Subscription expiration requires gympro_app connected to gympro_saas with function-only subscription access',
      );
    }

    this.runtimeVerified = true;
  }

  async expire(
    request: GymProAuthenticatedRequest,
    tenantId: string,
    subscriptionId: string,
    body: unknown,
    expectedBranchId: string | null = null,
  ): Promise<SubscriptionExpiration> {
    const session = request.gymproSession;

    if (
      !session ||
      !this.isUuid(session.sessionId) ||
      !this.isUuid(session.tenantId) ||
      !this.isUuid(session.membershipId) ||
      !this.isUuid(session.userId)
    ) {
      throw new UnauthorizedException('Invalid or expired session');
    }

    if (!this.isUuid(tenantId) || !this.isUuid(subscriptionId)) {
      throw new BadRequestException(
        'Invalid tenant or subscription identifier',
      );
    }

    if (!this.sameUuid(session.tenantId, tenantId)) {
      throw new ForbiddenException('Tenant access denied');
    }

    if (!this.runtimeVerified) {
      throw new ServiceUnavailableException(
        'Subscription expiration unavailable',
      );
    }

    if (expectedBranchId !== null && !this.isUuid(expectedBranchId)) {
      throw new BadRequestException('Invalid branch identifier');
    }

    this.validateBody(body);

    const tokenHash = this.bearerTokenService.hashAuthorization(
      request.headers?.authorization,
    );

    if (!Buffer.isBuffer(tokenHash) || tokenHash.length !== 32) {
      throw new UnauthorizedException('Invalid or expired session');
    }

    let result: pg.QueryResult<ExpirationRow>;

    try {
      result = await this.pool.query<ExpirationRow>(
        `
          SELECT
            id,
            tenant_id,
            subscription_id,
            coverage_starts_on::text AS coverage_starts_on,
            coverage_ends_on::text AS coverage_ends_on,
            processed_on::text AS processed_on,
            expired_at,
            created_at
          FROM ${expectedBranchId === null ? `security.expire_member_subscription($1::bytea, $2::uuid, $3::uuid)` : `security.expire_branch_member_subscription($1::bytea, $2::uuid, $3::uuid, $4::uuid)`}
        `,
        expectedBranchId === null
          ? [tokenHash, tenantId, subscriptionId]
          : [tokenHash, tenantId, expectedBranchId, subscriptionId],
      );
    } catch (error: unknown) {
      this.throwDatabaseError(error);
    }

    const row = result.rows[0];

    if (
      result.rows.length !== 1 ||
      !row ||
      !this.isUuid(row.id) ||
      !this.sameUuid(row.tenant_id, tenantId) ||
      !this.sameUuid(row.subscription_id, subscriptionId) ||
      !this.isCalendarDate(row.coverage_starts_on) ||
      !this.isCalendarDate(row.coverage_ends_on) ||
      !this.isCalendarDate(row.processed_on) ||
      row.coverage_ends_on <= row.coverage_starts_on ||
      row.processed_on < row.coverage_ends_on ||
      !this.isValidDate(row.expired_at) ||
      !this.isValidDate(row.created_at)
    ) {
      throw new ServiceUnavailableException(
        'Subscription expiration unavailable',
      );
    }

    return Object.freeze({
      id: row.id,
      tenantId: row.tenant_id,
      subscriptionId: row.subscription_id,
      coverageStartsOn: row.coverage_starts_on,
      coverageEndsOn: row.coverage_ends_on,
      processedOn: row.processed_on,
      expiredAt: row.expired_at,
      createdAt: row.created_at,
    });
  }

  async onModuleDestroy(): Promise<void> {
    this.runtimeVerified = false;
    await this.pool.end();
  }

  private validateBody(body: unknown): void {
    if (body === undefined) {
      return;
    }

    if (
      typeof body !== 'object' ||
      body === null ||
      Array.isArray(body) ||
      Object.keys(body).length !== 0
    ) {
      throw new BadRequestException(
        'Expiration accepts an empty request body only',
      );
    }
  }

  private isUuid(value: unknown): value is string {
    return typeof value === 'string' && UUID_PATTERN.test(value);
  }

  private sameUuid(value: unknown, expected: string): boolean {
    return this.isUuid(value) &&
      value.toLowerCase() === expected.toLowerCase();
  }

  private isValidDate(value: unknown): value is Date {
    return value instanceof Date && Number.isFinite(value.getTime());
  }

  private isCalendarDate(value: unknown): value is string {
    if (
      typeof value !== 'string' ||
      !/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(value)
    ) {
      return false;
    }

    const date = new Date(`${value}T00:00:00.000Z`);

    return Number.isFinite(date.getTime()) &&
      date.toISOString().slice(0, 10) === value;
  }

  private throwDatabaseError(error: unknown): never {
    const databaseError =
      typeof error === 'object' && error !== null
        ? error as { code?: unknown; message?: unknown }
        : {};

    if (
      databaseError.code === '28000' &&
      databaseError.message === 'Invalid or expired session'
    ) {
      throw new UnauthorizedException('Invalid or expired session');
    }

    if (
      databaseError.code === '42501' &&
      (
        databaseError.message === 'Tenant access denied' ||
        databaseError.message === 'Subscription access denied' ||
        databaseError.message === 'Member access denied' ||
        databaseError.message === 'Branch access denied' ||
        databaseError.message ===
          'Membership management permission denied'
      )
    ) {
      throw new ForbiddenException('Membership expiration access denied');
    }

    if (databaseError.code === '22023') {
      throw new BadRequestException(
        'Invalid membership expiration request',
      );
    }

    throw new ServiceUnavailableException(
      'Subscription expiration unavailable',
    );
  }
}

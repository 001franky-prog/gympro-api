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
  SubscriptionSuspension,
  SuspendMemberSubscriptionInput,
} from './subscription-suspension.js';

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

interface SuspensionRow {
  id: string;
  tenant_id: string;
  subscription_id: string;
  request_id: string;
  reason: string;
  suspended_at: Date;
  created_at: Date;
}

@Injectable()
export class SubscriptionSuspensionService
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
      console.error('Subscription suspension database pool error');
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
              'security.suspend_member_subscription(bytea,uuid,uuid,text,uuid)'
            ),
            'EXECUTE'
          ) AND has_function_privilege(
            current_user,
            to_regprocedure(
              'security.suspend_branch_member_subscription(bytea,uuid,uuid,uuid,text,uuid)'
            ),
            'EXECUTE'
          ) AS can_execute,
          has_table_privilege(
            current_user, 'app.subscription_suspensions', 'SELECT'
          ) AS history_select,
          has_table_privilege(
            current_user, 'app.subscription_suspensions', 'INSERT'
          ) AS history_insert,
          has_table_privilege(
            current_user, 'app.subscription_suspensions', 'UPDATE'
          ) AS history_update,
          has_table_privilege(
            current_user, 'app.subscription_suspensions', 'DELETE'
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
        'Subscription suspension database verification unavailable',
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
        'Subscription suspension requires gympro_app connected to gympro_saas with function-only subscription access',
      );
    }

    this.runtimeVerified = true;
  }

  async suspend(
    request: GymProAuthenticatedRequest,
    tenantId: string,
    subscriptionId: string,
    body: unknown,
  ): Promise<SubscriptionSuspension> {
    return this.suspendScoped(request, tenantId, null, subscriptionId, body);
  }

  async suspendBranch(
    request: GymProAuthenticatedRequest,
    tenantId: string,
    branchId: string,
    subscriptionId: string,
    body: unknown,
  ): Promise<SubscriptionSuspension> {
    return this.suspendScoped(request, tenantId, branchId, subscriptionId, body);
  }

  private async suspendScoped(
    request: GymProAuthenticatedRequest,
    tenantId: string,
    branchId: string | null,
    subscriptionId: string,
    body: unknown,
  ): Promise<SubscriptionSuspension> {
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
        'Subscription suspension unavailable',
      );
    }

    if (branchId !== null && !this.isUuid(branchId)) {
      throw new BadRequestException('Invalid branch identifier');
    }

    const input = this.validateBody(body);

    const tokenHash = this.bearerTokenService.hashAuthorization(
      request.headers?.authorization,
    );

    if (!Buffer.isBuffer(tokenHash) || tokenHash.length !== 32) {
      throw new UnauthorizedException('Invalid or expired session');
    }

    let result: pg.QueryResult<SuspensionRow>;

    try {
      result = await this.pool.query<SuspensionRow>(
        `
          SELECT
            id,
            tenant_id,
            subscription_id,
            request_id,
            reason,
            suspended_at,
            created_at
          FROM ${branchId === null
            ? `security.suspend_member_subscription(
                $1::bytea, $2::uuid, $3::uuid, $4::text, $5::uuid
              )`
            : `security.suspend_branch_member_subscription(
                $1::bytea, $2::uuid, $3::uuid,
                $4::uuid, $5::text, $6::uuid
              )`}
        `,
        branchId === null
          ? [tokenHash, tenantId, subscriptionId, input.reason, input.requestId]
          : [tokenHash, tenantId, branchId, subscriptionId, input.reason, input.requestId],
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
      !this.sameUuid(row.request_id, input.requestId) ||
      row.reason !== input.reason ||
      !this.isValidDate(row.suspended_at) ||
      !this.isValidDate(row.created_at)
    ) {
      throw new ServiceUnavailableException(
        'Subscription suspension unavailable',
      );
    }

    return Object.freeze({
      id: row.id,
      tenantId: row.tenant_id,
      subscriptionId: row.subscription_id,
      requestId: row.request_id,
      reason: row.reason,
      suspendedAt: row.suspended_at,
      createdAt: row.created_at,
    });
  }

  async onModuleDestroy(): Promise<void> {
    this.runtimeVerified = false;
    await this.pool.end();
  }

  private validateBody(
    body: unknown,
  ): SuspendMemberSubscriptionInput {
    if (
      typeof body !== 'object' ||
      body === null ||
      Array.isArray(body)
    ) {
      throw new BadRequestException('Invalid suspension request');
    }

    const input = body as Record<string, unknown>;
    const allowed = new Set(['reason', 'requestId']);

    if (
      Object.keys(input).some((key) => !allowed.has(key)) ||
      typeof input.reason !== 'string' ||
      !this.isUuid(input.requestId)
    ) {
      throw new BadRequestException(
        'Only reason and a valid requestId are accepted',
      );
    }

    const reason = input.reason.trim();

    // Count Unicode code points, matching PostgreSQL character length.
    const characterCount = Array.from(reason).length;

    if (
      characterCount < 2 ||
      characterCount > 500 ||
      !/\S/u.test(reason)
    ) {
      throw new BadRequestException(
        'A suspension reason of 2 to 500 characters is required',
      );
    }

    return Object.freeze({
      reason,
      requestId: input.requestId,
    });
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
      throw new ForbiddenException('Membership suspension access denied');
    }

    if (databaseError.code === '22023') {
      throw new BadRequestException(
        'Invalid membership suspension request',
      );
    }

    throw new ServiceUnavailableException(
      'Subscription suspension unavailable',
    );
  }
}
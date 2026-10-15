import {
  BadRequestException,
  ForbiddenException,
  Injectable,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';
import type { OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import pg from 'pg';
import { SessionBearerTokenService } from '../auth/session-bearer-token.service.js';
import type { GymProAuthenticatedRequest } from '../auth/authenticated-session.guard.js';
import { SUBSCRIPTION_DURATION_UNITS } from './member-subscription.js';
import type { SubscriptionDurationUnit } from './member-subscription.js';
import type {
  RenewMemberSubscriptionInput,
  SubscriptionRenewal,
} from './subscription-renewal.js';

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

interface RenewalRow {
  id: string;
  tenant_id: string;
  subscription_id: string;
  request_id: string;
  plan_id: string;
  plan_price_id: string;
  previous_ends_on: string;
  renewal_starts_on: string;
  renewal_ends_on: string;
  duration_value: number;
  duration_unit: string;
  agreed_price_amount: string;
  currency_code: string;
  created_at: Date;
}

@Injectable()
export class SubscriptionRenewalService
  implements OnModuleInit, OnModuleDestroy
{
  private readonly pool: pg.Pool;
  private runtimeVerified = false;

  constructor(
    config: ConfigService,
    private readonly bearerTokenService: SessionBearerTokenService,
  ) {
    const databaseUrl = config.get<string>('DATABASE_URL');
    if (!databaseUrl) throw new Error('DATABASE_URL is required');

    this.pool = new pg.Pool({
      connectionString: databaseUrl,
      max: 5,
      idleTimeoutMillis: 30000,
      connectionTimeoutMillis: 5000,
    });

    this.pool.on('error', () => {
      console.error('Subscription renewal database pool error');
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
          (
            has_function_privilege(
              current_user,
              to_regprocedure(
                'security.renew_member_subscription(bytea,uuid,uuid,uuid,uuid)'
              ),
              'EXECUTE'
            )
            AND has_function_privilege(
              current_user,
              to_regprocedure(
                'security.renew_branch_member_subscription(bytea,uuid,uuid,uuid,uuid,uuid)'
              ),
              'EXECUTE'
            )
          ) AS can_execute,
          has_table_privilege(
            current_user, 'app.subscription_renewals', 'SELECT'
          ) AS history_select,
          has_table_privilege(
            current_user, 'app.subscription_renewals', 'INSERT'
          ) AS history_insert,
          has_table_privilege(
            current_user, 'app.subscription_renewals', 'UPDATE'
          ) AS history_update,
          has_table_privilege(
            current_user, 'app.subscription_renewals', 'DELETE'
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
        FROM pg_roles r
        WHERE r.rolname = current_user
      `);
    } catch {
      throw new Error(
        'Subscription renewal database verification unavailable',
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
        'Subscription renewal requires gympro_app connected to gympro_saas with function-only subscription access',
      );
    }

    this.runtimeVerified = true;
  }

  async renew(
    request: GymProAuthenticatedRequest,
    tenantId: string,
    subscriptionId: string,
    body: unknown,
  ): Promise<SubscriptionRenewal> {
    return this.renewScoped(
      request, tenantId, null, subscriptionId, body,
    );
  }

  async renewBranch(
    request: GymProAuthenticatedRequest,
    tenantId: string,
    branchId: string,
    subscriptionId: string,
    body: unknown,
  ): Promise<SubscriptionRenewal> {
    return this.renewScoped(
      request, tenantId, branchId, subscriptionId, body,
    );
  }

  private async renewScoped(
    request: GymProAuthenticatedRequest,
    tenantId: string,
    branchId: string | null,
    subscriptionId: string,
    body: unknown,
  ): Promise<SubscriptionRenewal> {
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

    if (branchId !== null && !this.isUuid(branchId)) {
      throw new BadRequestException('Invalid branch identifier');
    }

    if (!this.runtimeVerified) {
      throw new ServiceUnavailableException(
        'Subscription renewal unavailable',
      );
    }

    const input = this.validateBody(body);
    const tokenHash = this.bearerTokenService.hashAuthorization(
      request.headers?.authorization,
    );

    if (!Buffer.isBuffer(tokenHash) || tokenHash.length !== 32) {
      throw new UnauthorizedException('Invalid or expired session');
    }

    const functionCall = branchId === null
      ? `security.renew_member_subscription(
          $1::bytea, $2::uuid, $3::uuid, $4::uuid, $5::uuid
        )`
      : `security.renew_branch_member_subscription(
          $1::bytea, $2::uuid, $3::uuid,
          $4::uuid, $5::uuid, $6::uuid
        )`;

    const values = branchId === null
      ? [
          tokenHash, tenantId, subscriptionId,
          input.planPriceId, input.requestId,
        ]
      : [
          tokenHash, tenantId, branchId, subscriptionId,
          input.planPriceId, input.requestId,
        ];

    let result: pg.QueryResult<RenewalRow>;
    try {
      result = await this.pool.query<RenewalRow>(
        `
          SELECT
            id, tenant_id, subscription_id, request_id,
            plan_id, plan_price_id,
            previous_ends_on::text AS previous_ends_on,
            renewal_starts_on::text AS renewal_starts_on,
            renewal_ends_on::text AS renewal_ends_on,
            duration_value, duration_unit,
            agreed_price_amount::text AS agreed_price_amount,
            currency_code, created_at
          FROM ${functionCall}
        `,
        values,
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
      !this.isUuid(row.plan_id) ||
      !this.sameUuid(row.plan_price_id, input.planPriceId) ||
      !this.isCalendarDate(row.previous_ends_on) ||
      !this.isCalendarDate(row.renewal_starts_on) ||
      !this.isCalendarDate(row.renewal_ends_on) ||
      row.renewal_starts_on < row.previous_ends_on ||
      row.renewal_ends_on <= row.renewal_starts_on ||
      !Number.isInteger(row.duration_value) ||
      row.duration_value <= 0 ||
      !SUBSCRIPTION_DURATION_UNITS.some(
        (unit) => unit === row.duration_unit,
      ) ||
      typeof row.agreed_price_amount !== 'string' ||
      !/^(0|[1-9][0-9]{0,11})\.[0-9]{2}$/.test(row.agreed_price_amount) ||
      row.currency_code !== 'MMK' ||
      !this.isValidDate(row.created_at)
    ) {
      throw new ServiceUnavailableException(
        'Subscription renewal unavailable',
      );
    }

    return Object.freeze({
      id: row.id,
      tenantId: row.tenant_id,
      subscriptionId: row.subscription_id,
      requestId: row.request_id,
      planId: row.plan_id,
      planPriceId: row.plan_price_id,
      previousEndsOn: row.previous_ends_on,
      renewalStartsOn: row.renewal_starts_on,
      renewalEndsOn: row.renewal_ends_on,
      durationValue: row.duration_value,
      durationUnit: row.duration_unit as SubscriptionDurationUnit,
      agreedPriceAmount: row.agreed_price_amount,
      currencyCode: 'MMK' as const,
      createdAt: row.created_at,
    });
  }

  async onModuleDestroy(): Promise<void> {
    this.runtimeVerified = false;
    await this.pool.end();
  }

  private validateBody(
    body: unknown,
  ): RenewMemberSubscriptionInput {
    if (typeof body !== 'object' || body === null || Array.isArray(body)) {
      throw new BadRequestException('Invalid renewal request');
    }

    const input = body as Record<string, unknown>;
    const allowed = new Set(['planPriceId', 'requestId']);

    if (
      Object.keys(input).some((key) => !allowed.has(key)) ||
      !this.isUuid(input.planPriceId) ||
      !this.isUuid(input.requestId)
    ) {
      throw new BadRequestException(
        'Only valid planPriceId and requestId are accepted',
      );
    }

    return Object.freeze({
      planPriceId: input.planPriceId,
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
      [
        'Tenant access denied',
        'Subscription access denied',
        'Member access denied',
        'Branch access denied',
        'Membership management permission denied',
      ].includes(String(databaseError.message))
    ) {
      throw new ForbiddenException('Membership renewal access denied');
    }

    if (databaseError.code === '22023') {
      throw new BadRequestException(
        'Invalid membership renewal request',
      );
    }

    throw new ServiceUnavailableException(
      'Subscription renewal unavailable',
    );
  }
}
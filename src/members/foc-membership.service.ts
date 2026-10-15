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
  FocMembershipGrant,
  GrantFocMembershipInput,
} from './foc-membership.js';

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

interface FocGrantRow {
  id: string;
  tenant_id: string;
  subscription_id: string;
  request_id: string;
  reason: string;
  listed_price_amount: string;
  currency_code: string;
  granted_at: Date;
  created_at: Date;
}

@Injectable()
export class FocMembershipService
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
      console.error('FOC membership database pool error');
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
              'security.grant_foc_membership(bytea,uuid,uuid,uuid,uuid,text,uuid)'
            ),
            'EXECUTE'
          ) AND has_function_privilege(current_user,
            to_regprocedure('security.grant_branch_foc_membership(bytea,uuid,uuid,uuid,uuid,uuid,text,uuid)'), 'EXECUTE'
          ) AS can_execute,
          has_table_privilege(
            current_user, 'app.subscription_foc_grants', 'SELECT'
          ) AS history_select,
          has_table_privilege(
            current_user, 'app.subscription_foc_grants', 'INSERT'
          ) AS history_insert,
          has_table_privilege(
            current_user, 'app.subscription_foc_grants', 'UPDATE'
          ) AS history_update,
          has_table_privilege(
            current_user, 'app.subscription_foc_grants', 'DELETE'
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
      throw new Error('FOC membership database verification unavailable');
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
        'FOC membership requires gympro_app connected to gympro_saas with function-only subscription access',
      );
    }

    this.runtimeVerified = true;
  }

  async grant(
    request: GymProAuthenticatedRequest,
    tenantId: string,
    memberId: string,
    body: unknown,
    expectedBranchId: string | null = null,
  ): Promise<FocMembershipGrant> {
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

    if (!this.isUuid(tenantId) || !this.isUuid(memberId)) {
      throw new BadRequestException('Invalid tenant or member identifier');
    }

    if (!this.sameUuid(session.tenantId, tenantId)) {
      throw new ForbiddenException('Tenant access denied');
    }

    if (!this.runtimeVerified) {
      throw new ServiceUnavailableException('FOC membership unavailable');
    }

    if (expectedBranchId !== null && !this.isUuid(expectedBranchId)) {
      throw new BadRequestException('Invalid branch identifier');
    }

    const input = this.validateBody(body);

    const tokenHash = this.bearerTokenService.hashAuthorization(
      request.headers?.authorization,
    );

    if (!Buffer.isBuffer(tokenHash) || tokenHash.length !== 32) {
      throw new UnauthorizedException('Invalid or expired session');
    }

    let result: pg.QueryResult<FocGrantRow>;

    try {
      result = await this.pool.query<FocGrantRow>(
        `
          SELECT
            id,
            tenant_id,
            subscription_id,
            request_id,
            reason,
            listed_price_amount::text AS listed_price_amount,
            currency_code,
            granted_at,
            created_at
          FROM ${expectedBranchId === null ? `security.grant_foc_membership($1::bytea, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6::text, $7::uuid)` : `security.grant_branch_foc_membership($1::bytea, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6::uuid, $7::text, $8::uuid)`}
        `,
        expectedBranchId === null
          ? [tokenHash, tenantId, memberId, input.planId, input.planPriceId, input.reason, input.requestId]
          : [tokenHash, tenantId, expectedBranchId, memberId, input.planId, input.planPriceId, input.reason, input.requestId],
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
      !this.isUuid(row.subscription_id) ||
      !this.sameUuid(row.request_id, input.requestId) ||
      row.reason !== input.reason ||
      typeof row.listed_price_amount !== 'string' ||
      !/^(0|[1-9][0-9]{0,11})\.[0-9]{2}$/.test(
        row.listed_price_amount,
      ) ||
      row.currency_code !== 'MMK' ||
      !this.isValidDate(row.granted_at) ||
      !this.isValidDate(row.created_at)
    ) {
      throw new ServiceUnavailableException('FOC membership unavailable');
    }

    return Object.freeze({
      id: row.id,
      tenantId: row.tenant_id,
      subscriptionId: row.subscription_id,
      requestId: row.request_id,
      reason: row.reason,
      listedPriceAmount: row.listed_price_amount,
      currencyCode: 'MMK' as const,
      grantedAt: row.granted_at,
      createdAt: row.created_at,
    });
  }

  async onModuleDestroy(): Promise<void> {
    this.runtimeVerified = false;
    await this.pool.end();
  }

  private validateBody(body: unknown): GrantFocMembershipInput {
    if (
      typeof body !== 'object' ||
      body === null ||
      Array.isArray(body)
    ) {
      throw new BadRequestException('Invalid FOC request');
    }

    const input = body as Record<string, unknown>;
    const allowed = new Set([
      'planId',
      'planPriceId',
      'reason',
      'requestId',
    ]);

    if (
      Object.keys(input).some((key) => !allowed.has(key)) ||
      !this.isUuid(input.planId) ||
      !this.isUuid(input.planPriceId) ||
      !this.isUuid(input.requestId) ||
      typeof input.reason !== 'string'
    ) {
      throw new BadRequestException(
        'Only valid planId, planPriceId, reason, and requestId are accepted',
      );
    }

    const reason = input.reason.trim();
    const characterCount = Array.from(reason).length;

    if (
      characterCount < 2 ||
      characterCount > 500 ||
      !/\S/u.test(reason)
    ) {
      throw new BadRequestException(
        'An FOC reason of 2 to 500 characters is required',
      );
    }

    return Object.freeze({
      planId: input.planId,
      planPriceId: input.planPriceId,
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
        databaseError.message === 'Member access denied' ||
        databaseError.message === 'Branch access denied' ||
        databaseError.message === 'Complimentary membership permission denied'
      )
    ) {
      throw new ForbiddenException('Complimentary membership access denied');
    }

    if (databaseError.code === '22023') {
      throw new BadRequestException('Invalid complimentary membership request');
    }

    throw new ServiceUnavailableException('FOC membership unavailable');
  }
}

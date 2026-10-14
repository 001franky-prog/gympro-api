\set ON_ERROR_STOP on
\connect gympro_saas
\pset pager off

BEGIN;

DO $$
BEGIN
    IF current_database() <> 'gympro_saas' THEN
        RAISE EXCEPTION 'Expected database gympro_saas.';
    END IF;

    IF to_regclass('platform.tenants') IS NULL
       OR to_regclass('app.members') IS NULL
       OR to_regclass('app.branches') IS NULL
       OR to_regclass('app.membership_plans') IS NULL
       OR to_regclass('app.plan_prices') IS NULL THEN
        RAISE EXCEPTION 'Required earlier tables are missing.';
    END IF;

    IF to_regclass('app.member_subscriptions') IS NOT NULL THEN
        RAISE EXCEPTION
            'member_subscriptions already exists. Inspect it before proceeding.';
    END IF;
END;
$$;

-- Enables a subscription to reference a price belonging
-- to both its tenant and its selected plan.
ALTER TABLE app.plan_prices
    ADD CONSTRAINT uq_plan_prices_tenant_plan_id
    UNIQUE (tenant_id, plan_id, id);

CREATE TABLE app.member_subscriptions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tenant_id uuid NOT NULL,
    member_id uuid NOT NULL,
    branch_id uuid,
    plan_id uuid NOT NULL,
    plan_price_id uuid NOT NULL,

    -- Agreed values copied from the selected plan and price
    -- by the protected subscription function added later.
    duration_value integer NOT NULL,
    duration_unit varchar(10) NOT NULL,
    agreed_price_amount numeric(14, 2) NOT NULL,
    currency_code varchar(3) NOT NULL DEFAULT 'MMK',

    status varchar(20) NOT NULL DEFAULT 'pending',

    starts_on date,
    ends_on date,

    activated_at timestamptz,
    suspended_at timestamptz,

    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_member_subscriptions_tenant_id
        UNIQUE (tenant_id, id),

    CONSTRAINT fk_member_subscriptions_tenant
        FOREIGN KEY (tenant_id)
        REFERENCES platform.tenants (id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_member_subscriptions_member
        FOREIGN KEY (tenant_id, member_id)
        REFERENCES app.members (tenant_id, id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_member_subscriptions_branch
        FOREIGN KEY (tenant_id, branch_id)
        REFERENCES app.branches (tenant_id, id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_member_subscriptions_plan
        FOREIGN KEY (tenant_id, plan_id)
        REFERENCES app.membership_plans (tenant_id, id)
        ON DELETE RESTRICT,

    CONSTRAINT fk_member_subscriptions_price
        FOREIGN KEY (tenant_id, plan_id, plan_price_id)
        REFERENCES app.plan_prices (tenant_id, plan_id, id)
        ON DELETE RESTRICT,

    CONSTRAINT chk_member_subscriptions_duration_value
        CHECK (duration_value > 0),

    CONSTRAINT chk_member_subscriptions_duration_unit
        CHECK (
            duration_unit IN ('days', 'weeks', 'months', 'years')
        ),

    CONSTRAINT chk_member_subscriptions_price
        CHECK (
            agreed_price_amount >= 0
            AND agreed_price_amount < 1000000000000
        ),

    CONSTRAINT chk_member_subscriptions_currency
        CHECK (currency_code = 'MMK'),

    CONSTRAINT chk_member_subscriptions_status
        CHECK (
            status IN ('pending', 'active', 'suspended', 'expired')
        ),

    CONSTRAINT chk_member_subscriptions_dates
        CHECK (
            (starts_on IS NULL AND ends_on IS NULL)
            OR (
                starts_on IS NOT NULL
                AND ends_on IS NOT NULL
                AND isfinite(starts_on)
                AND isfinite(ends_on)
                AND ends_on > starts_on
            )
        ),

    CONSTRAINT chk_member_subscriptions_activation
        CHECK (
            (
                status = 'pending'
                AND activated_at IS NULL
            )
            OR (
                status IN ('active', 'suspended', 'expired')
                AND starts_on IS NOT NULL
                AND ends_on IS NOT NULL
                AND activated_at IS NOT NULL
                AND isfinite(activated_at)
            )
        ),

    CONSTRAINT chk_member_subscriptions_suspension
        CHECK (
            (
                status = 'suspended'
                AND suspended_at IS NOT NULL
                AND isfinite(suspended_at)
                AND suspended_at >= activated_at
            )
            OR (
                status <> 'suspended'
                AND suspended_at IS NULL
            )
        )
);

-- A suspended subscription still occupies the member's
-- current membership slot.
CREATE UNIQUE INDEX uq_member_subscriptions_current_member
    ON app.member_subscriptions (tenant_id, member_id)
    WHERE status IN ('active', 'suspended');

CREATE INDEX idx_member_subscriptions_tenant_member
    ON app.member_subscriptions (tenant_id, member_id);

CREATE INDEX idx_member_subscriptions_tenant_branch
    ON app.member_subscriptions (tenant_id, branch_id);

CREATE INDEX idx_member_subscriptions_tenant_plan
    ON app.member_subscriptions (tenant_id, plan_id);

CREATE INDEX idx_member_subscriptions_tenant_price
    ON app.member_subscriptions (tenant_id, plan_id, plan_price_id);

CREATE INDEX idx_member_subscriptions_expiry
    ON app.member_subscriptions (tenant_id, ends_on)
    WHERE status IN ('active', 'suspended');

ALTER TABLE app.member_subscriptions
    ENABLE ROW LEVEL SECURITY;

ALTER TABLE app.member_subscriptions
    FORCE ROW LEVEL SECURITY;

REVOKE ALL PRIVILEGES
    ON TABLE app.member_subscriptions
    FROM PUBLIC, gympro_app;

COMMIT;

SELECT
    n.nspname AS schema_name,
    c.relname AS table_name,
    c.relrowsecurity AS rls_enabled,
    c.relforcerowsecurity AS rls_forced
FROM pg_class AS c
JOIN pg_namespace AS n
    ON n.oid = c.relnamespace
WHERE n.nspname = 'app'
  AND c.relname = 'member_subscriptions';

SELECT
    has_table_privilege(
        'gympro_app',
        'app.member_subscriptions',
        'SELECT'
    ) AS runtime_can_select,
    has_table_privilege(
        'gympro_app',
        'app.member_subscriptions',
        'INSERT'
    ) AS runtime_can_insert,
    has_table_privilege(
        'gympro_app',
        'app.member_subscriptions',
        'UPDATE'
    ) AS runtime_can_update,
    has_table_privilege(
        'gympro_app',
        'app.member_subscriptions',
        'DELETE'
    ) AS runtime_can_delete;import {
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

import {
  SUBSCRIPTION_DURATION_UNITS,
} from './member-subscription.js';

import type {
  ActivateMemberSubscriptionInput,
  MemberSubscription,
  SubscriptionDurationUnit,
} from './member-subscription.js';

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface RuntimeIdentity {
  database_name: string;
  database_user: string;
  is_superuser: boolean;
  bypasses_rls: boolean;
  schema_usage: boolean;
  can_execute: boolean;
  can_select: boolean;
  can_insert: boolean;
  can_update: boolean;
  can_delete: boolean;
}

interface SubscriptionRow {
  id: string;
  tenant_id: string;
  member_id: string;
  branch_id: string | null;
  plan_id: string;
  plan_price_id: string;
  duration_value: number;
  duration_unit: string;
  agreed_price_amount: string;
  currency_code: string;
  status: string;
  starts_on: string;
  ends_on: string;
  activated_at: Date;
  suspended_at: Date | null;
  created_at: Date;
  updated_at: Date;
}

@Injectable()
export class SubscriptionActivationService
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
      console.error('Subscription activation database pool error');
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
              'security.activate_member_subscription(bytea,uuid,uuid,uuid,uuid)'
            ),
            'EXECUTE'
          ) AS can_execute,
          has_table_privilege(
            current_user, 'app.member_subscriptions', 'SELECT'
          ) AS can_select,
          has_table_privilege(
            current_user, 'app.member_subscriptions', 'INSERT'
          ) AS can_insert,
          has_table_privilege(
            current_user, 'app.member_subscriptions', 'UPDATE'
          ) AS can_update,
          has_table_privilege(
            current_user, 'app.member_subscriptions', 'DELETE'
          ) AS can_delete
        FROM pg_roles AS r
        WHERE r.rolname = current_user
      `);
    } catch {
      throw new Error(
        'Subscription activation database verification unavailable',
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
      row.can_select !== false ||
      row.can_insert !== false ||
      row.can_update !== false ||
      row.can_delete !== false
    ) {
      throw new Error(
        'Subscription activation requires gympro_app connected to gympro_saas with function-only subscription access',
      );
    }

    this.runtimeVerified = true;
  }

  async activate(
    request: GymProAuthenticatedRequest,
    tenantId: string,
    memberId: string,
    body: unknown,
  ): Promise<MemberSubscription> {
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
      throw new ServiceUnavailableException(
        'Subscription activation unavailable',
      );
    }

    const input = this.validateBody(body);

    const tokenHash = this.bearerTokenService.hashAuthorization(
      request.headers?.authorization,
    );

    if (!Buffer.isBuffer(tokenHash) || tokenHash.length !== 32) {
      throw new UnauthorizedException('Invalid or expired session');
    }

    let result: pg.QueryResult<SubscriptionRow>;

    try {
      result = await this.pool.query<SubscriptionRow>(
        `
          SELECT
            id,
            tenant_id,
            member_id,
            branch_id,
            plan_id,
            plan_price_id,
            duration_value,
            duration_unit,
            agreed_price_amount::text AS agreed_price_amount,
            currency_code,
            status,
            starts_on::text AS starts_on,
            ends_on::text AS ends_on,
            activated_at,
            suspended_at,
            created_at,
            updated_at
          FROM security.activate_member_subscription(
            $1::bytea,
            $2::uuid,
            $3::uuid,
            $4::uuid,
            $5::uuid
          )
        `,
        [
          tokenHash,
          tenantId,
          memberId,
          input.planId,
          input.planPriceId,
        ],
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
      !this.sameUuid(row.member_id, memberId) ||
      !this.sameUuid(row.plan_id, input.planId) ||
      !this.sameUuid(row.plan_price_id, input.planPriceId) ||
      (row.branch_id !== null && !this.isUuid(row.branch_id)) ||
      !Number.isInteger(row.duration_value) ||
      row.duration_value <= 0 ||
      !SUBSCRIPTION_DURATION_UNITS.some(
        (unit) => unit === row.duration_unit,
      ) ||
      typeof row.agreed_price_amount !== 'string' ||
      !/^(0|[1-9][0-9]{0,11})\.[0-9]{2}$/.test(
        row.agreed_price_amount,
      ) ||
      row.currency_code !== 'MMK' ||
      row.status !== 'active' ||
      !this.isCalendarDate(row.starts_on) ||
      !this.isCalendarDate(row.ends_on) ||
      row.ends_on <= row.starts_on ||
      !this.isValidDate(row.activated_at) ||
      row.suspended_at !== null ||
      !this.isValidDate(row.created_at) ||
      !this.isValidDate(row.updated_at)
    ) {
      throw new ServiceUnavailableException(
        'Subscription activation unavailable',
      );
    }

    return Object.freeze({
      id: row.id,
      tenantId: row.tenant_id,
      memberId: row.member_id,
      branchId: row.branch_id,
      planId: row.plan_id,
      planPriceId: row.plan_price_id,
      durationValue: row.duration_value,
      durationUnit: row.duration_unit as SubscriptionDurationUnit,
      agreedPriceAmount: row.agreed_price_amount,
      currencyCode: 'MMK' as const,
      status: 'active' as const,
      startsOn: row.starts_on,
      endsOn: row.ends_on,
      activatedAt: row.activated_at,
      suspendedAt: null,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    });
  }

  async onModuleDestroy(): Promise<void> {
    this.runtimeVerified = false;
    await this.pool.end();
  }

  private validateBody(
    body: unknown,
  ): ActivateMemberSubscriptionInput {
    if (
      typeof body !== 'object' ||
      body === null ||
      Array.isArray(body)
    ) {
      throw new BadRequestException('Invalid activation request');
    }

    const input = body as Record<string, unknown>;
    const allowed = new Set(['planId', 'planPriceId']);

    if (
      Object.keys(input).some((key) => !allowed.has(key)) ||
      !this.isUuid(input.planId) ||
      !this.isUuid(input.planPriceId)
    ) {
      throw new BadRequestException(
        'Only valid planId and planPriceId are accepted',
      );
    }

    return Object.freeze({
      planId: input.planId,
      planPriceId: input.planPriceId,
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
      (
        databaseError.message === 'Tenant access denied' ||
        databaseError.message === 'Member access denied' ||
        databaseError.message ===
          'Membership management permission denied'
      )
    ) {
      throw new ForbiddenException('Membership activation access denied');
    }

    if (databaseError.code === '22023') {
      throw new BadRequestException(
        'Invalid membership activation request',
      );
    }

    throw new ServiceUnavailableException(
      'Subscription activation unavailable',
    );
  }
}
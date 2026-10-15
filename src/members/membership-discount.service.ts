import {
  BadRequestException,
  ForbiddenException,
  Injectable,
  OnModuleDestroy,
  OnModuleInit,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Pool } from 'pg';
import type { GymProAuthenticatedRequest } from '../auth/authenticated-session.guard.js';
import { SessionBearerTokenService } from '../auth/session-bearer-token.service.js';
import type { MembershipDiscountReceipt } from './membership-promotion.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DECIMAL = /^(0|[1-9][0-9]{0,11})\.[0-9]{2}$/;

const COLUMNS = `
  id, tenant_id, subscription_id, promotion_id, request_id,
  purchase_kind, renewal_id,
  listed_price_amount::text, discount_amount::text,
  agreed_price_amount::text, currency_code, applied_at, created_at
`;

@Injectable()
export class MembershipDiscountService
  implements OnModuleInit, OnModuleDestroy
{
  private readonly pool: Pool;
  private runtimeVerified = false;

  constructor(
    config: ConfigService,
    private readonly bearer: SessionBearerTokenService,
  ) {
    const connectionString = config.get<string>('DATABASE_URL');
    if (!connectionString) {
      throw new ServiceUnavailableException(
        'Discount database configuration is missing',
      );
    }

    this.pool = new Pool({
      connectionString,
      max: 5,
      idleTimeoutMillis: 30000,
      connectionTimeoutMillis: 5000,
    });

    this.pool.on('error', () => {
      this.runtimeVerified = false;
    });
  }

  async onModuleInit(): Promise<void> {
    this.runtimeVerified = false;

    try {
      const result = await this.pool.query(`
        SELECT
          current_database() AS database_name,
          current_user AS database_user,
          r.rolsuper AS is_superuser,
          r.rolbypassrls AS bypasses_rls,
          has_schema_privilege(current_user, 'security', 'USAGE')
            AS security_schema_usage,
          has_function_privilege(
            current_user,
            'security.activate_discounted_membership(bytea,uuid,uuid,uuid,uuid,uuid,uuid)',
            'EXECUTE'
          ) AND has_function_privilege(current_user, 'security.activate_branch_discounted_membership(bytea,uuid,uuid,uuid,uuid,uuid,uuid,uuid)', 'EXECUTE') AS can_activate,
          has_function_privilege(
            current_user,
            'security.renew_discounted_membership(bytea,uuid,uuid,uuid,uuid,uuid)',
            'EXECUTE'
          ) AND has_function_privilege(current_user, 'security.renew_branch_discounted_membership(bytea,uuid,uuid,uuid,uuid,uuid,uuid)', 'EXECUTE') AS can_renew,
          has_function_privilege(
            current_user,
            'security.calculate_membership_discount(bytea,uuid,uuid,uuid,numeric,uuid)',
            'EXECUTE'
          ) AS can_call_calculator,
          (
            has_table_privilege(
              current_user, 'app.membership_discounts',
              'SELECT,INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
              current_user, 'app.member_subscriptions',
              'SELECT,INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
              current_user, 'app.subscription_renewals',
              'SELECT,INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
              current_user, 'app.members',
              'SELECT,INSERT,UPDATE,DELETE'
            )
          ) AS direct_purchase_access
        FROM pg_roles r
        WHERE r.rolname = current_user
      `);

      const row = result.rows[0];

      if (
        result.rows.length !== 1 ||
        row.database_name !== 'gympro_saas' ||
        row.database_user !== 'gympro_app' ||
        row.is_superuser !== false ||
        row.bypasses_rls !== false ||
        row.security_schema_usage !== true ||
        row.can_activate !== true ||
        row.can_renew !== true ||
        row.can_call_calculator !== false ||
        row.direct_purchase_access !== false
      ) {
        throw new Error('Unexpected discount security boundary');
      }

      this.runtimeVerified = true;
    } catch {
      throw new ServiceUnavailableException(
        'Discount database security verification failed',
      );
    }
  }

  async onModuleDestroy(): Promise<void> {
    this.runtimeVerified = false;
    await this.pool.end();
  }

  async activate(
    request: GymProAuthenticatedRequest,
    tenantId: string,
    memberId: string,
    body: unknown,
    expectedBranchId: string | null = null,
  ): Promise<MembershipDiscountReceipt> {
    return this.purchase(request, tenantId, memberId, body, 'activation', expectedBranchId);
  }

  async renew(
    request: GymProAuthenticatedRequest,
    tenantId: string,
    subscriptionId: string,
    body: unknown,
    expectedBranchId: string | null = null,
  ): Promise<MembershipDiscountReceipt> {
    return this.purchase(
      request, tenantId, subscriptionId, body, 'renewal', expectedBranchId,
    );
  }

  private async purchase(
    request: GymProAuthenticatedRequest,
    tenantId: string,
    targetId: string,
    body: unknown,
    kind: 'activation' | 'renewal',
    expectedBranchId: string | null = null,
  ): Promise<MembershipDiscountReceipt> {
    const tokenHash = this.authorize(request, tenantId);

    if (!this.validUuid(targetId)) this.badRequest();
    if (expectedBranchId !== null && !this.validUuid(expectedBranchId)) this.badRequest();

    if (
      body === null ||
      typeof body !== 'object' ||
      Array.isArray(body)
    ) {
      this.badRequest();
    }

    const input = body as Record<string, unknown>;
    const allowed = kind === 'activation'
      ? ['planId', 'planPriceId', 'promotionId', 'requestId']
      : ['planPriceId', 'promotionId', 'requestId'];

    if (Object.keys(input).some((key) => !allowed.includes(key))) {
      this.badRequest();
    }

    if (
      !this.validUuid(input.planPriceId) ||
      !this.validUuid(input.promotionId) ||
      !this.validUuid(input.requestId) ||
      (kind === 'activation' && !this.validUuid(input.planId))
    ) {
      this.badRequest();
    }

    const priceId = input.planPriceId;
    const promotionId = input.promotionId;
    const requestId = input.requestId;

    const sql = kind === 'activation'
      ? `
          SELECT ${COLUMNS}
          FROM ${expectedBranchId === null ? `security.activate_discounted_membership($1::bytea, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6::uuid, $7::uuid)` : `security.activate_branch_discounted_membership($1::bytea, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6::uuid, $7::uuid, $8::uuid)`}
        `
      : `
          SELECT ${COLUMNS}
          FROM ${expectedBranchId === null ? `security.renew_discounted_membership($1::bytea, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6::uuid)` : `security.renew_branch_discounted_membership($1::bytea, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6::uuid, $7::uuid)`}
        `;

    const values = kind === 'activation'
      ? [
          tokenHash, tenantId, targetId, input.planId,
          priceId, promotionId, requestId,
        ]
      : [
          tokenHash, tenantId, targetId,
          priceId, promotionId, requestId,
        ];

    if (expectedBranchId !== null) values.splice(2, 0, expectedBranchId);

    try {
      const result = await this.pool.query(sql, values);
      if (result.rows.length !== 1) this.unavailable();

      const receipt = this.publicReceipt(result.rows[0]);

      if (
        !this.sameUuid(receipt.tenantId, tenantId) ||
        !this.sameUuid(receipt.promotionId, promotionId) ||
        !this.sameUuid(receipt.requestId, requestId) ||
        receipt.purchaseKind !== kind ||
        (kind === 'renewal' &&
          !this.sameUuid(receipt.subscriptionId, targetId))
      ) {
        this.unavailable();
      }

      return receipt;
    } catch (error) {
      this.databaseError(error);
    }
  }

  private authorize(
    request: GymProAuthenticatedRequest,
    tenantId: string,
  ): Buffer {
    const session = request.gymproSession;

    if (
      !session ||
      !this.validUuid(session.sessionId) ||
      !this.validUuid(session.tenantId) ||
      !this.validUuid(session.membershipId) ||
      !this.validUuid(session.userId)
    ) {
      throw new UnauthorizedException('Invalid or expired session');
    }

    if (!this.validUuid(tenantId)) this.badRequest();
    if (!this.sameUuid(session.tenantId, tenantId)) {
      throw new ForbiddenException('Tenant access denied');
    }

    if (!this.runtimeVerified) this.unavailable();

    let hash: Buffer;
    try {
      hash = this.bearer.hashAuthorization(
        request.headers?.authorization,
      );
    } catch {
      throw new UnauthorizedException('Invalid or expired session');
    }

    if (!Buffer.isBuffer(hash) || hash.length !== 32) {
      throw new UnauthorizedException('Invalid or expired session');
    }

    return hash;
  }

  private publicReceipt(
    row: Record<string, unknown>,
  ): MembershipDiscountReceipt {
    if (
      !this.validUuid(row.id) ||
      !this.validUuid(row.tenant_id) ||
      !this.validUuid(row.subscription_id) ||
      !this.validUuid(row.promotion_id) ||
      !this.validUuid(row.request_id) ||
      (row.purchase_kind !== 'activation' &&
        row.purchase_kind !== 'renewal') ||
      (row.purchase_kind === 'activation' && row.renewal_id !== null) ||
      (row.purchase_kind === 'renewal' && !this.validUuid(row.renewal_id)) ||
      !this.validDecimal(row.listed_price_amount) ||
      !this.validDecimal(row.discount_amount) ||
      !this.validDecimal(row.agreed_price_amount) ||
      row.currency_code !== 'MMK' ||
      !this.validTimestamp(row.applied_at) ||
      !this.validTimestamp(row.created_at)
    ) {
      this.unavailable();
    }

    const listed = this.cents(row.listed_price_amount);
    const discount = this.cents(row.discount_amount);
    const agreed = this.cents(row.agreed_price_amount);

    if (discount > listed || agreed !== listed - discount) {
      this.unavailable();
    }

    return Object.freeze({
      id: row.id,
      tenantId: row.tenant_id,
      subscriptionId: row.subscription_id,
      promotionId: row.promotion_id,
      requestId: row.request_id,
      purchaseKind: row.purchase_kind,
      renewalId: row.renewal_id as string | null,
      listedPriceAmount: row.listed_price_amount,
      discountAmount: row.discount_amount,
      agreedPriceAmount: row.agreed_price_amount,
      currencyCode: 'MMK',
      appliedAt: row.applied_at,
      createdAt: row.created_at,
    });
  }

  private validUuid(value: unknown): value is string {
    return typeof value === 'string' && UUID.test(value);
  }

  private sameUuid(left: string, right: string): boolean {
    return left.toLowerCase() === right.toLowerCase();
  }

  private validDecimal(value: unknown): value is string {
    return typeof value === 'string' && DECIMAL.test(value);
  }

  private cents(value: string): bigint {
    return BigInt(value.replace('.', ''));
  }

  private validTimestamp(value: unknown): value is Date {
    return value instanceof Date && Number.isFinite(value.getTime());
  }

  private badRequest(): never {
    throw new BadRequestException('Invalid discounted membership request');
  }

  private unavailable(): never {
    throw new ServiceUnavailableException(
      'Discounted membership purchase is unavailable',
    );
  }

  private databaseError(error: unknown): never {
    if (error instanceof ServiceUnavailableException) throw error;

    const failure = error as { code?: string; message?: string };

    if (
      failure?.code === '28000' &&
      failure.message === 'Invalid or expired session'
    ) {
      throw new UnauthorizedException('Invalid or expired session');
    }

    if (
      failure?.code === '42501' &&
      [
        'Tenant access denied',
        'Member access denied',
        'Branch access denied',
        'Subscription access denied',
        'Membership management permission denied',
        'Membership discount permission denied',
      ].includes(failure.message ?? '')
    ) {
      throw new ForbiddenException('Discounted membership access denied');
    }

    if (failure?.code === '22023') this.badRequest();
    this.unavailable();
  }
}

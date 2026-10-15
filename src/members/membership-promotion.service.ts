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
import type { MembershipPromotion } from './membership-promotion.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DECIMAL = /^(0|[1-9][0-9]{0,11})\.[0-9]{2}$/;

const RETURN_COLUMNS = `
  id, tenant_id, promotion_code, promotion_name, description,
  plan_id, branch_id, discount_kind, discount_value::text,
  currency_code, starts_on::text, ends_on::text, status,
  created_at, updated_at
`;

@Injectable()
export class MembershipPromotionService
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
        'Promotion database configuration is missing',
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
            'security.create_membership_promotion(bytea,uuid,text,text,text,uuid,uuid,text,numeric,date,date)',
            'EXECUTE'
          ) AS can_create,
          has_function_privilege(
            current_user,
            'security.set_membership_promotion_status(bytea,uuid,uuid,text)',
            'EXECUTE'
          ) AND has_function_privilege(current_user, 'security.set_branch_membership_promotion_status(bytea,uuid,uuid,uuid,text)', 'EXECUTE') AS can_set_status,
          has_function_privilege(
            current_user,
            'security.calculate_membership_discount(bytea,uuid,uuid,uuid,numeric,uuid)',
            'EXECUTE'
          ) AS can_call_calculator,
          has_table_privilege(
            current_user, 'app.membership_promotions',
            'SELECT,INSERT,UPDATE,DELETE'
          ) AS direct_promotion_access
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
        row.can_create !== true ||
        row.can_set_status !== true ||
        row.can_call_calculator !== false ||
        row.direct_promotion_access !== false
      ) {
        throw new Error('Unexpected database security boundary');
      }

      this.runtimeVerified = true;
    } catch {
      throw new ServiceUnavailableException(
        'Promotion database security verification failed',
      );
    }
  }

  async onModuleDestroy(): Promise<void> {
    this.runtimeVerified = false;
    await this.pool.end();
  }

  async create(
    request: GymProAuthenticatedRequest,
    tenantId: string,
    body: unknown,
    expectedBranchId: string | null = null,
  ): Promise<MembershipPromotion> {
    const tokenHash = this.authorize(request, tenantId);
    const input = this.object(body);

    this.allowedKeys(input, [
      'promotionCode',
      'promotionName',
      'description',
      'planId',
      'branchId',
      'discountKind',
      'discountValue',
      'startsOn',
      'endsOn',
    ]);

    const code =
      typeof input.promotionCode === 'string'
        ? input.promotionCode.trim()
        : '';

    const name =
      typeof input.promotionName === 'string'
        ? input.promotionName.trim()
        : '';

    if (
      !/^[A-Z][A-Z0-9_]{0,31}$/.test(code) ||
      [...name].length < 2 ||
      [...name].length > 150
    ) {
      this.badRequest();
    }

    let description: string | null = null;
    if (input.description !== undefined && input.description !== null) {
      if (typeof input.description !== 'string') this.badRequest();
      description = input.description.trim() || null;
    }

    const planId = this.optionalUuid(input.planId);
    if (expectedBranchId !== null && (!this.validUuid(expectedBranchId) || 'branchId' in input)) this.badRequest();
    const branchId = expectedBranchId ?? this.optionalUuid(input.branchId);

    const kind = input.discountKind;
    if (kind !== 'percentage' && kind !== 'fixed_amount') {
      this.badRequest();
    }

    const value = this.inputDecimal(input.discountValue);
    const cents = BigInt(value.replace('.', ''));

    if (cents <= 0n || (kind === 'percentage' && cents > 10000n)) {
      this.badRequest();
    }

    const startsOn = input.startsOn;
    if (!this.validDate(startsOn)) this.badRequest();

    const endsOn =
      input.endsOn === undefined || input.endsOn === null
        ? null
        : input.endsOn;

    if (
      endsOn !== null &&
      (!this.validDate(endsOn) || endsOn <= startsOn)
    ) {
      this.badRequest();
    }

    try {
      const result = await this.pool.query(
        `
          SELECT ${RETURN_COLUMNS}
          FROM security.create_membership_promotion(
            $1::bytea, $2::uuid, $3::text, $4::text, $5::text,
            $6::uuid, $7::uuid, $8::text, $9::numeric,
            $10::date, $11::date
          )
        `,
        [
          tokenHash,
          tenantId,
          code,
          name,
          description,
          planId,
          branchId,
          kind,
          value,
          startsOn,
          endsOn,
        ],
      );

      if (result.rows.length !== 1) this.unavailable();
      const promotion = this.publicPromotion(result.rows[0], tenantId);

      if (
        promotion.promotionCode !== code ||
        promotion.promotionName !== name ||
        promotion.description !== description ||
        !this.sameNullableUuid(promotion.planId, planId) ||
        !this.sameNullableUuid(promotion.branchId, branchId) ||
        promotion.discountKind !== kind ||
        promotion.discountValue !== value ||
        promotion.startsOn !== startsOn ||
        promotion.endsOn !== endsOn ||
        promotion.status !== 'draft'
      ) {
        this.unavailable();
      }

      return promotion;
    } catch (error) {
      this.databaseError(error);
    }
  }

  async setStatus(
    request: GymProAuthenticatedRequest,
    tenantId: string,
    promotionId: string,
    status: 'active' | 'inactive',
    body: unknown,
    expectedBranchId: string | null = null,
  ): Promise<MembershipPromotion> {
    const tokenHash = this.authorize(request, tenantId);

    if (!UUID.test(promotionId)) this.badRequest();
    if (expectedBranchId !== null && !this.validUuid(expectedBranchId)) this.badRequest();
    if (status !== 'active' && status !== 'inactive') this.badRequest();

    if (body !== undefined) {
      const input = this.object(body);
      this.allowedKeys(input, []);
    }

    try {
      const result = await this.pool.query(
        `
          SELECT ${RETURN_COLUMNS}
          FROM ${expectedBranchId === null
            ? `security.set_membership_promotion_status($1::bytea,$2::uuid,$3::uuid,$4::text)`
            : `security.set_branch_membership_promotion_status($1::bytea,$2::uuid,$3::uuid,$4::uuid,$5::text)`}
        `,
        expectedBranchId === null
          ? [tokenHash, tenantId, promotionId, status]
          : [tokenHash, tenantId, expectedBranchId, promotionId, status],
      );

      if (result.rows.length !== 1) this.unavailable();
      const promotion = this.publicPromotion(result.rows[0], tenantId);

      if (
        !this.sameUuid(promotion.id, promotionId) ||
        promotion.status !== status ||
        (expectedBranchId !== null && !this.sameNullableUuid(promotion.branchId, expectedBranchId))
      ) {
        this.unavailable();
      }

      return promotion;
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

  private publicPromotion(
    row: Record<string, unknown>,
    tenantId: string,
  ): MembershipPromotion {
    if (
      !this.validUuid(row.id) ||
      !this.validUuid(row.tenant_id) ||
      !this.sameUuid(row.tenant_id, tenantId) ||
      typeof row.promotion_code !== 'string' ||
      !/^[A-Z][A-Z0-9_]{0,31}$/.test(row.promotion_code) ||
      typeof row.promotion_name !== 'string' ||
      [...row.promotion_name.trim()].length < 2 ||
      [...row.promotion_name.trim()].length > 150 ||
      (row.description !== null && typeof row.description !== 'string') ||
      (row.plan_id !== null && !this.validUuid(row.plan_id)) ||
      (row.branch_id !== null && !this.validUuid(row.branch_id)) ||
      (row.discount_kind !== 'percentage' &&
        row.discount_kind !== 'fixed_amount') ||
      typeof row.discount_value !== 'string' ||
      !DECIMAL.test(row.discount_value) ||
      row.currency_code !== 'MMK' ||
      !this.validDate(row.starts_on) ||
      (row.ends_on !== null &&
        (!this.validDate(row.ends_on) || row.ends_on <= row.starts_on)) ||
      (row.status !== 'draft' &&
        row.status !== 'active' &&
        row.status !== 'inactive') ||
      !this.validTimestamp(row.created_at) ||
      !this.validTimestamp(row.updated_at)
    ) {
      this.unavailable();
    }

    const cents = BigInt(row.discount_value.replace('.', ''));
    if (
      cents <= 0n ||
      (row.discount_kind === 'percentage' && cents > 10000n)
    ) {
      this.unavailable();
    }

    return Object.freeze({
      id: row.id,
      tenantId: row.tenant_id,
      promotionCode: row.promotion_code,
      promotionName: row.promotion_name,
      description: row.description,
      planId: row.plan_id,
      branchId: row.branch_id,
      discountKind: row.discount_kind,
      discountValue: row.discount_value,
      currencyCode: 'MMK',
      startsOn: row.starts_on,
      endsOn: row.ends_on,
      status: row.status,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    });
  }

  private object(value: unknown): Record<string, unknown> {
    if (
      value === null ||
      typeof value !== 'object' ||
      Array.isArray(value)
    ) {
      this.badRequest();
    }

    return value as Record<string, unknown>;
  }

  private allowedKeys(
    input: Record<string, unknown>,
    allowed: readonly string[],
  ): void {
    if (Object.keys(input).some((key) => !allowed.includes(key))) {
      this.badRequest();
    }
  }

  private optionalUuid(value: unknown): string | null {
    if (value === undefined || value === null) return null;
    if (!this.validUuid(value)) this.badRequest();
    return value;
  }

  private inputDecimal(value: unknown): string {
    if (
      typeof value !== 'string' ||
      !/^(0|[1-9][0-9]{0,11})(\.[0-9]{1,2})?$/.test(value)
    ) {
      this.badRequest();
    }

    const [whole, fraction = ''] = value.split('.');
    return `${whole}.${fraction.padEnd(2, '0')}`;
  }

  private validUuid(value: unknown): value is string {
    return typeof value === 'string' && UUID.test(value);
  }

  private sameUuid(left: string, right: string): boolean {
    return left.toLowerCase() === right.toLowerCase();
  }

  private sameNullableUuid(
    left: string | null,
    right: string | null,
  ): boolean {
    return left === null || right === null
      ? left === right
      : this.sameUuid(left, right);
  }

  private validDate(value: unknown): value is string {
    if (
      typeof value !== 'string' ||
      !/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(value) ||
      value.startsWith('0000-')
    ) {
      return false;
    }

    const date = new Date(`${value}T00:00:00.000Z`);
    return (
      Number.isFinite(date.getTime()) &&
      date.toISOString().slice(0, 10) === value
    );
  }

  private validTimestamp(value: unknown): value is Date {
    return value instanceof Date && Number.isFinite(value.getTime());
  }

  private badRequest(): never {
    throw new BadRequestException('Invalid promotion request');
  }

  private unavailable(): never {
    throw new ServiceUnavailableException(
      'Promotion management is unavailable',
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
        'Branch access denied',
        'Promotion management permission denied',
      ].includes(failure.message ?? '')
    ) {
      throw new ForbiddenException('Promotion management access denied');
    }

    if (failure?.code === '22023') this.badRequest();
    this.unavailable();
  }
}

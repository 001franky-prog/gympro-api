import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  BadRequestException,
  ForbiddenException,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';
import type { ConfigService } from '@nestjs/config';
import type { GymProAuthenticatedRequest } from '../auth/authenticated-session.guard.js';
import type { SessionBearerTokenService } from '../auth/session-bearer-token.service.js';

const database = vi.hoisted(() => ({
  query: vi.fn(),
  end: vi.fn(),
  on: vi.fn(),
}));

vi.mock('pg', () => ({
  Pool: class {
    query = database.query;
    end = database.end;
    on = database.on;
  },
}));

import { MembershipPromotionService } from './membership-promotion.service.js';

const tenant = 'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b';
const otherTenant = 'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc';
const promotionId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

const identity = {
  database_name: 'gympro_saas',
  database_user: 'gympro_app',
  is_superuser: false,
  bypasses_rls: false,
  security_schema_usage: true,
  can_create: true,
  can_set_status: true,
  can_call_calculator: false,
  direct_promotion_access: false,
};

const row = {
  id: promotionId,
  tenant_id: tenant,
  promotion_code: 'MONTHLY10',
  promotion_name: 'Monthly discount',
  description: null,
  plan_id: null,
  branch_id: null,
  discount_kind: 'percentage',
  discount_value: '10.00',
  currency_code: 'MMK',
  starts_on: '2026-10-14',
  ends_on: null,
  status: 'draft',
  created_at: new Date('2026-10-14T12:00:00Z'),
  updated_at: new Date('2026-10-14T12:00:00Z'),
};

function request(): GymProAuthenticatedRequest {
  return {
    headers: { authorization: 'Bearer test-only-token' },
    gymproSession: {
      sessionId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      tenantId: tenant,
      membershipId: '3b318e89-f3bc-4ac5-a04d-09fdb3d626de',
      userId: '059e261a-226a-4f9e-93ee-86d374430406',
    },
  } as GymProAuthenticatedRequest;
}

function input() {
  return {
    promotionCode: 'MONTHLY10',
    promotionName: 'Monthly discount',
    discountKind: 'percentage',
    discountValue: '10',
    startsOn: '2026-10-14',
  };
}

describe('Gym Pro MembershipPromotionService', () => {
  let service: MembershipPromotionService;
  let hashAuthorization: ReturnType<typeof vi.fn>;

  function makeService() {
    return new MembershipPromotionService(
      {
        get: vi.fn().mockReturnValue('postgresql://test-only'),
      } as unknown as ConfigService,
      {
        hashAuthorization,
      } as unknown as SessionBearerTokenService,
    );
  }

  beforeEach(async () => {
    vi.clearAllMocks();
    database.end.mockResolvedValue(undefined);
    database.query.mockReset();
    database.query.mockResolvedValueOnce({ rows: [{ ...identity }] });

    hashAuthorization = vi.fn().mockReturnValue(Buffer.alloc(32, 1));
    service = makeService();
    await service.onModuleInit();

    database.query.mockResolvedValue({ rows: [{ ...row }] });
  });

  it('creates a normalized draft using parameterized SQL', async () => {
    const result = await service.create(request(), tenant, {
      ...input(),
      promotionCode: ' MONTHLY10 ',
      promotionName: ' Monthly discount ',
      description: '   ',
    });

    const [sql, values] = database.query.mock.calls.at(-1)!;
    expect(sql).toContain('security.create_membership_promotion');
    expect(values).toEqual([
      Buffer.alloc(32, 1),
      tenant,
      'MONTHLY10',
      'Monthly discount',
      null,
      null,
      null,
      'percentage',
      '10.00',
      '2026-10-14',
      null,
    ]);
    expect(result.discountValue).toBe('10.00');
    expect(result.status).toBe('draft');
    expect(Object.isFrozen(result)).toBe(true);
  });

  it('returns only public promotion fields', async () => {
    database.query.mockResolvedValueOnce({
      rows: [{ ...row, internal_secret: 'private-test-field' }],
    });
    const result = await service.create(request(), tenant, input());
    expect(result).not.toHaveProperty('internal_secret');
    expect(result).not.toHaveProperty('tenant_id');
  });

  it('activates with an empty body', async () => {
    database.query.mockResolvedValueOnce({
      rows: [{ ...row, status: 'active' }],
    });
    const result = await service.setStatus(
      request(), tenant, promotionId, 'active', {},
    );
    expect(result.status).toBe('active');
    expect(database.query.mock.calls.at(-1)![1]).toEqual([
      Buffer.alloc(32, 1), tenant, promotionId, 'active',
    ]);
  });

  it('deactivates with an absent body', async () => {
    database.query.mockResolvedValueOnce({
      rows: [{ ...row, status: 'inactive' }],
    });
    const result = await service.setStatus(
      request(), tenant, promotionId, 'inactive', undefined,
    );
    expect(result.status).toBe('inactive');
  });

  it('rejects a missing verified session', async () => {
    const req = request();
    delete req.gymproSession;
    await expect(service.create(req, tenant, input()))
      .rejects.toBeInstanceOf(UnauthorizedException);
  });

  it('rejects another route tenant', async () => {
    await expect(service.create(request(), otherTenant, input()))
      .rejects.toBeInstanceOf(ForbiddenException);
  });

  it('rejects an invalid token hash length', async () => {
    hashAuthorization.mockReturnValue(Buffer.alloc(31));
    await expect(service.create(request(), tenant, input()))
      .rejects.toBeInstanceOf(UnauthorizedException);
  });

  it('rejects creation before startup verification', async () => {
    const unverified = makeService();
    await expect(unverified.create(request(), tenant, input()))
      .rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it.each([
    ['client tenant', { tenantId: tenant }],
    ['client status', { status: 'active' }],
    ['client currency', { currencyCode: 'USD' }],
    ['lowercase code', { promotionCode: 'monthly10' }],
    ['short name', { promotionName: 'A' }],
    ['numeric discount', { discountValue: 10 }],
    ['zero discount', { discountValue: '0' }],
    ['excess percentage', { discountValue: '100.01' }],
    ['excess precision', { discountValue: '10.001' }],
    ['invalid kind', { discountKind: 'unknown' }],
    ['invalid plan', { planId: 'invalid' }],
    ['invalid branch', { branchId: 'invalid' }],
    ['invalid calendar date', { startsOn: '2026-02-30' }],
    ['reversed dates', { endsOn: '2026-10-13' }],
  ])('rejects %s', async (_name, changes) => {
    const before = database.query.mock.calls.length;
    await expect(service.create(request(), tenant, {
      ...input(), ...changes,
    })).rejects.toBeInstanceOf(BadRequestException);
    expect(database.query.mock.calls.length).toBe(before);
  });

  it.each([null, [], 'text'])('rejects invalid body %j', async (body) => {
    await expect(service.create(request(), tenant, body))
      .rejects.toBeInstanceOf(BadRequestException);
  });

  it('rejects client-controlled status-change fields', async () => {
    await expect(service.setStatus(
      request(), tenant, promotionId, 'active', { status: 'active' },
    )).rejects.toBeInstanceOf(BadRequestException);
  });

  it('rejects a malformed promotion identifier', async () => {
    await expect(service.setStatus(
      request(), tenant, 'invalid', 'active', {},
    )).rejects.toBeInstanceOf(BadRequestException);
  });

  it.each([
    ['invalid session', '28000', 'Invalid or expired session', UnauthorizedException],
    ['missing permission', '42501', 'Promotion management permission denied', ForbiddenException],
    ['invalid data', '22023', 'Private database validation detail', BadRequestException],
    ['privilege configuration', '42501', 'permission denied for function', ServiceUnavailableException],
    ['connection failure', 'ECONNREFUSED', 'Private connection detail', ServiceUnavailableException],
  ])('maps %s safely', async (_name, code, message, exception) => {
    database.query.mockRejectedValueOnce({ code, message });
    await expect(service.create(request(), tenant, input()))
      .rejects.toBeInstanceOf(exception);
  });

  it.each([
    ['another tenant', { tenant_id: otherTenant }],
    ['invalid identifier', { id: 'invalid' }],
    ['numeric decimal', { discount_value: 10 }],
    ['invalid date', { starts_on: '2026-02-30' }],
    ['unexpected creation status', { status: 'active' }],
    ['invalid timestamp', { created_at: new Date('invalid') }],
    ['incorrect normalized value', { discount_value: '11.00' }],
  ])('rejects returned %s', async (_name, changes) => {
    database.query.mockResolvedValueOnce({
      rows: [{ ...row, ...changes }],
    });
    await expect(service.create(request(), tenant, input()))
      .rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it('rejects an empty result', async () => {
    database.query.mockResolvedValueOnce({ rows: [] });
    await expect(service.create(request(), tenant, input()))
      .rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it.each([
    ['administrator account', { database_user: 'postgres', is_superuser: true }],
    ['direct table access', { direct_promotion_access: true }],
    ['internal calculator access', { can_call_calculator: true }],
    ['missing function execution', { can_create: false }],
  ])('rejects startup with %s', async (_name, changes) => {
    database.query.mockResolvedValueOnce({
      rows: [{ ...identity, ...changes }],
    });
    const unsafe = makeService();
    await expect(unsafe.onModuleInit())
      .rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it('closes the pool and blocks requests after shutdown', async () => {
    await service.onModuleDestroy();
    expect(database.end).toHaveBeenCalledOnce();
    await expect(service.create(request(), tenant, input()))
      .rejects.toBeInstanceOf(ServiceUnavailableException);
  });
});
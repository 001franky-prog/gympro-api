import 'reflect-metadata';

import {
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from 'vitest';

import {
  BadRequestException,
  ForbiddenException,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';

import type { ConfigService } from '@nestjs/config';

import type {
  GymProAuthenticatedRequest,
} from '../auth/authenticated-session.guard.js';

import type {
  SessionBearerTokenService,
} from '../auth/session-bearer-token.service.js';

const database = vi.hoisted(() => ({
  query: vi.fn(),
  on: vi.fn(),
  end: vi.fn(),
}));

vi.mock('pg', () => ({
  default: {
    Pool: class {
      query = database.query;
      on = database.on;
      end = database.end;
    },
  },
}));

import {
  SubscriptionActivationService,
} from './subscription-activation.service.js';

const tenantId = '11111111-1111-4111-8111-111111111111';
const otherTenantId = '22222222-2222-4222-8222-222222222222';
const memberId = '33333333-3333-4333-8333-333333333333';
const planId = '44444444-4444-4444-8444-444444444444';
const priceId = '55555555-5555-4555-8555-555555555555';
const branchId = '66666666-6666-4666-8666-666666666666';
const tokenHash = Buffer.alloc(32, 0xab);

const body = { planId, planPriceId: priceId };

const bearer = {
  hashAuthorization: vi.fn(),
};

function request(): GymProAuthenticatedRequest {
  return {
    headers: {
      authorization: 'Bearer test-only-token',
    },
    gymproSession: {
      sessionId: '77777777-7777-4777-8777-777777777777',
      tenantId,
      membershipId: '88888888-8888-4888-8888-888888888888',
      userId: '99999999-9999-4999-8999-999999999999',
    },
  };
}

function runtimeIdentity() {
  return {
    database_name: 'gympro_saas',
    database_user: 'gympro_app',
    is_superuser: false,
    bypasses_rls: false,
    schema_usage: true,
    can_execute: true,
    can_select: false,
    can_insert: false,
    can_update: false,
    can_delete: false,
  };
}

function subscriptionRow(branch: string | null = null) {
  return {
    id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    tenant_id: tenantId,
    member_id: memberId,
    branch_id: branch,
    plan_id: planId,
    plan_price_id: priceId,
    duration_value: 1,
    duration_unit: 'months',
    agreed_price_amount: '50000.25',
    currency_code: 'MMK',
    status: 'active',
    starts_on: '2026-10-14',
    ends_on: '2026-11-14',
    activated_at: new Date('2026-10-14T06:00:00.000Z'),
    suspended_at: null,
    created_at: new Date('2026-10-14T06:00:00.000Z'),
    updated_at: new Date('2026-10-14T06:00:00.000Z'),
  };
}

function createService(): SubscriptionActivationService {
  const config = {
    get: vi.fn(() =>
      'postgresql://gympro_app@127.0.0.1:1/gympro_saas',
    ),
  };

  return new SubscriptionActivationService(
    config as unknown as ConfigService,
    bearer as unknown as SessionBearerTokenService,
  );
}

describe('Gym Pro SubscriptionActivationService', () => {
  let service: SubscriptionActivationService;

  beforeEach(async () => {
    vi.resetAllMocks();

    bearer.hashAuthorization.mockReturnValue(tokenHash);
    database.query.mockResolvedValueOnce({
      rows: [runtimeIdentity()],
    });

    service = createService();
    await service.onModuleInit();

    database.query.mockReset();
  });

  it.each([
    ['tenant-wide', null],
    ['branch member', branchId],
  ])('activates a %s subscription', async (_name, branch) => {
    const row = subscriptionRow(branch);
    database.query.mockResolvedValueOnce({ rows: [row] });

    const result = await service.activate(
      request(), tenantId, memberId, body,
    );

    expect(database.query).toHaveBeenCalledTimes(1);

    const [sql, parameters] = database.query.mock.calls[0];

    expect(sql).toContain('security.activate_member_subscription');
    expect(sql).toContain('$1::bytea');
    expect(sql).toContain('$5::uuid');
    expect(parameters).toEqual([
      tokenHash, tenantId, memberId, planId, priceId,
    ]);

    expect(result).toEqual({
      id: row.id,
      tenantId,
      memberId,
      branchId: branch,
      planId,
      planPriceId: priceId,
      durationValue: 1,
      durationUnit: 'months',
      agreedPriceAmount: '50000.25',
      currencyCode: 'MMK',
      status: 'active',
      startsOn: '2026-10-14',
      endsOn: '2026-11-14',
      activatedAt: row.activated_at,
      suspendedAt: null,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    });

    expect(Object.isFrozen(result)).toBe(true);
  });

  it('rejects a missing verified session', async () => {
    await expect(
      service.activate({}, tenantId, memberId, body),
    ).rejects.toBeInstanceOf(UnauthorizedException);

    expect(database.query).not.toHaveBeenCalled();
    expect(bearer.hashAuthorization).not.toHaveBeenCalled();
  });

  it('rejects another route tenant', async () => {
    await expect(
      service.activate(request(), otherTenantId, memberId, body),
    ).rejects.toBeInstanceOf(ForbiddenException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it('rejects a malformed member identifier', async () => {
    await expect(
      service.activate(request(), tenantId, 'invalid', body),
    ).rejects.toBeInstanceOf(BadRequestException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it.each([
    ['tenantId', otherTenantId],
    ['memberId', memberId],
    ['status', 'active'],
    ['startsOn', '2026-10-14'],
    ['agreedPriceAmount', '1.00'],
  ])('rejects client-controlled %s', async (field, value) => {
    await expect(
      service.activate(
        request(),
        tenantId,
        memberId,
        { ...body, [field]: value },
      ),
    ).rejects.toBeInstanceOf(BadRequestException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it('rejects a missing plan price', async () => {
    await expect(
      service.activate(request(), tenantId, memberId, { planId }),
    ).rejects.toBeInstanceOf(BadRequestException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it('rejects an invalid token hash length', async () => {
    bearer.hashAuthorization.mockReturnValue(Buffer.alloc(1));

    await expect(
      service.activate(request(), tenantId, memberId, body),
    ).rejects.toBeInstanceOf(UnauthorizedException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it('rejects activation before startup verification', async () => {
    const uninitialized = createService();

    await expect(
      uninitialized.activate(request(), tenantId, memberId, body),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it.each([
    {
      name: 'invalid session',
      code: '28000',
      message: 'Invalid or expired session',
      exception: UnauthorizedException,
    },
    {
      name: 'missing permission',
      code: '42501',
      message: 'Membership management permission denied',
      exception: ForbiddenException,
    },
    {
      name: 'duplicate activation',
      code: '22023',
      message: 'Member already has a current subscription',
      exception: BadRequestException,
    },
    {
      name: 'database privilege configuration failure',
      code: '42501',
      message: 'permission denied for function activate_member_subscription',
      exception: ServiceUnavailableException,
    },
    {
      name: 'database connection failure',
      code: 'ECONNREFUSED',
      message: 'private-database-connection-details',
      exception: ServiceUnavailableException,
    },
  ])('handles $name safely', async (test) => {
    database.query.mockRejectedValueOnce({
      code: test.code,
      message: test.message,
    });

    let caught: unknown;

    try {
      await service.activate(request(), tenantId, memberId, body);
    } catch (error) {
      caught = error;
    }

    expect(caught).toBeInstanceOf(test.exception);

    if (caught instanceof ServiceUnavailableException) {
      expect(JSON.stringify(caught.getResponse()))
        .not.toContain(test.message);
    }
  });

  it('rejects a returned subscription from another tenant', async () => {
    database.query.mockResolvedValueOnce({
      rows: [{
        ...subscriptionRow(),
        tenant_id: otherTenantId,
      }],
    });

    await expect(
      service.activate(request(), tenantId, memberId, body),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it('rejects an empty function result', async () => {
    database.query.mockResolvedValueOnce({ rows: [] });

    await expect(
      service.activate(request(), tenantId, memberId, body),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it.each([
    ['invalid calendar date', { starts_on: '2026-02-30' }],
    ['reversed dates', { ends_on: '2026-10-13' }],
    ['numeric price instead of decimal text', { agreed_price_amount: 50000 }],
    ['unexpected status', { status: 'pending' }],
    ['invalid activation timestamp', { activated_at: new Date('invalid') }],
  ])('rejects a returned %s', async (_name, change) => {
    database.query.mockResolvedValueOnce({
      rows: [{ ...subscriptionRow(), ...change }],
    });

    await expect(
      service.activate(request(), tenantId, memberId, body),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it.each([
    [
      'administrator database account',
      { database_user: 'postgres', is_superuser: true },
    ],
    [
      'direct subscription access',
      { can_select: true },
    ],
  ])('rejects startup with %s', async (_name, change) => {
    database.query.mockResolvedValueOnce({
      rows: [{ ...runtimeIdentity(), ...change }],
    });

    const unsafeService = createService();

    await expect(
      unsafeService.onModuleInit(),
    ).rejects.toThrow('requires gympro_app');

    await expect(
      unsafeService.activate(request(), tenantId, memberId, body),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);

    expect(database.query).toHaveBeenCalledTimes(1);
  });
});
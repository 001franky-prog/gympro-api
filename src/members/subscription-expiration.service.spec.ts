import 'reflect-metadata';

import { beforeEach, describe, expect, it, vi } from 'vitest';

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
  SubscriptionExpirationService,
} from './subscription-expiration.service.js';

const tenantId = '11111111-1111-4111-8111-111111111111';
const otherTenantId = '22222222-2222-4222-8222-222222222222';
const subscriptionId = '33333333-3333-4333-8333-333333333333';
const tokenHash = Buffer.alloc(32, 0xab);

const bearer = { hashAuthorization: vi.fn() };

function request(): GymProAuthenticatedRequest {
  return {
    headers: { authorization: 'Bearer test-only-token' },
    gymproSession: {
      sessionId: '77777777-7777-4777-8777-777777777777',
      tenantId,
      membershipId: '88888888-8888-4888-8888-888888888888',
      userId: '99999999-9999-4999-8999-999999999999',
    },
  };
}

function identity() {
  return {
    database_name: 'gympro_saas',
    database_user: 'gympro_app',
    is_superuser: false,
    bypasses_rls: false,
    schema_usage: true,
    can_execute: true,
    history_select: false,
    history_insert: false,
    history_update: false,
    history_delete: false,
    subscription_select: false,
    subscription_insert: false,
    subscription_update: false,
    subscription_delete: false,
  };
}

function expirationRow() {
  return {
    id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    tenant_id: tenantId,
    subscription_id: subscriptionId,
    coverage_starts_on: '2026-09-14',
    coverage_ends_on: '2026-10-14',
    processed_on: '2026-10-14',
    expired_at: new Date('2026-10-14T06:00:00.000Z'),
    created_at: new Date('2026-10-14T06:00:00.000Z'),
  };
}

function createService() {
  const config = {
    get: vi.fn(() =>
      'postgresql://gympro_app@127.0.0.1:1/gympro_saas',
    ),
  };

  return new SubscriptionExpirationService(
    config as unknown as ConfigService,
    bearer as unknown as SessionBearerTokenService,
  );
}

describe('Gym Pro SubscriptionExpirationService', () => {
  let service: SubscriptionExpirationService;

  beforeEach(async () => {
    vi.resetAllMocks();
    bearer.hashAuthorization.mockReturnValue(tokenHash);
    database.query.mockResolvedValueOnce({ rows: [identity()] });

    service = createService();
    await service.onModuleInit();
    database.query.mockReset();
  });

  it.each([
    ['empty object', {}],
    ['absent body', undefined],
  ])('accepts an %s and returns only public receipt fields', async (_name, body) => {
    const row = expirationRow();

    database.query.mockResolvedValueOnce({
      rows: [{
        ...row,
        previous_subscription_snapshot: {
          private_audit_data: 'must-not-be-returned',
        },
      }],
    });

    const result = await service.expire(
      request(), tenantId, subscriptionId, body,
    );

    const [sql, parameters] = database.query.mock.calls[0];

    expect(sql).toContain('security.expire_member_subscription');
    expect(sql).toContain('$1::bytea');
    expect(sql).toContain('$3::uuid');
    expect(sql).not.toContain('previous_subscription_snapshot');
    expect(parameters).toEqual([
      tokenHash, tenantId, subscriptionId,
    ]);

    expect(result).toEqual({
      id: row.id,
      tenantId,
      subscriptionId,
      coverageStartsOn: '2026-09-14',
      coverageEndsOn: '2026-10-14',
      processedOn: '2026-10-14',
      expiredAt: row.expired_at,
      createdAt: row.created_at,
    });

    expect(Object.isFrozen(result)).toBe(true);
    expect(result).not.toHaveProperty('previous_subscription_snapshot');
  });

  it('returns the same receipt on repeated processing', async () => {
    database.query.mockResolvedValue({ rows: [expirationRow()] });

    const first = await service.expire(
      request(), tenantId, subscriptionId, {},
    );

    const retry = await service.expire(
      request(), tenantId, subscriptionId, {},
    );

    expect(retry).toEqual(first);
    expect(database.query.mock.calls[0][1])
      .toEqual(database.query.mock.calls[1][1]);
  });

  it('accepts processing after the coverage end date', async () => {
    database.query.mockResolvedValueOnce({
      rows: [{ ...expirationRow(), processed_on: '2026-10-15' }],
    });

    const result = await service.expire(
      request(), tenantId, subscriptionId, {},
    );

    expect(result.processedOn).toBe('2026-10-15');
  });

  it('rejects a missing verified session', async () => {
    await expect(
      service.expire({}, tenantId, subscriptionId, {}),
    ).rejects.toBeInstanceOf(UnauthorizedException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it('rejects another route tenant', async () => {
    await expect(
      service.expire(request(), otherTenantId, subscriptionId, {}),
    ).rejects.toBeInstanceOf(ForbiddenException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it('rejects a malformed subscription identifier', async () => {
    await expect(
      service.expire(request(), tenantId, 'invalid', {}),
    ).rejects.toBeInstanceOf(BadRequestException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it.each([
    ['client processing date', { processedOn: '2099-01-01' }],
    ['client end date', { coverageEndsOn: '2026-01-01' }],
    ['client tenant', { tenantId: otherTenantId }],
    ['client status', { status: 'expired' }],
    ['null', null],
    ['array', []],
    ['string', 'expire'],
  ])('rejects a body containing %s', async (_name, body) => {
    await expect(
      service.expire(request(), tenantId, subscriptionId, body),
    ).rejects.toBeInstanceOf(BadRequestException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it('rejects an invalid token hash length', async () => {
    bearer.hashAuthorization.mockReturnValue(Buffer.alloc(1));

    await expect(
      service.expire(request(), tenantId, subscriptionId, {}),
    ).rejects.toBeInstanceOf(UnauthorizedException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it('rejects expiration before startup verification', async () => {
    const uninitialized = createService();

    await expect(
      uninitialized.expire(request(), tenantId, subscriptionId, {}),
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
      name: 'not due for expiration',
      code: '22023',
      message: 'Subscription is not due for expiration',
      exception: BadRequestException,
    },
    {
      name: 'database privilege failure',
      code: '42501',
      message: 'permission denied for function expire_member_subscription',
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
      await service.expire(request(), tenantId, subscriptionId, {});
    } catch (error) {
      caught = error;
    }

    expect(caught).toBeInstanceOf(test.exception);

    if (caught instanceof ServiceUnavailableException) {
      expect(JSON.stringify(caught.getResponse()))
        .not.toContain(test.message);
    }
  });

  it.each([
    ['another tenant', { tenant_id: otherTenantId }],
    ['another subscription', { subscription_id: tenantId }],
    ['invalid calendar date', { coverage_starts_on: '2026-02-30' }],
    ['reversed coverage', { coverage_ends_on: '2026-09-13' }],
    ['processing before coverage end', { processed_on: '2026-10-13' }],
    ['invalid processing date', { processed_on: '2026-02-30' }],
    ['invalid expiration timestamp', { expired_at: new Date('invalid') }],
    ['invalid creation timestamp', { created_at: new Date('invalid') }],
  ])('rejects a returned receipt with %s', async (_name, change) => {
    database.query.mockResolvedValueOnce({
      rows: [{ ...expirationRow(), ...change }],
    });

    await expect(
      service.expire(request(), tenantId, subscriptionId, {}),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it('rejects an empty function result', async () => {
    database.query.mockResolvedValueOnce({ rows: [] });

    await expect(
      service.expire(request(), tenantId, subscriptionId, {}),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it.each([
    ['administrator account', {
      database_user: 'postgres',
      is_superuser: true,
    }],
    ['direct history access', { history_select: true }],
    ['direct subscription update', { subscription_update: true }],
  ])('rejects startup with %s', async (_name, change) => {
    database.query.mockResolvedValueOnce({
      rows: [{ ...identity(), ...change }],
    });

    const unsafeService = createService();

    await expect(
      unsafeService.onModuleInit(),
    ).rejects.toThrow('requires gympro_app');

    await expect(
      unsafeService.expire(request(), tenantId, subscriptionId, {}),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);

    expect(database.query).toHaveBeenCalledTimes(1);
  });

  it('closes the pool and blocks expiration after shutdown', async () => {
    database.end.mockResolvedValueOnce(undefined);

    await service.onModuleDestroy();

    expect(database.end).toHaveBeenCalledTimes(1);

    await expect(
      service.expire(request(), tenantId, subscriptionId, {}),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);

    expect(database.query).not.toHaveBeenCalled();
  });
});
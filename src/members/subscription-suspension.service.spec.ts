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
  SubscriptionSuspensionService,
} from './subscription-suspension.service.js';

const tenantId = '11111111-1111-4111-8111-111111111111';
const otherTenantId = '22222222-2222-4222-8222-222222222222';
const subscriptionId = '33333333-3333-4333-8333-333333333333';
const requestId = '44444444-4444-4444-8444-444444444444';
const tokenHash = Buffer.alloc(32, 0xab);

const body = {
  reason: '  Temporary medical pause  ',
  requestId,
};

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

function suspensionRow() {
  return {
    id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    tenant_id: tenantId,
    subscription_id: subscriptionId,
    request_id: requestId,
    reason: 'Temporary medical pause',
    suspended_at: new Date('2026-10-14T06:00:00.000Z'),
    created_at: new Date('2026-10-14T06:00:00.000Z'),
  };
}

function createService() {
  const config = {
    get: vi.fn(() =>
      'postgresql://gympro_app@127.0.0.1:1/gympro_saas',
    ),
  };

  return new SubscriptionSuspensionService(
    config as unknown as ConfigService,
    bearer as unknown as SessionBearerTokenService,
  );
}

describe('Gym Pro SubscriptionSuspensionService', () => {
  let service: SubscriptionSuspensionService;

  beforeEach(async () => {
    vi.resetAllMocks();
    bearer.hashAuthorization.mockReturnValue(tokenHash);
    database.query.mockResolvedValueOnce({ rows: [identity()] });

    service = createService();
    await service.onModuleInit();
    database.query.mockReset();
  });

  it('normalizes the reason and returns only public receipt fields', async () => {
    const row = suspensionRow();

    database.query.mockResolvedValueOnce({
      rows: [{
        ...row,
        previous_subscription_snapshot: {
          private_audit_data: 'must-not-be-returned',
        },
      }],
    });

    const result = await service.suspend(
      request(), tenantId, subscriptionId, body,
    );

    const [sql, parameters] = database.query.mock.calls[0];

    expect(sql).toContain('security.suspend_member_subscription');
    expect(sql).toContain('$4::text');
    expect(sql).toContain('$5::uuid');
    expect(sql).not.toContain('previous_subscription_snapshot');

    expect(parameters).toEqual([
      tokenHash,
      tenantId,
      subscriptionId,
      'Temporary medical pause',
      requestId,
    ]);

    expect(result).toEqual({
      id: row.id,
      tenantId,
      subscriptionId,
      requestId,
      reason: 'Temporary medical pause',
      suspendedAt: row.suspended_at,
      createdAt: row.created_at,
    });

    expect(Object.isFrozen(result)).toBe(true);
    expect(result).not.toHaveProperty('previous_subscription_snapshot');
  });

  it('preserves the request UUID and normalized reason on retry', async () => {
    database.query.mockResolvedValue({ rows: [suspensionRow()] });

    const first = await service.suspend(
      request(), tenantId, subscriptionId, body,
    );

    const retry = await service.suspend(
      request(), tenantId, subscriptionId,
      { reason: 'Temporary medical pause', requestId },
    );

    expect(retry).toEqual(first);
    expect(database.query.mock.calls[0][1])
      .toEqual(database.query.mock.calls[1][1]);
  });

  it('accepts 500 Unicode code points', async () => {
    const reason = '😀'.repeat(500);

    database.query.mockResolvedValueOnce({
      rows: [{ ...suspensionRow(), reason }],
    });

    const result = await service.suspend(
      request(), tenantId, subscriptionId, { reason, requestId },
    );

    expect(result.reason).toBe(reason);
  });

  it('rejects a missing verified session', async () => {
    await expect(
      service.suspend({}, tenantId, subscriptionId, body),
    ).rejects.toBeInstanceOf(UnauthorizedException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it('rejects another route tenant', async () => {
    await expect(
      service.suspend(request(), otherTenantId, subscriptionId, body),
    ).rejects.toBeInstanceOf(ForbiddenException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it('rejects a malformed subscription identifier', async () => {
    await expect(
      service.suspend(request(), tenantId, 'invalid', body),
    ).rejects.toBeInstanceOf(BadRequestException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it.each([
    ['tenantId', otherTenantId],
    ['subscriptionId', subscriptionId],
    ['status', 'suspended'],
    ['suspendedAt', '2026-01-01T00:00:00.000Z'],
    ['endsOn', '2099-01-01'],
  ])('rejects client-controlled %s', async (field, value) => {
    await expect(
      service.suspend(
        request(), tenantId, subscriptionId,
        { ...body, [field]: value },
      ),
    ).rejects.toBeInstanceOf(BadRequestException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it.each([
    ['blank', ''],
    ['spaces', '   '],
    ['tabs', '\t\t'],
    ['one character', 'A'],
    ['501 characters', 'A'.repeat(501)],
    ['501 Unicode code points', '😀'.repeat(501)],
    ['non-string', 123],
  ])('rejects a %s reason', async (_name, reason) => {
    await expect(
      service.suspend(
        request(), tenantId, subscriptionId,
        { reason, requestId },
      ),
    ).rejects.toBeInstanceOf(BadRequestException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it.each([
    ['missing', { reason: 'Test pause' }],
    ['malformed', { reason: 'Test pause', requestId: 'invalid' }],
  ])('rejects a %s request UUID', async (_name, input) => {
    await expect(
      service.suspend(request(), tenantId, subscriptionId, input),
    ).rejects.toBeInstanceOf(BadRequestException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it('rejects an invalid token hash length', async () => {
    bearer.hashAuthorization.mockReturnValue(Buffer.alloc(1));

    await expect(
      service.suspend(request(), tenantId, subscriptionId, body),
    ).rejects.toBeInstanceOf(UnauthorizedException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it('rejects suspension before startup verification', async () => {
    const uninitialized = createService();

    await expect(
      uninitialized.suspend(request(), tenantId, subscriptionId, body),
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
      name: 'request conflict',
      code: '22023',
      message: 'Request ID already belongs to another suspension request',
      exception: BadRequestException,
    },
    {
      name: 'database privilege failure',
      code: '42501',
      message: 'permission denied for function suspend_member_subscription',
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
      await service.suspend(request(), tenantId, subscriptionId, body);
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
    ['another subscription', { subscription_id: requestId }],
    ['another request', { request_id: subscriptionId }],
    ['different reason', { reason: 'Unexpected reason' }],
    ['invalid suspension timestamp', { suspended_at: new Date('invalid') }],
    ['invalid creation timestamp', { created_at: new Date('invalid') }],
  ])('rejects a returned receipt with %s', async (_name, change) => {
    database.query.mockResolvedValueOnce({
      rows: [{ ...suspensionRow(), ...change }],
    });

    await expect(
      service.suspend(request(), tenantId, subscriptionId, body),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it('rejects an empty function result', async () => {
    database.query.mockResolvedValueOnce({ rows: [] });

    await expect(
      service.suspend(request(), tenantId, subscriptionId, body),
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
      unsafeService.suspend(request(), tenantId, subscriptionId, body),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);

    expect(database.query).toHaveBeenCalledTimes(1);
  });

  it('closes the pool and blocks suspension after shutdown', async () => {
    database.end.mockResolvedValueOnce(undefined);

    await service.onModuleDestroy();

    expect(database.end).toHaveBeenCalledTimes(1);

    await expect(
      service.suspend(request(), tenantId, subscriptionId, body),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);

    expect(database.query).not.toHaveBeenCalled();
  });
});
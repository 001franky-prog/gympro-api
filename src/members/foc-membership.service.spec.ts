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

import { FocMembershipService } from './foc-membership.service.js';

const tenantId = '11111111-1111-4111-8111-111111111111';
const otherTenantId = '22222222-2222-4222-8222-222222222222';
const memberId = '33333333-3333-4333-8333-333333333333';
const planId = '44444444-4444-4444-8444-444444444444';
const priceId = '55555555-5555-4555-8555-555555555555';
const requestId = '66666666-6666-4666-8666-666666666666';
const tokenHash = Buffer.alloc(32, 0xab);

const body = {
  planId,
  planPriceId: priceId,
  reason: '  Complimentary verification  ',
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

function grantRow() {
  return {
    id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    tenant_id: tenantId,
    subscription_id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    request_id: requestId,
    reason: 'Complimentary verification',
    listed_price_amount: '50000.25',
    currency_code: 'MMK',
    granted_at: new Date('2026-10-14T06:00:00.000Z'),
    created_at: new Date('2026-10-14T06:00:00.000Z'),
  };
}

function createService() {
  const config = {
    get: vi.fn(() =>
      'postgresql://gympro_app@127.0.0.1:1/gympro_saas',
    ),
  };

  return new FocMembershipService(
    config as unknown as ConfigService,
    bearer as unknown as SessionBearerTokenService,
  );
}

describe('Gym Pro FocMembershipService', () => {
  let service: FocMembershipService;

  beforeEach(async () => {
    vi.resetAllMocks();
    bearer.hashAuthorization.mockReturnValue(tokenHash);
    database.query.mockResolvedValueOnce({ rows: [identity()] });

    service = createService();
    await service.onModuleInit();
    database.query.mockReset();
  });

  it('normalizes input and returns only public grant fields', async () => {
    const row = grantRow();

    database.query.mockResolvedValueOnce({
      rows: [{
        ...row,
        previous_member_snapshot: { private: 'not-for-response' },
      }],
    });

    const result = await service.grant(
      request(), tenantId, memberId, body,
    );

    const [sql, parameters] = database.query.mock.calls[0];

    expect(sql).toContain('security.grant_foc_membership');
    expect(sql).toContain('$7::uuid');
    expect(sql).not.toContain('previous_member_snapshot');

    expect(parameters).toEqual([
      tokenHash,
      tenantId,
      memberId,
      planId,
      priceId,
      'Complimentary verification',
      requestId,
    ]);

    expect(result).toEqual({
      id: row.id,
      tenantId,
      subscriptionId: row.subscription_id,
      requestId,
      reason: 'Complimentary verification',
      listedPriceAmount: '50000.25',
      currencyCode: 'MMK',
      grantedAt: row.granted_at,
      createdAt: row.created_at,
    });

    expect(Object.isFrozen(result)).toBe(true);
    expect(result).not.toHaveProperty('previous_member_snapshot');
  });

  it('preserves request parameters on retry', async () => {
    database.query.mockResolvedValue({ rows: [grantRow()] });

    const first = await service.grant(
      request(), tenantId, memberId, body,
    );

    const retry = await service.grant(
      request(), tenantId, memberId,
      { ...body, reason: 'Complimentary verification' },
    );

    expect(retry).toEqual(first);
    expect(database.query.mock.calls[0][1])
      .toEqual(database.query.mock.calls[1][1]);
  });

  it('accepts a zero listed price as decimal text', async () => {
    database.query.mockResolvedValueOnce({
      rows: [{ ...grantRow(), listed_price_amount: '0.00' }],
    });

    const result = await service.grant(
      request(), tenantId, memberId, body,
    );

    expect(result.listedPriceAmount).toBe('0.00');
  });

  it('accepts 500 Unicode code points in the reason', async () => {
    const reason = '😀'.repeat(500);

    database.query.mockResolvedValueOnce({
      rows: [{ ...grantRow(), reason }],
    });

    const result = await service.grant(
      request(), tenantId, memberId, { ...body, reason },
    );

    expect(result.reason).toBe(reason);
  });

  it('rejects a missing verified session', async () => {
    await expect(
      service.grant({}, tenantId, memberId, body),
    ).rejects.toBeInstanceOf(UnauthorizedException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it('rejects another route tenant', async () => {
    await expect(
      service.grant(request(), otherTenantId, memberId, body),
    ).rejects.toBeInstanceOf(ForbiddenException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it('rejects a malformed member identifier', async () => {
    await expect(
      service.grant(request(), tenantId, 'invalid', body),
    ).rejects.toBeInstanceOf(BadRequestException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it.each([
    ['tenantId', otherTenantId],
    ['memberId', memberId],
    ['agreedPriceAmount', '0.00'],
    ['membershipKind', 'foc'],
    ['startsOn', '2026-01-01'],
    ['status', 'active'],
  ])('rejects client-controlled %s', async (field, value) => {
    await expect(
      service.grant(
        request(), tenantId, memberId,
        { ...body, [field]: value },
      ),
    ).rejects.toBeInstanceOf(BadRequestException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it.each([
    'planId',
    'planPriceId',
    'requestId',
  ])('rejects a malformed %s', async (field) => {
    await expect(
      service.grant(
        request(), tenantId, memberId,
        { ...body, [field]: 'invalid' },
      ),
    ).rejects.toBeInstanceOf(BadRequestException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it('rejects a missing request UUID', async () => {
    await expect(
      service.grant(request(), tenantId, memberId, {
        planId,
        planPriceId: priceId,
        reason: 'Verification reason',
      }),
    ).rejects.toBeInstanceOf(BadRequestException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it.each([
    ['blank', ''],
    ['spaces', '   '],
    ['one character', 'A'],
    ['too long', 'A'.repeat(501)],
    ['too many Unicode code points', '😀'.repeat(501)],
    ['non-string', 123],
  ])('rejects a %s reason', async (_name, reason) => {
    await expect(
      service.grant(
        request(), tenantId, memberId,
        { ...body, reason },
      ),
    ).rejects.toBeInstanceOf(BadRequestException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it('rejects an invalid token hash length', async () => {
    bearer.hashAuthorization.mockReturnValue(Buffer.alloc(1));

    await expect(
      service.grant(request(), tenantId, memberId, body),
    ).rejects.toBeInstanceOf(UnauthorizedException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it('rejects grants before startup verification', async () => {
    const uninitialized = createService();

    await expect(
      uninitialized.grant(request(), tenantId, memberId, body),
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
      name: 'missing dedicated FOC permission',
      code: '42501',
      message: 'Complimentary membership permission denied',
      exception: ForbiddenException,
    },
    {
      name: 'current subscription conflict',
      code: '22023',
      message: 'Member already has a current subscription',
      exception: BadRequestException,
    },
    {
      name: 'database privilege failure',
      code: '42501',
      message: 'permission denied for function grant_foc_membership',
      exception: ServiceUnavailableException,
    },
    {
      name: 'connection failure',
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
      await service.grant(request(), tenantId, memberId, body);
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
    ['another request', { request_id: memberId }],
    ['invalid subscription UUID', { subscription_id: 'invalid' }],
    ['different reason', { reason: 'Different reason' }],
    ['numeric price', { listed_price_amount: 50000 }],
    ['negative price', { listed_price_amount: '-1.00' }],
    ['unsupported currency', { currency_code: 'USD' }],
    ['invalid grant timestamp', { granted_at: new Date('invalid') }],
    ['invalid creation timestamp', { created_at: new Date('invalid') }],
  ])('rejects a returned receipt with %s', async (_name, change) => {
    database.query.mockResolvedValueOnce({
      rows: [{ ...grantRow(), ...change }],
    });

    await expect(
      service.grant(request(), tenantId, memberId, body),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it('rejects an empty function result', async () => {
    database.query.mockResolvedValueOnce({ rows: [] });

    await expect(
      service.grant(request(), tenantId, memberId, body),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it.each([
    ['administrator account', {
      database_user: 'postgres',
      is_superuser: true,
    }],
    ['direct FOC history access', { history_select: true }],
    ['direct subscription insert', { subscription_insert: true }],
  ])('rejects startup with %s', async (_name, change) => {
    database.query.mockResolvedValueOnce({
      rows: [{ ...identity(), ...change }],
    });

    const unsafeService = createService();

    await expect(
      unsafeService.onModuleInit(),
    ).rejects.toThrow('requires gympro_app');

    await expect(
      unsafeService.grant(request(), tenantId, memberId, body),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);

    expect(database.query).toHaveBeenCalledTimes(1);
  });

  it('closes the pool and blocks grants after shutdown', async () => {
    database.end.mockResolvedValueOnce(undefined);

    await service.onModuleDestroy();

    expect(database.end).toHaveBeenCalledTimes(1);

    await expect(
      service.grant(request(), tenantId, memberId, body),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);

    expect(database.query).not.toHaveBeenCalled();
  });
});
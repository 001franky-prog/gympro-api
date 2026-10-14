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

import type {
  MemberBlacklistAction,
} from './member-blacklist.js';

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

import { MemberBlacklistService } from './member-blacklist.service.js';

const tenantId = '11111111-1111-4111-8111-111111111111';
const otherTenantId = '22222222-2222-4222-8222-222222222222';
const memberId = '33333333-3333-4333-8333-333333333333';
const requestId = '44444444-4444-4444-8444-444444444444';
const tokenHash = Buffer.alloc(32, 0xab);

const body = { reason: '  Verification reason  ', requestId };
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
    member_select: false,
    member_insert: false,
    member_update: false,
    member_delete: false,
  };
}

function eventRow(
  action: MemberBlacklistAction = 'blacklist',
  previous = 'active',
  resulting = 'blacklisted',
) {
  return {
    id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    tenant_id: tenantId,
    member_id: memberId,
    request_id: requestId,
    event_type: action,
    reason: 'Verification reason',
    previous_status: previous,
    resulting_status: resulting,
    recorded_at: new Date('2026-10-14T06:00:00.000Z'),
    created_at: new Date('2026-10-14T06:00:00.000Z'),
  };
}

function createService() {
  const config = {
    get: vi.fn(() =>
      'postgresql://gympro_app@127.0.0.1:1/gympro_saas',
    ),
  };

  return new MemberBlacklistService(
    config as unknown as ConfigService,
    bearer as unknown as SessionBearerTokenService,
  );
}

describe('Gym Pro MemberBlacklistService', () => {
  let service: MemberBlacklistService;

  beforeEach(async () => {
    vi.resetAllMocks();
    bearer.hashAuthorization.mockReturnValue(tokenHash);
    database.query.mockResolvedValueOnce({ rows: [identity()] });

    service = createService();
    await service.onModuleInit();
    database.query.mockReset();
  });

  it.each([
    ['blacklist', 'pending', 'blacklisted'],
    ['blacklist', 'active', 'blacklisted'],
    ['blacklist', 'inactive', 'blacklisted'],
    ['unblacklist', 'blacklisted', 'pending'],
    ['unblacklist', 'blacklisted', 'active'],
    ['unblacklist', 'blacklisted', 'inactive'],
  ] as const)('accepts %s from %s to %s', async (action, previous, resulting) => {
    const row = eventRow(action, previous, resulting);

    database.query.mockResolvedValueOnce({
      rows: [{
        ...row,
        previous_member_snapshot: { private: 'not-for-response' },
      }],
    });

    const result = await service.change(
      request(), tenantId, memberId, action, body,
    );

    const [sql, parameters] = database.query.mock.calls[0];

    expect(sql).toContain('security.change_member_blacklist');
    expect(sql).toContain('$6::uuid');
    expect(sql).not.toContain('previous_member_snapshot');

    expect(parameters).toEqual([
      tokenHash, tenantId, memberId,
      action, 'Verification reason', requestId,
    ]);

    expect(result).toEqual({
      id: row.id,
      tenantId,
      memberId,
      requestId,
      eventType: action,
      reason: 'Verification reason',
      previousStatus: previous,
      resultingStatus: resulting,
      recordedAt: row.recorded_at,
      createdAt: row.created_at,
    });

    expect(Object.isFrozen(result)).toBe(true);
    expect(result).not.toHaveProperty('previous_member_snapshot');
  });

  it('preserves the action, reason, and request UUID on retry', async () => {
    database.query.mockResolvedValue({ rows: [eventRow()] });

    const first = await service.change(
      request(), tenantId, memberId, 'blacklist', body,
    );

    const retry = await service.change(
      request(), tenantId, memberId, 'blacklist',
      { reason: 'Verification reason', requestId },
    );

    expect(retry).toEqual(first);
    expect(database.query.mock.calls[0][1])
      .toEqual(database.query.mock.calls[1][1]);
  });

  it('rejects a missing verified session', async () => {
    await expect(
      service.change({}, tenantId, memberId, 'blacklist', body),
    ).rejects.toBeInstanceOf(UnauthorizedException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it('rejects another route tenant', async () => {
    await expect(
      service.change(request(), otherTenantId, memberId, 'blacklist', body),
    ).rejects.toBeInstanceOf(ForbiddenException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it('rejects a malformed member identifier', async () => {
    await expect(
      service.change(request(), tenantId, 'invalid', 'blacklist', body),
    ).rejects.toBeInstanceOf(BadRequestException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it('rejects an invalid internal action', async () => {
    await expect(
      service.change(
        request(), tenantId, memberId,
        'invalid' as MemberBlacklistAction, body,
      ),
    ).rejects.toBeInstanceOf(BadRequestException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it.each([
    ['tenantId', otherTenantId],
    ['memberId', memberId],
    ['action', 'unblacklist'],
    ['resultingStatus', 'active'],
    ['recordedAt', '2026-01-01T00:00:00Z'],
  ])('rejects client-controlled %s', async (field, value) => {
    await expect(
      service.change(
        request(), tenantId, memberId, 'blacklist',
        { ...body, [field]: value },
      ),
    ).rejects.toBeInstanceOf(BadRequestException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it.each([
    ['blank', ''],
    ['spaces', '   '],
    ['one character', 'A'],
    ['too long', 'A'.repeat(501)],
    ['non-string', 123],
  ])('rejects a %s reason', async (_name, reason) => {
    await expect(
      service.change(
        request(), tenantId, memberId, 'blacklist',
        { reason, requestId },
      ),
    ).rejects.toBeInstanceOf(BadRequestException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it.each([
    ['missing', { reason: 'Test reason' }],
    ['malformed', { reason: 'Test reason', requestId: 'invalid' }],
  ])('rejects a %s request UUID', async (_name, input) => {
    await expect(
      service.change(request(), tenantId, memberId, 'blacklist', input),
    ).rejects.toBeInstanceOf(BadRequestException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it('rejects an invalid token hash length', async () => {
    bearer.hashAuthorization.mockReturnValue(Buffer.alloc(1));

    await expect(
      service.change(request(), tenantId, memberId, 'blacklist', body),
    ).rejects.toBeInstanceOf(UnauthorizedException);

    expect(database.query).not.toHaveBeenCalled();
  });

  it('rejects changes before startup verification', async () => {
    const uninitialized = createService();

    await expect(
      uninitialized.change(request(), tenantId, memberId, 'blacklist', body),
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
      message: 'Member blacklist permission denied',
      exception: ForbiddenException,
    },
    {
      name: 'request conflict',
      code: '22023',
      message: 'Request ID already belongs to another blacklist request',
      exception: BadRequestException,
    },
    {
      name: 'database privilege failure',
      code: '42501',
      message: 'permission denied for function change_member_blacklist',
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
      await service.change(request(), tenantId, memberId, 'blacklist', body);
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
    ['another member', { member_id: requestId }],
    ['another request', { request_id: memberId }],
    ['another action', { event_type: 'unblacklist' }],
    ['different reason', { reason: 'Different reason' }],
    ['invalid previous status', { previous_status: 'blacklisted' }],
    ['invalid resulting status', { resulting_status: 'active' }],
    ['invalid timestamp', { recorded_at: new Date('invalid') }],
  ])('rejects a returned event with %s', async (_name, change) => {
    database.query.mockResolvedValueOnce({
      rows: [{ ...eventRow(), ...change }],
    });

    await expect(
      service.change(request(), tenantId, memberId, 'blacklist', body),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it('rejects an invalid removal transition', async () => {
    database.query.mockResolvedValueOnce({
      rows: [eventRow('unblacklist', 'active', 'active')],
    });

    await expect(
      service.change(request(), tenantId, memberId, 'unblacklist', body),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it('rejects an empty function result', async () => {
    database.query.mockResolvedValueOnce({ rows: [] });

    await expect(
      service.change(request(), tenantId, memberId, 'blacklist', body),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it.each([
    ['administrator account', {
      database_user: 'postgres',
      is_superuser: true,
    }],
    ['direct history access', { history_select: true }],
    ['direct member update', { member_update: true }],
  ])('rejects startup with %s', async (_name, change) => {
    database.query.mockResolvedValueOnce({
      rows: [{ ...identity(), ...change }],
    });

    const unsafeService = createService();

    await expect(
      unsafeService.onModuleInit(),
    ).rejects.toThrow('requires gympro_app');

    await expect(
      unsafeService.change(request(), tenantId, memberId, 'blacklist', body),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);

    expect(database.query).toHaveBeenCalledTimes(1);
  });

  it('closes the pool and blocks changes after shutdown', async () => {
    database.end.mockResolvedValueOnce(undefined);

    await service.onModuleDestroy();

    expect(database.end).toHaveBeenCalledTimes(1);

    await expect(
      service.change(request(), tenantId, memberId, 'blacklist', body),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);

    expect(database.query).not.toHaveBeenCalled();
  });
});
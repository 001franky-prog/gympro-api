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
  default: {
    Pool: class {
      query = database.query;
      end = database.end;
      on = database.on;
    },
  },
}));

import { SubscriptionSuspensionService } from './subscription-suspension.service.js';

const tenant = 'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b';
const otherTenant = 'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc';
const branch = 'fa534b44-c8c6-44f5-bcc3-3ed14ace6e2c';
const subscription = '8a28fa97-e41f-4053-be61-8162ff3d387d';
const requestId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const reason = 'B8 branch suspension verification';

const identity = {
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

const row = {
  id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  tenant_id: tenant,
  subscription_id: subscription,
  request_id: requestId,
  reason,
  suspended_at: new Date('2026-10-14T12:00:00Z'),
  created_at: new Date('2026-10-14T12:00:00Z'),
};

function request(): GymProAuthenticatedRequest {
  return {
    headers: { authorization: 'Bearer test-only-token' },
    gymproSession: {
      sessionId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      tenantId: tenant,
      membershipId: '3b318e89-f3bc-4ac5-a04d-09fdb3d626de',
      userId: '059e261a-226a-4f9e-93ee-86d374430406',
    },
  } as GymProAuthenticatedRequest;
}

function input() {
  return { reason, requestId };
}

describe('Gym Pro branch subscription suspension', () => {
  let service: SubscriptionSuspensionService;

  beforeEach(async () => {
    vi.clearAllMocks();
    database.query.mockReset();
    database.end.mockResolvedValue(undefined);

    service = new SubscriptionSuspensionService(
      {
        get: vi.fn().mockReturnValue('postgresql://test-only'),
      } as unknown as ConfigService,
      {
        hashAuthorization: vi.fn().mockReturnValue(Buffer.alloc(32, 1)),
      } as unknown as SessionBearerTokenService,
    );

    database.query.mockResolvedValueOnce({ rows: [{ ...identity }] });
    await service.onModuleInit();
    database.query.mockResolvedValue({ rows: [{ ...row }] });
  });

  it('checks both suspension function privileges at startup', () => {
    const sql = database.query.mock.calls[0][0];
    expect(sql).toContain(
      'security.suspend_member_subscription(bytea,uuid,uuid,text,uuid)',
    );
    expect(sql).toContain(
      'security.suspend_branch_member_subscription(bytea,uuid,uuid,uuid,text,uuid)',
    );
  });

  it('passes the route branch and normalized reason to SQL', async () => {
    const result = await service.suspendBranch(
      request(), tenant, branch, subscription,
      { reason: ` ${reason} `, requestId },
    );

    const [sql, values] = database.query.mock.calls.at(-1)!;
    expect(sql).toContain('security.suspend_branch_member_subscription');
    expect(values).toEqual([
      Buffer.alloc(32, 1), tenant, branch, subscription, reason, requestId,
    ]);
    expect(result.reason).toBe(reason);
    expect(Object.isFrozen(result)).toBe(true);
  });

  it('preserves the receipt and request UUID on retry', async () => {
    const first = await service.suspendBranch(
      request(), tenant, branch, subscription, input(),
    );
    const retry = await service.suspendBranch(
      request(), tenant, branch, subscription, input(),
    );
    expect(retry).toEqual(first);
    expect(database.query.mock.calls.at(-1)![1][5]).toBe(requestId);
  });

  it('rejects a missing verified session', async () => {
    const req = request();
    delete req.gymproSession;
    await expect(service.suspendBranch(
      req, tenant, branch, subscription, input(),
    )).rejects.toBeInstanceOf(UnauthorizedException);
  });

  it('rejects another route tenant', async () => {
    await expect(service.suspendBranch(
      request(), otherTenant, branch, subscription, input(),
    )).rejects.toBeInstanceOf(ForbiddenException);
  });

  it('rejects a malformed route branch before querying', async () => {
    const before = database.query.mock.calls.length;
    await expect(service.suspendBranch(
      request(), tenant, 'invalid', subscription, input(),
    )).rejects.toBeInstanceOf(BadRequestException);
    expect(database.query.mock.calls.length).toBe(before);
  });

  it('rejects client-controlled branchId', async () => {
    await expect(service.suspendBranch(
      request(), tenant, branch, subscription,
      { ...input(), branchId: branch },
    )).rejects.toBeInstanceOf(BadRequestException);
  });

  it('maps database branch denial to HTTP 403', async () => {
    database.query.mockRejectedValueOnce({
      code: '42501',
      message: 'Branch access denied',
    });
    await expect(service.suspendBranch(
      request(), tenant, branch, subscription, input(),
    )).rejects.toBeInstanceOf(ForbiddenException);
  });

  it.each([
    ['another subscription', {
      subscription_id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
    }],
    ['another request', {
      request_id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
    }],
    ['different reason', {
      reason: 'Unexpected reason',
    }],
  ])('rejects a returned receipt with %s', async (_name, changes) => {
    database.query.mockResolvedValueOnce({
      rows: [{ ...row, ...changes }],
    });
    await expect(service.suspendBranch(
      request(), tenant, branch, subscription, input(),
    )).rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it('rejects suspension after shutdown', async () => {
    await service.onModuleDestroy();
    await expect(service.suspendBranch(
      request(), tenant, branch, subscription, input(),
    )).rejects.toBeInstanceOf(ServiceUnavailableException);
  });
});
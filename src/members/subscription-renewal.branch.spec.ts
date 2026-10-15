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

import { SubscriptionRenewalService } from './subscription-renewal.service.js';

const tenant = 'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b';
const otherTenant = 'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc';
const branch = 'fa534b44-c8c6-44f5-bcc3-3ed14ace6e2c';
const subscription = '8a28fa97-e41f-4053-be61-8162ff3d387d';
const plan = '838d86b2-9665-414d-865a-8f5fb559e39c';
const price = 'f1017c52-3518-4e13-9fd8-f4cc647771b1';
const requestId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

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
  plan_id: plan,
  plan_price_id: price,
  previous_ends_on: '2026-11-14',
  renewal_starts_on: '2026-11-14',
  renewal_ends_on: '2026-12-14',
  duration_value: 1,
  duration_unit: 'months',
  agreed_price_amount: '50000.00',
  currency_code: 'MMK',
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
  return { planPriceId: price, requestId };
}

describe('Gym Pro branch subscription renewal', () => {
  let service: SubscriptionRenewalService;

  beforeEach(async () => {
    vi.clearAllMocks();
    database.query.mockReset();
    database.end.mockResolvedValue(undefined);

    service = new SubscriptionRenewalService(
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

  it('checks both renewal function privileges at startup', () => {
    const sql = database.query.mock.calls[0][0];
    expect(sql).toContain(
      'security.renew_member_subscription(bytea,uuid,uuid,uuid,uuid)',
    );
    expect(sql).toContain(
      'security.renew_branch_member_subscription(bytea,uuid,uuid,uuid,uuid,uuid)',
    );
  });

  it('calls the branch function with route and request identifiers', async () => {
    const result = await service.renewBranch(
      request(), tenant, branch, subscription, input(),
    );
    const [sql, values] = database.query.mock.calls.at(-1)!;
    expect(sql).toContain('security.renew_branch_member_subscription');
    expect(values).toEqual([
      Buffer.alloc(32, 1), tenant, branch, subscription, price, requestId,
    ]);
    expect(result.subscriptionId).toBe(subscription);
    expect(result.requestId).toBe(requestId);
    expect(Object.isFrozen(result)).toBe(true);
  });

  it('preserves the same request UUID and receipt on retry', async () => {
    const first = await service.renewBranch(
      request(), tenant, branch, subscription, input(),
    );
    const retry = await service.renewBranch(
      request(), tenant, branch, subscription, input(),
    );
    expect(retry).toEqual(first);
    expect(database.query.mock.calls.at(-1)![1][5]).toBe(requestId);
  });

  it('rejects a missing verified session', async () => {
    const req = request();
    delete req.gymproSession;
    await expect(service.renewBranch(
      req, tenant, branch, subscription, input(),
    )).rejects.toBeInstanceOf(UnauthorizedException);
  });

  it('rejects another route tenant', async () => {
    await expect(service.renewBranch(
      request(), otherTenant, branch, subscription, input(),
    )).rejects.toBeInstanceOf(ForbiddenException);
  });

  it('rejects a malformed route branch before querying', async () => {
    const before = database.query.mock.calls.length;
    await expect(service.renewBranch(
      request(), tenant, 'invalid', subscription, input(),
    )).rejects.toBeInstanceOf(BadRequestException);
    expect(database.query.mock.calls.length).toBe(before);
  });

  it('rejects client-controlled branchId', async () => {
    await expect(service.renewBranch(
      request(), tenant, branch, subscription,
      { ...input(), branchId: branch },
    )).rejects.toBeInstanceOf(BadRequestException);
  });

  it('maps database branch denial to HTTP 403', async () => {
    database.query.mockRejectedValueOnce({
      code: '42501',
      message: 'Branch access denied',
    });
    await expect(service.renewBranch(
      request(), tenant, branch, subscription, input(),
    )).rejects.toBeInstanceOf(ForbiddenException);
  });

  it('rejects a receipt for another subscription', async () => {
    database.query.mockResolvedValueOnce({
      rows: [{
        ...row,
        subscription_id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
      }],
    });
    await expect(service.renewBranch(
      request(), tenant, branch, subscription, input(),
    )).rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it('rejects a receipt for another request', async () => {
    database.query.mockResolvedValueOnce({
      rows: [{
        ...row,
        request_id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
      }],
    });
    await expect(service.renewBranch(
      request(), tenant, branch, subscription, input(),
    )).rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it('rejects renewal after shutdown', async () => {
    await service.onModuleDestroy();
    await expect(service.renewBranch(
      request(), tenant, branch, subscription, input(),
    )).rejects.toBeInstanceOf(ServiceUnavailableException);
  });
});
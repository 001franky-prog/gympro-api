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

import { SubscriptionActivationService } from './subscription-activation.service.js';

const tenant = 'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b';
const otherTenant = 'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc';
const branch = 'fa534b44-c8c6-44f5-bcc3-3ed14ace6e2c';
const member = '41f45bd6-114c-4241-9be0-0a949dc5f2b6';
const plan = '838d86b2-9665-414d-865a-8f5fb559e39c';
const price = 'f1017c52-3518-4e13-9fd8-f4cc647771b1';

const identity = {
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

const row = {
  id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  tenant_id: tenant,
  member_id: member,
  branch_id: branch,
  plan_id: plan,
  plan_price_id: price,
  duration_value: 1,
  duration_unit: 'months',
  agreed_price_amount: '50000.00',
  currency_code: 'MMK',
  status: 'active',
  starts_on: '2026-10-14',
  ends_on: '2026-11-14',
  activated_at: new Date('2026-10-14T12:00:00Z'),
  suspended_at: null,
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

describe('Gym Pro branch subscription activation', () => {
  let service: SubscriptionActivationService;
  let hashAuthorization: ReturnType<typeof vi.fn>;

  beforeEach(async () => {
    vi.clearAllMocks();
    database.query.mockReset();
    database.end.mockResolvedValue(undefined);
    hashAuthorization = vi.fn().mockReturnValue(Buffer.alloc(32, 1));

    service = new SubscriptionActivationService(
      {
        get: vi.fn().mockReturnValue('postgresql://test-only'),
      } as unknown as ConfigService,
      {
        hashAuthorization,
      } as unknown as SessionBearerTokenService,
    );

    database.query.mockResolvedValueOnce({ rows: [{ ...identity }] });
    await service.onModuleInit();
    database.query.mockResolvedValue({ rows: [{ ...row }] });
  });

  it('checks both activation function privileges at startup', () => {
    const sql = database.query.mock.calls[0][0];
    expect(sql).toContain(
      'security.activate_member_subscription(bytea,uuid,uuid,uuid,uuid)',
    );
    expect(sql).toContain(
      'security.activate_branch_member_subscription(bytea,uuid,uuid,uuid,uuid,uuid)',
    );
  });

  it('calls the branch function with the route branch', async () => {
    const result = await service.activateBranch(
      request(), tenant, branch, member,
      { planId: plan, planPriceId: price },
    );

    const [sql, values] = database.query.mock.calls.at(-1)!;
    expect(sql).toContain('security.activate_branch_member_subscription');
    expect(values).toEqual([
      Buffer.alloc(32, 1), tenant, branch, member, plan, price,
    ]);
    expect(result.branchId).toBe(branch);
    expect(Object.isFrozen(result)).toBe(true);
  });

  it('accepts an uppercase route branch UUID', async () => {
    const result = await service.activateBranch(
      request(), tenant, branch.toUpperCase(), member,
      { planId: plan, planPriceId: price },
    );
    expect(result.branchId).toBe(branch);
  });

  it('rejects a missing verified session', async () => {
    const req = request();
    delete req.gymproSession;
    await expect(service.activateBranch(
      req, tenant, branch, member,
      { planId: plan, planPriceId: price },
    )).rejects.toBeInstanceOf(UnauthorizedException);
  });

  it('rejects another route tenant', async () => {
    await expect(service.activateBranch(
      request(), otherTenant, branch, member,
      { planId: plan, planPriceId: price },
    )).rejects.toBeInstanceOf(ForbiddenException);
  });

  it('rejects a malformed route branch before querying', async () => {
    const before = database.query.mock.calls.length;
    await expect(service.activateBranch(
      request(), tenant, 'invalid', member,
      { planId: plan, planPriceId: price },
    )).rejects.toBeInstanceOf(BadRequestException);
    expect(database.query.mock.calls.length).toBe(before);
  });

  it('rejects a client-controlled branchId', async () => {
    await expect(service.activateBranch(
      request(), tenant, branch, member,
      { planId: plan, planPriceId: price, branchId: branch },
    )).rejects.toBeInstanceOf(BadRequestException);
  });

  it('maps database branch denial to HTTP 403', async () => {
    database.query.mockRejectedValueOnce({
      code: '42501',
      message: 'Branch access denied',
    });
    await expect(service.activateBranch(
      request(), tenant, branch, member,
      { planId: plan, planPriceId: price },
    )).rejects.toBeInstanceOf(ForbiddenException);
  });

  it.each([
    ['another branch', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'],
    ['no branch', null],
    ['invalid branch', 'invalid'],
  ])('rejects a returned subscription with %s', async (_name, value) => {
    database.query.mockResolvedValueOnce({
      rows: [{ ...row, branch_id: value }],
    });
    await expect(service.activateBranch(
      request(), tenant, branch, member,
      { planId: plan, planPriceId: price },
    )).rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it('rejects activation after shutdown', async () => {
    await service.onModuleDestroy();
    await expect(service.activateBranch(
      request(), tenant, branch, member,
      { planId: plan, planPriceId: price },
    )).rejects.toBeInstanceOf(ServiceUnavailableException);
  });
});
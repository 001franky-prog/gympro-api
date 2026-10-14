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

import { MembershipDiscountService } from './membership-discount.service.js';

const tenant = 'd0d732f6-a08d-4c68-bb8c-20ad3f98ab0b';
const otherTenant = 'b4d1d0af-dbc7-4f0a-8751-c438eaaf37dc';
const member = '3113ab9f-8edd-41f4-afe6-c8f03e291f89';
const subscription = '8a28fa97-e41f-4053-be61-8162ff3d387d';
const plan = '838d86b2-9665-414d-865a-8f5fb559e39c';
const price = 'f1017c52-3518-4e13-9fd8-f4cc647771b1';
const promotion = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const requestId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const renewal = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

const identity = {
  database_name: 'gympro_saas',
  database_user: 'gympro_app',
  is_superuser: false,
  bypasses_rls: false,
  security_schema_usage: true,
  can_activate: true,
  can_renew: true,
  can_call_calculator: false,
  direct_purchase_access: false,
};

const activationRow = {
  id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
  tenant_id: tenant,
  subscription_id: subscription,
  promotion_id: promotion,
  request_id: requestId,
  purchase_kind: 'activation',
  renewal_id: null,
  listed_price_amount: '50000.00',
  discount_amount: '5000.00',
  agreed_price_amount: '45000.00',
  currency_code: 'MMK',
  applied_at: new Date('2026-10-14T12:00:00Z'),
  created_at: new Date('2026-10-14T12:00:00Z'),
};

function request(): GymProAuthenticatedRequest {
  return {
    headers: { authorization: 'Bearer test-only-token' },
    gymproSession: {
      sessionId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
      tenantId: tenant,
      membershipId: '3b318e89-f3bc-4ac5-a04d-09fdb3d626de',
      userId: '059e261a-226a-4f9e-93ee-86d374430406',
    },
  } as GymProAuthenticatedRequest;
}

function activationInput() {
  return {
    planId: plan,
    planPriceId: price,
    promotionId: promotion,
    requestId,
  };
}

function renewalInput() {
  return {
    planPriceId: price,
    promotionId: promotion,
    requestId,
  };
}

describe('Gym Pro MembershipDiscountService', () => {
  let service: MembershipDiscountService;
  let hashAuthorization: ReturnType<typeof vi.fn>;

  function makeService() {
    return new MembershipDiscountService(
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
    database.query.mockReset();
    database.end.mockResolvedValue(undefined);
    hashAuthorization = vi.fn().mockReturnValue(Buffer.alloc(32, 1));

    database.query.mockResolvedValueOnce({ rows: [{ ...identity }] });
    service = makeService();
    await service.onModuleInit();

    database.query.mockResolvedValue({ rows: [{ ...activationRow }] });
  });

  it('activates through the parameterized discounted function', async () => {
    const result = await service.activate(
      request(), tenant, member, activationInput(),
    );
    const [sql, values] = database.query.mock.calls.at(-1)!;
    expect(sql).toContain('security.activate_discounted_membership');
    expect(sql).not.toContain('actor_snapshot');
    expect(values).toEqual([
      Buffer.alloc(32, 1), tenant, member,
      plan, price, promotion, requestId,
    ]);
    expect(result.agreedPriceAmount).toBe('45000.00');
    expect(Object.isFrozen(result)).toBe(true);
  });

  it('renews through the parameterized discounted function', async () => {
    database.query.mockResolvedValueOnce({
      rows: [{
        ...activationRow,
        purchase_kind: 'renewal',
        renewal_id: renewal,
      }],
    });
    const result = await service.renew(
      request(), tenant, subscription, renewalInput(),
    );
    const [sql, values] = database.query.mock.calls.at(-1)!;
    expect(sql).toContain('security.renew_discounted_membership');
    expect(values).toEqual([
      Buffer.alloc(32, 1), tenant, subscription,
      price, promotion, requestId,
    ]);
    expect(result.renewalId).toBe(renewal);
  });

  it('returns only public receipt fields', async () => {
    database.query.mockResolvedValueOnce({
      rows: [{
        ...activationRow,
        promotion_snapshot: { private: true },
        actor_snapshot: { private: true },
      }],
    });
    const result = await service.activate(
      request(), tenant, member, activationInput(),
    );
    expect(result).not.toHaveProperty('promotion_snapshot');
    expect(result).not.toHaveProperty('actor_snapshot');
  });

  it('preserves the request UUID on retry', async () => {
    const first = await service.activate(
      request(), tenant, member, activationInput(),
    );
    const retry = await service.activate(
      request(), tenant, member, activationInput(),
    );
    expect(retry).toEqual(first);
    expect(database.query.mock.calls.at(-1)![1][6]).toBe(requestId);
  });

  it('accepts a correctly calculated zero final price', async () => {
    database.query.mockResolvedValueOnce({
      rows: [{
        ...activationRow,
        discount_amount: '50000.00',
        agreed_price_amount: '0.00',
      }],
    });
    const result = await service.activate(
      request(), tenant, member, activationInput(),
    );
    expect(result.agreedPriceAmount).toBe('0.00');
  });

  it('rejects a missing verified session', async () => {
    const req = request();
    delete req.gymproSession;
    await expect(service.activate(req, tenant, member, activationInput()))
      .rejects.toBeInstanceOf(UnauthorizedException);
  });

  it('rejects another route tenant', async () => {
    await expect(service.activate(
      request(), otherTenant, member, activationInput(),
    )).rejects.toBeInstanceOf(ForbiddenException);
  });

  it('rejects an invalid token hash length', async () => {
    hashAuthorization.mockReturnValue(Buffer.alloc(31));
    await expect(service.activate(
      request(), tenant, member, activationInput(),
    )).rejects.toBeInstanceOf(UnauthorizedException);
  });

  it('rejects purchase before startup verification', async () => {
    const unverified = makeService();
    await expect(unverified.activate(
      request(), tenant, member, activationInput(),
    )).rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it.each([
    ['client tenant', { tenantId: tenant }],
    ['client member', { memberId: member }],
    ['client price', { agreedPriceAmount: '1.00' }],
    ['client discount', { discountAmount: '1.00' }],
    ['client start date', { startsOn: '2026-10-14' }],
    ['client status', { status: 'active' }],
    ['invalid plan', { planId: 'invalid' }],
    ['invalid price', { planPriceId: 'invalid' }],
    ['invalid promotion', { promotionId: 'invalid' }],
    ['missing request', { requestId: undefined }],
    ['invalid request', { requestId: 'invalid' }],
  ])('rejects %s', async (_name, changes) => {
    const before = database.query.mock.calls.length;
    await expect(service.activate(
      request(), tenant, member, { ...activationInput(), ...changes },
    )).rejects.toBeInstanceOf(BadRequestException);
    expect(database.query.mock.calls.length).toBe(before);
  });

  it.each([null, undefined, [], 'text'])(
    'rejects invalid body %j',
    async (body) => {
      await expect(service.activate(request(), tenant, member, body))
        .rejects.toBeInstanceOf(BadRequestException);
    },
  );

  it('rejects a malformed member identifier', async () => {
    await expect(service.activate(
      request(), tenant, 'invalid', activationInput(),
    )).rejects.toBeInstanceOf(BadRequestException);
  });

  it('rejects a malformed subscription identifier', async () => {
    await expect(service.renew(
      request(), tenant, 'invalid', renewalInput(),
    )).rejects.toBeInstanceOf(BadRequestException);
  });

  it('rejects client planId on renewal', async () => {
    await expect(service.renew(
      request(), tenant, subscription, { ...renewalInput(), planId: plan },
    )).rejects.toBeInstanceOf(BadRequestException);
  });

  it.each([
    ['invalid session', '28000', 'Invalid or expired session', UnauthorizedException],
    ['missing discount permission', '42501', 'Membership discount permission denied', ForbiddenException],
    ['request conflict', '22023', 'Private database validation detail', BadRequestException],
    ['privilege configuration', '42501', 'permission denied for function', ServiceUnavailableException],
    ['connection failure', 'ECONNREFUSED', 'Private connection detail', ServiceUnavailableException],
  ])('maps %s safely', async (_name, code, message, exception) => {
    database.query.mockRejectedValueOnce({ code, message });
    await expect(service.activate(
      request(), tenant, member, activationInput(),
    )).rejects.toBeInstanceOf(exception);
  });

  it.each([
    ['another tenant', { tenant_id: otherTenant }],
    ['another promotion', { promotion_id: renewal }],
    ['another request', { request_id: renewal }],
    ['invalid receipt ID', { id: 'invalid' }],
    ['invalid subscription ID', { subscription_id: 'invalid' }],
    ['unexpected purchase kind', { purchase_kind: 'renewal', renewal_id: renewal }],
    ['activation with renewal ID', { renewal_id: renewal }],
    ['numeric price', { listed_price_amount: 50000 }],
    ['negative discount', { discount_amount: '-1.00' }],
    ['discount above price', { discount_amount: '50001.00' }],
    ['incorrect arithmetic', { agreed_price_amount: '44000.00' }],
    ['invalid currency', { currency_code: 'USD' }],
    ['invalid application timestamp', { applied_at: new Date('invalid') }],
  ])('rejects returned %s', async (_name, changes) => {
    database.query.mockResolvedValueOnce({
      rows: [{ ...activationRow, ...changes }],
    });
    await expect(service.activate(
      request(), tenant, member, activationInput(),
    )).rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it('rejects a renewal receipt for another subscription', async () => {
    database.query.mockResolvedValueOnce({
      rows: [{
        ...activationRow,
        subscription_id: renewal,
        purchase_kind: 'renewal',
        renewal_id: renewal,
      }],
    });
    await expect(service.renew(
      request(), tenant, subscription, renewalInput(),
    )).rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it('rejects an empty result', async () => {
    database.query.mockResolvedValueOnce({ rows: [] });
    await expect(service.activate(
      request(), tenant, member, activationInput(),
    )).rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it.each([
    ['administrator account', { database_user: 'postgres', is_superuser: true }],
    ['direct purchase access', { direct_purchase_access: true }],
    ['internal calculator access', { can_call_calculator: true }],
    ['missing renewal execution', { can_renew: false }],
  ])('rejects startup with %s', async (_name, changes) => {
    database.query.mockResolvedValueOnce({
      rows: [{ ...identity, ...changes }],
    });
    const unsafe = makeService();
    await expect(unsafe.onModuleInit())
      .rejects.toBeInstanceOf(ServiceUnavailableException);
  });

  it('closes the pool and blocks purchases after shutdown', async () => {
    await service.onModuleDestroy();
    expect(database.end).toHaveBeenCalledOnce();
    await expect(service.activate(
      request(), tenant, member, activationInput(),
    )).rejects.toBeInstanceOf(ServiceUnavailableException);
  });
});
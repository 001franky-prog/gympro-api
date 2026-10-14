import {
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from 'vitest';

import type { ConfigService } from '@nestjs/config';

import {
  AuthDatabaseService,
} from './auth-database.service.js';

const mocks = vi.hoisted(() => ({
  query: vi.fn(),
  on: vi.fn(),
  end: vi.fn(),
}));

vi.mock('pg', () => ({
  default: {
    Pool: vi.fn().mockImplementation(function () {
      return {
        query: mocks.query,
        on: mocks.on,
        end: mocks.end,
      };
    }),
  },
}));

describe('Gym Pro Session Identity Validation', () => {
  const identity = {
    session_id:
      '11111111-1111-4111-8111-111111111111',
    tenant_id:
      '22222222-2222-4222-8222-222222222222',
    membership_id:
      '33333333-3333-4333-8333-333333333333',
    user_id:
      '44444444-4444-4444-8444-444444444444',
  };

  const hash = Buffer.alloc(32, 0xab);

  let service: AuthDatabaseService;

  beforeEach(() => {
    vi.clearAllMocks();

    mocks.query.mockReset();
    mocks.on.mockReset();
    mocks.end.mockReset();

    mocks.query.mockResolvedValue({
      rows: [{ ...identity }],
    });

    mocks.end.mockResolvedValue(undefined);

    const config = {
      get: vi.fn().mockReturnValue(
        'postgresql://test-only-placeholder',
      ),
    } as unknown as ConfigService;

    service = new AuthDatabaseService(config);
  });

  it('V01: accepts four valid session UUIDs', async () => {
    await expect(
      service.verifySessionTokenHash(hash),
    ).resolves.toEqual({
      sessionId: identity.session_id,
      tenantId: identity.tenant_id,
      membershipId: identity.membership_id,
      userId: identity.user_id,
    });

    expect(mocks.query).toHaveBeenCalledTimes(1);
    expect(mocks.query).toHaveBeenCalledWith(
      expect.stringContaining(
        'security.verify_tenant_session',
      ),
      [hash],
    );
  });

  it('V02: denies unknown sessions', async () => {
    mocks.query.mockResolvedValueOnce({
      rows: [],
    });

    await expect(
      service.verifySessionTokenHash(hash),
    ).resolves.toBeNull();
  });

  it('V03: rejects malformed hashes', async () => {
    await expect(
      service.verifySessionTokenHash(
        Buffer.alloc(12, 0),
      ),
    ).resolves.toBeNull();

    expect(mocks.query).not.toHaveBeenCalled();
  });

  it('V04: rejects malformed database identities', async () => {
    mocks.query.mockResolvedValueOnce({
      rows: [{
        ...identity,
        tenant_id: 'invalid-tenant',
      }],
    });

    await expect(
      service.verifySessionTokenHash(hash),
    ).rejects.toThrow(
      'Invalid session verification result',
    );
  });

  it('V05: rejects duplicate verification rows', async () => {
    mocks.query.mockResolvedValueOnce({
      rows: [
        { ...identity },
        { ...identity },
      ],
    });

    await expect(
      service.verifySessionTokenHash(hash),
    ).rejects.toThrow(
      'Unexpected session verification result',
    );
  });

  it('V06: propagates operational errors', async () => {
    mocks.query.mockRejectedValueOnce(
      new Error('Database unavailable'),
    );

    await expect(
      service.verifySessionTokenHash(hash),
    ).rejects.toThrow('Database unavailable');
  });

  it('V07: verifies database connection identity', async () => {
    mocks.query.mockResolvedValueOnce({
      rows: [{
        database_name: 'gympro_saas',
        database_user: 'gympro_auth',
      }],
    });

    await expect(
      service.onModuleInit(),
    ).resolves.toBeUndefined();
  });

  it('V08: rejects incorrect database role', async () => {
    mocks.query.mockResolvedValueOnce({
      rows: [{
        database_name: 'gympro_saas',
        database_user: 'postgres',
      }],
    });

    await expect(
      service.onModuleInit(),
    ).rejects.toThrow(
      'Authentication database connection verification failed',
    );
  });
});
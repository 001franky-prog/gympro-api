import {
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from 'vitest';

import pg from 'pg';

import type {
  ConfigService,
} from '@nestjs/config';

import {
  SessionRevocationDatabaseService,
} from './session-revocation-database.service.js';

/**
 * Gym Pro SaaS
 * Session Revocation Database Service Tests
 *
 * Uses a mocked PostgreSQL pool.
 * Never changes actual database records.
 */

const mocks = vi.hoisted(() => ({
  query: vi.fn(),
  end: vi.fn(),
  on: vi.fn(),
}));

vi.mock('pg', () => ({
  default: {
    Pool: vi.fn().mockImplementation(function () {
      return {
        query: mocks.query,
        end: mocks.end,
        on: mocks.on,
      };
    }),
  },
}));

describe('Gym Pro SessionRevocationDatabaseService', () => {
  const sessionId =
    '11111111-1111-4111-8111-111111111111';

  const tokenHash = Buffer.alloc(32, 0xab);

  let service: SessionRevocationDatabaseService;

  beforeEach(() => {
    // Preserve the mocked pg.Pool constructor.
    vi.clearAllMocks();

    // Reset mock outcomes without removing
    // the Pool constructor implementation.
    mocks.query.mockReset();
    mocks.end.mockReset();
    mocks.on.mockReset();

    mocks.query.mockResolvedValue({
      rows: [{ revoked: true }],
    });

    mocks.end.mockResolvedValue(undefined);

    const config = {
      get: vi.fn().mockReturnValue(
        'postgresql://test-only-placeholder',
      ),
    } as unknown as ConfigService;

    service =
      new SessionRevocationDatabaseService(
        config,
      );
  });

  it('L01: revokes a matching session', async () => {
    await expect(
      service.revokeSession(sessionId, tokenHash),
    ).resolves.toBe(true);

    expect(mocks.query).toHaveBeenCalledWith(
      expect.stringContaining(
        'security.revoke_tenant_session',
      ),
      [sessionId, tokenHash],
    );
  });

  it('L02: returns false when no session is revoked', async () => {
    mocks.query.mockResolvedValueOnce({
      rows: [{ revoked: false }],
    });

    await expect(
      service.revokeSession(sessionId, tokenHash),
    ).resolves.toBe(false);
  });

  it('L03: rejects malformed session UUID', async () => {
    await expect(
      service.revokeSession('invalid', tokenHash),
    ).resolves.toBe(false);

    expect(mocks.query).not.toHaveBeenCalled();
  });

  it('L04: rejects a short token hash', async () => {
    await expect(
      service.revokeSession(
        sessionId,
        Buffer.alloc(12),
      ),
    ).resolves.toBe(false);

    expect(mocks.query).not.toHaveBeenCalled();
  });

  it('L05: rejects an empty token hash', async () => {
    await expect(
      service.revokeSession(
        sessionId,
        Buffer.alloc(0),
      ),
    ).resolves.toBe(false);

    expect(mocks.query).not.toHaveBeenCalled();
  });

  it('L06: rejects a non-Buffer hash', async () => {
    await expect(
      service.revokeSession(
        sessionId,
        'not-a-buffer' as unknown as Buffer,
      ),
    ).resolves.toBe(false);

    expect(mocks.query).not.toHaveBeenCalled();
  });

  it('L07: propagates database errors', async () => {
    mocks.query.mockRejectedValueOnce(
      new Error('Database unavailable'),
    );

    await expect(
      service.revokeSession(sessionId, tokenHash),
    ).rejects.toThrow('Database unavailable');
  });

  it('L08: rejects missing database rows', async () => {
    mocks.query.mockResolvedValueOnce({
      rows: [],
    });

    await expect(
      service.revokeSession(sessionId, tokenHash),
    ).rejects.toThrow(
      'Invalid session revocation database response',
    );
  });

  it('L09: rejects a nonboolean database result', async () => {
    mocks.query.mockResolvedValueOnce({
      rows: [{ revoked: 'true' }],
    });

    await expect(
      service.revokeSession(sessionId, tokenHash),
    ).rejects.toThrow(
      'Invalid session revocation database response',
    );
  });

  it('L10: verifies correct database identity', async () => {
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

  it('L11: rejects an unexpected database role', async () => {
    mocks.query.mockResolvedValueOnce({
      rows: [{
        database_name: 'gympro_saas',
        database_user: 'postgres',
      }],
    });

    await expect(
      service.onModuleInit(),
    ).rejects.toThrow(
      'Session revocation database identity verification failed',
    );
  });

  it('L12: closes the connection pool', async () => {
    await service.onModuleDestroy();

    expect(mocks.end).toHaveBeenCalledTimes(1);
  });

  it('L13: requires database configuration', () => {
    const config = {
      get: vi.fn().mockReturnValue(undefined),
    } as unknown as ConfigService;

    expect(
      () => new SessionRevocationDatabaseService(
        config,
      ),
    ).toThrow(
      'AUTH_DATABASE_URL is not configured',
    );
  });

  it('L14: uses a restricted PostgreSQL pool', () => {
    expect(pg.Pool).toHaveBeenCalledWith(
      expect.objectContaining({
        max: 5,
        connectionTimeoutMillis: 5000,
      }),
    );
  });

  it('L15: passes only the session ID and token hash', async () => {
    await service.revokeSession(
      sessionId,
      tokenHash,
    );

    expect(mocks.query).toHaveBeenCalledTimes(1);

    expect(mocks.query.mock.calls[0]?.[1])
      .toEqual([sessionId, tokenHash]);
  });
});
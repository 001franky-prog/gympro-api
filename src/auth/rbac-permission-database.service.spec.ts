
import {
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from 'vitest';

import pg from 'pg';

import {
  RbacPermissionDatabaseService,
} from './rbac-permission-database.service.js';

import type {
  ConfigService,
} from '@nestjs/config';

/**
 * Gym Pro SaaS
 * Step A-F6.15.2
 *
 * RBAC Database Service Unit Tests
 *
 * Important:
 * Preserve the mocked PostgreSQL Pool constructor
 * while resetting query outcomes between tests.
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

describe('Gym Pro RBAC Permission Database Service', () => {
  const tenantId =
    '22222222-2222-4222-8222-222222222222';

  const membershipId =
    '33333333-3333-4333-8333-333333333333';

  const branchId =
    '44444444-4444-4444-8444-444444444444';

  const validRequest = {
    tenantId,
    membershipId,
    permissionCode: 'gym.members.read',
  };

  let service: RbacPermissionDatabaseService;

  beforeEach(() => {
    // Preserve the PostgreSQL Pool implementation.
    vi.clearAllMocks();

    // Reset individual mock behavior explicitly.
    mocks.query.mockReset();
    mocks.end.mockReset();
    mocks.on.mockReset();

    mocks.query.mockResolvedValue({
      rows: [{ allowed: true }],
    });

    mocks.end.mockResolvedValue(undefined);

    const config = {
      get: vi.fn().mockReturnValue(
        'postgresql://test-only-placeholder',
      ),
    } as unknown as ConfigService;

    service = new RbacPermissionDatabaseService(
      config,
    );
  });

  it('R01: allows an authorized permission', async () => {
    await expect(
      service.hasTenantPermission(validRequest),
    ).resolves.toBe(true);

    expect(mocks.query).toHaveBeenCalledTimes(1);
  });

  it('R02: denies a permission rejected by PostgreSQL', async () => {
    mocks.query.mockResolvedValueOnce({
      rows: [{ allowed: false }],
    });

    await expect(
      service.hasTenantPermission(validRequest),
    ).resolves.toBe(false);
  });

  it('R03: passes branch scope to PostgreSQL', async () => {
    await service.hasTenantPermission({
      ...validRequest,
      branchId,
    });

    expect(mocks.query).toHaveBeenCalledWith(
      expect.stringContaining(
        'security.has_tenant_permission',
      ),
      [
        tenantId,
        membershipId,
        'gym.members.read',
        branchId,
      ],
    );
  });

  it('R04: uses null for tenant-wide checks', async () => {
    await service.hasTenantPermission(validRequest);

    expect(mocks.query).toHaveBeenCalledWith(
      expect.any(String),
      [
        tenantId,
        membershipId,
        'gym.members.read',
        null,
      ],
    );
  });

  it('R05: rejects malformed tenant identifiers', async () => {
    await expect(
      service.hasTenantPermission({
        ...validRequest,
        tenantId: 'invalid',
      }),
    ).resolves.toBe(false);

    expect(mocks.query).not.toHaveBeenCalled();
  });

  it('R06: rejects malformed membership identifiers', async () => {
    await expect(
      service.hasTenantPermission({
        ...validRequest,
        membershipId: 'invalid',
      }),
    ).resolves.toBe(false);

    expect(mocks.query).not.toHaveBeenCalled();
  });

  it('R07: rejects malformed branch identifiers', async () => {
    await expect(
      service.hasTenantPermission({
        ...validRequest,
        branchId: 'invalid',
      }),
    ).resolves.toBe(false);

    expect(mocks.query).not.toHaveBeenCalled();
  });

  it('R08: rejects invalid permission codes', async () => {
    await expect(
      service.hasTenantPermission({
        ...validRequest,
        permissionCode: 'DROP TABLE users;',
      }),
    ).resolves.toBe(false);

    expect(mocks.query).not.toHaveBeenCalled();
  });

  it('R09: rejects an empty permission', async () => {
    await expect(
      service.hasTenantPermission({
        ...validRequest,
        permissionCode: '',
      }),
    ).resolves.toBe(false);

    expect(mocks.query).not.toHaveBeenCalled();
  });

  it('R10: propagates database failures', async () => {
    mocks.query.mockRejectedValueOnce(
      new Error('Database unavailable'),
    );

    await expect(
      service.hasTenantPermission(validRequest),
    ).rejects.toThrow('Database unavailable');
  });

  it('R11: rejects an empty database response', async () => {
    mocks.query.mockResolvedValueOnce({
      rows: [],
    });

    await expect(
      service.hasTenantPermission(validRequest),
    ).rejects.toThrow(
      'Invalid RBAC database response',
    );
  });

  it('R12: rejects a nonboolean database result', async () => {
    mocks.query.mockResolvedValueOnce({
      rows: [{ allowed: 'true' }],
    });

    await expect(
      service.hasTenantPermission(validRequest),
    ).rejects.toThrow(
      'Invalid RBAC database response',
    );
  });

  it('R13: verifies the correct database identity', async () => {
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

  it('R14: rejects the wrong database role', async () => {
    mocks.query.mockResolvedValueOnce({
      rows: [{
        database_name: 'gympro_saas',
        database_user: 'postgres',
      }],
    });

    await expect(
      service.onModuleInit(),
    ).rejects.toThrow(
      'RBAC database identity verification failed',
    );
  });

  it('R15: closes the database pool', async () => {
    await service.onModuleDestroy();

    expect(mocks.end).toHaveBeenCalledTimes(1);
  });

  it('R16: requires database configuration', () => {
    const config = {
      get: vi.fn().mockReturnValue(undefined),
    } as unknown as ConfigService;

    expect(() =>
      new RbacPermissionDatabaseService(config),
    ).toThrow(
      'AUTH_DATABASE_URL is not configured',
    );
  });

  it('R17: creates a restricted pg Pool', () => {
    expect(pg.Pool).toHaveBeenCalledWith(
      expect.objectContaining({
        max: 5,
        connectionTimeoutMillis: 5000,
      }),
    );
  });
});


import {
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from 'vitest';

import { AuthDatabaseService } from './auth-database.service.js';

describe('Gym Pro Session Identity Revalidation', () => {
  const userId =
    '11111111-1111-4111-8111-111111111111';

  const tenantId =
    '22222222-2222-4222-8222-222222222222';

  const membershipId =
    '33333333-3333-4333-8333-333333333333';

  const otherTenantId =
    '44444444-4444-4444-8444-444444444444';

  const otherMembershipId =
    '55555555-5555-4555-8555-555555555555';

  const verifyActiveTenantMembership = vi.fn();

  let service: AuthDatabaseService;

  beforeEach(() => {
    vi.resetAllMocks();

    verifyActiveTenantMembership.mockResolvedValue(
      membershipId,
    );

    // Create a prototype-based test instance to
    // exercise the real revalidation method without
    // creating a PostgreSQL connection pool.
    service = Object.create(
      AuthDatabaseService.prototype,
    ) as AuthDatabaseService;

    service.verifyActiveTenantMembership =
      verifyActiveTenantMembership;
  });

  it('V01: accepts matching active membership', async () => {
    const result =
      await service.revalidateSessionIdentity(
        userId,
        tenantId,
        membershipId,
      );

    expect(result).toBe(true);
  });

  it('V02: rejects a different membership UUID', async () => {
    const result =
      await service.revalidateSessionIdentity(
        userId,
        tenantId,
        otherMembershipId,
      );

    expect(result).toBe(false);
  });

  it('V03: rejects missing active membership', async () => {
    verifyActiveTenantMembership.mockResolvedValue(
      null,
    );

    const result =
      await service.revalidateSessionIdentity(
        userId,
        tenantId,
        membershipId,
      );

    expect(result).toBe(false);
  });

  it('V04: rejects invalid user UUID', async () => {
    const result =
      await service.revalidateSessionIdentity(
        'invalid-user',
        tenantId,
        membershipId,
      );

    expect(result).toBe(false);

    expect(
      verifyActiveTenantMembership,
    ).not.toHaveBeenCalled();
  });

  it('V05: rejects invalid tenant UUID', async () => {
    const result =
      await service.revalidateSessionIdentity(
        userId,
        'invalid-tenant',
        membershipId,
      );

    expect(result).toBe(false);

    expect(
      verifyActiveTenantMembership,
    ).not.toHaveBeenCalled();
  });

  it('V06: rejects invalid membership UUID', async () => {
    const result =
      await service.revalidateSessionIdentity(
        userId,
        tenantId,
        'invalid-membership',
      );

    expect(result).toBe(false);

    expect(
      verifyActiveTenantMembership,
    ).not.toHaveBeenCalled();
  });

  it('V07: rejects cross-tenant membership denial', async () => {
    verifyActiveTenantMembership.mockResolvedValue(
      null,
    );

    const result =
      await service.revalidateSessionIdentity(
        userId,
        otherTenantId,
        membershipId,
      );

    expect(result).toBe(false);

    expect(
      verifyActiveTenantMembership,
    ).toHaveBeenCalledWith(
      userId,
      otherTenantId,
    );
  });

  it('V08: accepts case-insensitive UUID match', async () => {
    const result =
      await service.revalidateSessionIdentity(
        userId,
        tenantId,
        membershipId.toUpperCase(),
      );

    expect(result).toBe(true);
  });

  it('V09: propagates database operational errors', async () => {
    verifyActiveTenantMembership.mockRejectedValue(
      new Error('Authentication database unavailable'),
    );

    await expect(
      service.revalidateSessionIdentity(
        userId,
        tenantId,
        membershipId,
      ),
    ).rejects.toThrow(
      'Authentication database unavailable',
    );
  });

  it('V10: forwards the correct user and tenant', async () => {
    await service.revalidateSessionIdentity(
      userId,
      tenantId,
      membershipId,
    );

    expect(
      verifyActiveTenantMembership,
    ).toHaveBeenCalledExactlyOnceWith(
      userId,
      tenantId,
    );
  });
});


import {
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from 'vitest';

import {
  HttpStatus,
  UnauthorizedException,
} from '@nestjs/common';

import {
  SessionPersistenceAuthorizationService,
} from './session-persistence-authorization.service.js';

import type {
  AuthDatabaseService,
} from './auth-database.service.js';

import {
  createVerifiedLoginEligibility,
} from './verified-login-eligibility.js';

import type {
  AuthenticatedSessionRequest,
} from './authenticated-session-request.js';

/**
 * Gym Pro SaaS
 * Session Persistence Authorization Tests
 *
 * Tests the internal authorization gate.
 *
 * No PostgreSQL connections are opened.
 * No session records are created.
 * No permissions are changed.
 */

describe('Gym Pro SessionPersistenceAuthorizationService', () => {
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

  const revalidateSessionIdentity = vi.fn();

  let service: SessionPersistenceAuthorizationService;

  const validRequest = (): AuthenticatedSessionRequest => ({
    eligibility: createVerifiedLoginEligibility({
      userId,
      tenantId,
      membershipId,
    }),
    tokenHash: Buffer.alloc(32, 0xab),
  });

  /**
   * Assert that authorization returns HTTP 401.
   */
  async function expectDenied(
    request: AuthenticatedSessionRequest,
  ): Promise<void> {
    await expect(
      service.authorize(request),
    ).rejects.toMatchObject({
      status: HttpStatus.UNAUTHORIZED,
    });
  }

  beforeEach(() => {
    vi.resetAllMocks();

    revalidateSessionIdentity.mockResolvedValue(true);

    service = new SessionPersistenceAuthorizationService(
      {
        revalidateSessionIdentity,
      } as unknown as AuthDatabaseService,
    );
  });

  it('A01: authorizes a valid active membership', async () => {
    await expect(
      service.authorize(validRequest()),
    ).resolves.toBeUndefined();

    expect(revalidateSessionIdentity)
      .toHaveBeenCalledExactlyOnceWith(
        userId,
        tenantId,
        membershipId,
      );
  });

  it('A02: rejects an inactive membership', async () => {
    revalidateSessionIdentity.mockResolvedValue(false);

    await expectDenied(validRequest());

    expect(revalidateSessionIdentity)
      .toHaveBeenCalledTimes(1);
  });

  it('A03: rejects a cross-tenant relationship', async () => {
    revalidateSessionIdentity.mockResolvedValue(false);

    const request: AuthenticatedSessionRequest = {
      ...validRequest(),
      eligibility: createVerifiedLoginEligibility({
        userId,
        tenantId: otherTenantId,
        membershipId,
      }),
    };

    await expectDenied(request);

    expect(revalidateSessionIdentity)
      .toHaveBeenCalledExactlyOnceWith(
        userId,
        otherTenantId,
        membershipId,
      );
  });

  it('A04: rejects an incorrect membership ID', async () => {
    revalidateSessionIdentity.mockResolvedValue(false);

    const request: AuthenticatedSessionRequest = {
      ...validRequest(),
      eligibility: createVerifiedLoginEligibility({
        userId,
        tenantId,
        membershipId: otherMembershipId,
      }),
    };

    await expectDenied(request);

    expect(revalidateSessionIdentity)
      .toHaveBeenCalledExactlyOnceWith(
        userId,
        tenantId,
        otherMembershipId,
      );
  });

  it('A05: rejects unbranded eligibility', async () => {
    const request = {
      eligibility: {
        userId,
        tenantId,
        membershipId,
      },
      tokenHash: Buffer.alloc(32),
    } as unknown as AuthenticatedSessionRequest;

    await expectDenied(request);

    expect(revalidateSessionIdentity)
      .not.toHaveBeenCalled();
  });

  it('A06: rejects invalid user UUID', async () => {
    const request: AuthenticatedSessionRequest = {
      ...validRequest(),
      eligibility: createVerifiedLoginEligibility({
        userId: 'invalid-user',
        tenantId,
        membershipId,
      }),
    };

    await expectDenied(request);

    expect(revalidateSessionIdentity)
      .not.toHaveBeenCalled();
  });

  it('A07: rejects invalid tenant UUID', async () => {
    const request: AuthenticatedSessionRequest = {
      ...validRequest(),
      eligibility: createVerifiedLoginEligibility({
        userId,
        tenantId: 'invalid-tenant',
        membershipId,
      }),
    };

    await expectDenied(request);

    expect(revalidateSessionIdentity)
      .not.toHaveBeenCalled();
  });

  it('A08: rejects invalid membership UUID', async () => {
    const request: AuthenticatedSessionRequest = {
      ...validRequest(),
      eligibility: createVerifiedLoginEligibility({
        userId,
        tenantId,
        membershipId: 'invalid-membership',
      }),
    };

    await expectDenied(request);

    expect(revalidateSessionIdentity)
      .not.toHaveBeenCalled();
  });

  it('A09: rejects an invalid token digest', async () => {
    const request: AuthenticatedSessionRequest = {
      ...validRequest(),
      tokenHash: Buffer.alloc(16),
    };

    await expectDenied(request);

    expect(revalidateSessionIdentity)
      .not.toHaveBeenCalled();
  });

  it('A10: rejects missing eligibility', async () => {
    const request = {
      tokenHash: Buffer.alloc(32),
    } as unknown as AuthenticatedSessionRequest;

    await expectDenied(request);

    expect(revalidateSessionIdentity)
      .not.toHaveBeenCalled();
  });

  it('A11: propagates database operational errors', async () => {
    revalidateSessionIdentity.mockRejectedValue(
      new Error('Authentication database unavailable'),
    );

    await expect(
      service.authorize(validRequest()),
    ).rejects.toThrow(
      'Authentication database unavailable',
    );
  });

  it('A12: forwards only the expected identity values', async () => {
    await service.authorize(validRequest());

    expect(revalidateSessionIdentity)
      .toHaveBeenCalledExactlyOnceWith(
        userId,
        tenantId,
        membershipId,
      );
  });

  it('A13: malformed requests never reach the database', async () => {
    const malformedRequests = [
      null,
      undefined,
      {},
      {
        eligibility: null,
        tokenHash: Buffer.alloc(32),
      },
      {
        eligibility: {
          userId,
          tenantId,
          membershipId,
        },
        tokenHash: Buffer.alloc(32),
      },
      {
        eligibility: validRequest().eligibility,
        tokenHash: 'invalid-hash',
      },
    ];

    for (const request of malformedRequests) {
      await expect(
        service.authorize(
          request as AuthenticatedSessionRequest,
        ),
      ).rejects.toBeInstanceOf(
        UnauthorizedException,
      );
    }

    expect(revalidateSessionIdentity)
      .not.toHaveBeenCalled();
  });
});

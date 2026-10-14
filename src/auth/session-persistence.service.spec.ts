
import {
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from 'vitest';

import {
  HttpStatus,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';

import {
  SessionPersistenceService,
} from './session-persistence.service.js';

import type {
  SessionDatabaseService,
} from './session-database.service.js';

import type {
  SessionPersistenceAuthorizationService,
} from './session-persistence-authorization.service.js';

import {
  createVerifiedLoginEligibility,
} from './verified-login-eligibility.js';

import type {
  AuthenticatedSessionRequest,
} from './authenticated-session-request.js';

/**
 * Gym Pro SaaS
 * Session Persistence Security Unit Tests
 *
 * Validates:
 * - Request structure enforcement.
 * - Authorization before future persistence.
 * - Unauthorized membership rejection.
 * - Database operational error propagation.
 * - Fail-closed persistence behavior.
 * - No session database writes.
 *
 * No real PostgreSQL connections are opened.
 */

describe('Gym Pro SessionPersistenceService', () => {
  const identity = {
    userId:
      '11111111-1111-4111-8111-111111111111',
    tenantId:
      '22222222-2222-4222-8222-222222222222',
    membershipId:
      '33333333-3333-4333-8333-333333333333',
  };

  const validRequest = (): AuthenticatedSessionRequest => ({
    eligibility: createVerifiedLoginEligibility({
      ...identity,
    }),
    tokenHash: Buffer.alloc(32, 0xab),
  });

  const verifySessionPrivileges = vi.fn();
  const createTenantSession = vi.fn();
  const authorize = vi.fn();

  let service: SessionPersistenceService;

  beforeEach(() => {
    vi.resetAllMocks();

    // Simulate successful authorization by default.
    authorize.mockResolvedValue(undefined);

    // Mock database operations to detect any calls.
    verifySessionPrivileges.mockResolvedValue(true);

    createTenantSession.mockRejectedValue(
      new Error(
        'SECURITY FAILURE: Database operation called',
      ),
    );

    service = new SessionPersistenceService(
      {
        verifySessionPrivileges,
        createTenantSession,
      } as unknown as SessionDatabaseService,

      {
        authorize,
      } as unknown as SessionPersistenceAuthorizationService,
    );
  });

  async function expectDisabled(
    request: AuthenticatedSessionRequest,
  ): Promise<void> {
    await expect(
      service.createSession(request),
    ).rejects.toMatchObject({
      status: HttpStatus.SERVICE_UNAVAILABLE,
    });

    expect(createTenantSession).not.toHaveBeenCalled();
    expect(verifySessionPrivileges).not.toHaveBeenCalled();
  }

  it('P01: rejects an authorized request while persistence is disabled', async () => {
    await expectDisabled(validRequest());

    expect(authorize).toHaveBeenCalledTimes(1);
  });

  it('P02: rejects invalid user UUID before authorization', async () => {
    await expectDisabled({
      ...validRequest(),
      eligibility: createVerifiedLoginEligibility({
        ...identity,
        userId: 'invalid-user',
      }),
    });

    expect(authorize).not.toHaveBeenCalled();
  });

  it('P03: rejects invalid tenant UUID before authorization', async () => {
    await expectDisabled({
      ...validRequest(),
      eligibility: createVerifiedLoginEligibility({
        ...identity,
        tenantId: 'invalid-tenant',
      }),
    });

    expect(authorize).not.toHaveBeenCalled();
  });

  it('P04: rejects invalid membership UUID before authorization', async () => {
    await expectDisabled({
      ...validRequest(),
      eligibility: createVerifiedLoginEligibility({
        ...identity,
        membershipId: 'invalid-membership',
      }),
    });

    expect(authorize).not.toHaveBeenCalled();
  });

  it('P05: rejects a short token digest', async () => {
    await expectDisabled({
      ...validRequest(),
      tokenHash: Buffer.alloc(16),
    });

    expect(authorize).not.toHaveBeenCalled();
  });

  it('P06: rejects a long token digest', async () => {
    await expectDisabled({
      ...validRequest(),
      tokenHash: Buffer.alloc(64),
    });

    expect(authorize).not.toHaveBeenCalled();
  });

  it('P07: rejects a non-Buffer token digest', async () => {
    await expectDisabled({
      ...validRequest(),
      tokenHash:
        'invalid' as unknown as Buffer,
    });

    expect(authorize).not.toHaveBeenCalled();
  });

  it('P08: rejects missing eligibility', async () => {
    await expectDisabled({
      ...validRequest(),
      eligibility:
        undefined as unknown as
          AuthenticatedSessionRequest['eligibility'],
    });

    expect(authorize).not.toHaveBeenCalled();
  });

  it('P09: rejects unbranded eligibility', async () => {
    await expectDisabled({
      ...validRequest(),
      eligibility: {
        ...identity,
      } as unknown as
        AuthenticatedSessionRequest['eligibility'],
    });

    expect(authorize).not.toHaveBeenCalled();
  });

  it('P10: denied authorization prevents persistence', async () => {
    authorize.mockRejectedValue(
      new UnauthorizedException(
        'Invalid credentials or tenant access',
      ),
    );

    await expect(
      service.createSession(validRequest()),
    ).rejects.toMatchObject({
      status: HttpStatus.UNAUTHORIZED,
    });

    expect(authorize).toHaveBeenCalledTimes(1);

    expect(createTenantSession).not.toHaveBeenCalled();
    expect(verifySessionPrivileges).not.toHaveBeenCalled();
  });

  it('P11: authorization database errors propagate safely', async () => {
    authorize.mockRejectedValue(
      new Error(
        'Authentication database unavailable',
      ),
    );

    await expect(
      service.createSession(validRequest()),
    ).rejects.toThrow(
      'Authentication database unavailable',
    );

    expect(createTenantSession).not.toHaveBeenCalled();
    expect(verifySessionPrivileges).not.toHaveBeenCalled();
  });

  it('P12: repeated valid requests always fail closed', async () => {
    for (let i = 0; i < 5; i++) {
      await expectDisabled(validRequest());
    }

    expect(authorize).toHaveBeenCalledTimes(5);
  });

  it('P13: authorization runs before the fail-closed response', async () => {
    await expectDisabled(validRequest());

    expect(authorize).toHaveBeenCalledExactlyOnceWith(
      expect.objectContaining({
        eligibility: expect.objectContaining({
          userId: identity.userId,
          tenantId: identity.tenantId,
          membershipId: identity.membershipId,
        }),
        tokenHash: expect.any(Buffer),
      }),
    );
  });

  it('P14: no session ID is returned when authorization succeeds', async () => {
    await expect(
      service.createSession(validRequest()),
    ).rejects.toBeInstanceOf(
      ServiceUnavailableException,
    );

    expect(authorize).toHaveBeenCalledTimes(1);
    expect(createTenantSession).not.toHaveBeenCalled();
  });
});


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
  AuthController,
} from './auth.controller.js';

import type {
  SessionIssuanceService,
} from './session-issuance.service.js';

import type {
  SessionBearerTokenService,
} from './session-bearer-token.service.js';

import type {
  SessionRevocationDatabaseService,
} from './session-revocation-database.service.js';

import type {
  GymProAuthenticatedRequest,
} from './authenticated-session.guard.js';

/**
 * Gym Pro SaaS
 * Step A-F6.27.1
 *
 * Authentication Controller Tests
 *
 * Covers:
 * - Login request validation
 * - Fail-closed session issuance
 * - Protected session identity response
 * - Tenant and permission diagnostic responses
 * - Logout and database revocation
 *
 * Uses mocked dependencies.
 * Does not create or revoke real sessions.
 */

describe('Gym Pro AuthController', () => {
  const issueSession = vi.fn();
  const hashAuthorization = vi.fn();
  const revokeSession = vi.fn();

  const tenantId =
    '22222222-2222-4222-8222-222222222222';

  const verifiedSession = {
    sessionId:
      '11111111-1111-4111-8111-111111111111',
    userId:
      '44444444-4444-4444-8444-444444444444',
    tenantId,
    membershipId:
      '33333333-3333-4333-8333-333333333333',
  };

  const validLogin = {
    email: 'Admin@Example.com',
    password: 'ExamplePassword123!',
    tenantId,
  };

  const tokenHash = Buffer.alloc(32, 0xab);

  let controller: AuthController;

  function authenticatedRequest():
    GymProAuthenticatedRequest {
    return {
      headers: {
        authorization: 'Bearer test-token',
      },
      gymproSession: {
        ...verifiedSession,
      },
    };
  }

  beforeEach(() => {
    vi.resetAllMocks();

    issueSession.mockRejectedValue(
      new ServiceUnavailableException(
        'Session issuance is not enabled',
      ),
    );

    hashAuthorization.mockReturnValue(tokenHash);

    revokeSession.mockResolvedValue(true);

    controller = new AuthController(
      {
        issueSession,
      } as unknown as SessionIssuanceService,

      {
        hashAuthorization,
      } as unknown as SessionBearerTokenService,

      {
        revokeSession,
      } as unknown as SessionRevocationDatabaseService,
    );
  });

  // ==================================================
  // LOGIN REQUEST VALIDATION
  // ==================================================

  it('A01: rejects an empty login body', async () => {
    await expect(
      controller.login({}),
    ).rejects.toMatchObject({
      status: HttpStatus.UNAUTHORIZED,
    });

    expect(issueSession).not.toHaveBeenCalled();
  });

  it('A02: rejects a null body', async () => {
    await expect(
      controller.login(null),
    ).rejects.toMatchObject({
      status: HttpStatus.UNAUTHORIZED,
    });

    expect(issueSession).not.toHaveBeenCalled();
  });

  it('A03: rejects non-object input', async () => {
    await expect(
      controller.login('invalid'),
    ).rejects.toMatchObject({
      status: HttpStatus.UNAUTHORIZED,
    });

    expect(issueSession).not.toHaveBeenCalled();
  });

  it('A04: rejects a missing password', async () => {
    await expect(
      controller.login({
        email: validLogin.email,
        tenantId,
      }),
    ).rejects.toMatchObject({
      status: HttpStatus.UNAUTHORIZED,
    });

    expect(issueSession).not.toHaveBeenCalled();
  });

  it('A05: rejects malformed tenant UUID', async () => {
    await expect(
      controller.login({
        ...validLogin,
        tenantId: 'invalid-tenant',
      }),
    ).rejects.toMatchObject({
      status: HttpStatus.UNAUTHORIZED,
    });

    expect(issueSession).not.toHaveBeenCalled();
  });

  it('A06: rejects empty email', async () => {
    await expect(
      controller.login({
        ...validLogin,
        email: '   ',
      }),
    ).rejects.toMatchObject({
      status: HttpStatus.UNAUTHORIZED,
    });

    expect(issueSession).not.toHaveBeenCalled();
  });

  it('A07: rejects empty password', async () => {
    await expect(
      controller.login({
        ...validLogin,
        password: '',
      }),
    ).rejects.toMatchObject({
      status: HttpStatus.UNAUTHORIZED,
    });

    expect(issueSession).not.toHaveBeenCalled();
  });

  it('A08: normalizes email and forwards login', async () => {
    await expect(
      controller.login(validLogin),
    ).rejects.toMatchObject({
      status: HttpStatus.SERVICE_UNAVAILABLE,
    });

    expect(issueSession).toHaveBeenCalledTimes(1);

    expect(issueSession).toHaveBeenCalledWith({
      email: 'admin@example.com',
      password: validLogin.password,
      tenantId,
    });
  });

  it('A09: preserves authentication failure', async () => {
    issueSession.mockRejectedValueOnce(
      new UnauthorizedException(
        'Invalid credentials or tenant access',
      ),
    );

    await expect(
      controller.login(validLogin),
    ).rejects.toMatchObject({
      status: HttpStatus.UNAUTHORIZED,
    });
  });

  it('A10: fails closed when issuance is unavailable', async () => {
    await expect(
      controller.login(validLogin),
    ).rejects.toBeInstanceOf(
      ServiceUnavailableException,
    );
  });

  it('A11: rejects excessively long password', async () => {
    await expect(
      controller.login({
        ...validLogin,
        password: 'x'.repeat(1025),
      }),
    ).rejects.toMatchObject({
      status: HttpStatus.UNAUTHORIZED,
    });

    expect(issueSession).not.toHaveBeenCalled();
  });

  it('A12: rejects array request body', async () => {
    await expect(
      controller.login([validLogin]),
    ).rejects.toMatchObject({
      status: HttpStatus.UNAUTHORIZED,
    });

    expect(issueSession).not.toHaveBeenCalled();
  });

  // ==================================================
  // AUTHENTICATED IDENTITY ENDPOINT
  // ==================================================

  it('A13: returns verified session identity', () => {
    expect(
      controller.getCurrentSession(
        authenticatedRequest(),
      ),
    ).toEqual(verifiedSession);
  });

  it('A14: rejects missing verified identity', () => {
    expect(() =>
      controller.getCurrentSession({
        headers: {},
      }),
    ).toThrow(UnauthorizedException);
  });

  // ==================================================
  // TENANT AND PERMISSION DIAGNOSTIC ENDPOINTS
  // ==================================================

  it('A15: returns matching tenant identity', () => {
    expect(
      controller.checkTenantAccess(
        authenticatedRequest(),
      ),
    ).toEqual({
      authorized: true,
      tenantId,
      userId: verifiedSession.userId,
    });
  });

  it('A16: returns authorized permission result', () => {
    expect(
      controller.checkMembersReadPermission(
        authenticatedRequest(),
      ),
    ).toEqual({
      authorized: true,
      permission: 'gym.members.read',
      tenantId,
    });
  });

  // ==================================================
  // LOGOUT AND SESSION REVOCATION
  // ==================================================

  it('A17: revokes the current authenticated session', async () => {
    await expect(
      controller.logout(
        authenticatedRequest(),
      ),
    ).resolves.toBeUndefined();

    expect(hashAuthorization).toHaveBeenCalledWith(
      'Bearer test-token',
    );

    expect(revokeSession).toHaveBeenCalledWith(
      verifiedSession.sessionId,
      tokenHash,
    );

    expect(revokeSession).toHaveBeenCalledTimes(1);
  });

  it('A18: rejects logout without a verified session', async () => {
    await expect(
      controller.logout({
        headers: {
          authorization: 'Bearer test-token',
        },
      }),
    ).rejects.toBeInstanceOf(
      UnauthorizedException,
    );

    expect(revokeSession).not.toHaveBeenCalled();
    expect(hashAuthorization).not.toHaveBeenCalled();
  });

  it('A19: rejects a failed revocation', async () => {
    revokeSession.mockResolvedValueOnce(false);

    await expect(
      controller.logout(
        authenticatedRequest(),
      ),
    ).rejects.toMatchObject({
      status: HttpStatus.UNAUTHORIZED,
    });
  });

  it('A20: fails closed on database error', async () => {
    revokeSession.mockRejectedValueOnce(
      new Error('SENSITIVE_DATABASE_ERROR'),
    );

    await expect(
      controller.logout(
        authenticatedRequest(),
      ),
    ).rejects.toMatchObject({
      status: HttpStatus.SERVICE_UNAVAILABLE,
      message: 'Session revocation unavailable',
    });
  });

  it('A21: does not accept a client-supplied session ID', async () => {
    const request = authenticatedRequest();

    const forgedRequest = {
      ...request,
      body: {
        sessionId:
          '99999999-9999-4999-8999-999999999999',
      },
    };

    await controller.logout(forgedRequest);

    expect(revokeSession).toHaveBeenCalledWith(
      verifiedSession.sessionId,
      tokenHash,
    );
  });

  it('A22: does not revoke if the token cannot be hashed', async () => {
    hashAuthorization.mockImplementationOnce(() => {
      throw new UnauthorizedException(
        'Invalid or expired session',
      );
    });

    await expect(
      controller.logout(
        authenticatedRequest(),
      ),
    ).rejects.toBeInstanceOf(
      UnauthorizedException,
    );

    expect(revokeSession).not.toHaveBeenCalled();
  });
});

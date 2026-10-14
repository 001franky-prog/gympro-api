
import {
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from 'vitest';

import {
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';

import {
  SessionIssuanceService,
} from './session-issuance.service.js';

import type {
  AuthenticatedEligibilityService,
} from './authenticated-eligibility.service.js';

import type {
  AuthDatabaseService,
} from './auth-database.service.js';

import type {
  SessionTokenService,
} from './session-token.service.js';

import type {
  SessionPersistenceService,
} from './session-persistence.service.js';

import {
  createVerifiedLoginEligibility,
} from './verified-login-eligibility.js';

import {
  SESSION_SECURITY_POLICY,
} from './session-security-policy.js';

describe('Gym Pro Trusted Session Activation Boundary', () => {
  const identity = {
    userId:
      '11111111-1111-4111-8111-111111111111',
    tenantId:
      '22222222-2222-4222-8222-222222222222',
    membershipId:
      '33333333-3333-4333-8333-333333333333',
  };

  const login = {
    email: 'admin@example.com',
    password: 'TestPassword123!',
    tenantId: identity.tenantId,
  };

  const token = 'test-only-opaque-session-token';
  const tokenHash = Buffer.alloc(32, 0xab);

  const authenticateTenant = vi.fn();
  const revalidateSessionIdentity = vi.fn();
  const generateToken = vi.fn();
  const createSession = vi.fn();

  let service: SessionIssuanceService;

  beforeEach(() => {
    vi.resetAllMocks();

    authenticateTenant.mockResolvedValue(
      createVerifiedLoginEligibility(identity),
    );

    revalidateSessionIdentity.mockResolvedValue(true);

    generateToken.mockReturnValue({
      token,
      tokenHash,
    });

    createSession.mockRejectedValue(
      new ServiceUnavailableException(
        'Session persistence is not enabled',
      ),
    );

    service = new SessionIssuanceService(
      {
        authenticateTenant,
      } as unknown as AuthenticatedEligibilityService,

      {
        revalidateSessionIdentity,
      } as unknown as AuthDatabaseService,

      {
        generateToken,
      } as unknown as SessionTokenService,

      {
        createSession,
      } as unknown as SessionPersistenceService,
    );
  });

  it('B01: security policy remains disabled', () => {
    expect(
      SESSION_SECURITY_POLICY.persistenceEnabled,
    ).toBe(false);
  });

  it('B02: invalid credentials prevent persistence', async () => {
    authenticateTenant.mockRejectedValueOnce(
      new UnauthorizedException(
        'Invalid credentials or tenant access',
      ),
    );

    await expect(
      service.issueSession(login),
    ).rejects.toBeInstanceOf(
      UnauthorizedException,
    );

    expect(generateToken).not.toHaveBeenCalled();
    expect(createSession).not.toHaveBeenCalled();
  });

  it('B03: revoked membership prevents persistence', async () => {
    revalidateSessionIdentity.mockResolvedValueOnce(
      false,
    );

    await expect(
      service.issueSession(login),
    ).rejects.toBeInstanceOf(
      UnauthorizedException,
    );

    expect(generateToken).not.toHaveBeenCalled();
    expect(createSession).not.toHaveBeenCalled();
  });

  it('B04: database revalidation errors stop issuance', async () => {
    revalidateSessionIdentity.mockRejectedValueOnce(
      new Error('Database unavailable'),
    );

    await expect(
      service.issueSession(login),
    ).rejects.toThrow('Database unavailable');

    expect(generateToken).not.toHaveBeenCalled();
    expect(createSession).not.toHaveBeenCalled();
  });

  it('B05: persistence failure never returns a token', async () => {
    await expect(
      service.issueSession(login),
    ).rejects.toBeInstanceOf(
      ServiceUnavailableException,
    );

    expect(createSession).toHaveBeenCalledTimes(1);
  });

  it('B06: fake persistence success cannot bypass disabled policy', async () => {
    createSession.mockResolvedValueOnce({
      sessionId:
        '44444444-4444-4444-8444-444444444444',
    });

    await expect(
      service.issueSession(login),
    ).rejects.toBeInstanceOf(
      ServiceUnavailableException,
    );
  });

  it('B07: persistence receives token hash, not raw token', async () => {
    await expect(
      service.issueSession(login),
    ).rejects.toBeInstanceOf(
      ServiceUnavailableException,
    );

    expect(createSession).toHaveBeenCalledWith({
      eligibility: expect.objectContaining(identity),
      tokenHash,
    });

    const request = createSession.mock.calls[0]?.[0];

    expect(request).toBeDefined();
    expect(request.tokenHash).toBeInstanceOf(Buffer);
    expect(request.tokenHash).toHaveLength(32);
    expect(request).not.toHaveProperty('token');
    expect(request).not.toHaveProperty('accessToken');
    expect(request).not.toHaveProperty('password');
  });

  it('B08: issuance verifies the authenticated identity', async () => {
    await expect(
      service.issueSession(login),
    ).rejects.toBeInstanceOf(
      ServiceUnavailableException,
    );

    expect(authenticateTenant).toHaveBeenCalledWith(
      login.email,
      login.password,
      login.tenantId,
    );

    expect(revalidateSessionIdentity).toHaveBeenCalledWith(
      identity.userId,
      identity.tenantId,
      identity.membershipId,
    );
  });

  it('B09: invalid eligibility cannot generate a token', async () => {
    authenticateTenant.mockResolvedValueOnce({
      ...identity,
    });

    await expect(
      service.issueSession(login),
    ).rejects.toBeInstanceOf(
      UnauthorizedException,
    );

    expect(generateToken).not.toHaveBeenCalled();
    expect(createSession).not.toHaveBeenCalled();
  });
});

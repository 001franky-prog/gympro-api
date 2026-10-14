
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
  isSessionPersistenceEnabled,
} from './session-security-policy.js';

/**
 * GYM PRO SAAS
 * Step A-F6.35
 *
 * Trusted Session Issuance Workflow Tests
 *
 * No actual PostgreSQL writes.
 * No real user passwords.
 * No real bearer tokens issued.
 */

describe('Gym Pro Trusted Session Issuance', () => {
  const identity = {
    userId:
      '11111111-1111-4111-8111-111111111111',
    tenantId:
      '22222222-2222-4222-8222-222222222222',
    membershipId:
      '33333333-3333-4333-8333-333333333333',
  };

  const request = {
    email: 'test@example.invalid',
    password: 'TestOnlyPassword123!',
    tenantId: identity.tenantId,
  };

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
      token: 'test-only-token-not-a-real-credential',
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

  it('T01: development writes are disabled in test mode', () => {
    expect(isSessionPersistenceEnabled()).toBe(false);
  });

  it('T02: invalid password prevents session issuance', async () => {
    authenticateTenant.mockRejectedValueOnce(
      new UnauthorizedException(
        'Invalid credentials or tenant access',
      ),
    );

    await expect(
      service.issueSession(request),
    ).rejects.toBeInstanceOf(
      UnauthorizedException,
    );

    expect(revalidateSessionIdentity)
      .not.toHaveBeenCalled();

    expect(generateToken).not.toHaveBeenCalled();
    expect(createSession).not.toHaveBeenCalled();
  });

  it('T03: inactive membership prevents persistence', async () => {
    revalidateSessionIdentity.mockResolvedValueOnce(
      false,
    );

    await expect(
      service.issueSession(request),
    ).rejects.toBeInstanceOf(
      UnauthorizedException,
    );

    expect(generateToken).not.toHaveBeenCalled();
    expect(createSession).not.toHaveBeenCalled();
  });

  it('T04: database revalidation failure prevents persistence', async () => {
    revalidateSessionIdentity.mockRejectedValueOnce(
      new Error('Test database unavailable'),
    );

    await expect(
      service.issueSession(request),
    ).rejects.toThrow(
      'Test database unavailable',
    );

    expect(generateToken).not.toHaveBeenCalled();
    expect(createSession).not.toHaveBeenCalled();
  });

  it('T05: unbranded identity is rejected', async () => {
    authenticateTenant.mockResolvedValueOnce({
      ...identity,
    });

    await expect(
      service.issueSession(request),
    ).rejects.toBeInstanceOf(
      UnauthorizedException,
    );

    expect(generateToken).not.toHaveBeenCalled();
    expect(createSession).not.toHaveBeenCalled();
  });

  it('T06: authorized identity is revalidated before persistence', async () => {
    await expect(
      service.issueSession(request),
    ).rejects.toBeInstanceOf(
      ServiceUnavailableException,
    );

    expect(authenticateTenant).toHaveBeenCalledWith(
      request.email,
      request.password,
      request.tenantId,
    );

    expect(revalidateSessionIdentity)
      .toHaveBeenCalledWith(
        identity.userId,
        identity.tenantId,
        identity.membershipId,
      );

    expect(createSession).toHaveBeenCalledTimes(1);
  });

  it('T07: persistence receives only the token hash and eligibility', async () => {
    await expect(
      service.issueSession(request),
    ).rejects.toBeInstanceOf(
      ServiceUnavailableException,
    );

    expect(createSession).toHaveBeenCalledWith({
      eligibility: expect.objectContaining(identity),
      tokenHash,
    });

    const persistenceInput =
      createSession.mock.calls[0]?.[0];

    expect(persistenceInput)
      .not.toHaveProperty('password');

    expect(persistenceInput)
      .not.toHaveProperty('accessToken');

    expect(persistenceInput)
      .not.toHaveProperty('token');

    expect(persistenceInput.tokenHash)
      .toHaveLength(32);
  });

  it('T08: simulated persistence success does not expose a token', async () => {
    createSession.mockResolvedValueOnce({
      sessionId:
        '44444444-4444-4444-8444-444444444444',
    });

    await expect(
      service.issueSession(request),
    ).rejects.toBeInstanceOf(
      ServiceUnavailableException,
    );
  });

  it('T09: malformed token hash cannot produce a session', async () => {
    generateToken.mockReturnValueOnce({
      token: 'test-token',
      tokenHash: Buffer.alloc(12, 0),
    });

    await expect(
      service.issueSession(request),
    ).rejects.toBeInstanceOf(
      ServiceUnavailableException,
    );

    expect(createSession).not.toHaveBeenCalled();
  });
});

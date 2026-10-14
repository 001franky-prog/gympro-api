
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

import { SessionIssuanceService } from './session-issuance.service.js';
import { AuthenticatedEligibilityService } from './authenticated-eligibility.service.js';
import { AuthDatabaseService } from './auth-database.service.js';
import { SessionTokenService } from './session-token.service.js';
import { SessionPersistenceService } from './session-persistence.service.js';

import {
  createVerifiedLoginEligibility,
} from './verified-login-eligibility.js';

describe('Gym Pro SessionIssuanceService', () => {
  const request = {
    email: 'test@example.com',
    password: 'test-only-password',
    tenantId: '22222222-2222-4222-8222-222222222222',
  };

  const eligibility = createVerifiedLoginEligibility({
    userId: '11111111-1111-4111-8111-111111111111',
    tenantId: request.tenantId,
    membershipId: '33333333-3333-4333-8333-333333333333',
  });

  const testHash = Buffer.alloc(32, 0xab);

  const authenticateTenant = vi.fn();
  const revalidateSessionIdentity = vi.fn();
  const generateToken = vi.fn();
  const createSession = vi.fn();

  let service: SessionIssuanceService;

  beforeEach(() => {
    vi.resetAllMocks();

    authenticateTenant.mockResolvedValue(eligibility);
    revalidateSessionIdentity.mockResolvedValue(true);

    generateToken.mockReturnValue({
      token: 'test-only-bearer-token',
      tokenHash: Buffer.from(testHash),
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

  it('S01: invalid credentials return 401 without generating a token', async () => {
    authenticateTenant.mockRejectedValue(
      new UnauthorizedException(
        'Invalid credentials or tenant access',
      ),
    );

    await expect(
      service.issueSession(request),
    ).rejects.toMatchObject({
      status: HttpStatus.UNAUTHORIZED,
    });

    expect(revalidateSessionIdentity).not.toHaveBeenCalled();
    expect(generateToken).not.toHaveBeenCalled();
    expect(createSession).not.toHaveBeenCalled();
  });

  it('S02: unauthorized tenant does not proceed', async () => {
    authenticateTenant.mockRejectedValue(
      new UnauthorizedException(),
    );

    await expect(
      service.issueSession(request),
    ).rejects.toBeInstanceOf(UnauthorizedException);

    expect(revalidateSessionIdentity).not.toHaveBeenCalled();
    expect(generateToken).not.toHaveBeenCalled();
    expect(createSession).not.toHaveBeenCalled();
  });

  it('S03: authorized identity is revalidated before token generation', async () => {
    await expect(
      service.issueSession(request),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);

    expect(revalidateSessionIdentity)
      .toHaveBeenCalledExactlyOnceWith(
        eligibility.userId,
        eligibility.tenantId,
        eligibility.membershipId,
      );

    expect(generateToken).toHaveBeenCalledTimes(1);
    expect(createSession).toHaveBeenCalledTimes(1);

    expect(
      revalidateSessionIdentity.mock.invocationCallOrder[0],
    ).toBeLessThan(
      generateToken.mock.invocationCallOrder[0],
    );
  });

  it('S04: forwards only login credentials and tenant ID', async () => {
    await expect(
      service.issueSession(request),
    ).rejects.toMatchObject({
      status: HttpStatus.SERVICE_UNAVAILABLE,
    });

    expect(authenticateTenant)
      .toHaveBeenCalledExactlyOnceWith(
        request.email,
        request.password,
        request.tenantId,
      );
  });

  it('S05: unbranded eligibility is rejected before revalidation', async () => {
    authenticateTenant.mockResolvedValue({
      userId: eligibility.userId,
      tenantId: eligibility.tenantId,
      membershipId: eligibility.membershipId,
    });

    await expect(
      service.issueSession(request),
    ).rejects.toBeInstanceOf(UnauthorizedException);

    expect(revalidateSessionIdentity).not.toHaveBeenCalled();
    expect(generateToken).not.toHaveBeenCalled();
    expect(createSession).not.toHaveBeenCalled();
  });

  it('S06: persistence errors propagate without returning a token', async () => {
    createSession.mockRejectedValue(
      new Error('Database unavailable'),
    );

    await expect(
      service.issueSession(request),
    ).rejects.toThrow('Database unavailable');

    expect(createSession).toHaveBeenCalledTimes(1);
  });

  it('S07: unexpected persistence success still fails closed', async () => {
    createSession.mockResolvedValue({
      sessionId: '44444444-4444-4444-8444-444444444444',
    });

    await expect(
      service.issueSession(request),
    ).rejects.toMatchObject({
      status: HttpStatus.SERVICE_UNAVAILABLE,
    });
  });

  it('S08: failed revalidation prevents token generation', async () => {
    revalidateSessionIdentity.mockResolvedValue(false);

    await expect(
      service.issueSession(request),
    ).rejects.toMatchObject({
      status: HttpStatus.UNAUTHORIZED,
    });

    expect(generateToken).not.toHaveBeenCalled();
    expect(createSession).not.toHaveBeenCalled();
  });

  it('S09: malformed token hash never reaches persistence', async () => {
    generateToken.mockReturnValue({
      token: 'test-only-bearer-token',
      tokenHash: Buffer.alloc(16),
    });

    await expect(
      service.issueSession(request),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);

    expect(createSession).not.toHaveBeenCalled();
  });

  it('S10: authentication infrastructure errors propagate', async () => {
    authenticateTenant.mockRejectedValue(
      new Error('Authentication database unavailable'),
    );

    await expect(
      service.issueSession(request),
    ).rejects.toThrow('Authentication database unavailable');

    expect(revalidateSessionIdentity).not.toHaveBeenCalled();
    expect(generateToken).not.toHaveBeenCalled();
  });

  it('S11: revalidation database errors prevent token generation', async () => {
    revalidateSessionIdentity.mockRejectedValue(
      new Error('Membership database unavailable'),
    );

    await expect(
      service.issueSession(request),
    ).rejects.toThrow('Membership database unavailable');

    expect(generateToken).not.toHaveBeenCalled();
    expect(createSession).not.toHaveBeenCalled();
  });

  it('S12: correct digest is passed without raw bearer token', async () => {
    await expect(
      service.issueSession(request),
    ).rejects.toBeInstanceOf(ServiceUnavailableException);

    expect(createSession).toHaveBeenCalledWith({
      eligibility,
      tokenHash: expect.any(Buffer),
    });

    const persistenceRequest = createSession.mock.calls[0]?.[0];

    expect(persistenceRequest.tokenHash).toEqual(testHash);
    expect(Object.keys(persistenceRequest).sort()).toEqual([
      'eligibility',
      'tokenHash',
    ]);
  });
});

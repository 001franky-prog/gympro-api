
import {
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from 'vitest';

import {
  UnauthorizedException,
} from '@nestjs/common';

import {
  AuthenticatedEligibilityService,
} from './authenticated-eligibility.service.js';

import {
  LoginOrchestratorService,
} from './login-orchestrator.service.js';

import {
  isVerifiedLoginEligibility,
} from './verified-login-eligibility.js';

describe('Gym Pro AuthenticatedEligibilityService', () => {
  const email = 'test@example.com';
  const password = 'test-only-password';

  const tenantId =
    '22222222-2222-4222-8222-222222222222';

  const eligibility = {
    userId:
      '11111111-1111-4111-8111-111111111111',
    tenantId,
    membershipId:
      '33333333-3333-4333-8333-333333333333',
  };

  const verifyLoginEligibility = vi.fn();

  let service: AuthenticatedEligibilityService;

  beforeEach(() => {
    vi.resetAllMocks();

    verifyLoginEligibility.mockResolvedValue({
      ...eligibility,
    });

    service = new AuthenticatedEligibilityService(
      {
        verifyLoginEligibility,
      } as unknown as LoginOrchestratorService,
    );
  });

  it('A01: creates branded eligibility after successful verification', async () => {
    const result = await service.authenticateTenant(
      email,
      password,
      tenantId,
    );

    expect(isVerifiedLoginEligibility(result))
      .toBe(true);

    expect(result.userId).toBe(eligibility.userId);
    expect(result.tenantId).toBe(eligibility.tenantId);
    expect(result.membershipId)
      .toBe(eligibility.membershipId);
  });

  it('A02: rejects invalid credentials with HTTP 401', async () => {
    verifyLoginEligibility.mockRejectedValue(
      new UnauthorizedException(
        'Invalid credentials or tenant access',
      ),
    );

    await expect(
      service.authenticateTenant(
        email,
        'incorrect-password',
        tenantId,
      ),
    ).rejects.toBeInstanceOf(
      UnauthorizedException,
    );
  });

  it('A03: rejects unauthorized tenant membership', async () => {
    verifyLoginEligibility.mockRejectedValue(
      new UnauthorizedException(
        'Invalid credentials or tenant access',
      ),
    );

    await expect(
      service.authenticateTenant(
        email,
        password,
        tenantId,
      ),
    ).rejects.toMatchObject({
      status: 401,
    });
  });

  it('A04: propagates operational errors', async () => {
    verifyLoginEligibility.mockRejectedValue(
      new Error('Authentication database unavailable'),
    );

    await expect(
      service.authenticateTenant(
        email,
        password,
        tenantId,
      ),
    ).rejects.toThrow(
      'Authentication database unavailable',
    );
  });

  it('A05: forwards login credentials and tenant ID correctly', async () => {
    await service.authenticateTenant(
      email,
      password,
      tenantId,
    );

    expect(
      verifyLoginEligibility,
    ).toHaveBeenCalledExactlyOnceWith(
      email,
      password,
      tenantId,
    );
  });

  it('A06: rejected login produces no eligibility result', async () => {
    verifyLoginEligibility.mockRejectedValue(
      new UnauthorizedException(),
    );

    await expect(
      service.authenticateTenant(
        email,
        password,
        tenantId,
      ),
    ).rejects.toBeInstanceOf(
      UnauthorizedException,
    );

    expect(
      verifyLoginEligibility,
    ).toHaveBeenCalledTimes(1);
  });

  it('A07: returned eligibility object is frozen', async () => {
    const result = await service.authenticateTenant(
      email,
      password,
      tenantId,
    );

    expect(Object.isFrozen(result)).toBe(true);

    expect(() => {
      Object.assign(result, {
        membershipId:
          '44444444-4444-4444-8444-444444444444',
      });
    }).toThrow(TypeError);

    expect(result.membershipId)
      .toBe(eligibility.membershipId);
  });

  it('A08: result excludes password and session token', async () => {
    const result = await service.authenticateTenant(
      email,
      password,
      tenantId,
    );

    expect(Object.keys(result).sort()).toEqual([
      'membershipId',
      'tenantId',
      'userId',
    ]);

    const serialized = JSON.stringify(result);

    expect(serialized).not.toContain(password);
    expect(serialized).not.toContain('tokenHash');
    expect(serialized).not.toContain('sessionToken');
    expect(serialized).not.toContain('password');
  });
});

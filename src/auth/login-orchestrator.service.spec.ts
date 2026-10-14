
import {
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from 'vitest';

import {
  UnauthorizedException,
  HttpStatus,
} from '@nestjs/common';

import { LoginOrchestratorService } from './login-orchestrator.service.js';
import { AuthenticationService } from './authentication.service.js';
import { AuthDatabaseService } from './auth-database.service.js';

describe('Gym Pro LoginOrchestratorService', () => {
  const userId = '11111111-1111-4111-8111-111111111111';
  const tenantId = '22222222-2222-4222-8222-222222222222';
  const membershipId = '33333333-3333-4333-8333-333333333333';

  const email = 'test@example.com';
  const password = 'test-only-password';

  const validateCredentials = vi.fn();
  const verifyActiveTenantMembership = vi.fn();

  let service: LoginOrchestratorService;

  const expectUnauthorized = async (
    operation: Promise<unknown>,
  ) => {
    try {
      await operation;
      throw new Error('Expected UnauthorizedException');
    } catch (error) {
      expect(error).toBeInstanceOf(UnauthorizedException);

      const exception = error as UnauthorizedException;

      expect(exception.getStatus()).toBe(
        HttpStatus.UNAUTHORIZED,
      );

      expect(exception.getResponse()).toMatchObject({
        message: 'Invalid credentials or tenant access',
      });
    }
  };

  beforeEach(() => {
    vi.resetAllMocks();

    validateCredentials.mockResolvedValue({ userId });
    verifyActiveTenantMembership.mockResolvedValue(
      membershipId,
    );

    service = new LoginOrchestratorService(
      {
        validateCredentials,
      } as unknown as AuthenticationService,

      {
        verifyActiveTenantMembership,
      } as unknown as AuthDatabaseService,
    );
  });

  it('L01: accepts valid credentials and active membership', async () => {
    const result = await service.verifyLoginEligibility(
      email,
      password,
      tenantId,
    );

    expect(result).toEqual({
      userId,
      tenantId,
      membershipId,
    });

    expect(validateCredentials).toHaveBeenCalledWith(
      email,
      password,
    );

    expect(
      verifyActiveTenantMembership,
    ).toHaveBeenCalledWith(userId, tenantId);
  });

  it('L02: rejects invalid credentials', async () => {
    validateCredentials.mockRejectedValue(
      new UnauthorizedException(
        'Invalid email or password',
      ),
    );

    await expectUnauthorized(
      service.verifyLoginEligibility(
        email,
        'wrong-password',
        tenantId,
      ),
    );
  });

  it('L03: rejects missing active membership', async () => {
    verifyActiveTenantMembership.mockResolvedValue(null);

    await expectUnauthorized(
      service.verifyLoginEligibility(
        email,
        password,
        tenantId,
      ),
    );
  });

  it('L04: rejects invalid tenant UUID', async () => {
    await expectUnauthorized(
      service.verifyLoginEligibility(
        email,
        password,
        'invalid-tenant',
      ),
    );

    expect(validateCredentials).not.toHaveBeenCalled();
    expect(
      verifyActiveTenantMembership,
    ).not.toHaveBeenCalled();
  });

  it('L05: skips membership lookup after failed authentication', async () => {
    validateCredentials.mockRejectedValue(
      new UnauthorizedException(),
    );

    await expectUnauthorized(
      service.verifyLoginEligibility(
        email,
        password,
        tenantId,
      ),
    );

    expect(
      verifyActiveTenantMembership,
    ).not.toHaveBeenCalled();
  });

  it('L06: propagates operational errors', async () => {
    verifyActiveTenantMembership.mockRejectedValue(
      new Error('Database unavailable'),
    );

    await expect(
      service.verifyLoginEligibility(
        email,
        password,
        tenantId,
      ),
    ).rejects.toThrow('Database unavailable');
  });

  it('L07: uses authenticated identity for membership lookup', async () => {
    await service.verifyLoginEligibility(
      email,
      password,
      tenantId,
    );

    expect(
      verifyActiveTenantMembership,
    ).toHaveBeenCalledWith(
      userId,
      tenantId,
    );

    expect(
      verifyActiveTenantMembership,
    ).toHaveBeenCalledTimes(1);
  });
});

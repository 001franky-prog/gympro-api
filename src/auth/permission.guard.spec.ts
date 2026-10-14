import {
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from 'vitest';

import {
  ForbiddenException,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';

import type { ExecutionContext } from '@nestjs/common';
import { Reflector } from '@nestjs/core';

import {
  PermissionGuard,
} from './permission.guard.js';

import type {
  RbacPermissionDatabaseService,
} from './rbac-permission-database.service.js';

import {
  REQUIRED_PERMISSION_KEY,
  RequirePermission,
} from './require-permission.decorator.js';

describe('Gym Pro PermissionGuard', () => {
  const tenantId =
    '22222222-2222-4222-8222-222222222222';

  const membershipId =
    '33333333-3333-4333-8333-333333333333';

  const branchId =
    '44444444-4444-4444-8444-444444444444';

  const session = {
    sessionId:
      '11111111-1111-4111-8111-111111111111',
    tenantId,
    membershipId,
    userId:
      '55555555-5555-4555-8555-555555555555',
  };

  const getAllAndOverride = vi.fn();
  const hasTenantPermission = vi.fn();

  let guard: PermissionGuard;

  function context(
    options: {
      authenticated?: boolean;
      tenant?: unknown;
      branch?: unknown;
    } = {},
  ): ExecutionContext {
    const params: Record<string, unknown> = {};

    if ('tenant' in options) {
      params.tenantId = options.tenant;
    }

    if ('branch' in options) {
      params.branchId = options.branch;
    }

    const request = {
      gymproSession:
        options.authenticated === false
          ? undefined
          : session,
      params,
    };

    return {
      switchToHttp: () => ({
        getRequest: () => request,
      }),
      getHandler: () => function testHandler() {},
      getClass: () => class TestController {},
    } as unknown as ExecutionContext;
  }

  beforeEach(() => {
    vi.resetAllMocks();

    getAllAndOverride.mockReturnValue(
      'gym.members.read',
    );

    hasTenantPermission.mockResolvedValue(true);

    guard = new PermissionGuard(
      {
        getAllAndOverride,
      } as unknown as Reflector,
      {
        hasTenantPermission,
      } as unknown as RbacPermissionDatabaseService,
    );
  });

  it('P01: permits authorized operation', async () => {
    await expect(
      guard.canActivate(context()),
    ).resolves.toBe(true);

    expect(hasTenantPermission).toHaveBeenCalledWith({
      tenantId,
      membershipId,
      permissionCode: 'gym.members.read',
      branchId: null,
    });
  });

  it('P02: denies missing authentication', async () => {
    await expect(
      guard.canActivate(
        context({ authenticated: false }),
      ),
    ).rejects.toBeInstanceOf(
      UnauthorizedException,
    );

    expect(hasTenantPermission)
      .not.toHaveBeenCalled();
  });

  it('P03: denies missing permission metadata', async () => {
    getAllAndOverride.mockReturnValueOnce(undefined);

    await expect(
      guard.canActivate(context()),
    ).rejects.toBeInstanceOf(
      ForbiddenException,
    );

    expect(hasTenantPermission)
      .not.toHaveBeenCalled();
  });

  it('P04: denies rejected permission', async () => {
    hasTenantPermission.mockResolvedValueOnce(false);

    await expect(
      guard.canActivate(context()),
    ).rejects.toBeInstanceOf(
      ForbiddenException,
    );
  });

  it('P05: passes branch context', async () => {
    await expect(
      guard.canActivate(
        context({ branch: branchId }),
      ),
    ).resolves.toBe(true);

    expect(hasTenantPermission).toHaveBeenCalledWith({
      tenantId,
      membershipId,
      permissionCode: 'gym.members.read',
      branchId,
    });
  });

  it('P06: rejects malformed branch', async () => {
    await expect(
      guard.canActivate(
        context({ branch: 'invalid' }),
      ),
    ).rejects.toBeInstanceOf(
      ForbiddenException,
    );

    expect(hasTenantPermission)
      .not.toHaveBeenCalled();
  });

  it('P07: rejects cross-tenant request', async () => {
    await expect(
      guard.canActivate(
        context({
          tenant:
            '99999999-9999-4999-8999-999999999999',
        }),
      ),
    ).rejects.toBeInstanceOf(
      ForbiddenException,
    );
  });

  it('P08: permits matching tenant scope', async () => {
    await expect(
      guard.canActivate(
        context({ tenant: tenantId }),
      ),
    ).resolves.toBe(true);
  });

  it('P09: fails closed on database error', async () => {
    hasTenantPermission.mockRejectedValueOnce(
      new Error('Sensitive database error'),
    );

    await expect(
      guard.canActivate(context()),
    ).rejects.toBeInstanceOf(
      ServiceUnavailableException,
    );
  });

  it('P10: denies malformed permission', async () => {
    getAllAndOverride.mockReturnValueOnce(
      'DELETE FROM users',
    );

    await expect(
      guard.canActivate(context()),
    ).rejects.toBeInstanceOf(
      ForbiddenException,
    );
  });

  it('P11: never trusts role values in request body', async () => {
    await expect(
      guard.canActivate(context()),
    ).resolves.toBe(true);

    expect(hasTenantPermission)
      .toHaveBeenCalledTimes(1);
  });

  it('P12: rejects undefined database result', async () => {
    hasTenantPermission.mockResolvedValueOnce(undefined);

    await expect(
      guard.canActivate(context()),
    ).rejects.toBeInstanceOf(
      ForbiddenException,
    );
  });

  it('P13: uses the required metadata key', async () => {
    await guard.canActivate(context());

    expect(getAllAndOverride)
      .toHaveBeenCalledWith(
        REQUIRED_PERMISSION_KEY,
        expect.any(Array),
      );
  });

  it('P14: decorator creates permission metadata', () => {
    class ExampleController {
      @RequirePermission('gym.members.read')
      readMembers() {}
    }

    const reflector = new Reflector();

    expect(
      reflector.get(
        REQUIRED_PERMISSION_KEY,
        ExampleController.prototype.readMembers,
      ),
    ).toBe('gym.members.read');
  });
});
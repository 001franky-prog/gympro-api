
import {
  describe,
  expect,
  it,
} from 'vitest';

import {
  ForbiddenException,
  UnauthorizedException,
} from '@nestjs/common';

import type {
  ExecutionContext,
} from '@nestjs/common';

import {
  TenantScopeGuard,
} from './tenant-scope.guard.js';

import type {
  GymProAuthenticatedRequest,
} from './authenticated-session.guard.js';

/**
 * Gym Pro SaaS
 * Phase A — Tenant Scope Guard Tests
 *
 * Corrected test helper:
 * Missing authentication must remain missing.
 *
 * No default session is automatically inserted.
 */

describe('Gym Pro TenantScopeGuard', () => {
  const tenantA =
    '22222222-2222-4222-8222-222222222222';

  const tenantB =
    '99999999-9999-4999-8999-999999999999';

  const verifiedSession = {
    sessionId:
      '11111111-1111-4111-8111-111111111111',
    tenantId: tenantA,
    membershipId:
      '33333333-3333-4333-8333-333333333333',
    userId:
      '44444444-4444-4444-8444-444444444444',
  };

  const guard = new TenantScopeGuard();

  /**
   * Construct a controlled HTTP test request.
   *
   * The session parameter has NO default.
   * This prevents unauthenticated test requests
   * from accidentally receiving a valid identity.
   */
  function context(
    requestedTenant: unknown,
    session: GymProAuthenticatedRequest['gymproSession'],
  ): ExecutionContext {
    const request = {
      gymproSession: session,
      params: {
        tenantId: requestedTenant,
      },
    };

    return {
      switchToHttp: () => ({
        getRequest: () => request,
      }),
    } as unknown as ExecutionContext;
  }

  it('I01: allows access to the matching tenant', () => {
    expect(
      guard.canActivate(
        context(tenantA, verifiedSession),
      ),
    ).toBe(true);
  });

  it('I02: rejects a different tenant', () => {
    expect(() =>
      guard.canActivate(
        context(tenantB, verifiedSession),
      ),
    ).toThrow(ForbiddenException);
  });

  it('I03: rejects missing authentication', () => {
    expect(() =>
      guard.canActivate(
        context(tenantA, undefined),
      ),
    ).toThrow(UnauthorizedException);
  });

  it('I04: rejects missing route tenant', () => {
    expect(() =>
      guard.canActivate(
        context(undefined, verifiedSession),
      ),
    ).toThrow(ForbiddenException);
  });

  it('I05: rejects malformed tenant UUID', () => {
    expect(() =>
      guard.canActivate(
        context('GYM-B', verifiedSession),
      ),
    ).toThrow(ForbiddenException);
  });

  it('I06: rejects empty tenant ID', () => {
    expect(() =>
      guard.canActivate(
        context('', verifiedSession),
      ),
    ).toThrow(ForbiddenException);
  });

  it('I07: handles UUID letter case', () => {
    const mixedCaseTenant =
      'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';

    const session = {
      ...verifiedSession,
      tenantId: mixedCaseTenant.toLowerCase(),
    };

    expect(
      guard.canActivate(
        context(mixedCaseTenant, session),
      ),
    ).toBe(true);
  });

  it('I08: rejects malformed session tenant', () => {
    const session = {
      ...verifiedSession,
      tenantId: 'invalid-tenant',
    };

    expect(() =>
      guard.canActivate(
        context(tenantA, session),
      ),
    ).toThrow(ForbiddenException);
  });

  it('I09: rejects non-string tenant ID', () => {
    expect(() =>
      guard.canActivate(
        context(12345, verifiedSession),
      ),
    ).toThrow(ForbiddenException);
  });

  it('I10: does not accept a matching tenant without authentication', () => {
    expect(() =>
      guard.canActivate(
        context(tenantA, undefined),
      ),
    ).toThrow(UnauthorizedException);
  });

  it('I11: rejects an explicit null session', () => {
    expect(() =>
      guard.canActivate(
        context(
          tenantA,
          null as unknown as
            GymProAuthenticatedRequest['gymproSession'],
        ),
      ),
    ).toThrow(UnauthorizedException);
  });

  it('I12: rejects cross-tenant access even with a valid session', () => {
    expect(() =>
      guard.canActivate(
        context(tenantB, verifiedSession),
      ),
    ).toThrow(ForbiddenException);
  });
});

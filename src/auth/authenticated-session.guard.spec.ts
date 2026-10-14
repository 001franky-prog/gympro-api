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

import type {
  ExecutionContext,
} from '@nestjs/common';

import {
  AuthenticatedSessionGuard,
} from './authenticated-session.guard.js';

import type {
  GymProAuthenticatedRequest,
} from './authenticated-session.guard.js';

import type {
  SessionBearerTokenService,
} from './session-bearer-token.service.js';

import type {
  AuthDatabaseService,
} from './auth-database.service.js';

describe('Gym Pro AuthenticatedSessionGuard', () => {
  const identity = {
    sessionId:
      '11111111-1111-4111-8111-111111111111',
    tenantId:
      '22222222-2222-4222-8222-222222222222',
    membershipId:
      '33333333-3333-4333-8333-333333333333',
    userId:
      '44444444-4444-4444-8444-444444444444',
  };

  const tokenHash = Buffer.alloc(32, 0xab);

  const hashAuthorization = vi.fn();
  const verifySessionTokenHash = vi.fn();

  let guard: AuthenticatedSessionGuard;

  function createContext(
    request: GymProAuthenticatedRequest,
  ): ExecutionContext {
    return {
      switchToHttp: () => ({
        getRequest: () => request,
      }),
    } as unknown as ExecutionContext;
  }

  beforeEach(() => {
    vi.resetAllMocks();

    hashAuthorization.mockReturnValue(tokenHash);

    verifySessionTokenHash.mockResolvedValue({
      ...identity,
    });

    guard = new AuthenticatedSessionGuard(
      {
        hashAuthorization,
      } as unknown as SessionBearerTokenService,

      {
        verifySessionTokenHash,
      } as unknown as AuthDatabaseService,
    );
  });

  it('G01: allows a verified session', async () => {
    const request = {
      headers: {
        authorization: 'Bearer example',
      },
    };

    const result =
      await guard.canActivate(createContext(request));

    expect(result).toBe(true);

    expect(hashAuthorization).toHaveBeenCalledWith(
      'Bearer example',
    );

    expect(verifySessionTokenHash)
      .toHaveBeenCalledWith(tokenHash);

    expect(request).toHaveProperty(
      'gymproSession',
      identity,
    );
  });

  it('G02: rejects a missing Authorization header', async () => {
    hashAuthorization.mockImplementationOnce(() => {
      throw new UnauthorizedException();
    });

    const request = {
      headers: {},
    };

    await expect(
      guard.canActivate(createContext(request)),
    ).rejects.toMatchObject({
      status: HttpStatus.UNAUTHORIZED,
    });

    expect(verifySessionTokenHash)
      .not.toHaveBeenCalled();
  });

  it('G03: rejects invalid bearer token format', async () => {
    hashAuthorization.mockImplementationOnce(() => {
      throw new UnauthorizedException();
    });

    const request = {
      headers: {
        authorization: 'Basic invalid',
      },
    };

    await expect(
      guard.canActivate(createContext(request)),
    ).rejects.toBeInstanceOf(
      UnauthorizedException,
    );

    expect(verifySessionTokenHash)
      .not.toHaveBeenCalled();
  });

  it('G04: rejects unknown sessions', async () => {
    verifySessionTokenHash.mockResolvedValueOnce(null);

    const request = {
      headers: {
        authorization: 'Bearer example',
      },
    };

    await expect(
      guard.canActivate(createContext(request)),
    ).rejects.toMatchObject({
      status: HttpStatus.UNAUTHORIZED,
    });

    expect(request)
      .not.toHaveProperty('gymproSession');
  });

  it('G05: fails closed on database errors', async () => {
    verifySessionTokenHash.mockRejectedValueOnce(
      new Error('Database connection failed'),
    );

    const request = {
      headers: {
        authorization: 'Bearer example',
      },
    };

    await expect(
      guard.canActivate(createContext(request)),
    ).rejects.toBeInstanceOf(
      ServiceUnavailableException,
    );

    expect(request)
      .not.toHaveProperty('gymproSession');
  });

  it('G06: rejects malformed database identities', async () => {
    verifySessionTokenHash.mockResolvedValueOnce({
      ...identity,
      tenantId: 'invalid-tenant',
    });

    const request = {
      headers: {
        authorization: 'Bearer example',
      },
    };

    await expect(
      guard.canActivate(createContext(request)),
    ).rejects.toMatchObject({
      status: HttpStatus.SERVICE_UNAVAILABLE,
    });

    expect(request)
      .not.toHaveProperty('gymproSession');
  });

  it('G07: removes an untrusted preexisting identity', async () => {
    verifySessionTokenHash.mockResolvedValueOnce(null);

    const request: GymProAuthenticatedRequest = {
      headers: {
        authorization: 'Bearer example',
      },
      gymproSession: {
        ...identity,
        tenantId:
          '99999999-9999-4999-8999-999999999999',
      },
    };

    await expect(
      guard.canActivate(createContext(request)),
    ).rejects.toBeInstanceOf(
      UnauthorizedException,
    );

    expect(request.gymproSession).toBeUndefined();
  });

  it('G08: attaches a frozen verified identity', async () => {
    const request: GymProAuthenticatedRequest = {
      headers: {
        authorization: 'Bearer example',
      },
    };

    await guard.canActivate(createContext(request));

    expect(request.gymproSession).toEqual(identity);

    expect(Object.isFrozen(request.gymproSession))
      .toBe(true);
  });

  it('G09: does not create a database session', async () => {
    const request = {
      headers: {
        authorization: 'Bearer example',
      },
    };

    await guard.canActivate(createContext(request));

    expect(verifySessionTokenHash)
      .toHaveBeenCalledTimes(1);

    expect(hashAuthorization)
      .toHaveBeenCalledTimes(1);
  });

  it('G10: database failure does not expose details', async () => {
    verifySessionTokenHash.mockRejectedValueOnce(
      new Error('SECRET_DATABASE_CONNECTION_DATA'),
    );

    const request = {
      headers: {
        authorization: 'Bearer example',
      },
    };

    await expect(
      guard.canActivate(createContext(request)),
    ).rejects.toMatchObject({
      status: HttpStatus.SERVICE_UNAVAILABLE,
      message: 'Session verification unavailable',
    });
  });
});
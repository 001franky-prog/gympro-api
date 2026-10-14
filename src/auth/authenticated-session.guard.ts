import {
  CanActivate,
  ExecutionContext,
  Injectable,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';

import {
  SessionBearerTokenService,
} from './session-bearer-token.service.js';

import {
  AuthDatabaseService,
} from './auth-database.service.js';

import type {
  VerifiedTenantSession,
} from './auth-database.service.js';

/**
 * Gym Pro SaaS
 * Phase A - Authenticated Session Guard
 *
 * Responsibilities:
 *
 * 1. Read the Authorization header.
 * 2. Validate and hash the bearer token.
 * 3. Ask PostgreSQL to verify the session.
 * 4. Reject invalid or revoked sessions.
 * 5. Attach verified identity to the HTTP request.
 *
 * Does not create sessions or grant tenant permissions.
 */

export interface GymProAuthenticatedRequest {
  headers?: {
    authorization?: unknown;
  };

  gymproSession?: VerifiedTenantSession;
}

@Injectable()
export class AuthenticatedSessionGuard
  implements CanActivate
{
  constructor(
    private readonly bearerTokenService:
      SessionBearerTokenService,

    private readonly authDatabase:
      AuthDatabaseService,
  ) {}

  async canActivate(
    context: ExecutionContext,
  ): Promise<boolean> {
    const request =
      context.switchToHttp()
        .getRequest<GymProAuthenticatedRequest>();

    // Default to denial if the request is missing.
    if (!request || typeof request !== 'object') {
      throw new UnauthorizedException(
        'Invalid or expired session',
      );
    }

    // Never trust an identity supplied by request
    // data or a previous middleware.
    delete request.gymproSession;

    // 1. Validate bearer token format.
    // 2. Compute its SHA-256 hash.
    //
    // Invalid input throws HTTP 401.
    const tokenHash =
      this.bearerTokenService.hashAuthorization(
        request.headers?.authorization,
      );

    let verified: VerifiedTenantSession | null;

    // 3. Verify session against PostgreSQL.
    try {
      verified =
        await this.authDatabase.verifySessionTokenHash(
          tokenHash,
        );
    } catch {
      // Operational failures must not be
      // interpreted as successful authentication.
      // Avoid exposing database error details.
      throw new ServiceUnavailableException(
        'Session verification unavailable',
      );
    }

    // 4. Reject missing, expired, revoked or
    // otherwise invalid sessions.
    if (!verified) {
      throw new UnauthorizedException(
        'Invalid or expired session',
      );
    }

    // Validate the trusted database result.
    const uuidPattern =
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

    if (
      typeof verified.sessionId !== 'string' ||
      typeof verified.tenantId !== 'string' ||
      typeof verified.membershipId !== 'string' ||
      typeof verified.userId !== 'string' ||
      !uuidPattern.test(verified.sessionId) ||
      !uuidPattern.test(verified.tenantId) ||
      !uuidPattern.test(verified.membershipId) ||
      !uuidPattern.test(verified.userId)
    ) {
      throw new ServiceUnavailableException(
        'Session verification unavailable',
      );
    }

    // 5. Attach server-verified identity.
    //
    // This is authentication context, not
    // permission to perform every operation.
    request.gymproSession = Object.freeze({
      sessionId: verified.sessionId,
      tenantId: verified.tenantId,
      membershipId: verified.membershipId,
      userId: verified.userId,
    });

    return true;
  }
}
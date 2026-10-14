
import {
  Injectable,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';

import {
  AuthenticatedEligibilityService,
} from './authenticated-eligibility.service.js';

import {
  AuthDatabaseService,
} from './auth-database.service.js';

import {
  SessionTokenService,
} from './session-token.service.js';

import {
  SessionPersistenceService,
} from './session-persistence.service.js';

import {
  isVerifiedLoginEligibility,
} from './verified-login-eligibility.js';

import {
  isAuthenticatedSessionRequest,
} from './authenticated-session-request.js';

import {
  isSessionPersistenceEnabled,
  SESSION_SECURITY_POLICY,
} from './session-security-policy.js';

export interface TenantLoginRequest {
  readonly email: string;
  readonly password: string;
  readonly tenantId: string;
}

export interface TenantLoginResponse {
  readonly sessionId: string;
  readonly tokenType: 'Bearer';
  readonly accessToken: string;
  readonly expiresIn: number;
  readonly userId: string;
  readonly tenantId: string;
  readonly membershipId: string;
}

/**
 * Gym Pro SaaS
 * Phase A — Session Issuance Service
 *
 * Responsibilities:
 * 1. Authenticate credentials and tenant membership.
 * 2. Revalidate current authorization.
 * 3. Generate a cryptographically secure bearer token.
 * 4. Persist only its SHA-256 hash.
 * 5. Return the raw token only after confirmed persistence.
 *
 * SECURITY:
 * Session persistence is presently disabled.
 * The code below must not issue a token until the
 * existing security policy is explicitly enabled
 * after the database trust boundary and integration
 * security tests have passed.
 */

@Injectable()
export class SessionIssuanceService {
  constructor(
    private readonly authenticatedEligibility:
      AuthenticatedEligibilityService,

    private readonly authDatabase:
      AuthDatabaseService,

    private readonly sessionTokenService:
      SessionTokenService,

    private readonly sessionPersistence:
      SessionPersistenceService,
  ) {}

  async issueSession(
    request: TenantLoginRequest,
  ): Promise<TenantLoginResponse> {
    const unavailable = () =>
      new ServiceUnavailableException(
        'Session issuance is not enabled',
      );

    // Step 1: Authenticate password and tenant.
    const eligibility =
      await this.authenticatedEligibility.authenticateTenant(
        request.email,
        request.password,
        request.tenantId,
      );

    if (!isVerifiedLoginEligibility(eligibility)) {
      throw new UnauthorizedException(
        'Invalid credentials or tenant access',
      );
    }

    // Step 2: Recheck the active identity relationship.
    const stillAuthorized =
      await this.authDatabase.revalidateSessionIdentity(
        eligibility.userId,
        eligibility.tenantId,
        eligibility.membershipId,
      );

    if (!stillAuthorized) {
      throw new UnauthorizedException(
        'Invalid credentials or tenant access',
      );
    }

    // Step 3: Generate a secure random token.
    const generated =
      this.sessionTokenService.generateToken();

    const persistenceRequest = {
      eligibility,
      tokenHash: generated.tokenHash,
    };

    if (!isAuthenticatedSessionRequest(
      persistenceRequest
    )) {
      throw unavailable();
    }

    // Step 4: Request authorized persistence.
    //
    // This currently throws HTTP 503 because
    // persistenceEnabled is false.
    const result =
      await this.sessionPersistence.createSession(
        persistenceRequest,
      );

    // Step 5: Enforce security policy again before
    // releasing the bearer token.
    if (!isSessionPersistenceEnabled()) {
      throw unavailable();
    }

    // Verify database persistence result.
    const sessionId = result?.sessionId;

    const uuidPattern =
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

    if (
      typeof sessionId !== 'string' ||
      !uuidPattern.test(sessionId)
    ) {
      throw unavailable();
    }

    // Step 6: Return the token only after
    // successful session persistence.
    //
    // Never include password or tokenHash.
    return {
      sessionId,
      tokenType: 'Bearer',
      accessToken: generated.token,
      expiresIn:
        SESSION_SECURITY_POLICY.sessionLifetimeSeconds,
      userId: eligibility.userId,
      tenantId: eligibility.tenantId,
      membershipId: eligibility.membershipId,
    };
  }
}

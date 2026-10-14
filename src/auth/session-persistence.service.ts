
import {
  Injectable,
  ServiceUnavailableException,
} from '@nestjs/common';

import {
  SessionDatabaseService,
} from './session-database.service.js';

import {
  SessionPersistenceAuthorizationService,
} from './session-persistence-authorization.service.js';

import type {
  SessionPersistencePort,
  SessionPersistenceResult,
} from './session-persistence.contract.js';

import type {
  AuthenticatedSessionRequest,
} from './authenticated-session-request.js';

import {
  isAuthenticatedSessionRequest,
} from './authenticated-session-request.js';

import {
  isSessionPersistenceEnabled,
} from './session-security-policy.js';

/**
 * Gym Pro SaaS
 * Phase A — Session Persistence Service
 *
 * Responsibilities:
 * 1. Validate session persistence request.
 * 2. Revalidate tenant/user/membership relationship.
 * 3. Enforce session security policy.
 * 4. Delegate permitted writes to SessionDatabaseService.
 * 5. Return the session ID only after successful persistence.
 *
 * Important:
 * - Structural validation is not proof of authentication.
 * - This service must only be invoked by the trusted
 *   session issuance workflow.
 * - Database permissions and the security policy
 *   remain disabled until end-to-end verification.
 */

@Injectable()
export class SessionPersistenceService
  implements SessionPersistencePort
{
  constructor(
    private readonly sessionDatabase:
      SessionDatabaseService,

    private readonly persistenceAuthorization:
      SessionPersistenceAuthorizationService,
  ) {}

  async createSession(
    request: AuthenticatedSessionRequest,
  ): Promise<SessionPersistenceResult> {
    const unavailable = () =>
      new ServiceUnavailableException(
        'Session persistence is not enabled',
      );

    // Step 1: Check request structure.
    if (!isAuthenticatedSessionRequest(request)) {
      throw unavailable();
    }

    // Step 2: Verify current database relationship.
    await this.persistenceAuthorization.authorize(
      request,
    );

    // Step 3: Enforce fail-closed feature policy.
    //
    // Currently false.
    // Do not enable before completing authentication
    // trust-boundary and integration security tests.
    if (!isSessionPersistenceEnabled()) {
      throw unavailable();
    }

    // Step 4: Persist the token hash, never raw token.
    //
    // This code path remains unreachable while
    // the security policy is disabled.
    const sessionId =
      await this.sessionDatabase.createTenantSession(
        request.eligibility.membershipId,
        request.tokenHash,
      );

    // Step 5: Return only the database session ID.
    return {
      sessionId,
    };
  }
}

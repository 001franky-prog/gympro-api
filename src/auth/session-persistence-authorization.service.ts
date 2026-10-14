
import {
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';

import {
  AuthDatabaseService,
} from './auth-database.service.js';

import type {
  AuthenticatedSessionRequest,
} from './authenticated-session-request.js';

import {
  isAuthenticatedSessionRequest,
} from './authenticated-session-request.js';

/**
 * Gym Pro SaaS
 * Session Persistence Authorization Service
 *
 * Purpose:
 * Revalidate the relationship between the
 * user, tenant and membership immediately
 * before a future session persistence operation.
 *
 * Security restrictions:
 * - Does not authenticate passwords.
 * - Does not create sessions.
 * - Does not generate bearer tokens.
 * - Does not expose database queries.
 * - Does not grant PostgreSQL privileges.
 *
 * This is an additional authorization check,
 * not independent authentication proof.
 */
@Injectable()
export class SessionPersistenceAuthorizationService {
  constructor(
    private readonly authDatabase:
      AuthDatabaseService,
  ) {}

  /**
   * Verify that the supplied internal request
   * has a valid structure and currently belongs
   * to an active user/tenant/membership relationship.
   *
   * Returns:
   * - void if the relationship is valid.
   * - UnauthorizedException if invalid.
   *
   * Database operational errors propagate,
   * so persistence must fail closed.
   */
  async authorize(
    request: AuthenticatedSessionRequest,
  ): Promise<void> {
    const deny = () =>
      new UnauthorizedException(
        'Invalid credentials or tenant access',
      );

    // Validate the internal request structure.
    if (!isAuthenticatedSessionRequest(request)) {
      throw deny();
    }

    const eligibility = request.eligibility;

    // Recheck current database relationships using
    // the restricted gympro_auth database connection.
    const authorized =
      await this.authDatabase.revalidateSessionIdentity(
        eligibility.userId,
        eligibility.tenantId,
        eligibility.membershipId,
      );

    if (!authorized) {
      throw deny();
    }

    // Relationship verified.
    //
    // This method does not authorize arbitrary
    // callers to create database sessions.
    //
    // It does not persist any data or issue a token.
  }
}

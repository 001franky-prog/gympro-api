
import {
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';

import { AuthenticationService } from './authentication.service.js';
import { AuthDatabaseService } from './auth-database.service.js';

/**
 * Internal authenticated tenant eligibility.
 *
 * This is NOT a session, access token or final
 * authorization principal.
 */
export interface TenantLoginEligibility {
  readonly userId: string;
  readonly tenantId: string;
  readonly membershipId: string;
}

@Injectable()
export class LoginOrchestratorService {
  constructor(
    private readonly authenticationService:
      AuthenticationService,

    private readonly authDatabase:
      AuthDatabaseService,
  ) {}

  async verifyLoginEligibility(
    email: string,
    password: string,
    requestedTenantId: string,
  ): Promise<TenantLoginEligibility> {
    const invalidLogin = () =>
      new UnauthorizedException(
        'Invalid credentials or tenant access',
      );

    if (
      typeof requestedTenantId !== 'string' ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
        .test(requestedTenantId)
    ) {
      throw invalidLogin();
    }

    let userId: string;

    try {
      // User identity is derived from password
      // authentication, never client-supplied.
      const authenticatedUser =
        await this.authenticationService
          .validateCredentials(email, password);

      userId = authenticatedUser.userId;
    } catch (error) {
      if (error instanceof UnauthorizedException) {
        throw invalidLogin();
      }

      // Operational failures must not masquerade
      // as invalid credentials.
      throw error;
    }

    const membershipId =
      await this.authDatabase
        .verifyActiveTenantMembership(
          userId,
          requestedTenantId,
        );

    if (!membershipId) {
      throw invalidLogin();
    }

    return {
      userId,
      tenantId: requestedTenantId,
      membershipId,
    };
  }
}

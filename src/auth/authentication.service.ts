
import {
  Injectable,
  OnModuleInit,
  UnauthorizedException,
} from '@nestjs/common';

import { AuthDatabaseService } from './auth-database.service.js';
import { PasswordService } from './password.service.js';

/**
 * Internal authentication result.
 *
 * Do not return credentials, password hashes,
 * or authentication database records.
 */
export interface AuthenticatedUser {
  readonly userId: string;
}

/**
 * Gym Pro SaaS Authentication Service
 *
 * Responsibilities:
 * - Look up credentials using gympro_auth
 * - Verify Argon2id password hashes
 * - Reject inactive or unknown accounts
 * - Return generic authentication failures
 *
 * Does not issue sessions or authorize tenants.
 */
@Injectable()
export class AuthenticationService
  implements OnModuleInit
{
  private dummyHash!: string;

  constructor(
    private readonly authDatabase: AuthDatabaseService,
    private readonly passwordService: PasswordService,
  ) {}

  /**
   * Prepare a dummy Argon2id hash for checking
   * nonexistent users without skipping hashing work.
   */
  async onModuleInit(): Promise<void> {
    this.dummyHash =
      await this.passwordService.hashPassword(
        'gympro-internal-dummy-password',
      );
  }

  /**
   * Validate credentials for a global user identity.
   *
   * All authentication failures use the same
   * public-facing error message.
   */
  async validateCredentials(
    email: string,
    password: string,
  ): Promise<AuthenticatedUser> {
    const invalidCredentials =
      new UnauthorizedException(
        'Invalid email or password',
      );

    if (
      typeof email !== 'string' ||
      typeof password !== 'string' ||
      !email.trim() ||
      !password ||
      email.length > 255 ||
      password.length > 1024
    ) {
      throw invalidCredentials;
    }

    const normalizedEmail =
      email.trim().toLowerCase();

    const user =
      await this.authDatabase.findUserCredentials(
        normalizedEmail,
      );

    // Use a dummy hash when no stored hash exists.
    const hashToVerify =
      user?.password_hash ?? this.dummyHash;

    const passwordMatches =
      await this.passwordService.verifyPassword(
        hashToVerify,
        password,
      );

    if (
      !user ||
      !user.password_hash ||
      !passwordMatches ||
      user.account_status !== 'active'
    ) {
      throw invalidCredentials;
    }

    // Only return a verified internal identity.
    // Tenant authorization is a separate step.
    return {
      userId: user.user_id,
    };
  }
}

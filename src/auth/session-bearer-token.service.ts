import {
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';

import {
  createHash,
} from 'node:crypto';

/**
 * Gym Pro SaaS
 * Secure Bearer Token Validation
 *
 * Responsibilities:
 * 1. Validate Authorization header format.
 * 2. Validate token encoding and length.
 * 3. Return SHA-256 hash for database lookup.
 *
 * IMPORTANT:
 * A correctly formatted token is NOT proof of
 * authentication. The hash must match an active,
 * unexpired, non-revoked database session.
 */

@Injectable()
export class SessionBearerTokenService {
  private unauthorized(): UnauthorizedException {
    return new UnauthorizedException(
      'Invalid or expired session',
    );
  }

  extractToken(
    authorizationHeader: unknown,
  ): string {
    if (
      typeof authorizationHeader !== 'string'
    ) {
      throw this.unauthorized();
    }

    const match =
      /^Bearer ([A-Za-z0-9_-]{43})$/i.exec(
        authorizationHeader,
      );

    if (!match || !match[1]) {
      throw this.unauthorized();
    }

    const token = match[1];

    let decoded: Buffer;

    try {
      decoded = Buffer.from(
        token,
        'base64url',
      );
    } catch {
      throw this.unauthorized();
    }

    if (decoded.length !== 32) {
      throw this.unauthorized();
    }

    // Require canonical base64url encoding.
    // This prevents alternate representations
    // of the same token bytes.
    if (
      decoded.toString('base64url') !== token
    ) {
      throw this.unauthorized();
    }

    return token;
  }

  hashAuthorization(
    authorizationHeader: unknown,
  ): Buffer {
    const token =
      this.extractToken(authorizationHeader);

    return createHash('sha256')
      .update(token, 'utf8')
      .digest();
  }
}

import { Injectable } from '@nestjs/common';
import {
  randomBytes,
  createHash,
} from 'node:crypto';

export interface GeneratedSessionToken {
  readonly token: string;
  readonly tokenHash: Buffer;
}

@Injectable()
export class SessionTokenService {

  /**
   * Generate a cryptographically random bearer token.
   *
   * Only the SHA-256 digest will be persisted.
   * Never log or store the raw token in plaintext.
   */
  generateToken(): GeneratedSessionToken {
    const token = randomBytes(32).toString('base64url');

    return {
      token,
      tokenHash: this.hashToken(token),
    };
  }

  /**
   * Hash a bearer token for database lookup.
   *
   * Returns a 32-byte SHA-256 digest for
   * security.tenant_sessions.session_token_hash.
   */
  hashToken(token: string): Buffer {
    return createHash('sha256')
      .update(token, 'utf8')
      .digest();
  }
}


import type {
  VerifiedLoginEligibility,
} from './verified-login-eligibility.js';

import {
  isVerifiedLoginEligibility,
} from './verified-login-eligibility.js';

import {
  SESSION_SECURITY_POLICY,
} from './session-security-policy.js';

/**
 * Gym Pro SaaS
 * Authenticated Session Request
 *
 * Internal application-layer contract.
 *
 * This request should only be constructed
 * after successful password authentication
 * and active tenant membership verification.
 *
 * A TypeScript interface or runtime brand
 * is not independent authentication proof.
 */
export interface AuthenticatedSessionRequest {
  readonly eligibility: VerifiedLoginEligibility;

  /**
   * SHA-256 digest of a cryptographically
   * generated 256-bit opaque bearer token.
   *
   * Never persist the raw bearer token.
   */
  readonly tokenHash: Buffer;
}

/**
 * Runtime structural validation.
 *
 * Validates:
 * 1. Request object exists.
 * 2. Eligibility has the internal runtime brand.
 * 3. Eligibility identifiers have valid UUID formats.
 * 4. Token hash is a Buffer of exactly 32 bytes.
 *
 * Does NOT independently authenticate the user
 * or establish authorization to create sessions.
 */
export function isAuthenticatedSessionRequest(
  value: unknown,
): value is AuthenticatedSessionRequest {
  if (
    typeof value !== 'object' ||
    value === null
  ) {
    return false;
  }

  const candidate =
    value as Record<string, unknown>;

  if (
    !isVerifiedLoginEligibility(
      candidate.eligibility,
    )
  ) {
    return false;
  }

  const eligibility = candidate.eligibility;

  const uuidPattern =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

  if (
    !uuidPattern.test(eligibility.userId) ||
    !uuidPattern.test(eligibility.tenantId) ||
    !uuidPattern.test(eligibility.membershipId)
  ) {
    return false;
  }

  return (
    Buffer.isBuffer(candidate.tokenHash) &&
    candidate.tokenHash.length ===
      SESSION_SECURITY_POLICY.tokenHashBytes
  );
}

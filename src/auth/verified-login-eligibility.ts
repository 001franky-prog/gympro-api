
import type {
  TenantLoginEligibility,
} from './login-orchestrator.service.js';

/**
 * Gym Pro SaaS
 * Verified Login Eligibility
 *
 * An opaque internal object representing a
 * successful password + tenant membership check.
 *
 * This is not a database session or bearer token.
 */

// Private runtime brand. Not exported.
const eligibilityBrand = Symbol(
  'gympro.verified-login-eligibility',
);

export interface VerifiedLoginEligibility {
  readonly userId: string;
  readonly tenantId: string;
  readonly membershipId: string;
  readonly [eligibilityBrand]: true;
}

/**
 * Internal factory.
 *
 * Only invoke this after the LoginOrchestratorService
 * has successfully verified credentials and membership.
 *
 * This function itself does NOT authenticate a user.
 */
export function createVerifiedLoginEligibility(
  eligibility: TenantLoginEligibility,
): VerifiedLoginEligibility {
  return Object.freeze({
    userId: eligibility.userId,
    tenantId: eligibility.tenantId,
    membershipId: eligibility.membershipId,
    [eligibilityBrand]: true as const,
  });
}

/**
 * Runtime guard.
 *
 * Rejects objects constructed from ordinary HTTP
 * request bodies unless they possess the internal
 * runtime brand.
 */
export function isVerifiedLoginEligibility(
  value: unknown,
): value is VerifiedLoginEligibility {
  if (typeof value !== 'object' || value === null) {
    return false;
  }

  const candidate = value as Record<PropertyKey, unknown>;

  return (
    candidate[eligibilityBrand] === true &&
    typeof candidate.userId === 'string' &&
    typeof candidate.tenantId === 'string' &&
    typeof candidate.membershipId === 'string'
  );
}

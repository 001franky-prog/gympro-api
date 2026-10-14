
/**
 * Gym Pro SaaS
 * Authenticated Tenant Principal
 *
 * This interface represents identity and tenant context
 * AFTER successful authentication and authorization.
 *
 * Never populate these fields directly from untrusted
 * request parameters, headers or JWT claims without
 * the required verification.
 */

export interface TenantPrincipal {
  readonly userId: string;

  readonly tenantId: string;

  readonly membershipId: string;

  readonly sessionId: string;

  readonly roleIds: readonly string[];

  readonly authorizedBranchIds: readonly string[];

  readonly authenticated: true;

  readonly membershipActive: true;
}

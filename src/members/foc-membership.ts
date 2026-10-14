export interface FocMembershipGrant {
  readonly id: string;

  readonly tenantId: string;
  readonly subscriptionId: string;
  readonly requestId: string;

  readonly reason: string;

  /**
   * Normal listed price when the complimentary
   * membership was granted.
   *
   * Represented as text to preserve decimal precision.
   * The FOC subscription's agreed price is zero.
   */
  readonly listedPriceAmount: string;
  readonly currencyCode: 'MMK';

  readonly grantedAt: Date;
  readonly createdAt: Date;
}

export interface GrantFocMembershipInput {
  readonly planId: string;
  readonly planPriceId: string;

  /**
   * Required reason containing 2–500 characters
   * after trimming.
   */
  readonly reason: string;

  /**
   * Generate once per intended grant.
   * Reuse the same UUID and input when retrying.
   */
  readonly requestId: string;
}
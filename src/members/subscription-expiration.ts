export interface SubscriptionExpiration {
  readonly id: string;

  readonly tenantId: string;
  readonly subscriptionId: string;

  /**
   * Calendar dates in YYYY-MM-DD format.
   * coverageEndsOn is exclusive.
   */
  readonly coverageStartsOn: string;
  readonly coverageEndsOn: string;

  /**
   * Server-calculated Myanmar date when expiration
   * was processed.
   */
  readonly processedOn: string;

  readonly expiredAt: Date;
  readonly createdAt: Date;
}
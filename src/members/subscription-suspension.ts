export interface SubscriptionSuspension {
  readonly id: string;

  readonly tenantId: string;
  readonly subscriptionId: string;
  readonly requestId: string;

  readonly reason: string;
  readonly suspendedAt: Date;
  readonly createdAt: Date;
}

export interface SuspendMemberSubscriptionInput {
  /**
   * Required reason, normalized before storage.
   * Must contain 2–500 characters after trimming.
   */
  readonly reason: string;

  /**
   * Generate once per intended suspension.
   * Reuse the same UUID and reason when retrying.
   */
  readonly requestId: string;
}
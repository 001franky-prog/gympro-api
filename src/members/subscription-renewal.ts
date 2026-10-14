import type {
  SubscriptionDurationUnit,
} from './member-subscription.js';

export interface SubscriptionRenewal {
  readonly id: string;

  readonly tenantId: string;
  readonly subscriptionId: string;
  readonly requestId: string;

  readonly planId: string;
  readonly planPriceId: string;

  /**
   * Calendar dates in YYYY-MM-DD format.
   * renewalEndsOn is exclusive.
   */
  readonly previousEndsOn: string;
  readonly renewalStartsOn: string;
  readonly renewalEndsOn: string;

  readonly durationValue: number;
  readonly durationUnit: SubscriptionDurationUnit;

  readonly agreedPriceAmount: string;
  readonly currencyCode: 'MMK';

  readonly createdAt: Date;
}

export interface RenewMemberSubscriptionInput {
  readonly planPriceId: string;

  /**
   * Generate once for each intended renewal.
   * Reuse the same UUID when retrying that renewal.
   */
  readonly requestId: string;
}
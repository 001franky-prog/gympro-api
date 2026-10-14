export const SUBSCRIPTION_STATUSES = [
  'pending',
  'active',
  'suspended',
  'expired',
] as const;

export type SubscriptionStatus =
  (typeof SUBSCRIPTION_STATUSES)[number];

export const SUBSCRIPTION_DURATION_UNITS = [
  'days',
  'weeks',
  'months',
  'years',
] as const;

export type SubscriptionDurationUnit =
  (typeof SUBSCRIPTION_DURATION_UNITS)[number];

export interface MemberSubscription {
  readonly id: string;

  readonly tenantId: string;
  readonly memberId: string;
  readonly branchId: string | null;

  readonly planId: string;
  readonly planPriceId: string;

  readonly durationValue: number;
  readonly durationUnit: SubscriptionDurationUnit;

  readonly agreedPriceAmount: string;
  readonly currencyCode: 'MMK';

  readonly status: SubscriptionStatus;

  /**
   * Calendar dates in YYYY-MM-DD format.
   * endsOn is exclusive.
   */
  readonly startsOn: string | null;
  readonly endsOn: string | null;

  readonly activatedAt: Date | null;
  readonly suspendedAt: Date | null;

  readonly createdAt: Date;
  readonly updatedAt: Date;
}

export interface ActivateMemberSubscriptionInput {
  readonly planId: string;
  readonly planPriceId: string;
}
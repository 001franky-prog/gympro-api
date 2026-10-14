export type PromotionDiscountKind = 'percentage' | 'fixed_amount';

export type PromotionStatus = 'draft' | 'active' | 'inactive';

export interface MembershipPromotion {
  readonly id: string;
  readonly tenantId: string;
  readonly promotionCode: string;
  readonly promotionName: string;
  readonly description: string | null;
  readonly planId: string | null;
  readonly branchId: string | null;
  readonly discountKind: PromotionDiscountKind;
  readonly discountValue: string;
  readonly currencyCode: 'MMK';
  readonly startsOn: string;
  readonly endsOn: string | null;
  readonly status: PromotionStatus;
  readonly createdAt: Date;
  readonly updatedAt: Date;
}

export interface CreateMembershipPromotionInput {
  readonly promotionCode: string;
  readonly promotionName: string;
  readonly description?: string | null;
  readonly planId?: string | null;
  readonly branchId?: string | null;
  readonly discountKind: PromotionDiscountKind;
  readonly discountValue: string;
  readonly startsOn: string;
  readonly endsOn?: string | null;
}

export interface MembershipDiscountReceipt {
  readonly id: string;
  readonly tenantId: string;
  readonly subscriptionId: string;
  readonly promotionId: string;
  readonly requestId: string;
  readonly purchaseKind: 'activation' | 'renewal';
  readonly renewalId: string | null;
  readonly listedPriceAmount: string;
  readonly discountAmount: string;
  readonly agreedPriceAmount: string;
  readonly currencyCode: 'MMK';
  readonly appliedAt: Date;
  readonly createdAt: Date;
}

export interface ActivateDiscountedMembershipInput {
  readonly planId: string;
  readonly planPriceId: string;
  readonly promotionId: string;
  readonly requestId: string;
}

export interface RenewDiscountedMembershipInput {
  readonly planPriceId: string;
  readonly promotionId: string;
  readonly requestId: string;
}
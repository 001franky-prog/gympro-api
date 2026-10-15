import { Body, Controller, HttpCode, HttpStatus, Param, Post, Req, UseGuards } from '@nestjs/common';
import { AuthenticatedSessionGuard, type GymProAuthenticatedRequest } from '../auth/authenticated-session.guard.js';
import { TenantScopeGuard } from '../auth/tenant-scope.guard.js';
import { PermissionGuard } from '../auth/permission.guard.js';
import { RequirePermission } from '../auth/require-permission.decorator.js';
import { SubscriptionExpirationService } from './subscription-expiration.service.js';
import { MemberBlacklistService } from './member-blacklist.service.js';
import { FocMembershipService } from './foc-membership.service.js';
import { MembershipDiscountService } from './membership-discount.service.js';
import { MembershipPromotionService } from './membership-promotion.service.js';

@Controller('tenants/:tenantId/branches/:branchId')
@UseGuards(AuthenticatedSessionGuard, TenantScopeGuard, PermissionGuard)
export class BranchMembershipController {
 constructor(private readonly expiration: SubscriptionExpirationService,
 private readonly blacklist: MemberBlacklistService, private readonly foc: FocMembershipService,
 private readonly discounts: MembershipDiscountService, private readonly promotions: MembershipPromotionService) {}
 @Post('subscriptions/:subscriptionId/expire') @HttpCode(HttpStatus.OK)
 @RequirePermission('gym.memberships.manage')
 async expire(@Req() request: GymProAuthenticatedRequest, @Param('tenantId') tenantId: string, @Param('branchId') branchId: string, @Param('subscriptionId') targetId: string, @Body() body: unknown) { return this.expiration.expire(request,tenantId,targetId,body,branchId); }
 @Post('members/:memberId/blacklist') @HttpCode(HttpStatus.OK)
 @RequirePermission('gym.members.update')
 async blacklistMember(@Req() request: GymProAuthenticatedRequest, @Param('tenantId') tenantId: string, @Param('branchId') branchId: string, @Param('memberId') targetId: string, @Body() body: unknown) { return this.blacklist.change(request,tenantId,targetId,'blacklist',body,branchId); }
 @Post('members/:memberId/unblacklist') @HttpCode(HttpStatus.OK)
 @RequirePermission('gym.members.update')
 async unblacklistMember(@Req() request: GymProAuthenticatedRequest, @Param('tenantId') tenantId: string, @Param('branchId') branchId: string, @Param('memberId') targetId: string, @Body() body: unknown) { return this.blacklist.change(request,tenantId,targetId,'unblacklist',body,branchId); }
 @Post('members/:memberId/subscriptions/grant-foc') @HttpCode(HttpStatus.OK)
 @RequirePermission('gym.memberships.grant_foc')
 async grantFoc(@Req() request: GymProAuthenticatedRequest, @Param('tenantId') tenantId: string, @Param('branchId') branchId: string, @Param('memberId') targetId: string, @Body() body: unknown) { return this.foc.grant(request,tenantId,targetId,body,branchId); }
 @Post('members/:memberId/subscriptions/activate-discounted') @HttpCode(HttpStatus.OK)
 @RequirePermission('gym.memberships.apply_discount')
 async activateDiscount(@Req() request: GymProAuthenticatedRequest, @Param('tenantId') tenantId: string, @Param('branchId') branchId: string, @Param('memberId') targetId: string, @Body() body: unknown) { return this.discounts.activate(request,tenantId,targetId,body,branchId); }
 @Post('subscriptions/:subscriptionId/renew-discounted') @HttpCode(HttpStatus.OK)
 @RequirePermission('gym.memberships.apply_discount')
 async renewDiscount(@Req() request: GymProAuthenticatedRequest, @Param('tenantId') tenantId: string, @Param('branchId') branchId: string, @Param('subscriptionId') targetId: string, @Body() body: unknown) { return this.discounts.renew(request,tenantId,targetId,body,branchId); }
 @Post('promotions') @HttpCode(HttpStatus.CREATED)
 @RequirePermission('gym.promotions.manage')
 async createPromotion(@Req() request: GymProAuthenticatedRequest, @Param('tenantId') tenantId: string, @Param('branchId') branchId: string, @Body() body: unknown) { return this.promotions.create(request,tenantId,body,branchId); }
 @Post('promotions/:promotionId/activate') @HttpCode(HttpStatus.OK)
 @RequirePermission('gym.promotions.manage')
 async activatePromotion(@Req() request: GymProAuthenticatedRequest, @Param('tenantId') tenantId: string, @Param('branchId') branchId: string, @Param('promotionId') targetId: string, @Body() body: unknown) { return this.promotions.setStatus(request,tenantId,targetId,'active',body,branchId); }
 @Post('promotions/:promotionId/deactivate') @HttpCode(HttpStatus.OK)
 @RequirePermission('gym.promotions.manage')
 async deactivatePromotion(@Req() request: GymProAuthenticatedRequest, @Param('tenantId') tenantId: string, @Param('branchId') branchId: string, @Param('promotionId') targetId: string, @Body() body: unknown) { return this.promotions.setStatus(request,tenantId,targetId,'inactive',body,branchId); }
}

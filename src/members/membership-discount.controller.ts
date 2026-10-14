import {
  Body,
  Controller,
  HttpCode,
  HttpStatus,
  Param,
  Post,
  Req,
  UseGuards,
} from '@nestjs/common';
import {
  AuthenticatedSessionGuard,
  type GymProAuthenticatedRequest,
} from '../auth/authenticated-session.guard.js';
import { PermissionGuard } from '../auth/permission.guard.js';
import { RequirePermission } from '../auth/require-permission.decorator.js';
import { TenantScopeGuard } from '../auth/tenant-scope.guard.js';
import { MembershipDiscountService } from './membership-discount.service.js';
import type { MembershipDiscountReceipt } from './membership-promotion.js';

@Controller('tenants/:tenantId')
@UseGuards(
  AuthenticatedSessionGuard,
  TenantScopeGuard,
  PermissionGuard,
)
@RequirePermission('gym.memberships.apply_discount')
export class MembershipDiscountController {
  constructor(
    private readonly discounts: MembershipDiscountService,
  ) {}

  @Post('members/:memberId/subscriptions/activate-discounted')
  @HttpCode(HttpStatus.OK)
  async activate(
    @Req() request: GymProAuthenticatedRequest,
    @Param('tenantId') tenantId: string,
    @Param('memberId') memberId: string,
    @Body() body: unknown,
  ): Promise<MembershipDiscountReceipt> {
    return this.discounts.activate(request, tenantId, memberId, body);
  }

  @Post('subscriptions/:subscriptionId/renew-discounted')
  @HttpCode(HttpStatus.OK)
  async renew(
    @Req() request: GymProAuthenticatedRequest,
    @Param('tenantId') tenantId: string,
    @Param('subscriptionId') subscriptionId: string,
    @Body() body: unknown,
  ): Promise<MembershipDiscountReceipt> {
    return this.discounts.renew(request, tenantId, subscriptionId, body);
  }
}
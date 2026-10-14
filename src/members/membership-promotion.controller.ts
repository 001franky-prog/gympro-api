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
import { MembershipPromotionService } from './membership-promotion.service.js';
import type { MembershipPromotion } from './membership-promotion.js';

@Controller('tenants/:tenantId/promotions')
@UseGuards(
  AuthenticatedSessionGuard,
  TenantScopeGuard,
  PermissionGuard,
)
@RequirePermission('gym.promotions.manage')
export class MembershipPromotionController {
  constructor(
    private readonly promotions: MembershipPromotionService,
  ) {}

  @Post()
  @HttpCode(HttpStatus.CREATED)
  async create(
    @Req() request: GymProAuthenticatedRequest,
    @Param('tenantId') tenantId: string,
    @Body() body: unknown,
  ): Promise<MembershipPromotion> {
    return this.promotions.create(request, tenantId, body);
  }

  @Post(':promotionId/activate')
  @HttpCode(HttpStatus.OK)
  async activate(
    @Req() request: GymProAuthenticatedRequest,
    @Param('tenantId') tenantId: string,
    @Param('promotionId') promotionId: string,
    @Body() body: unknown,
  ): Promise<MembershipPromotion> {
    return this.promotions.setStatus(
      request,
      tenantId,
      promotionId,
      'active',
      body,
    );
  }

  @Post(':promotionId/deactivate')
  @HttpCode(HttpStatus.OK)
  async deactivate(
    @Req() request: GymProAuthenticatedRequest,
    @Param('tenantId') tenantId: string,
    @Param('promotionId') promotionId: string,
    @Body() body: unknown,
  ): Promise<MembershipPromotion> {
    return this.promotions.setStatus(
      request,
      tenantId,
      promotionId,
      'inactive',
      body,
    );
  }
}
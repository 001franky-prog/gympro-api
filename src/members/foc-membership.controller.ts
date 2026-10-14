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
} from '../auth/authenticated-session.guard.js';

import type {
  GymProAuthenticatedRequest,
} from '../auth/authenticated-session.guard.js';

import {
  TenantScopeGuard,
} from '../auth/tenant-scope.guard.js';

import {
  PermissionGuard,
} from '../auth/permission.guard.js';

import {
  RequirePermission,
} from '../auth/require-permission.decorator.js';

import {
  FocMembershipService,
} from './foc-membership.service.js';

import type {
  FocMembershipGrant,
} from './foc-membership.js';

@Controller('tenants/:tenantId/members/:memberId/subscriptions')
@UseGuards(
  AuthenticatedSessionGuard,
  TenantScopeGuard,
  PermissionGuard,
)
@RequirePermission('gym.memberships.grant_foc')
export class FocMembershipController {
  constructor(
    private readonly focService: FocMembershipService,
  ) {}

  @Post('grant-foc')
  @HttpCode(HttpStatus.OK)
  async grant(
    @Req() request: GymProAuthenticatedRequest,
    @Param('tenantId') tenantId: string,
    @Param('memberId') memberId: string,
    @Body() body: unknown,
  ): Promise<FocMembershipGrant> {
    return this.focService.grant(
      request,
      tenantId,
      memberId,
      body,
    );
  }
}
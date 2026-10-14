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
  MemberRegistrationService,
} from './member-registration.service.js';

import type {
  MemberProfile,
} from './member-profile.js';

@Controller('tenants/:tenantId')
@UseGuards(
  AuthenticatedSessionGuard,
  TenantScopeGuard,
  PermissionGuard,
)
@RequirePermission('gym.members.create')
export class MembersController {
  constructor(
    private readonly memberRegistrationService:
      MemberRegistrationService,
  ) {}

  @Post('members')
  @HttpCode(HttpStatus.CREATED)
  async registerTenantMember(
    @Req() request: GymProAuthenticatedRequest,
    @Param('tenantId') tenantId: string,
    @Body() body: unknown,
  ): Promise<MemberProfile> {
    return this.memberRegistrationService.register(
      request,
      tenantId,
      null,
      body,
    );
  }

  @Post('branches/:branchId/members')
  @HttpCode(HttpStatus.CREATED)
  async registerBranchMember(
    @Req() request: GymProAuthenticatedRequest,
    @Param('tenantId') tenantId: string,
    @Param('branchId') branchId: string,
    @Body() body: unknown,
  ): Promise<MemberProfile> {
    return this.memberRegistrationService.register(
      request,
      tenantId,
      branchId,
      body,
    );
  }
}
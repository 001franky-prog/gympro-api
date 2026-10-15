import { Body, Controller, HttpCode, Param, Post, Req, UseGuards } from '@nestjs/common';
import { AuthenticatedSessionGuard } from '../auth/authenticated-session.guard.js';
import type { GymProAuthenticatedRequest } from '../auth/authenticated-session.guard.js';
import { TenantScopeGuard } from '../auth/tenant-scope.guard.js';
import { PermissionGuard } from '../auth/permission.guard.js';
import { RequirePermission } from '../auth/require-permission.decorator.js';
import { AttendanceCheckoutService } from './attendance-checkout.service.js';
@Controller('tenants/:tenantId/branches/:branchId/attendance/:visitId')
@UseGuards(AuthenticatedSessionGuard,TenantScopeGuard,PermissionGuard)
export class AttendanceCheckoutController {
 constructor(private readonly service:AttendanceCheckoutService){}
 @Post('check-out') @HttpCode(200) @RequirePermission('gym.attendance.record')
 checkOut(@Req()req:GymProAuthenticatedRequest,@Param('tenantId')tenant:string,@Param('branchId')branch:string,@Param('visitId')visit:string,@Body()body:unknown){return this.service.checkOut(req,tenant,branch,visit,body);}
}

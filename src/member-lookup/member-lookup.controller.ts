import {Controller,Get,Header,Param,Query,Req,UseGuards} from '@nestjs/common';
import {AuthenticatedSessionGuard} from '../auth/authenticated-session.guard.js';
import type {GymProAuthenticatedRequest} from '../auth/authenticated-session.guard.js';
import {TenantScopeGuard} from '../auth/tenant-scope.guard.js';
import {PermissionGuard} from '../auth/permission.guard.js';
import {RequirePermission} from '../auth/require-permission.decorator.js';
import {MemberLookupService} from './member-lookup.service.js';
@Controller('tenants/:tenantId/branches/:branchId/members')
@UseGuards(AuthenticatedSessionGuard,TenantScopeGuard,PermissionGuard)
export class MemberLookupController {
 constructor(private readonly service:MemberLookupService){}
 @Get('lookup') @Header('Cache-Control','no-store') @RequirePermission('gym.members.read')
 search(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Query()q:unknown){return this.service.search(r,t,b,q);}
}

import {Controller,Get,Header,Param,Query,Req,UseGuards} from '@nestjs/common';
import {AuthenticatedSessionGuard} from '../auth/authenticated-session.guard.js';
import type {GymProAuthenticatedRequest} from '../auth/authenticated-session.guard.js';
import {TenantScopeGuard} from '../auth/tenant-scope.guard.js';
import {PermissionGuard} from '../auth/permission.guard.js';
import {RequirePermission} from '../auth/require-permission.decorator.js';
import {PosHistoryService} from './pos-history.service.js';
@Controller('tenants/:tenantId/branches/:branchId/pos/sales')
@UseGuards(AuthenticatedSessionGuard,TenantScopeGuard,PermissionGuard)
export class PosHistoryController {
 constructor(private readonly service:PosHistoryService){}
 @Get() @Header('Cache-Control','no-store') @RequirePermission('pos.sales.read') list(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Query()q:unknown){return this.service.list(r,t,b,q);}
}

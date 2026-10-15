import {Body,Controller,Get,Header,Param,Post,Query,Req,UseGuards} from '@nestjs/common';
import {AuthenticatedSessionGuard} from '../auth/authenticated-session.guard.js';
import type {GymProAuthenticatedRequest} from '../auth/authenticated-session.guard.js';
import {TenantScopeGuard} from '../auth/tenant-scope.guard.js';
import {PermissionGuard} from '../auth/permission.guard.js';
import {RequirePermission} from '../auth/require-permission.decorator.js';
import {PosService} from './pos.service.js';
@Controller('tenants/:tenantId/branches/:branchId/pos/sales')
@UseGuards(AuthenticatedSessionGuard,TenantScopeGuard,PermissionGuard)
export class PosController {
 constructor(private readonly service:PosService){}
 @Post() @RequirePermission('pos.sales.create') create(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Body()body:unknown){return this.service.create(r,t,b,body);}
 @Get(':saleId') @Header('Cache-Control','no-store') @RequirePermission('pos.sales.read') read(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Param('saleId')s:string,@Query()q:unknown){return this.service.read(r,t,b,s,q);}
}

import {Body,Controller,Get,Header,HttpCode,Param,Post,Query,Req,UseGuards} from '@nestjs/common';
import {AuthenticatedSessionGuard} from '../auth/authenticated-session.guard.js';
import type {GymProAuthenticatedRequest} from '../auth/authenticated-session.guard.js';
import {TenantScopeGuard} from '../auth/tenant-scope.guard.js';
import {PermissionGuard} from '../auth/permission.guard.js';
import {RequirePermission} from '../auth/require-permission.decorator.js';
import {PosReturnService} from './pos-return.service.js';
@Controller('tenants/:tenantId/branches/:branchId/pos/sales')
@UseGuards(AuthenticatedSessionGuard,TenantScopeGuard,PermissionGuard)
export class PosReturnController {
 constructor(private readonly service:PosReturnService){}
 @Post(':saleId/refund') @HttpCode(200) @RequirePermission('pos.sales.refund') refund(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Param('saleId')s:string,@Body()body:unknown){return this.service.change(r,t,b,s,'refund',body);}
 @Post(':saleId/void') @HttpCode(200) @RequirePermission('pos.sales.void') voidSale(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Param('saleId')s:string,@Body()body:unknown){return this.service.change(r,t,b,s,'void',body);}
 @Get(':saleId/returns/:returnId') @Header('Cache-Control','no-store') @RequirePermission('pos.sales.read') read(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Param('saleId')s:string,@Param('returnId')id:string,@Query()q:unknown){return this.service.read(r,t,b,s,id,q);}
 @Get(':saleId/return-status') @Header('Cache-Control','no-store') @RequirePermission('pos.sales.read') status(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Param('saleId')s:string,@Query()q:unknown){return this.service.status(r,t,b,s,q);}
}

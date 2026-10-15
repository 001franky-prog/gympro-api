import {Controller,Get,Header,Param,Query,Req,UseGuards} from '@nestjs/common';
import {AuthenticatedSessionGuard} from '../auth/authenticated-session.guard.js';
import type {GymProAuthenticatedRequest} from '../auth/authenticated-session.guard.js';
import {TenantScopeGuard} from '../auth/tenant-scope.guard.js';
import {PermissionGuard} from '../auth/permission.guard.js';
import {RequirePermission} from '../auth/require-permission.decorator.js';
import {InventoryHistoryService} from './inventory-history.service.js';
@Controller('tenants/:tenantId/branches/:branchId/inventory/products/:productId/movements')
@UseGuards(AuthenticatedSessionGuard,TenantScopeGuard,PermissionGuard)
export class InventoryHistoryController {
 constructor(private readonly service:InventoryHistoryService){}
 @Get() @Header('Cache-Control','no-store') @RequirePermission('inventory.products.read') list(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Param('productId')p:string,@Query()q:unknown){return this.service.list(r,t,b,p,q);}
}

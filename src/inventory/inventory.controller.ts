import {Body,Controller,Get,Header,HttpCode,Param,Patch,Post,Query,Req,UseGuards} from '@nestjs/common';
import {AuthenticatedSessionGuard} from '../auth/authenticated-session.guard.js';
import type {GymProAuthenticatedRequest} from '../auth/authenticated-session.guard.js';
import {TenantScopeGuard} from '../auth/tenant-scope.guard.js';
import {PermissionGuard} from '../auth/permission.guard.js';
import {RequirePermission} from '../auth/require-permission.decorator.js';
import {InventoryService} from './inventory.service.js';
@Controller('tenants/:tenantId/inventory/products')
@UseGuards(AuthenticatedSessionGuard,TenantScopeGuard,PermissionGuard)
export class InventoryProductController {
 constructor(private readonly service:InventoryService){}
 @Post() @RequirePermission('inventory.products.create')
 create(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Body()body:unknown){return this.service.create(r,t,body);}
 @Patch(':productId') @RequirePermission('inventory.products.update')
 update(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('productId')p:string,@Body()body:unknown){return this.service.update(r,t,p,body);}
 @Get() @Header('Cache-Control','no-store') @RequirePermission('inventory.products.read')
 list(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Query()q:unknown){return this.service.list(r,t,undefined,q);}
}
@Controller('tenants/:tenantId/branches/:branchId/inventory')
@UseGuards(AuthenticatedSessionGuard,TenantScopeGuard,PermissionGuard)
export class InventoryBranchController {
 constructor(private readonly service:InventoryService){}
 @Get('products') @Header('Cache-Control','no-store') @RequirePermission('inventory.products.read')
 list(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Query()q:unknown){return this.service.list(r,t,b,q);}
 @Get('products/:productId/stock') @Header('Cache-Control','no-store') @RequirePermission('inventory.products.read')
 stock(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Param('productId')p:string,@Query()q:unknown){return this.service.stock(r,t,b,p,q);}
 @Post('products/:productId/stock-adjustments') @HttpCode(200) @RequirePermission('inventory.stock.adjust')
 adjust(@Req()r:GymProAuthenticatedRequest,@Param('tenantId')t:string,@Param('branchId')b:string,@Param('productId')p:string,@Body()body:unknown){return this.service.adjust(r,t,b,p,body);}
}

import 'reflect-metadata';
import {describe,expect,it} from 'vitest';
import {GUARDS_METADATA} from '@nestjs/common/constants';
import {AuthenticatedSessionGuard} from '../auth/authenticated-session.guard.js';
import {TenantScopeGuard} from '../auth/tenant-scope.guard.js';
import {PermissionGuard} from '../auth/permission.guard.js';
import {InventoryProductController,InventoryBranchController} from './inventory.controller.js';
describe('Inventory route authorization metadata',()=>{
 for(const Controller of [InventoryProductController,InventoryBranchController])it(`${Controller.name} enforces authentication, tenant and permission guards`,()=>{expect(Reflect.getMetadata(GUARDS_METADATA,Controller)).toEqual([AuthenticatedSessionGuard,TenantScopeGuard,PermissionGuard]);});
 const cases=[
  [InventoryProductController.prototype.create,'create','inventory.products.create'],
  [InventoryProductController.prototype.update,'update','inventory.products.update'],
  [InventoryProductController.prototype.list,'tenant list','inventory.products.read'],
  [InventoryBranchController.prototype.list,'branch list','inventory.products.read'],
  [InventoryBranchController.prototype.stock,'stock','inventory.products.read'],
  [InventoryBranchController.prototype.adjust,'adjust','inventory.stock.adjust'],
 ] as const;
 for(const [handler,name,permission]of cases)it(`${name} requires ${permission}`,()=>{expect(Reflect.getMetadata('gympro.required_permission',handler)).toBe(permission);});
});

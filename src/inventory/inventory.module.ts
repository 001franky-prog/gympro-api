import {Module} from '@nestjs/common';
import {AuthModule} from '../auth/auth.module.js';
import {InventoryService} from './inventory.service.js';
import {InventoryProductController,InventoryBranchController} from './inventory.controller.js';
@Module({imports:[AuthModule],controllers:[InventoryProductController,InventoryBranchController],providers:[InventoryService]})
export class InventoryModule {}

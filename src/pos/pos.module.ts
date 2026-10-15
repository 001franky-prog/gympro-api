import {PosUiController} from './pos-ui.controller.js';
import {PosHistoryController} from './pos-history.controller.js';
import {PosHistoryService} from './pos-history.service.js';
import {PosReturnController} from './pos-return.controller.js';
import {PosReturnService} from './pos-return.service.js';
import {Module} from '@nestjs/common';
import {AuthModule} from '../auth/auth.module.js';
import {PosController} from './pos.controller.js';
import {PosService} from './pos.service.js';
@Module({imports:[AuthModule],controllers:[PosUiController, PosHistoryController, PosReturnController, PosController],providers:[PosHistoryService, PosReturnService, PosService]})
export class PosModule {}

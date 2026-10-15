import {PosReturnController} from './pos-return.controller.js';
import {PosReturnService} from './pos-return.service.js';
import {Module} from '@nestjs/common';
import {AuthModule} from '../auth/auth.module.js';
import {PosController} from './pos.controller.js';
import {PosService} from './pos.service.js';
@Module({imports:[AuthModule],controllers:[PosReturnController, PosController],providers:[PosReturnService, PosService]})
export class PosModule {}

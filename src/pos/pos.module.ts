import {Module} from '@nestjs/common';
import {AuthModule} from '../auth/auth.module.js';
import {PosController} from './pos.controller.js';
import {PosService} from './pos.service.js';
@Module({imports:[AuthModule],controllers:[PosController],providers:[PosService]})
export class PosModule {}

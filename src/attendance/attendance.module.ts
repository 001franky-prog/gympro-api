import { AttendanceReadService } from './attendance-read.service.js';
import { AttendanceReadController } from './attendance-read.controller.js';
import { AttendanceCheckoutService } from './attendance-checkout.service.js';
import { AttendanceCheckoutController } from './attendance-checkout.controller.js';
import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module.js';
import { AttendanceController } from './attendance.controller.js';
import { AttendanceService } from './attendance.service.js';
@Module({imports:[AuthModule],controllers:[AttendanceController,AttendanceCheckoutController,AttendanceReadController],providers:[AttendanceService,AttendanceCheckoutService,AttendanceReadService]})
export class AttendanceModule {}

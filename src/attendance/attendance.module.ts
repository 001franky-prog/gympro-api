import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module.js';
import { AttendanceController } from './attendance.controller.js';
import { AttendanceService } from './attendance.service.js';
@Module({imports:[AuthModule],controllers:[AttendanceController],providers:[AttendanceService]})
export class AttendanceModule {}

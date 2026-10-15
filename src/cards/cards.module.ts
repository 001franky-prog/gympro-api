import {CardScanService} from './card-scan.service.js';
import {CardScanController} from './card-scan.controller.js';
import {Module} from '@nestjs/common';
import {AuthModule} from '../auth/auth.module.js';
import {MemberCardController} from './member-card.controller.js';
import {MemberCardService} from './member-card.service.js';
@Module({imports:[AuthModule],controllers:[MemberCardController,CardScanController],providers:[MemberCardService,CardScanService]})
export class CardsModule {}

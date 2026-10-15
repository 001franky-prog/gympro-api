import {Module} from '@nestjs/common';
import {AuthModule} from '../auth/auth.module.js';
import {MemberLookupController} from './member-lookup.controller.js';
import {MemberLookupService} from './member-lookup.service.js';
@Module({imports:[AuthModule],controllers:[MemberLookupController],providers:[MemberLookupService]})
export class MemberLookupModule {}

import { Module } from '@nestjs/common';

import { AuthModule } from '../auth/auth.module.js';

import { MembersController } from './members.controller.js';
import { MemberRegistrationService } from './member-registration.service.js';

import {
  SubscriptionActivationController,
} from './subscription-activation.controller.js';

import {
  SubscriptionActivationService,
} from './subscription-activation.service.js';

import {
  SubscriptionRenewalController,
} from './subscription-renewal.controller.js';

import {
  SubscriptionRenewalService,
} from './subscription-renewal.service.js';

import {
  SubscriptionSuspensionController,
} from './subscription-suspension.controller.js';

import {
  SubscriptionSuspensionService,
} from './subscription-suspension.service.js';

import {
  SubscriptionExpirationController,
} from './subscription-expiration.controller.js';

import {
  SubscriptionExpirationService,
} from './subscription-expiration.service.js';

import {
  MemberBlacklistController,
} from './member-blacklist.controller.js';

import {
  MemberBlacklistService,
} from './member-blacklist.service.js';

import {
  FocMembershipController,
} from './foc-membership.controller.js';

import {
  FocMembershipService,
} from './foc-membership.service.js';

@Module({
  imports: [
    AuthModule,
  ],
  controllers: [
    MembersController,
    SubscriptionActivationController,
    SubscriptionRenewalController,
    SubscriptionSuspensionController,
    SubscriptionExpirationController,
    MemberBlacklistController,
    FocMembershipController,
  ],
  providers: [
    MemberRegistrationService,
    SubscriptionActivationService,
    SubscriptionRenewalService,
    SubscriptionSuspensionService,
    SubscriptionExpirationService,
    MemberBlacklistService,
    FocMembershipService,
  ],
})
export class MembersModule {}
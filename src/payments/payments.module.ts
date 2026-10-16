import {PaymentUiController} from './payment-ui.controller.js';
import {PaymentReconciliationService} from './payment-reconciliation.service.js';
import {PaymentReconciliationController} from './payment-reconciliation.controller.js';
import {PaymentReportingService} from './payment-reporting.service.js';
import {PaymentReportingController} from './payment-reporting.controller.js';
import {PaymentReversalService} from './payment-reversal.service.js';
import {PaymentReversalController} from './payment-reversal.controller.js';
import {Module} from '@nestjs/common';
import {AuthModule} from '../auth/auth.module.js';
import {PaymentService} from './payment.service.js';
import {PaymentController} from './payment.controller.js';
@Module({imports:[AuthModule],controllers:[PaymentController,PaymentReversalController,PaymentReportingController,PaymentReconciliationController,PaymentUiController],providers:[PaymentService,PaymentReversalService,PaymentReportingService,PaymentReconciliationService]})
export class PaymentsModule {}

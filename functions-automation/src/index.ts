import { ensureFirebaseAdminApp, ensureSentryForFunctions } from '@sfc/functions-shared/init';

ensureFirebaseAdminApp();
ensureSentryForFunctions();

import {
  registerSendgridMailConfigProvider,
  registerStripeKeysProvider,
} from '@sfc/functions-shared';

import {
  SENDGRID_API_KEY,
  SENDGRID_FROM_EMAIL,
  STRIPE_PUBLISHABLE_KEY,
  STRIPE_SECRET_KEY,
} from './secrets';

registerStripeKeysProvider({
  getSecretKey: () => STRIPE_SECRET_KEY.value(),
  getPublishableKey: () => STRIPE_PUBLISHABLE_KEY.value(),
});

registerSendgridMailConfigProvider({
  getApiKey: () => SENDGRID_API_KEY.value(),
  getFromEmail: () => SENDGRID_FROM_EMAIL.value(),
});

export { generateMonthlyRentCharges } from './monthlyRentCharges';
// Monthly rent charges fan out one job per facility; see rentChargeJob.ts for
// why the previous single-invocation scheduler could not scale.
export {
  scheduledGenerateMonthlyRentCharges,
  processFacilityRentChargeJob,
} from './rentChargeJob';
export { processDelinquencyAutomation } from './delinquencyAutomation';
export { processAutopayPayments, processFacilityAutopayJob } from './autopayScheduled';
export { resetMonthlySMSUsage } from './smsUsageReset';
export { autoProtectMoveIn, autoProtectAudit, checkInsuranceCompliance } from './insuranceAutomation';
export { processPaymentReminders } from './paymentRemindersScheduled';

export { cleanupExpiredExports, getExportDownloadUrl, processExportJob } from './processExportJob';

import { ensureFirebaseAdminApp, ensureSentryForFunctions } from '@sfc/functions-shared/init';

ensureFirebaseAdminApp();
ensureSentryForFunctions();

import { registerSendgridMailConfigProvider, registerSfcLeadConfigProvider } from '@sfc/functions-shared';
import { SENDGRID_API_KEY, SENDGRID_FROM_EMAIL, SFC_LEAD_LINE_NUMBER, SFC_LEAD_SMS_AUTO_REPLY } from './secrets';

registerSendgridMailConfigProvider({
  getApiKey: () => SENDGRID_API_KEY.value(),
  getFromEmail: () => SENDGRID_FROM_EMAIL.value(),
});

registerSfcLeadConfigProvider({
  getLeadLine: () => SFC_LEAD_LINE_NUMBER.value(),
  getSmsAutoReply: () => SFC_LEAD_SMS_AUTO_REPLY.value(),
  getForwardTo: () => '',
});

export { sendSMS } from './twilioCallables';
export {
  getTextingOnboardingStatus,
  saveTextingBusinessInfo,
  ensureMessagingService,
  createOrUpdateA2PProfile,
  setTextingPlatformApproval,
  provisionPhoneNumber,
  submitTextingOnboarding,
  submitBrandRegistration,
  submitCampaign,
  refreshTextingOnboardingStatus,
  resubmitTextingOnboarding,
} from './twilioCallables';

export { getSMSUsageStatus, overrideSMSLimit } from './smsUsage';

export { handleIncomingSMS } from './incomingSmsWebhook';

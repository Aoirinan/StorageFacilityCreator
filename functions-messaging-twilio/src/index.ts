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
// Hourly sweep so a carrier rejection reaches the product without an operator
// happening to press "refresh" in the texting UI.
export { pollA2PRegistrationStatus } from './a2pStatusPoll';
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

export { listFacilitySmsOptOuts, restoreFacilitySmsForPhone } from './smsStaffOptOut';

export { handleIncomingSMS } from './incomingSmsWebhook';

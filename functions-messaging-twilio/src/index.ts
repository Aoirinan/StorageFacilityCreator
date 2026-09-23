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
// Emails the super admins when a facility's registration is submitted,
// approved or rejected, so they need not watch Twilio or each Texting page.
export { notifyAdminsOfA2PChanges, listA2PAdminEvents } from './a2pAdminAlerts';
// Six-hourly probe of account status and balance, so a suspension or a dead
// card reaches the super admins instead of silently failing every send.
export { checkTwilioAccountHealthScheduled } from './twilioAccountHealth';
export {
  getTextingOnboardingStatus,
  saveTextingBusinessInfo,
  ensureMessagingService,
  createOrUpdateA2PProfile,
  setTextingPlatformApproval,
  provisionPhoneNumber,
  submitTextingOnboarding,
  submitBrandRegistration,
  resendSoleProprietorOtp,
  submitCampaign,
  refreshTextingOnboardingStatus,
  resubmitTextingOnboarding,
} from './twilioCallables';

export { getSMSUsageStatus, overrideSMSLimit } from './smsUsage';

export { listFacilitySmsOptOuts, restoreFacilitySmsForPhone } from './smsStaffOptOut';

export { handleIncomingSMS } from './incomingSmsWebhook';

export { processRentDueTextReminders } from './rentReminderSms';

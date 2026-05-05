import { ensureFirebaseAdminApp, ensureSentryForFunctions } from '@sfc/functions-shared/init';

ensureFirebaseAdminApp();
ensureSentryForFunctions();

import { registerSendgridMailConfigProvider } from '@sfc/functions-shared';
import { SENDGRID_API_KEY, SENDGRID_FROM_EMAIL } from './secrets';

registerSendgridMailConfigProvider({
  getApiKey: () => SENDGRID_API_KEY.value(),
  getFromEmail: () => SENDGRID_FROM_EMAIL.value(),
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

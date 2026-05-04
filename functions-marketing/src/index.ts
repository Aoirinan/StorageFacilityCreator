import { ensureFirebaseAdminApp, ensureSentryForFunctions } from '@sfc/functions-shared/init';

ensureFirebaseAdminApp();
ensureSentryForFunctions();

import './sfcLeadConfig';

export {
  claimReferralAttribution,
  ensureReferralCodeForAccount,
  setReferralRewardPreferredFacility,
} from './referralRewards';
export { captureMarketingLead } from './marketingLead';
export { handleSfcLeadSMS, handleSfcLeadCall } from './sfcLeadWebhooks';

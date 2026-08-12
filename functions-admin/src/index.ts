import { ensureFirebaseAdminApp, ensureSentryForFunctions } from '@sfc/functions-shared/init';

ensureFirebaseAdminApp();
ensureSentryForFunctions();

import { registerSendgridMailConfigProvider } from '@sfc/functions-shared/email/sendgridRegistry';
import { registerHostingConfigProvider } from '@sfc/functions-shared/hosting/hostingConfigRegistry';
import { registerStripeKeysProvider } from '@sfc/functions-shared/stripe/keysRegistry';

import {
  HOSTING_PROJECT_ID,
  HOSTING_SITE_ID,
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

registerHostingConfigProvider({
  getProjectId: () => HOSTING_PROJECT_ID.value(),
  getSiteId: () => HOSTING_SITE_ID.value(),
});

export * from './superAdminCallables';
export { superAdminPurgePlatformData } from './superAdminPlatformPurge';
export { lookupUserByEmail, runPhase2Migrations } from './lookupMigrations';
export {
  superAdminGetHostingCustomDomainStatus,
  superAdminProvisionHostingCustomDomain,
  superAdminRemoveHostingCustomDomain,
} from '@sfc/functions-shared/hosting/hostingCustomDomains';

export { enableStripeConnectAdmin } from './enableStripeConnectAdmin';

export { getStripePublishableKey } from './getStripePublishableKey';

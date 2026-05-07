import { ensureFirebaseAdminApp, ensureSentryForFunctions } from '@sfc/functions-shared/init';

ensureFirebaseAdminApp();
ensureSentryForFunctions();

import {
  registerHostingConfigProvider,
  registerSendgridMailConfigProvider,
  registerStripeKeysProvider,
} from '@sfc/functions-shared';

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
export { lookupUserByEmail, runPhase2Migrations } from './lookupMigrations';
export { diagnosticFixOwnership } from './diagnostic_fix_ownership';
export {
  superAdminGetHostingCustomDomainStatus,
  superAdminProvisionHostingCustomDomain,
} from '@sfc/functions-shared/hosting/hostingCustomDomains';

export { enableStripeConnectAdmin } from './enableStripeConnectAdmin';

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

export {
  syncPublicFacilityMapInventoryOnTenantWrite,
  syncPublicFacilityMapInventoryOnUnitWrite,
} from './publicFacilityMapInventorySync';
export { getPublicWebsiteConfig, renderPublicWebsite, routeCustomDomainRoot, robotsTxt, sitemapXml } from './publicWebsite';
export {
  getPublicReservationByToken,
  createPublicReservationHold,
  transitionPublicReservationStatus,
  createPublicMoveInCheckout,
  confirmPublicMoveInCheckout,
  completePublicMoveIn,
} from './publicMoveIn';
export {
  createPublicPaymentLink,
  getPublicPaymentLink,
  createPublicPaymentCheckout,
} from './publicPaymentCheckout';
export { migratePublicWebsiteTemplateV4OptionalFields } from './migratePublicWebsiteTemplate';
export { redirectToCustomDomain } from './redirectToCustomDomain';

import { ensureFirebaseAdminApp, ensureSentryForFunctions } from '@sfc/functions-shared/init';

ensureFirebaseAdminApp();
ensureSentryForFunctions();

import { defineString } from 'firebase-functions/params';
import { registerHostingConfigProvider, registerStripeKeysProvider } from '@sfc/functions-shared';
import { STRIPE_PUBLISHABLE_KEY, STRIPE_SECRET_KEY } from './secrets';

registerStripeKeysProvider({
  getSecretKey: () => STRIPE_SECRET_KEY.value(),
  getPublishableKey: () => STRIPE_PUBLISHABLE_KEY.value(),
});

const HOSTING_PROJECT_ID = defineString('HOSTING_PROJECT_ID', { default: 'storage-facility-creator' });
const HOSTING_SITE_ID = defineString('HOSTING_SITE_ID', { default: 'storage-facility-creator' });
registerHostingConfigProvider({
  getProjectId: () => HOSTING_PROJECT_ID.value(),
  getSiteId: () => HOSTING_SITE_ID.value(),
});

export {
  quickBooksOAuthCallback,
  getQuickBooksConnectionStatus,
  getQuickBooksConnectUrl,
  completeQuickBooksConnect,
  disconnectQuickBooks,
  syncInvoiceToQuickBooks,
  syncPaymentToQuickBooks,
  setQuickBooksAutoSync,
} from './quickbooksHttpsFunctions';

export { reconcileStripePayment } from './reconcileStripePayment';
export { reconcileAccountFacilityIds } from './reconcileAccountFacilityIds';
export { stripeWebhook } from './stripeWebhook';
export {
  createCheckoutSession,
  createSubscriptionCheckout,
  startTrial,
  createCustomerPortalSession,
  cancelSubscription,
  createFacilitySubscriptionCheckout,
  cancelFacilitySubscription,
  updateSubscriptionQuantity,
  getSubscriptionStatus,
} from './stripePlatformSubscriptions';

export * from './stripeFacilityCallables';

export { autoSyncInvoiceToQuickBooks, autoSyncPaymentToQuickBooks } from './quickbooksFirestoreTriggers';

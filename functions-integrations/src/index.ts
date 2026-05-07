import { ensureFirebaseAdminApp, ensureSentryForFunctions } from '@sfc/functions-shared/init';

ensureFirebaseAdminApp();
ensureSentryForFunctions();

import { registerStripeKeysProvider } from '@sfc/functions-shared';
import { STRIPE_PUBLISHABLE_KEY, STRIPE_SECRET_KEY } from './secrets';

registerStripeKeysProvider({
  getSecretKey: () => STRIPE_SECRET_KEY.value(),
  getPublishableKey: () => STRIPE_PUBLISHABLE_KEY.value(),
});

import * as functions from 'firebase-functions/v1';
import { enforceAppCheckOrThrow } from '@sfc/functions-shared';
import * as quickBooksAccounting from './accounting/quickbooks';
import { getPublicAppUrl } from './publicApp';
import {
  QUICKBOOKS_SECRETS,
  QUICKBOOKS_VPC_CONNECTOR,
  getQuickBooksConfig,
} from './secrets';

/**
 * HTTP callback target for Intuit OAuth.
 * Redirects into the Flutter hash route while preserving OAuth params.
 */
export const quickBooksOAuthCallback = functions.https.onRequest((req, res) => {
  const code = typeof req.query.code === 'string' ? req.query.code.trim() : '';
  const realmId = typeof req.query.realmId === 'string' ? req.query.realmId.trim() : '';
  const state = typeof req.query.state === 'string' ? req.query.state.trim() : '';
  const error = typeof req.query.error === 'string' ? req.query.error.trim() : '';

  const params = new URLSearchParams();
  params.set('tab', 'accounting');
  if (code) params.set('code', code);
  if (realmId) params.set('realmId', realmId);
  if (state) params.set('state', state);
  if (error) params.set('error', error);

  const redirectUrl = `${getPublicAppUrl()}/#/subscription?${params.toString()}`;
  res.set('Cache-Control', 'no-store');
  res.redirect(302, redirectUrl);
});

export const getQuickBooksConnectionStatus = functions.https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
  return quickBooksAccounting.getQuickBooksConnectionStatus(data, context, getQuickBooksConfig());
});

export const getQuickBooksConnectUrl = functions.runWith({ secrets: QUICKBOOKS_SECRETS }).https.onCall(
  async (data: any, context) => {
    enforceAppCheckOrThrow(context);
    return quickBooksAccounting.getQuickBooksConnectUrl(data, context, getQuickBooksConfig());
  },
);

export const completeQuickBooksConnect = functions
  .runWith({ secrets: QUICKBOOKS_SECRETS, ...QUICKBOOKS_VPC_CONNECTOR })
  .https.onCall(async (data: any, context) => {
    enforceAppCheckOrThrow(context);
    return quickBooksAccounting.completeQuickBooksConnect(data, context, getQuickBooksConfig());
  });

export const disconnectQuickBooks = functions.https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
  return quickBooksAccounting.disconnectQuickBooks(data, context);
});

export const syncInvoiceToQuickBooks = functions
  .runWith({ secrets: QUICKBOOKS_SECRETS, ...QUICKBOOKS_VPC_CONNECTOR })
  .https.onCall(async (data: any, context) => {
    enforceAppCheckOrThrow(context);
    return quickBooksAccounting.syncInvoiceToQuickBooks(data, context, getQuickBooksConfig());
  });

export const syncPaymentToQuickBooks = functions
  .runWith({ secrets: QUICKBOOKS_SECRETS, ...QUICKBOOKS_VPC_CONNECTOR })
  .https.onCall(async (data: any, context) => {
    enforceAppCheckOrThrow(context);
    return quickBooksAccounting.syncPaymentToQuickBooks(data, context, getQuickBooksConfig());
  });

export const setQuickBooksAutoSync = functions.https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
  return quickBooksAccounting.setQuickBooksAutoSync(data, context);
});

export { reconcileStripePayment } from './reconcileStripePayment';
export { reconcileAccountFacilityIds } from './reconcileAccountFacilityIds';

export const autoSyncInvoiceToQuickBooks = functions
  .runWith({
    secrets: QUICKBOOKS_SECRETS,
    timeoutSeconds: 120,
    memory: '256MB',
    ...QUICKBOOKS_VPC_CONNECTOR,
  })
  .firestore.document('facilities/{facilityId}/invoices/{invoiceId}')
  .onWrite(async (change, context) => {
    if (!change.after.exists) return;

    const afterData = (change.after.data() || {}) as Record<string, unknown>;
    const beforeData = (change.before.data() || {}) as Record<string, unknown>;
    const afterQuickbooks = (afterData.quickbooks || {}) as Record<string, unknown>;

    if (typeof afterQuickbooks.invoiceId === 'string' && String(afterQuickbooks.invoiceId).trim() !== '') return;

    const status = String(afterData.status || '').toLowerCase();
    if (status === '' || status === 'draft' || status === 'voided') return;

    const beforeStatus = String(beforeData.status || '').toLowerCase();
    const beforeQuickbooks = (beforeData.quickbooks || {}) as Record<string, unknown>;
    const hadQboInvoiceId =
      typeof beforeQuickbooks.invoiceId === 'string' && String(beforeQuickbooks.invoiceId).trim() !== '';
    const statusChanged = beforeStatus !== status;
    const createdNow = !change.before.exists;
    const lineItemsChanged =
      JSON.stringify(beforeData.lineItems || []) !== JSON.stringify(afterData.lineItems || []);
    const totalChanged = Number(beforeData.total || 0) !== Number(afterData.total || 0);

    if (!createdNow && !statusChanged && !lineItemsChanged && !totalChanged && !hadQboInvoiceId) return;

    const facilityId = context.params.facilityId as string;
    const invoiceId = context.params.invoiceId as string;
    await quickBooksAccounting.autoSyncInvoiceIfEligible(facilityId, invoiceId, getQuickBooksConfig());
  });

export const autoSyncPaymentToQuickBooks = functions
  .runWith({
    secrets: QUICKBOOKS_SECRETS,
    timeoutSeconds: 120,
    memory: '256MB',
    ...QUICKBOOKS_VPC_CONNECTOR,
  })
  .firestore.document('facilities/{facilityId}/payments/{paymentId}')
  .onWrite(async (change, context) => {
    if (!change.after.exists) return;

    const afterData = (change.after.data() || {}) as Record<string, unknown>;
    const beforeData = (change.before.data() || {}) as Record<string, unknown>;
    const afterQuickbooks = (afterData.quickbooks || {}) as Record<string, unknown>;

    if (typeof afterQuickbooks.paymentId === 'string' && String(afterQuickbooks.paymentId).trim() !== '') return;

    const status = String(afterData.status || '').toLowerCase();
    const isPaidStatus = status === 'paid' || status === 'completed';
    if (!isPaidStatus) return;

    const beforeStatus = String(beforeData.status || '').toLowerCase();
    const becamePaid = beforeStatus !== 'paid' && beforeStatus !== 'completed';
    if (!change.before.exists || becamePaid) {
      const facilityId = context.params.facilityId as string;
      const paymentId = context.params.paymentId as string;
      await quickBooksAccounting.autoSyncPaymentIfEligible(facilityId, paymentId, getQuickBooksConfig());
    }
  });

import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import { getStripeClient } from '@sfc/functions-shared';
import {
  invoiceSubscriptionId,
  isWebsiteAddonSubscription,
  updateFacilityFromWebsiteSubscription,
} from './stripeWebhookSubscriptionInternal';

export async function handleInvoicePaymentFailed(invoice: Stripe.Invoice) {
  const subscriptionId = invoiceSubscriptionId(invoice);
  if (!subscriptionId) {
    return;
  }

  const stripe = getStripeClient();
  const subscription = await stripe.subscriptions.retrieve(subscriptionId);
  const accountId = subscription.metadata?.accountId;
  const facilityId = subscription.metadata?.facilityId;
  const tenantId = subscription.metadata?.tenantId;
  const lastError = invoice.last_finalization_error;
  const failureCode = lastError?.code || null;
  const failureMessage = lastError?.message || null;

  if (facilityId && isWebsiteAddonSubscription(subscription)) {
    await updateFacilityFromWebsiteSubscription(facilityId, subscription);
    functions.logger.info(`Facility ${facilityId} website add-on payment failed`);
    return;
  }

  if (facilityId && !tenantId) {
    await admin.firestore().collection('facilities').doc(facilityId).update({
      platformSubscriptionStatus: 'past_due',
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    functions.logger.info(`Facility ${facilityId} platform payment failed`);
    return;
  }
  if (accountId) {
    await admin.firestore().collection('facilityCreatorAccounts').doc(accountId).update({
      subscriptionStatus: 'past_due',
      subscriptionLastPaymentFailed: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    functions.logger.info(`Payment failed for account: ${accountId}`);
  }

  if (facilityId && tenantId) {
    const billingRef = admin
      .firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId)
      .collection('billing')
      .doc('default');
    await billingRef.set(
      {
        lastPaymentStatus: 'failed',
        lastPaymentAt: admin.firestore.FieldValue.serverTimestamp(),
        lastFailureCode: failureCode,
        lastFailureMessage: failureMessage,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    await admin
      .firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId)
      .collection('payments')
      .add({
        type: 'invoice',
        amountCents: invoice.amount_due || 0,
        currency: 'usd',
        stripeObjectId: invoice.id,
        status: 'failed',
        failureCode,
        failureMessage,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    functions.logger.info(`Tenant autopay invoice failed: ${invoice.id} for tenant ${tenantId}`);
  }
}

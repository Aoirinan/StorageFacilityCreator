import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import { getStripeClient, processReferralOnPlatformInvoicePaid } from '@sfc/functions-shared';
import {
  invoiceSubscriptionId,
  subPeriodEnd,
  updateAccountFromSubscription,
  updateFacilityFromPlatformSubscription,
} from './stripeWebhookSubscriptionInternal';

export async function handleInvoicePaymentSucceeded(invoice: Stripe.Invoice) {
  const subscriptionId = invoiceSubscriptionId(invoice);
  if (!subscriptionId) {
    return;
  }

  const stripe = getStripeClient();
  const subscription = await stripe.subscriptions.retrieve(subscriptionId);
  const accountId = subscription.metadata?.accountId;
  const facilityId = subscription.metadata?.facilityId;
  const tenantId = subscription.metadata?.tenantId;

  if (facilityId && !tenantId) {
    await updateFacilityFromPlatformSubscription(facilityId, subscriptionId);
    functions.logger.info(`Facility ${facilityId} platform payment succeeded`);
    try {
      await processReferralOnPlatformInvoicePaid(getStripeClient(), invoice, subscription, facilityId);
    } catch (referralErr: any) {
      functions.logger.error('Referral reward processing failed', referralErr);
    }
    return;
  }
  if (accountId) {
    await updateAccountFromSubscription(accountId, subscriptionId);
    functions.logger.info(`Payment succeeded for account: ${accountId}`);
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
    const periodEnd = subPeriodEnd(subscription);
    const nextDue = periodEnd ? admin.firestore.Timestamp.fromDate(new Date(periodEnd * 1000)) : null;
    await billingRef.set(
      {
        lastPaymentStatus: 'succeeded',
        lastPaymentAt: admin.firestore.FieldValue.serverTimestamp(),
        lastFailureCode: null,
        lastFailureMessage: null,
        nextDueAt: nextDue,
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
        amountCents: invoice.amount_paid || 0,
        currency: 'usd',
        stripeObjectId: invoice.id,
        status: 'succeeded',
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    functions.logger.info(`Tenant autopay invoice succeeded: ${invoice.id} for tenant ${tenantId}`);
  }
}

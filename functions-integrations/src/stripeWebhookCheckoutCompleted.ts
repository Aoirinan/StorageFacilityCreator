import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import {
  completePublicLinkPayment,
  getStripeClient,
  isPublicLinkCheckoutSession,
} from '@sfc/functions-shared';
import {
  updateAccountFromSubscription,
  updateFacilityFromPlatformSubscription,
  updateFacilityFromWebsiteSubscription,
} from './stripeWebhookSubscriptionInternal';
import { reconcileAccountSubscription } from './accountSubscriptionReconcile';

/**
 * [connectedAccountId] is the event's `account`: set when the session lives
 * on a facility's connected account (public payment links), absent for the
 * platform's own subscription checkouts.
 */
export async function handleCheckoutCompleted(
  session: Stripe.Checkout.Session,
  connectedAccountId?: string,
) {
  // Public payment links are tenant payments on the facility's connected
  // account and carry no accountId, so the subscription path below dropped
  // them with "No accountId" and the link stayed pending forever. The money
  // itself is recorded by payment_intent.succeeded; this marks the link paid
  // (or raises an exception for staff). No try/catch: a failure returns 500
  // and Stripe redelivers, instead of the event being marked processed.
  if (isPublicLinkCheckoutSession(session)) {
    const result = await completePublicLinkPayment({
      db: admin.firestore(),
      session,
      connectedAccountId,
      source: 'webhook',
    });
    const details = { sessionId: session.id, connectedAccountId: connectedAccountId || null, ...result };
    if (result.outcome === 'rejected') {
      functions.logger.error('Public payment link checkout rejected', details);
    } else {
      functions.logger.info('Public payment link checkout completed', details);
    }
    return;
  }

  const accountId = session.metadata?.accountId;
  const facilityId = session.metadata?.facilityId;
  if (!accountId) {
    functions.logger.error('No accountId in checkout session metadata');
    return;
  }

  const subscriptionId = session.subscription as string;
  if (!subscriptionId) {
    functions.logger.error('No subscription ID in checkout session');
    return;
  }

  if (facilityId && session.metadata?.subscriptionType === 'website_addon') {
    const subscription = await getStripeClient().subscriptions.retrieve(subscriptionId);
    await updateFacilityFromWebsiteSubscription(facilityId, subscription);
    return;
  }

  if (facilityId) {
    await updateFacilityFromPlatformSubscription(facilityId, subscriptionId);
    const accountDoc = await admin.firestore().collection('facilityCreatorAccounts').doc(accountId).get();
    if (accountDoc.exists) {
      const facilityIds = (accountDoc.data()?.facilityIds as string[]) || [];
      if (!facilityIds.includes(facilityId)) {
        await admin.firestore().collection('facilityCreatorAccounts').doc(accountId).update({
          facilityIds: admin.firestore.FieldValue.arrayUnion(facilityId),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
    }
    // Roll the new facility subscription up to the account, which this branch
    // previously skipped entirely.
    await reconcileAccountSubscription(accountId);
    return;
  }

  await updateAccountFromSubscription(accountId, subscriptionId);
}

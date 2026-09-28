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
import { recordStripeEventRefusal, refusalReasonFor } from './connectedAccountGuard';

/**
 * [connectedAccountId] is the event's `account`: set when the session lives
 * on a facility's connected account (public payment links), absent for the
 * platform's own subscription checkouts.
 */
export async function handleCheckoutCompleted(
  session: Stripe.Checkout.Session,
  connectedAccountId?: string,
  eventId?: string,
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
      // Refused for good, like the other connected-account checks: record it
      // where a super admin will see it.
      if (result.rejectReason === 'account_mismatch' && connectedAccountId) {
        const facilityId = session.metadata?.facilityId || '';
        const facilitySnap = facilityId
          ? await admin.firestore().collection('facilities').doc(facilityId).get()
          : null;
        const facilityData = (facilitySnap?.exists ? facilitySnap.data() : {}) as Record<string, unknown>;
        const facilityAccount =
          typeof facilityData.stripeConnectAccountId === 'string' ? facilityData.stripeConnectAccountId : null;
        await recordStripeEventRefusal({
          reason: refusalReasonFor(facilityData, connectedAccountId),
          facilityId,
          facilityExists: !!facilitySnap?.exists,
          facilityAccount,
          connectedAccountId,
          eventType: 'checkout.session.completed',
          objectId: session.id,
          eventId,
          tenantId: session.metadata?.tenantId ?? null,
          amount: typeof session.amount_total === 'number' ? session.amount_total / 100 : null,
        });
      }
    } else {
      functions.logger.info('Public payment link checkout completed', details);
    }
    return;
  }

  // Owner subscription checkouts live on the platform account. One from a
  // connected account carries whatever metadata its owner wrote (accountId,
  // facilityId), and this path adds that facility to that owner account.
  if (connectedAccountId) {
    // Tenant portal payments, online move-ins and tenant payment checkouts
    // also complete on connected accounts, and are recorded elsewhere (their
    // payment_intent.succeeded, the move-in flow). Only one that looks like
    // an owner subscription is worth an error: at error level, every tenant
    // payment raised an alert once the Connect endpoint sent these.
    const looksLikeSubscription = session.mode === 'subscription' || !!session.metadata?.accountId;
    const log = looksLikeSubscription ? functions.logger.error : functions.logger.info;
    log(
      looksLikeSubscription
        ? 'Subscription checkout from a connected account ignored'
        : 'Connected-account checkout left to its own handler',
      { sessionId: session.id, connectedAccountId, mode: session.mode ?? null },
    );
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

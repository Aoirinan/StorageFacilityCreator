import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import {
  completePublicLinkPayment,
  FIRST_MONTH_FREE_COUPON_ID,
  FIRST_MONTH_FREE_METADATA_KEY,
  getStripeClient,
  isPublicLinkCheckoutSession,
} from '@sfc/functions-shared';
import {
  recordPlatformOfferUsage,
  updateAccountFromSubscription,
  updateFacilityFromPlatformSubscription,
  updateFacilityFromWebsiteSubscription,
} from './stripeWebhookSubscriptionInternal';
import { reconcileAccountSubscription } from './accountSubscriptionReconcile';
import { recordStripeEventRefusal, refusalReasonFor } from './connectedAccountGuard';

/**
 * Did this completed platform checkout carry the owner's free month? Read from the
 * `firstMonthFree` metadata flag checkout sets, or, for sessions created before the free
 * month became trial time, the retired first-month-free coupon in the session's
 * discounts (coupon id or expanded coupon). The trial marker comes from the subscription
 * itself (see updateAccountFromSubscription).
 */
export function platformOfferUsageFromCheckoutSession(session: Stripe.Checkout.Session): {
  trialUsed: boolean;
  firstMonthFreeUsed: boolean;
} {
  const discountHasLegacyCoupon = (session.discounts ?? []).some((d) => {
    const coupon = d?.coupon;
    const id = typeof coupon === 'string' ? coupon : coupon?.id;
    return id === FIRST_MONTH_FREE_COUPON_ID;
  });
  return {
    trialUsed: false,
    firstMonthFreeUsed: discountHasLegacyCoupon || session.metadata?.[FIRST_MONTH_FREE_METADATA_KEY] === 'true',
  };
}

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

  // A completed platform checkout that carried the free month has used the owner's one free month.
  // The subscription events record the same thing from the subscription's metadata, so
  // a failure here is logged rather than failing (and replaying) the whole event.
  try {
    await recordPlatformOfferUsage(admin.firestore(), accountId, platformOfferUsageFromCheckoutSession(session));
  } catch (err: unknown) {
    functions.logger.error('Could not record first-month-free usage from checkout', { accountId, err });
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

import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import {
  getStripeClient,
  getOrCreateBasePriceId,
  getOrCreateFirstMonthFreeCouponId,
  getRefereePlatformTrialDays,
  decidePlatformCheckoutTrial,
  platformCheckoutTrialSubscriptionData,
  type PlatformCheckoutTrialDecision,
} from '@sfc/functions-shared';

export type FacilitySubscriptionCheckoutInput = {
  accountId: string;
  facilityId: string;
  customerEmail: string;
  successUrl?: string;
  cancelUrl?: string;
};

/**
 * Pure: the Checkout Session params for one facility's platform subscription.
 * The trial comes from `decidePlatformCheckoutTrial`; the first-month-free coupon is
 * always attached.
 */
export function buildFacilitySubscriptionCheckoutParams(options: {
  accountId: string;
  facilityId: string;
  customerId: string;
  basePriceId: string;
  firstMonthFreeCouponId: string;
  trial: PlatformCheckoutTrialDecision;
  ownerUid: string;
  successUrl?: string;
  cancelUrl?: string;
}): Stripe.Checkout.SessionCreateParams {
  const { accountId, facilityId, customerId, basePriceId, firstMonthFreeCouponId, trial, ownerUid, successUrl, cancelUrl } =
    options;
  return {
    customer: customerId,
    mode: 'subscription',
    line_items: [{ price: basePriceId, quantity: 1 }],
    discounts: [{ coupon: firstMonthFreeCouponId }],
    success_url:
      successUrl || `https://app.storagefacilitycreator.com/subscription/success?session_id={CHECKOUT_SESSION_ID}&facility_id=${facilityId}`,
    cancel_url: cancelUrl || `https://app.storagefacilitycreator.com/subscription/cancel?facility_id=${facilityId}`,
    metadata: { accountId, facilityId, ownerUid },
    subscription_data: {
      ...platformCheckoutTrialSubscriptionData(trial),
      metadata: { accountId, facilityId, trialDecision: trial.kind },
    },
  };
}

/**
 * Core flow for single-facility platform subscription checkout (after auth, App Check, and required fields).
 */
export async function executeCreateFacilitySubscriptionCheckout(
  input: FacilitySubscriptionCheckoutInput,
  context: functions.https.CallableContext,
): Promise<{ subscriptionUpdated: boolean; checkoutUrl: null; message: string } | { checkoutUrl: string | null; sessionId: string }> {
  const { accountId, facilityId, customerEmail, successUrl, cancelUrl } = input;

  try {
    const db = admin.firestore();
    const [accountDoc, facilityDoc] = await Promise.all([
      db.collection('facilityCreatorAccounts').doc(accountId).get(),
      db.collection('facilities').doc(facilityId).get(),
    ]);
    if (!accountDoc.exists || !facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Account or facility not found');
    }
    const accountData = accountDoc.data()!;
    const facilityData = facilityDoc.data()!;
    if (accountData.ownerUid !== context.auth!.uid || facilityData.ownerUid !== context.auth!.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }
    if ((facilityData.facilityCreatorAccountId as string) !== accountId) {
      throw new functions.https.HttpsError('failed-precondition', 'Facility must be linked to this account first');
    }

    const facilityPlatformSubId = facilityData.stripePlatformSubscriptionId as string | undefined;
    const platformStatus = (facilityData.platformSubscriptionStatus as string) || '';
    if (facilityPlatformSubId && (platformStatus === 'active' || platformStatus === 'trialing')) {
      return {
        subscriptionUpdated: true,
        checkoutUrl: null,
        message: 'This facility already has an active subscription.',
      };
    }

    const stripe = getStripeClient();
    let customerId = accountData.stripeCustomerId as string | undefined;
    if (!customerId) {
      const customer = await stripe.customers.create({
        email: customerEmail,
        metadata: { accountId, ownerUid: context.auth!.uid },
      });
      customerId = customer.id;
      await db.collection('facilityCreatorAccounts').doc(accountId).update({
        stripeCustomerId: customerId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    const basePriceId = process.env.STRIPE_BASE_PRICE_ID || (await getOrCreateBasePriceId(stripe));
    // Public offer: 30-day trial, then the first paid month is free (two months in total).
    // The trial is the account's app trial when one is running, none when it is over,
    // and the usual (referral-aware) length only when there never was one.
    const trial = decidePlatformCheckoutTrial({
      accountSubscriptionStatus: accountData.subscriptionStatus as string | undefined,
      accountTrialEnd: accountData.subscriptionTrialEnd,
      accountHasStripeSubscription: !!(accountData.stripeSubscriptionId as string | undefined),
      defaultTrialDays: getRefereePlatformTrialDays(facilityDoc),
      nowMs: Date.now(),
    });
    functions.logger.info('Facility subscription checkout trial', {
      accountId,
      facilityId,
      trialDecision: trial.kind,
      trialReason: trial.reason,
    });
    const firstMonthFreeCouponId = await getOrCreateFirstMonthFreeCouponId(stripe);
    const session = await stripe.checkout.sessions.create(
      buildFacilitySubscriptionCheckoutParams({
        accountId,
        facilityId,
        customerId,
        basePriceId,
        firstMonthFreeCouponId,
        trial,
        ownerUid: context.auth!.uid,
        successUrl,
        cancelUrl,
      }),
    );

    return { checkoutUrl: session.url, sessionId: session.id };
  } catch (error: any) {
    if (error instanceof functions.https.HttpsError) throw error;
    functions.logger.error('Error creating facility subscription checkout', error);
    throw new functions.https.HttpsError('internal', `Failed: ${error.message}`);
  }
}

import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import {
  getOrCreateBasePriceId,
  getRefereePlatformTrialDays,
  platformCheckoutOfferMetadata,
  platformCheckoutTrialSubscriptionData,
  type PlatformCheckoutTrialDecision,
} from '@sfc/functions-shared';
import {
  decideOfferForAccount,
  resolvePlatformCheckoutDeps,
  type PlatformCheckoutDeps,
} from './platformCheckoutOfferContext';

export type FacilitySubscriptionCheckoutInput = {
  accountId: string;
  facilityId: string;
  customerEmail: string;
  successUrl?: string;
  cancelUrl?: string;
};

/**
 * Pure: the Checkout Session params for one facility's platform subscription.
 * The trial comes from `decidePlatformCheckoutOffer`. The free month is trial time
 * (`trial_end`); no coupon or discount is sent.
 */
export function buildFacilitySubscriptionCheckoutParams(options: {
  accountId: string;
  facilityId: string;
  customerId: string;
  basePriceId: string;
  trial: PlatformCheckoutTrialDecision;
  ownerUid: string;
  successUrl?: string;
  cancelUrl?: string;
}): Stripe.Checkout.SessionCreateParams {
  const { accountId, facilityId, customerId, basePriceId, trial, ownerUid, successUrl, cancelUrl } = options;
  const offerMetadata = platformCheckoutOfferMetadata(trial);
  return {
    customer: customerId,
    mode: 'subscription',
    line_items: [{ price: basePriceId, quantity: 1 }],
    success_url:
      successUrl || `https://app.storagefacilitycreator.com/subscription/success?session_id={CHECKOUT_SESSION_ID}&facility_id=${facilityId}`,
    cancel_url: cancelUrl || `https://app.storagefacilitycreator.com/subscription/cancel?facility_id=${facilityId}`,
    metadata: { accountId, facilityId, ownerUid, ...offerMetadata },
    subscription_data: {
      ...platformCheckoutTrialSubscriptionData(trial),
      metadata: { accountId, facilityId, ...offerMetadata },
    },
  };
}

/**
 * Core flow for single-facility platform subscription checkout (after auth, App Check, and required fields).
 * `deps` is for tests; the callable passes nothing.
 */
export async function executeCreateFacilitySubscriptionCheckout(
  input: FacilitySubscriptionCheckoutInput,
  context: functions.https.CallableContext,
  deps?: Partial<PlatformCheckoutDeps>,
): Promise<{ subscriptionUpdated: boolean; checkoutUrl: null; message: string } | { checkoutUrl: string | null; sessionId: string }> {
  const { accountId, facilityId, customerEmail, successUrl, cancelUrl } = input;

  try {
    const { db, stripe, nowMs } = resolvePlatformCheckoutDeps(deps);
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
    // Public offer: 30-day trial, then the first month free, once per owner ever. The
    // free month is extra trial time after the owner's trial. Judged on the account,
    // every facility it owns, and this facility's own record (`platformSubscriptionTrialEnd`
    // and friends). The referral days apply only to an owner with no trial record at all.
    const offer = await decideOfferForAccount({
      db,
      accountId,
      account: accountData,
      extraFacility: facilityData,
      defaultTrialDays: getRefereePlatformTrialDays(facilityDoc),
      nowMs: nowMs(),
    });
    functions.logger.info('Facility subscription checkout offer', {
      accountId,
      facilityId,
      trialDecision: offer.trial.kind,
      trialReason: offer.trial.reason,
      firstMonthFree: offer.firstMonthFree,
      historyReasons: offer.history.reasons,
    });
    const session = await stripe.checkout.sessions.create(
      buildFacilitySubscriptionCheckoutParams({
        accountId,
        facilityId,
        customerId,
        basePriceId,
        trial: offer.trial,
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

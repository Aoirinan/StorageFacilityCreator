import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import {
  getOrCreateBasePriceId,
  getOrCreateAddOnPriceId,
  DEFAULT_PLATFORM_TRIAL_DAYS,
  writeAuditLog,
} from '@sfc/functions-shared';
import { tryUpdateExistingSubscriptionInsteadOfCheckout } from './stripePlatformSubscriptionCheckoutUpdateExisting';
import { createSubscriptionCheckoutSessionAndAudit } from './stripePlatformSubscriptionCheckoutSessionCreate';
import {
  decideOfferForAccount,
  resolvePlatformCheckoutDeps,
  type PlatformCheckoutDeps,
} from './platformCheckoutOfferContext';

/**
 * Core flow for account-level subscription checkout (after auth, App Check, rate limit, and required fields).
 * `deps` is for tests; the callable passes nothing.
 */
export async function executeCreateSubscriptionCheckout(
  data: { accountId: string; customerEmail: string; successUrl?: string; cancelUrl?: string },
  context: functions.https.CallableContext,
  deps?: Partial<PlatformCheckoutDeps>,
): Promise<unknown> {
  const { accountId, customerEmail, successUrl, cancelUrl } = data;
  let auditLog = deps?.auditLog;

  try {
    const { db, stripe, auditLog: resolvedAuditLog, nowMs } = resolvePlatformCheckoutDeps(deps);
    auditLog = resolvedAuditLog;
    const accountRef = db.collection('facilityCreatorAccounts').doc(accountId);
    const accountDoc = await accountRef.get();

    if (!accountDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Account not found');
    }

    const accountData = accountDoc.data()!;
    if (accountData.ownerUid !== context.auth!.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }

    let customerId = accountData.stripeCustomerId as string | undefined;
    if (!customerId) {
      const customer = await stripe.customers.create({
        email: customerEmail,
        metadata: {
          accountId: accountId,
          ownerUid: context.auth!.uid,
        },
      });
      customerId = customer.id;

      await accountRef.update({
        stripeCustomerId: customerId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    const facilityIds = (accountData.facilityIds as string[]) || [];
    const facilityCount = facilityIds.length;
    const additionalFacilityCount = Math.max(0, facilityCount - 1);

    let basePriceId: string;
    let addOnPriceId: string;
    try {
      basePriceId = process.env.STRIPE_BASE_PRICE_ID || (await getOrCreateBasePriceId(stripe));
      addOnPriceId = process.env.STRIPE_ADDON_PRICE_ID || (await getOrCreateAddOnPriceId(stripe));
      functions.logger.info(`Using price IDs - Base: ${basePriceId}, Add-on: ${addOnPriceId}`);
    } catch (priceError: any) {
      functions.logger.error('Error getting/creating price IDs', {
        error: priceError.message,
        stack: priceError.stack,
        accountId,
      });
      throw new functions.https.HttpsError('internal', `Failed to get pricing: ${priceError.message}`);
    }

    const subscriptionStatus = (accountData.subscriptionStatus as string) || '';
    let subscriptionId = accountData.stripeSubscriptionId as string | undefined;

    if (!subscriptionId && customerId && (subscriptionStatus === 'trialing' || subscriptionStatus === 'active')) {
      const subs = await stripe.subscriptions.list({
        customer: customerId,
        status: 'all',
        limit: 10,
      });
      const activeOrTrialing = subs.data.find((s) => s.status === 'active' || s.status === 'trialing');
      if (activeOrTrialing) {
        subscriptionId = activeOrTrialing.id;
        functions.logger.info('Resolved missing stripeSubscriptionId from customer subscriptions', {
          accountId,
          subscriptionId,
        });
        await accountRef.update({
          stripeSubscriptionId: subscriptionId,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
    }

    const updatedInstead = await tryUpdateExistingSubscriptionInsteadOfCheckout({
      stripe,
      accountId,
      subscriptionId,
      subscriptionStatus,
      facilityCount,
      basePriceId,
      addOnPriceId,
      uid: context.auth!.uid,
      db,
      auditLog,
    });
    if (updatedInstead) {
      return updatedInstead;
    }

    // One trial and one free month per owner, ever. An unused free month is extra trial
    // time after the owner's trial; once it is used, only the rest of a running app
    // trial is left, and nothing fresh is ever given again.
    const offer = await decideOfferForAccount({
      db,
      accountId,
      account: { ...accountData, stripeSubscriptionId: subscriptionId ?? accountData.stripeSubscriptionId },
      defaultTrialDays: DEFAULT_PLATFORM_TRIAL_DAYS,
      nowMs: nowMs(),
    });
    functions.logger.info('Account subscription checkout offer', {
      accountId,
      trialDecision: offer.trial.kind,
      trialReason: offer.trial.reason,
      firstMonthFree: offer.firstMonthFree,
      historyReasons: offer.history.reasons,
    });

    return await createSubscriptionCheckoutSessionAndAudit({
      stripe,
      accountId,
      customerId,
      facilityCount,
      additionalFacilityCount,
      basePriceId,
      addOnPriceId,
      successUrl,
      cancelUrl,
      ownerUid: context.auth!.uid,
      trial: offer.trial,
      auditLog,
    });
  } catch (error: any) {
    const errorMessage = error?.message || 'Unknown error';
    const errorStack = error?.stack || 'No stack trace';

    functions.logger.error('Error creating checkout session', {
      error: errorMessage,
      stack: errorStack,
      accountId,
      userId: context.auth?.uid,
      errorType: error?.constructor?.name,
      errorCode: error?.code,
    });

    await (auditLog ?? writeAuditLog)(accountId, {
      action: 'subscription_checkout_failed',
      userId: context.auth?.uid,
      error: errorMessage,
      errorType: error?.constructor?.name,
    });

    if (error instanceof functions.https.HttpsError) {
      throw error;
    }

    throw new functions.https.HttpsError('internal', `Failed to create checkout: ${errorMessage}`);
  }
}

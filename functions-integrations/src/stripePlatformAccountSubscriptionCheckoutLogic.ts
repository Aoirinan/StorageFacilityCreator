import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import {
  writeAuditLog,
  getStripeClient,
  getOrCreateBasePriceId,
  getOrCreateAddOnPriceId,
} from '@sfc/functions-shared';
import { tryUpdateExistingSubscriptionInsteadOfCheckout } from './stripePlatformSubscriptionCheckoutUpdateExisting';
import { createSubscriptionCheckoutSessionAndAudit } from './stripePlatformSubscriptionCheckoutSessionCreate';

/**
 * Core flow for account-level subscription checkout (after auth, App Check, rate limit, and required fields).
 */
export async function executeCreateSubscriptionCheckout(
  data: { accountId: string; customerEmail: string; successUrl?: string; cancelUrl?: string },
  context: functions.https.CallableContext,
): Promise<unknown> {
  const { accountId, customerEmail, successUrl, cancelUrl } = data;

  try {
    const accountDoc = await admin.firestore().collection('facilityCreatorAccounts').doc(accountId).get();

    if (!accountDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Account not found');
    }

    const accountData = accountDoc.data()!;
    if (accountData.ownerUid !== context.auth!.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }

    const stripe = getStripeClient();

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

      await admin.firestore().collection('facilityCreatorAccounts').doc(accountId).update({
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
        await admin.firestore().collection('facilityCreatorAccounts').doc(accountId).update({
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
    });
    if (updatedInstead) {
      return updatedInstead;
    }

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

    await writeAuditLog(accountId, {
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

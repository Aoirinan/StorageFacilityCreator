import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import {
  enforceAppCheckOrThrow,
  getStripeClient,
} from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';

/**
 * Create Stripe Customer Portal session for managing subscription
 */
export const createCustomerPortalSession = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { accountId, returnUrl } = data;

  if (!accountId) {
    throw new functions.https.HttpsError('invalid-argument', 'accountId is required');
  }

  try {
    const accountDoc = await admin.firestore().collection('facilityCreatorAccounts').doc(accountId).get();

    if (!accountDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Account not found');
    }

    const accountData = accountDoc.data()!;
    if (accountData.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }

    const customerId = accountData.stripeCustomerId as string | undefined;
    if (!customerId) {
      throw new functions.https.HttpsError('failed-precondition', 'No Stripe customer found. Please subscribe first.');
    }

    const stripe = getStripeClient();

    const session = await stripe.billingPortal.sessions.create({
      customer: customerId,
      return_url: returnUrl || 'https://www.storagefacilitycreator.com/subscription/manage',
    });

    return {
      portalUrl: session.url,
    };
  } catch (error: any) {
    functions.logger.error('Error creating portal session', error);
    throw new functions.https.HttpsError('internal', `Failed to create portal: ${error.message}`);
  }
});

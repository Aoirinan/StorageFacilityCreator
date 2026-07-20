import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import {
  enforceAppCheckOrThrow,
  getStripeClient,
} from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';

const WEBSITE_SUBSCRIPTION_TYPE = 'website_addon';
const WEBSITE_PRICE_LOOKUP_KEY = 'sfc_website_monthly_25';

async function getOrCreateWebsitePriceId(stripe: Stripe): Promise<string> {
  const configuredPriceId = (process.env.STRIPE_WEBSITE_PRICE_ID || '').trim();
  if (configuredPriceId) return configuredPriceId;

  const existing = await stripe.prices.list({
    lookup_keys: [WEBSITE_PRICE_LOOKUP_KEY],
    active: true,
    limit: 1,
  });
  if (existing.data.length > 0) return existing.data[0].id;

  const product = await stripe.products.create({
    name: 'SFC Public Website',
    description: 'Public marketing website and online rentals for one facility',
  });
  const price = await stripe.prices.create({
    product: product.id,
    unit_amount: 2500,
    currency: 'usd',
    recurring: { interval: 'month' },
    lookup_key: WEBSITE_PRICE_LOOKUP_KEY,
  });
  return price.id;
}

/**
 * Starts a separate $25/month website add-on subscription for one facility.
 * Stripe webhooks are the only authority that activates the entitlement.
 */
export const createWebsiteSubscriptionCheckout = functions
  .runWith({
    timeoutSeconds: 60,
    memory: '256MB',
    secrets: STRIPE_SECRETS,
    invoker: 'public',
  })
  .https.onCall(async (data: {
    accountId?: string;
    facilityId?: string;
    customerEmail?: string;
    successUrl?: string;
    cancelUrl?: string;
  }, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }
    enforceAppCheckOrThrow(context);

    const accountId = data?.accountId?.trim();
    const facilityId = data?.facilityId?.trim();
    const customerEmail = data?.customerEmail?.trim();
    if (!accountId || !facilityId || !customerEmail) {
      throw new functions.https.HttpsError(
        'invalid-argument',
        'accountId, facilityId, and customerEmail are required',
      );
    }

    const db = admin.firestore();
    const [accountSnap, facilitySnap] = await Promise.all([
      db.collection('facilityCreatorAccounts').doc(accountId).get(),
      db.collection('facilities').doc(facilityId).get(),
    ]);
    if (!accountSnap.exists || !facilitySnap.exists) {
      throw new functions.https.HttpsError('not-found', 'Account or facility not found');
    }

    const account = accountSnap.data() as Record<string, unknown>;
    const facility = facilitySnap.data() as Record<string, unknown>;
    if (account.ownerUid !== context.auth.uid || facility.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError(
        'permission-denied',
        'Only the facility owner can purchase the website add-on',
      );
    }
    if (facility.facilityCreatorAccountId !== accountId) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Facility is not linked to this account',
      );
    }

    const platformStatus = String(facility.platformSubscriptionStatus || '');
    if (platformStatus !== 'active' && platformStatus !== 'trialing') {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'An active facility subscription is required before adding a website',
      );
    }

    const websiteStatus = String(facility.websiteSubscriptionStatus || '');
    if (
      typeof facility.stripeWebsiteSubscriptionId === 'string' &&
      (websiteStatus === 'active' || websiteStatus === 'trialing')
    ) {
      return {
        subscriptionUpdated: true,
        checkoutUrl: null,
        message: 'This facility already has an active website subscription.',
      };
    }

    try {
      const stripe = getStripeClient();
      let customerId =
        typeof account.stripeCustomerId === 'string' ? account.stripeCustomerId : '';
      if (!customerId) {
        const customer = await stripe.customers.create({
          email: customerEmail,
          metadata: { accountId, ownerUid: context.auth.uid },
        });
        customerId = customer.id;
        await accountSnap.ref.update({
          stripeCustomerId: customerId,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }

      const priceId = await getOrCreateWebsitePriceId(stripe);
      const metadata = {
        accountId,
        facilityId,
        ownerUid: context.auth.uid,
        subscriptionType: WEBSITE_SUBSCRIPTION_TYPE,
      };
      const session = await stripe.checkout.sessions.create({
        customer: customerId,
        mode: 'subscription',
        line_items: [{ price: priceId, quantity: 1 }],
        success_url:
          data.successUrl || 'https://app.storagefacilitycreator.com/#/settings',
        cancel_url:
          data.cancelUrl || 'https://app.storagefacilitycreator.com/#/settings',
        metadata,
        subscription_data: { metadata },
      });

      await facilitySnap.ref.update({
        websiteSubscriptionStatus: 'checkoutPending',
        websiteCheckoutSessionId: session.id,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return { checkoutUrl: session.url, sessionId: session.id };
    } catch (error: unknown) {
      if (error instanceof functions.https.HttpsError) throw error;
      const message = error instanceof Error ? error.message : String(error);
      functions.logger.error('Website subscription checkout failed', {
        accountId,
        facilityId,
        message,
      });
      throw new functions.https.HttpsError(
        'internal',
        'Could not start website subscription checkout. Please try again.',
      );
    }
  });

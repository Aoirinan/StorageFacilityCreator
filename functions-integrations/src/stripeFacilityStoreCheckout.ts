import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { enforceAppCheckOrThrow, getStripeClient } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';
import { isStripeFeatureEnabled } from './stripeFacilityFeatureFlags';

/**
 * Create a one-time PaymentIntent for store checkout (locks/boxes) on connected account
 * Feature-flagged: Requires storeEnabledGlobal OR facilityId in allowlist
 */
export const createStoreCheckout = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId, lineItems, customerEmail, customerName } = data;

  if (!facilityId || !lineItems || !Array.isArray(lineItems) || lineItems.length === 0) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId and lineItems are required');
  }

  // Feature flag check
  const storeEnabled = await isStripeFeatureEnabled('store', facilityId);
  if (!storeEnabled) {
    throw new functions.https.HttpsError('failed-precondition', 'Store checkout is not enabled for this facility');
  }

  try {
    // Verify user has access to this facility
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data();
    const ownerUid = facilityData?.ownerUid;
    const roles = facilityData?.roles || {};
    const connectAccountId = facilityData?.stripeConnectAccountId as string | undefined;

    if (!connectAccountId) {
      throw new functions.https.HttpsError('failed-precondition', 'Facility must have a connected Stripe account');
    }

    // Check if user is owner or has manager role
    if (ownerUid !== context.auth.uid && roles[context.auth.uid] !== 'manager' && roles[context.auth.uid] !== 'owner') {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission');
    }

    const stripe = getStripeClient();

    // Calculate total amount from line items
    let totalAmount = 0;
    lineItems.forEach((item: any) => {
      const amount = Math.round((item.price || 0) * 100); // Convert to cents
      totalAmount += amount;
    });

    // Create PaymentIntent on CONNECTED account
    const paymentIntent = await stripe.paymentIntents.create({
      amount: totalAmount,
      currency: 'usd',
      payment_method_types: ['card'],
      description: `Store purchase - ${facilityData?.name || 'Facility'}`,
      metadata: {
        facilityId,
        chargeType: 'store_checkout',
        userId: context.auth.uid,
        lineItemCount: lineItems.length.toString(),
      },
    }, {
      stripeAccount: connectAccountId, // Create on connected account
    });

    // Store sale record in Firestore
    const saleRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('sales')
      .doc();

    await saleRef.set({
      facilityId,
      stripePaymentIntentId: paymentIntent.id,
      stripeConnectedAccountId: connectAccountId,
      lineItems: lineItems.map((item: any) => ({
        sku: item.sku || null,
        name: item.name || 'Store Item',
        description: item.description || null,
        quantity: item.quantity || 1,
        price: item.price || 0,
      })),
      totalAmount: totalAmount / 100,
      currency: 'usd',
      customerEmail: customerEmail || null,
      customerName: customerName || null,
      status: 'pending',
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      createdBy: context.auth.uid,
    });

    functions.logger.info(`Store checkout created on connected account: ${paymentIntent.id} for facility ${facilityId}`);

    return {
      clientSecret: paymentIntent.client_secret,
      paymentIntentId: paymentIntent.id,
      saleId: saleRef.id,
      amount: totalAmount / 100,
    };
  } catch (error: any) {
    const safeError = error?.message || 'Failed to create store checkout';
    functions.logger.error('Error creating store checkout:', {
      facilityId,
      error: safeError,
    });
    throw new functions.https.HttpsError('internal', `Failed to create store checkout: ${safeError}`);
  }
});

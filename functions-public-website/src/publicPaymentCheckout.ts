import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { getStripeClient } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';

/**
 * Create a payment checkout session for public payment links
 * No authentication required - uses token-based validation
 */
export const createPublicPaymentCheckout = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, _context) => {
  // Note: No auth check - public access via token
  const { token } = data;

  if (!token) {
    throw new functions.https.HttpsError('invalid-argument', 'token is required');
  }

  try {
    // Get payment link from Firestore
    const linkDoc = await admin.firestore()
      .collection('publicPaymentLinks')
      .doc(token)
      .get();

    if (!linkDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Payment link not found');
    }

    const linkData = linkDoc.data()!;
    const facilityId = linkData.facilityId as string;
    const tenantId = linkData.tenantId as string;
    const amount = linkData.amount as number;
    const description = linkData.description as string || 'Payment';
    const status = linkData.status as string;
    const expiresAt = linkData.expiresAt as admin.firestore.Timestamp;

    // Validate link is active
    if (status !== 'pending') {
      throw new functions.https.HttpsError('failed-precondition', 'Payment link is no longer active');
    }

    // Check if expired
    if (expiresAt && expiresAt.toDate() < new Date()) {
      throw new functions.https.HttpsError('failed-precondition', 'Payment link has expired');
    }

    // Get facility info
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data()!;
    const connectAccountId = facilityData.stripeConnectAccountId as string | undefined;
    const onboardingComplete = facilityData.stripeConnectOnboardingComplete as boolean | undefined;

    if (!connectAccountId || !onboardingComplete) {
      throw new functions.https.HttpsError('failed-precondition', 'Facility owner must complete Stripe Connect onboarding before accepting payments');
    }

    // Get tenant info
    const tenantDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId)
      .get();

    if (!tenantDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Tenant not found');
    }

    const tenantData = tenantDoc.data()!;
    const tenantEmail = tenantData['email'] as string | undefined;

    const stripe = getStripeClient();

    // Create checkout session directly on the connected account
    // For Standard accounts, payments go directly to the connected account (0% platform fee)
    const session = await stripe.checkout.sessions.create({
      mode: 'payment',
      payment_method_types: ['card'],
      line_items: [
        {
          price_data: {
            currency: 'usd',
            product_data: {
              name: description || `Payment for ${facilityData['name'] || 'Facility'}`,
              description: `Payment for ${facilityData['name'] || 'Facility'}`,
            },
            unit_amount: Math.round(amount * 100), // Convert to cents
          },
          quantity: 1,
        },
      ],
      customer_email: tenantEmail,
      success_url: 'https://app.storagefacilitycreator.com/pay?token=' + token + '&status=success&session_id={CHECKOUT_SESSION_ID}',
      cancel_url: 'https://app.storagefacilitycreator.com/pay?token=' + token + '&status=cancel',
      metadata: {
        facilityId: facilityId,
        tenantId: tenantId,
        type: 'public_payment_link',
        paymentLinkToken: token,
      },
    }, {
      stripeAccount: connectAccountId, // Create session on connected account - all funds go to facility owner
    });

    return {
      checkoutUrl: session.url,
      sessionId: session.id,
    };
  } catch (error: any) {
    if (error instanceof functions.https.HttpsError) {
      throw error;
    }
    functions.logger.error('Error creating public payment checkout', error);
    throw new functions.https.HttpsError('internal', `Failed to create checkout: ${error.message}`);
  }
});

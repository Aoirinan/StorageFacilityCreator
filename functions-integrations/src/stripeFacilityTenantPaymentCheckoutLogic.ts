import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { getStripeClient } from '@sfc/functions-shared';

export type TenantPaymentCheckoutInput = {
  facilityId: string;
  tenantId: string;
  amount: number;
  description?: string;
};

export async function executeCreateTenantPaymentCheckout(
  input: TenantPaymentCheckoutInput,
): Promise<{ checkoutUrl: string | null; sessionId: string }> {
  const { facilityId, tenantId, amount, description } = input;

  try {
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
    const tenantName = tenantData['name'] as string | undefined || 'Tenant';

    const stripe = getStripeClient();

    const session = await stripe.checkout.sessions.create({
      mode: 'payment',
      payment_method_types: ['card'],
      line_items: [
        {
          price_data: {
            currency: 'usd',
            product_data: {
              name: description || `Rent Payment - ${tenantName}`,
              description: `Payment for ${facilityData['name'] || 'Facility'}`,
            },
            unit_amount: Math.round(amount * 100),
          },
          quantity: 1,
        },
      ],
      customer_email: tenantEmail,
      success_url: 'https://www.storagefacilitycreator.com/payment/success?session_id={CHECKOUT_SESSION_ID}',
      cancel_url: 'https://www.storagefacilitycreator.com/payment/cancel',
      metadata: {
        facilityId: facilityId,
        tenantId: tenantId,
        type: 'tenant_rent_payment',
      },
    }, {
      stripeAccount: connectAccountId,
    });

    return {
      checkoutUrl: session.url,
      sessionId: session.id,
    };
  } catch (error: any) {
    functions.logger.error('Error creating tenant payment checkout', error);
    throw new functions.https.HttpsError('internal', `Failed to create checkout: ${error.message}`);
  }
}

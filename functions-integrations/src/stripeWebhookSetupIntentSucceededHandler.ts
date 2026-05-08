import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import { getStripeClient } from '@sfc/functions-shared';

/**
 * Handle successful setup intent (for saving payment methods).
 * If connectedAccountId is set, the SetupIntent was on a Connect account; use stripeAccount for Stripe API calls.
 */
export async function handleSetupIntentSucceeded(setupIntent: Stripe.SetupIntent, connectedAccountId?: string) {
  try {
    const facilityId = setupIntent.metadata?.facilityId as string | undefined;
    const tenantId = setupIntent.metadata?.tenantId as string | undefined;
    const paymentMethodId = setupIntent.payment_method as string | undefined;

    if (!facilityId || !tenantId || !paymentMethodId) {
      functions.logger.warn('Setup intent missing facilityId, tenantId, or payment_method');
      return;
    }

    functions.logger.info(
      `Setup intent succeeded: ${setupIntent.id} for tenant ${tenantId}` + (connectedAccountId ? ' (Connect)' : ''),
    );

    const stripe = getStripeClient();
    const customerId = setupIntent.customer as string;
    const requestOptions = connectedAccountId ? { stripeAccount: connectedAccountId } : {};
    if (customerId) {
      await stripe.customers.update(
        customerId,
        {
          invoice_settings: { default_payment_method: paymentMethodId },
        },
        requestOptions,
      );
    }

    const billingRef = admin
      .firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId)
      .collection('billing')
      .doc('default');
    await billingRef.set(
      {
        facilityId,
        tenantId,
        stripeCustomerId: customerId || null,
        defaultPaymentMethodId: paymentMethodId,
        lastPaymentStatus: 'succeeded',
        lastPaymentAt: admin.firestore.FieldValue.serverTimestamp(),
        lastFailureCode: null,
        lastFailureMessage: null,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    if (connectedAccountId) {
      const stripeConnect = getStripeClient();
      const pm = await stripeConnect.paymentMethods.retrieve(paymentMethodId, { stripeAccount: connectedAccountId });
      const card = pm.card;
      const paymentMethodSummary = {
        brand: card?.brand ?? null,
        last4: card?.last4 ?? null,
        expMonth: card?.exp_month ?? null,
        expYear: card?.exp_year ?? null,
      };
      await admin.firestore().collection('facilities').doc(facilityId).collection('tenants').doc(tenantId).update({
        'stripe.defaultPaymentMethodId': paymentMethodId,
        'stripe.paymentMethodSummary': paymentMethodSummary,
        'stripe.customerId': customerId,
        stripeConnectedCustomerId: customerId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  } catch (error: any) {
    functions.logger.error('Error handling setup intent succeeded:', error);
  }
}

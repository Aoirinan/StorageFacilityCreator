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
      const tenantRef = admin
        .firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .doc(tenantId);

      await tenantRef.update({
        'stripe.defaultPaymentMethodId': paymentMethodId,
        'stripe.paymentMethodSummary': paymentMethodSummary,
        'stripe.customerId': customerId,
        stripeConnectedCustomerId: customerId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      // Record the card in `paymentMethods` as well.
      //
      // This is the only collection the autopay worker reads, and the only one
      // toggleAutopay looks at. Writing just the tenant/billing fields above
      // left a tenant who saved a card in the portal invisible to autopay
      // forever, and made "enable autopay" fail with "Add a payment method
      // first" immediately after they had added one. The staff-side attach
      // callable always wrote this document; the portal path never did, so
      // self-service could not produce a single autopay collection.
      const paymentMethodsRef = tenantRef.collection('paymentMethods');
      const existing = await paymentMethodsRef
        .where('stripePaymentMethodId', '==', paymentMethodId)
        .limit(1)
        .get();

      // Stripe redelivers webhooks; re-saving the same card must not stack up
      // duplicate rows, which would let the nightly job charge once per row.
      const targetRef = existing.empty ? paymentMethodsRef.doc() : existing.docs[0].ref;

      // A newly saved card becomes the default, so clear the flag on the rest
      // rather than leaving two cards both claiming it.
      const others = await paymentMethodsRef.where('isDefault', '==', true).get();
      for (const doc of others.docs) {
        if (doc.id !== targetRef.id) {
          await doc.ref.update({ isDefault: false });
        }
      }

      await targetRef.set(
        {
          tenantId,
          // Required by the worker's collection-group query.
          facilityId,
          type: 'creditCard',
          stripePaymentMethodId: paymentMethodId,
          stripeCustomerId: customerId,
          stripeConnectedAccountId: connectedAccountId,
          last4: paymentMethodSummary.last4,
          brand: paymentMethodSummary.brand,
          expiryMonth: paymentMethodSummary.expMonth,
          expiryYear: paymentMethodSummary.expYear,
          isDefault: true,
          isActive: true,
          // Saving a card is not consent to be charged automatically; autopay
          // is armed separately by the tenant or by staff.
          ...(existing.empty ? { autopayEnabled: false } : {}),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          ...(existing.empty
            ? {
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
                createdBy: 'setupIntentWebhook',
              }
            : {}),
        },
        { merge: true },
      );

      functions.logger.info(
        `Payment method ${paymentMethodId} recorded for tenant ${tenantId} ` +
          `(${existing.empty ? 'created' : 'updated'}); autopay can now see it`,
      );
    }
  } catch (error: any) {
    functions.logger.error('Error handling setup intent succeeded:', error);
  }
}

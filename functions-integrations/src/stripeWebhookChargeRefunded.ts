import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import { getStripeClient } from '@sfc/functions-shared';

/**
 * Record a refund against the tenant's ledger.
 *
 * Two things this has to get right, both of which it previously did not:
 *
 * 1. Tenant charges live on the facility's *connected* account, so retrieving
 *    the PaymentIntent without `stripeAccount` looks it up on the platform and
 *    fails with "no such payment_intent". The handler then warned and returned,
 *    so refunds were never recorded. That was invisible until now only because
 *    connected-account events were not being delivered at all; now that they
 *    are, this would have failed on every real refund.
 *
 * 2. `charge.amount_refunded` is the cumulative total refunded so far, not the
 *    amount of this refund. Posting it on each event means two partial refunds
 *    of $10 record $10 and then $20 — crediting $30 against $20 actually
 *    returned. Each individual refund is recorded once instead, keyed by its
 *    own id so redelivery and partial refunds are both safe.
 */
export async function handleChargeRefunded(
  charge: Stripe.Charge,
  connectedAccountId?: string,
) {
  try {
    const paymentIntentId = charge.payment_intent as string;
    if (!paymentIntentId) {
      functions.logger.warn('Charge refunded but no payment intent ID');
      return;
    }

    const stripe = getStripeClient();
    const requestOptions = connectedAccountId ? { stripeAccount: connectedAccountId } : {};
    const paymentIntent = await stripe.paymentIntents.retrieve(paymentIntentId, requestOptions);

    const facilityId = paymentIntent.metadata?.facilityId;
    const tenantId = paymentIntent.metadata?.tenantId;

    if (!facilityId) {
      functions.logger.warn('Charge refunded but missing facilityId metadata');
      return;
    }

    const facilityRef = admin.firestore().collection('facilities').doc(facilityId);
    const paymentsRef = facilityRef.collection('payments');
    const existingPayments = await paymentsRef
      .where('externalPaymentId', '==', paymentIntentId)
      .limit(1)
      .get();

    if (!existingPayments.empty) {
      await existingPayments.docs[0].ref.update({
        // Stripe allows refunding part of a charge; only call it fully refunded
        // when it actually is.
        status: charge.amount_refunded >= charge.amount ? 'refunded' : 'partially_refunded',
        amountRefunded: charge.amount_refunded / 100,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    // Refund objects may not be expanded on the event payload; fetch them so
    // each one can be recorded individually.
    const refunds =
      charge.refunds?.data && charge.refunds.data.length > 0
        ? charge.refunds.data
        : (await stripe.refunds.list({ charge: charge.id, limit: 100 }, requestOptions)).data;

    for (const refund of refunds) {
      if (refund.status && refund.status !== 'succeeded') continue;

      // Deterministic id per refund: redelivery of the same event, or a later
      // event listing this refund again, updates one entry instead of adding
      // another. A ledger that double-counts refunds understates what a tenant
      // owes, which is money the facility never collects.
      const ledgerRef = facilityRef.collection('ledgers').doc(`refund_${refund.id}`);
      await ledgerRef.set(
        {
          tenantId: tenantId || null,
          facilityId,
          type: 'refund',
          // Positive: a refund reverses a payment, so what the tenant owes goes
          // back up. Payments are stored negative, charges positive.
          amount: refund.amount / 100,
          description: `Refund for charge ${charge.id}`,
          referenceId: existingPayments.empty ? null : existingPayments.docs[0].id,
          entryDate: admin.firestore.FieldValue.serverTimestamp(),
          status: 'posted',
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          createdBy: 'system@stripe-webhook',
          metadata: {
            chargeId: charge.id,
            paymentIntentId,
            refundId: refund.id,
            connectedAccountId: connectedAccountId || null,
          },
        },
        { merge: true },
      );
    }

    functions.logger.info(
      `Charge refunded: ${charge.id} (${refunds.length} refund(s)) for payment intent ${paymentIntentId}` +
        (connectedAccountId ? ' on connected account' : ''),
    );
  } catch (error: any) {
    functions.logger.error('Error handling charge refunded:', error);
  }
}

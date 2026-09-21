import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import {
  enforceAppCheckOrThrow,
  enforceRateLimit,
  getStripeClient,
  writeAuditLog,
} from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';

/**
 * Process refund via Stripe
 * Used for move-out refunds and other refund scenarios
 */
export const processRefund = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  await enforceRateLimit({
    facilityId: data?.facilityId,
    key: 'processRefund',
    limit: 20,
    windowSeconds: 60,
    userId: context.auth.uid,
  });

  const { facilityId, tenantId, amount, refundMethod, referenceId } = data;

  if (!facilityId || !tenantId || !amount || amount <= 0) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required parameters or invalid amount');
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
    const stripeConnectAccountId = facilityData?.stripeConnectAccountId;

    // Check if user is owner or has manager role
    if (ownerUid !== context.auth.uid && roles[context.auth.uid] !== 'manager') {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission to process refunds');
    }

    // If Stripe Connect is set up and refund method is card, process via Stripe
    if (stripeConnectAccountId && refundMethod === 'creditCard' && referenceId) {
      try {
        const stripe = getStripeClient();

        // Look up the original payment intent ON THE CONNECTED ACCOUNT.
        //
        // Tenant charges live on the facility's connected account, so a
        // platform-scoped retrieve raises "no such payment_intent". That threw
        // into the catch below, which fell through to the manual branch and
        // returned success with an invented refund id — so the operator was
        // told the refund went through while the card was never touched.
        const paymentIntent = await stripe.paymentIntents.retrieve(
          referenceId,
          { expand: ['charges'] },
          { stripeAccount: stripeConnectAccountId },
        );

        if (paymentIntent.status !== 'succeeded') {
          throw new Error('Payment intent not succeeded, cannot refund');
        }

        const chargeId =
          (paymentIntent as any).charges?.data?.[0]?.id ??
          (typeof (paymentIntent as any).latest_charge === 'string'
            ? (paymentIntent as any).latest_charge
            : (paymentIntent as any).latest_charge?.id);
        if (!chargeId) {
          throw new Error('Charge ID not found in payment intent');
        }

        // Create refund on the connected account. The idempotency key is
        // derived from the charge and amount so a double-click, or a retry
        // after a timeout, cannot refund the tenant twice.
        const refund = await stripe.refunds.create(
          {
            charge: chargeId,
            amount: Math.round(amount * 100), // Convert to cents
          },
          {
            stripeAccount: stripeConnectAccountId,
            idempotencyKey: `refund_${chargeId}_${Math.round(amount * 100)}`,
          },
        );

        functions.logger.info(`Stripe refund processed: ${refund.id} for $${amount}`);

        // Record it on the ledger. Without this the tenant kept the credit from
        // the original payment: the facility was out the cash and the tenant
        // still looked paid up.
        //
        // Positive, matching the charge.refunded webhook: a refund removes a
        // credit the tenant held, so what they owe goes back up. The document
        // id is derived from the Stripe refund so the webhook for this same
        // refund converges here rather than posting a second entry.
        await admin
          .firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('ledgers')
          .doc(`refund_${refund.id}`)
          .set({
            tenantId,
            facilityId,
            type: 'refund',
            amount,
            description: `Refund for charge ${chargeId}`,
            referenceId: referenceId || null,
            entryDate: admin.firestore.FieldValue.serverTimestamp(),
            status: 'posted',
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
            createdBy: context.auth.uid,
            metadata: {
              stripeRefundId: refund.id,
              stripeChargeId: chargeId,
              refundMethod,
            },
          });

        // Log audit event
        await writeAuditLog(facilityId, {
          eventType: 'payment.refunded',
          actorUid: context.auth.uid,
          targetType: 'payment',
          targetId: referenceId,
          tenantId,
          after: {
            amount,
            refundId: refund.id,
            method: refundMethod,
            status: 'refunded',
          },
          metadata: {
            method: 'stripe',
            stripeRefundId: refund.id,
            stripeConnectAccountId: stripeConnectAccountId || null,
          },
        });

        return {
          success: true,
          refundId: refund.id,
          amount: amount,
          method: refundMethod,
          stripeRefundId: refund.id,
          message: 'Refund processed successfully via Stripe',
        };
      } catch (stripeError: any) {
        // Do not fall through to the manual branch. It returns success with an
        // invented refund id, which told the operator a card refund had been
        // made when it had not. A card refund that fails must fail loudly so
        // they can retry or refund by another method deliberately.
        functions.logger.error('Stripe refund error:', stripeError);
        await writeAuditLog(facilityId, {
          action: 'refund_failed',
          userId: context.auth.uid,
          tenantId,
          amount,
          error: stripeError?.message || 'unknown',
        });
        throw new functions.https.HttpsError(
          'internal',
          `Card refund failed: ${stripeError?.message || 'unknown error'}. No refund was issued.`,
        );
      }
    }

    // For non-Stripe refunds or if Stripe fails, log for manual processing
    functions.logger.info(`Refund requested: $${amount} for tenant ${tenantId}, method: ${refundMethod || 'manual'}`);
    await writeAuditLog(facilityId, {
      eventType: 'payment.refundRequested',
      actorUid: context.auth.uid,
      targetType: 'payment',
      targetId: referenceId || 'manual',
      tenantId,
      after: {
        amount,
        method: refundMethod || 'manual',
        status: 'pending',
      },
      metadata: {
        requiresManualProcessing: true,
        tenantId,
        amount,
        method: refundMethod || 'manual',
      },
      referenceId: referenceId || null,
    });

    return {
      success: true,
      refundId: `refund-${Date.now()}`,
      amount: amount,
      method: refundMethod || 'manual',
      message: 'Refund logged for processing',
    };
  } catch (error: any) {
    functions.logger.error('Error processing refund:', error);
    await writeAuditLog(facilityId, {
      action: 'refund_failed',
      userId: context.auth.uid,
      tenantId,
      amount,
      error: error?.message || 'unknown',
    });
    throw new functions.https.HttpsError('internal', `Failed to process refund: ${error.message}`);
  }
});

import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import * as Sentry from '@sentry/node';
import {
  enforceAppCheckOrThrow,
  enforceRateLimit,
  getStripeClient,
  mapStripeErrorToUserMessage,
  writeAuditLog,
} from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';
import { isPaymentSafetyFeatureEnabled } from './stripeFacilityFeatureFlags';
import { throwIfDuplicateRecentPayment } from './stripeFacilityProcessPaymentDuplicateCheck';
import { recordSucceededStripePaymentAndAudit } from './stripeFacilityProcessPaymentSucceeded';

/**
 * Process payment via Stripe for autopay or manual payments
 */
export const processStripePayment = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  await enforceRateLimit({
    facilityId: data?.facilityId,
    key: 'processStripePayment',
    limit: 40,
    windowSeconds: 60,
    userId: context.auth.uid,
  });

  const { facilityId, tenantId, paymentMethodId, customerId, amount, description } = data;

  if (!facilityId || !tenantId || !paymentMethodId || !amount) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required parameters');
  }

  try {
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

    if (ownerUid !== context.auth.uid && roles[context.auth.uid] !== 'manager' && roles[context.auth.uid] !== 'owner') {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission');
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

    const stripe = getStripeClient();

    const idempotencyEnabled = await isPaymentSafetyFeatureEnabled('idempotency', facilityId);
    const duplicateDetectionEnabled = await isPaymentSafetyFeatureEnabled('duplicateDetection', facilityId);

    const idempotencyKey = idempotencyEnabled
      ? `payment_${facilityId}_${tenantId}_${Date.now()}_${Math.round(amount * 100)}`
      : undefined;

    if (duplicateDetectionEnabled) {
      await throwIfDuplicateRecentPayment(facilityId, tenantId, amount);
    }

    const paymentIntentParams: Stripe.PaymentIntentCreateParams = {
      amount: Math.round(amount * 100),
      currency: 'usd',
      payment_method: paymentMethodId,
      customer: customerId,
      confirmation_method: 'automatic',
      confirm: true,
      description: description || `Payment for tenant ${tenantId}`,
      ...(idempotencyKey ? { idempotency_key: idempotencyKey } : {}),
      metadata: {
        facilityId,
        tenantId,
        userId: context.auth.uid,
        ...(idempotencyKey ? { idempotencyKey } : {}),
      },
    };

    if (stripeConnectAccountId) {
      paymentIntentParams.on_behalf_of = stripeConnectAccountId;
      paymentIntentParams.transfer_data = {
        destination: stripeConnectAccountId,
      };
    }

    const paymentIntent = await stripe.paymentIntents.create(paymentIntentParams);

    if (paymentIntent.status === 'succeeded') {
      functions.logger.info(`Payment succeeded: ${paymentIntent.id} for tenant ${tenantId}`);
      return await recordSucceededStripePaymentAndAudit({
        facilityId,
        tenantId,
        amount,
        paymentIntent,
        stripeConnectAccountId,
        idempotencyKey,
        actorUid: context.auth.uid,
      });
    }
    if (paymentIntent.status === 'requires_action') {
      return {
        success: false,
        requiresAction: true,
        clientSecret: paymentIntent.client_secret,
        transactionId: paymentIntent.id,
      };
    }
    throw new Error(`Payment failed with status: ${paymentIntent.status}`);
  } catch (error: any) {
    const safeError = error?.message || 'Failed to process payment';
    const logData = {
      facilityId,
      tenantId,
      error: safeError,
    };

    functions.logger.error('Error processing Stripe payment:', logData);

    const sentryDsn = process.env.SENTRY_DSN;
    if (sentryDsn) {
      Sentry.captureException(error, {
        tags: {
          function: 'processStripePayment',
          facilityId,
        },
        extra: {
          tenantId,
        },
      });
    }

    await writeAuditLog(facilityId, {
      action: 'payment_failed',
      userId: context.auth.uid,
      tenantId,
      amount,
      error: safeError,
    });

    const userMessage = mapStripeErrorToUserMessage(error);
    throw new functions.https.HttpsError('internal', userMessage);
  }
});

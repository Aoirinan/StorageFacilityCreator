import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { canAccessFacility, getStripeClient, mapStripeErrorToUserMessage } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';
import { isTenantAutopayAllowedForFacility } from './stripeFacilityFeatureFlags';
import { persistOffSessionChargeRecords } from './stripeFacilityOffSessionChargePersistence';

/**
 * Charge a tenant off-session using a stored payment method on a connected account
 * Feature-flagged: Requires tenantAutopayEnabledGlobal OR facilityId in allowlist
 */
export const chargeTenantOffSession = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  if (!context.app) {
    functions.logger.warn('chargeTenantOffSession: App Check token missing – allowing for auth-only');
  }

  const { facilityId, tenantId, paymentMethodId, amount, description } = data;

  if (!facilityId || !tenantId || !paymentMethodId || amount === undefined || amount === null) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required parameters');
  }

  const amountNum = Number(amount);
  if (!Number.isFinite(amountNum) || amountNum < 0.5) {
    throw new functions.https.HttpsError('invalid-argument', 'Amount must be a number of at least 0.50 (USD).');
  }

  const tenantAutopayAllowed = await isTenantAutopayAllowedForFacility(facilityId);
  if (!tenantAutopayAllowed) {
    throw new functions.https.HttpsError('failed-precondition', 'Payments are not enabled for this facility. Connect and complete Stripe onboarding first.');
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
    const roles = (facilityData?.roles || {}) as Record<string, string>;
    const connectAccountId = facilityData?.stripeConnectAccountId as string | undefined;

    if (!connectAccountId) {
      throw new functions.https.HttpsError('failed-precondition', 'Facility must have a connected Stripe account');
    }

    const isElevated =
      ownerUid === context.auth.uid ||
      roles[context.auth.uid] === 'manager' ||
      roles[context.auth.uid] === 'owner';
    if (!isElevated) {
      const staffOk = await canAccessFacility(context.auth.uid, facilityId);
      if (!staffOk) {
        throw new functions.https.HttpsError('permission-denied', 'User does not have permission');
      }
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

    const tenantData = tenantDoc.data();
    const stripe = getStripeClient();

    const customerId = tenantData?.stripeConnectedCustomerId as string | undefined;
    if (!customerId) {
      throw new functions.https.HttpsError('failed-precondition', 'Tenant does not have a Stripe customer on connected account');
    }

    const paymentIntent = await stripe.paymentIntents.create({
      amount: Math.round(amountNum * 100),
      currency: 'usd',
      payment_method: paymentMethodId,
      customer: customerId,
      confirmation_method: 'automatic',
      confirm: true,
      off_session: true,
      description: description || `Payment for tenant ${tenantId}`,
      metadata: {
        facilityId,
        tenantId,
        userId: context.auth.uid,
        chargeType: 'tenant_one_time_card_on_file',
      },
    }, {
      stripeAccount: connectAccountId,
    });

    if (paymentIntent.status !== 'succeeded') {
      throw new functions.https.HttpsError(
        'failed-precondition',
        `Payment was not completed (status: ${paymentIntent.status}). Try "Pay with new card" or ask the tenant to approve with their bank.`,
      );
    }

    const amountCents = Math.round(amountNum * 100);
    const { recordingWarning } = await persistOffSessionChargeRecords({
      facilityId,
      tenantId,
      amountNum,
      amountCents,
      paymentIntentId: paymentIntent.id,
      paymentIntentStatus: paymentIntent.status,
      customerId,
      connectAccountId,
      description,
      actorUid: context.auth.uid,
    });

    return {
      success: true,
      paymentIntentId: paymentIntent.id,
      status: paymentIntent.status,
      amount: amountNum,
      ...(recordingWarning ? { recordingWarning } : {}),
    };
  } catch (error: any) {
    if (error instanceof functions.https.HttpsError) {
      throw error;
    }
    const safeError = error?.message || 'Failed to charge tenant';
    functions.logger.error('Error charging tenant off-session on connected account:', {
      facilityId,
      tenantId,
      error: safeError,
      stack: error?.stack,
    });

    const userMessage = mapStripeErrorToUserMessage(error);
    throw new functions.https.HttpsError('internal', userMessage);
  }
});

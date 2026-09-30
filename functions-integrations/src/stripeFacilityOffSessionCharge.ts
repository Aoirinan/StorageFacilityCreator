import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import {
  canAccessFacility,
  checkDisputeForPayment,
  getStripeClient,
  mapStripeErrorToUserMessage,
  writeAuditLog,
} from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';
import { isTenantAutopayAllowedForFacility } from './stripeFacilityFeatureFlags';
import { persistOffSessionChargeRecords } from './stripeFacilityOffSessionChargePersistence';

/**
 * The staff member's confirmation that the tenant agreed to a card-dispute
 * charge on their card on file: `tenantConsent: true` in the request (the
 * app's "The tenant has agreed to this charge on their card"). Null when it
 * is not a dispute charge or the confirmation is missing. [metadata] goes on
 * the PaymentIntent and the audit log. Exported for tests.
 */
export function disputeCardChargeConsent(
  data: unknown,
  disputeId: string | null,
  actorUid: string,
  now: Date,
): { metadata: Record<string, string> } | null {
  if (!disputeId) return null;
  const confirmed = !!data && typeof data === 'object' && (data as { tenantConsent?: unknown }).tenantConsent === true;
  if (!confirmed) return null;
  return {
    metadata: {
      tenantConsent: 'confirmed_by_staff',
      tenantConsentBy: actorUid,
      tenantConsentAt: now.toISOString(),
    },
  };
}

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

    // "Record payment for this dispute" on the Ledger charges the card for a
    // card dispute: the charge is booked against the dispute, not as rent.
    // Never for a fraud dispute: the cardholder says they did not make the
    // charge, so it is not going back on a card on file.
    const dispute = await checkDisputeForPayment(admin.firestore(), facilityId, tenantId, data?.disputeId, amountNum, {
      cardOnFile: true,
    });
    if (!dispute.ok) {
      throw new functions.https.HttpsError('failed-precondition', dispute.message);
    }
    const disputeId = dispute.disputeId;

    // Charging a disputed amount back to the card needs the cardholder's
    // fresh consent. The app's dialog asks staff to confirm it; the server
    // now refuses without that confirmation too, and keeps it on the
    // PaymentIntent and in the audit log ([disputeCardChargeConsent]).
    const consent = disputeCardChargeConsent(data, disputeId, context.auth.uid, new Date());
    if (disputeId && !consent) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Confirm the tenant agreed to this card charge before charging a card dispute to the card on file.',
      );
    }

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
        ...(disputeId ? { disputeId } : {}),
        ...(consent ? consent.metadata : {}),
      },
    }, {
      stripeAccount: connectAccountId,
      // Without a key, an operator double-clicking "charge card on file" makes
      // two real charges for the same amount. Keyed on facility, tenant, amount
      // and the current minute, so a rapid second press reuses the first
      // charge while a deliberate repeat later still goes through.
      // The dispute is in the key so a dispute payment and a rent charge of
      // the same amount in the same minute stay two charges.
      idempotencyKey: `offsession_${facilityId}_${tenantId}_${Math.round(amountNum * 100)}_${Math.floor(Date.now() / 60000)}${disputeId ? `_${disputeId}` : ''}`,
    });

    if (paymentIntent.status !== 'succeeded') {
      throw new functions.https.HttpsError(
        'failed-precondition',
        `Payment was not completed (status: ${paymentIntent.status}). Try "Pay with new card" or ask the tenant to approve with their bank.`,
      );
    }

    if (disputeId && consent) {
      // Best effort (writeAuditLog logs its own failures): the card has been
      // charged, and the consent is on the PaymentIntent either way.
      await writeAuditLog(facilityId, {
        eventType: 'payment.dispute_card_charge',
        actorUid: context.auth.uid,
        targetType: 'payment',
        targetId: paymentIntent.id,
        tenantId,
        metadata: {
          disputeId,
          amount: amountNum,
          paymentIntentId: paymentIntent.id,
          ...consent.metadata,
        },
      });
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
      disputeId,
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

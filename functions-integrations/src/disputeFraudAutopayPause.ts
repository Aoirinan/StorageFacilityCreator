import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import {
  cancelLegacyAutopaySubscription,
  getStripeClient,
  legacySubscriptionId,
  type LegacyCancelOutcome,
  type LegacySubscriptionStripe,
} from '@sfc/functions-shared';

/** Stripe's dispute reason when the cardholder says they never made the charge. */
export const FRAUDULENT_DISPUTE_REASON = 'fraudulent';

export function fraudDisputeAutopayNotificationId(disputeId: string): string {
  return `autopayFraudDispute_${disputeId}`;
}

function dollars(amount: number): string {
  return `$${amount.toFixed(2)}`;
}

/** Added to the staff notification when the tenant's legacy subscription could not be cancelled. */
export const LEGACY_SUBSCRIPTION_NOT_CANCELLED_NOTE =
  'Their older autopay subscription in Stripe could not be cancelled, so it may still charge this card. Press ' +
  "Disable autopay on the tenant's page to try again (autopay stays off), and contact support if it still fails.";

/**
 * Turns autopay off for a tenant whose card payment was disputed as
 * `fraudulent`, and tells staff.
 *
 * The cardholder has told their bank they never made the charge. Autopay
 * charged next month's rent to the saved card all the same: a second charge
 * to a card that may be stolen, which the cardholder will dispute too, and
 * each dispute costs the facility its fee. Autopay stays off until staff
 * have spoken to the tenant and turn it back on themselves.
 *
 * What it writes, once per dispute (the notification's id is the marker, so
 * a later event for the same dispute does not switch autopay off again after
 * staff have turned it back on):
 * - every armed card (`paymentMethods` with `autopayEnabled`) disarmed, with
 *   `autopayDisabledReason` and `autopayPausedForDisputeId`;
 * - `billing/default.autopayEnabled` false, as the billing panel reads it;
 * - the tenant's `autopay` display state OFF, with
 *   `autopay.pausedForDisputeId`: the tenant portal will not let the tenant
 *   turn autopay back on while it is set (setTenantAutopayFromPortal);
 * - an AutopayEvents row and a STRIPE_ACTION_REQUIRED notification saying
 *   how to turn it back on: from the tenant's page in the app, which clears
 *   the pause (setTenantAutopay).
 *
 * Then, after the transaction (Stripe is not called inside one), the
 * tenant's legacy AutoPay subscription on the platform account
 * (`billing/default.stripeSubscriptionId`), if they still have one, is
 * cancelled through cancelLegacyAutopaySubscription, as every other switch
 * that turns autopay off does. Disarming the cards left it charging the
 * reported card every month. Its id is deleted only once it is not billing.
 * If the cancel fails, the notification says so and how to try again, and
 * the id stays (the facility delete refusal and the tenant page's Disable
 * autopay button both look for it). A failed cancel does not fail the
 * event: later events for the dispute do not pause again, so a retry would
 * not cancel it either, and failing the event would hold the dispute's
 * ledger rows back for as long as Stripe kept refusing.
 *
 * Runs whether or not the dispute ledger is switched on
 * (disputeLedgerGate.ts): it only stops charges. Throws on Firestore failure
 * so the webhook returns 500 and Stripe retries.
 */
export async function pauseAutopayForFraudDispute(params: {
  facilityId: string;
  tenantId: string;
  disputeId: string;
  amount: number;
  now?: Date;
  // The platform Stripe client, only created when there is a legacy
  // subscription to cancel. Tests pass a fake.
  stripe?: () => LegacySubscriptionStripe;
}): Promise<{ paused: boolean; disarmedCards: number; legacySubscription: LegacyCancelOutcome }> {
  const { facilityId, tenantId, disputeId } = params;
  const db = admin.firestore();
  const facilityRef = db.collection('facilities').doc(facilityId);
  const tenantRef = facilityRef.collection('tenants').doc(tenantId);
  const billingRef = tenantRef.collection('billing').doc('default');
  const notificationRef = facilityRef.collection('Notifications').doc(fraudDisputeAutopayNotificationId(disputeId));
  const eventRef = facilityRef.collection('AutopayEvents').doc(`fraudDispute_${disputeId}`);
  const armedCards = tenantRef.collection('paymentMethods').where('autopayEnabled', '==', true);
  const timestamp = admin.firestore.Timestamp.fromDate(params.now ?? new Date());

  const notPaused = { paused: false, disarmedCards: 0, legacyId: '', message: '' };
  const result = await db.runTransaction(async (tx) => {
    const notificationSnap = await tx.get(notificationRef);
    if (notificationSnap.exists) return notPaused;
    const tenantSnap = await tx.get(tenantRef);
    if (!tenantSnap.exists) return notPaused;
    const cards = await tx.get(armedCards);
    const billingSnap = await tx.get(billingRef);

    const tenant = (tenantSnap.data() || {}) as Record<string, unknown>;
    const name = typeof tenant.name === 'string' && tenant.name.trim() ? tenant.name.trim() : null;
    // A legacy subscription charges the card whether or not a card is armed.
    const legacyId = legacySubscriptionId(billingSnap.data());
    const wasOn = cards.size > 0 || legacyId !== '';
    const reason =
      `Card dispute ${disputeId}: the cardholder told their bank they did not make a ${dollars(params.amount)} charge.`;

    for (const card of cards.docs) {
      tx.update(card.ref, {
        autopayEnabled: false,
        autopayDisabledReason: reason,
        autopayDisabledAt: timestamp,
        autopayPausedForDisputeId: disputeId,
        updatedAt: timestamp,
      });
    }
    tx.set(billingRef, { autopayEnabled: false, updatedAt: timestamp }, { merge: true });
    tx.update(tenantRef, {
      'autopay.requested': false,
      'autopay.enabled': false,
      'autopay.status': 'OFF',
      'autopay.disabledAt': timestamp,
      'autopay.disabledReason': reason,
      'autopay.pausedForDisputeId': disputeId,
      'autopay.updatedBy': 'SYSTEM',
      'autopay.updatedAt': timestamp,
      updatedAt: timestamp,
    });
    tx.set(eventRef, {
      facilityId,
      tenantId,
      tenantName: name,
      action: 'DISABLED',
      source: 'SYSTEM',
      reason,
      createdAt: timestamp,
    });
    const who = name ?? 'this tenant';
    const message = wasOn
      ? `Autopay was turned off for ${who}. ${reason} Autopay would have charged next month's rent to a card ` +
        'the cardholder says was used without their permission. Talk to the tenant before charging this card again. ' +
        "To turn autopay back on, use the Autopay switch on the tenant's page once they have confirmed the card " +
        'is theirs and agreed to automatic charges. The tenant cannot turn it back on from the portal until you do.'
      : `${reason} Autopay was not on for ${who}. The tenant cannot turn it on from the portal until you turn it ` +
        "on for them from the tenant's page, after they have confirmed the card is theirs.";
    tx.set(notificationRef, {
      facilityId,
      tenantId,
      tenantName: name,
      type: 'STRIPE_ACTION_REQUIRED',
      message,
      readAt: null,
      createdAt: timestamp,
      createdBy: 'system@stripe-webhook',
      metadata: {
        reason: 'fraud_dispute_autopay_paused',
        disputeId,
        autopayWasOn: wasOn,
        ...(legacyId ? { legacySubscriptionId: legacyId } : {}),
      },
    });
    return { paused: true, disarmedCards: cards.size, legacyId, message };
  });

  let legacySubscription: LegacyCancelOutcome = 'none';
  if (result.paused && result.legacyId) {
    try {
      legacySubscription = await cancelLegacyAutopaySubscription(
        params.stripe ?? getStripeClient,
        { facilityId, tenantId },
        { stripeSubscriptionId: result.legacyId },
      );
    } catch (error) {
      // Creating the client failed (the cancel itself reports 'failed').
      functions.logger.error('Legacy AutoPay subscription not cancelled; it may still be billing', {
        facilityId,
        tenantId,
        subscriptionId: result.legacyId,
        error: error instanceof Error ? error.message : String(error),
      });
      legacySubscription = 'failed';
    }
    if (legacySubscription === 'failed') {
      await notificationRef.update({
        message: `${result.message} ${LEGACY_SUBSCRIPTION_NOT_CANCELLED_NOTE}`,
        'metadata.legacySubscriptionCancelled': false,
      });
    } else {
      // Only the id that was cancelled: one written since is left alone.
      await db.runTransaction(async (tx) => {
        const billing = await tx.get(billingRef);
        if (legacySubscriptionId(billing.data()) !== result.legacyId) return;
        tx.update(billingRef, {
          stripeSubscriptionId: admin.firestore.FieldValue.delete(),
          updatedAt: admin.firestore.Timestamp.fromDate(params.now ?? new Date()),
        });
      });
      await notificationRef.update({ 'metadata.legacySubscriptionCancelled': true });
    }
  }

  if (result.paused) {
    functions.logger.warn('Autopay paused for a fraudulent card dispute', {
      facilityId,
      tenantId,
      disputeId,
      disarmedCards: result.disarmedCards,
      legacySubscription,
    });
  }
  return { paused: result.paused, disarmedCards: result.disarmedCards, legacySubscription };
}

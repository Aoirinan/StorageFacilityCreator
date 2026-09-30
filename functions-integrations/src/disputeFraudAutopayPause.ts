import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';

/** Stripe's dispute reason when the cardholder says they never made the charge. */
export const FRAUDULENT_DISPUTE_REASON = 'fraudulent';

export function fraudDisputeAutopayNotificationId(disputeId: string): string {
  return `autopayFraudDispute_${disputeId}`;
}

function dollars(amount: number): string {
  return `$${amount.toFixed(2)}`;
}

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
}): Promise<{ paused: boolean; disarmedCards: number }> {
  const { facilityId, tenantId, disputeId } = params;
  const db = admin.firestore();
  const facilityRef = db.collection('facilities').doc(facilityId);
  const tenantRef = facilityRef.collection('tenants').doc(tenantId);
  const notificationRef = facilityRef.collection('Notifications').doc(fraudDisputeAutopayNotificationId(disputeId));
  const eventRef = facilityRef.collection('AutopayEvents').doc(`fraudDispute_${disputeId}`);
  const armedCards = tenantRef.collection('paymentMethods').where('autopayEnabled', '==', true);
  const timestamp = admin.firestore.Timestamp.fromDate(params.now ?? new Date());

  const result = await db.runTransaction(async (tx) => {
    const notificationSnap = await tx.get(notificationRef);
    if (notificationSnap.exists) return { paused: false, disarmedCards: 0 };
    const tenantSnap = await tx.get(tenantRef);
    if (!tenantSnap.exists) return { paused: false, disarmedCards: 0 };
    const cards = await tx.get(armedCards);

    const tenant = (tenantSnap.data() || {}) as Record<string, unknown>;
    const name = typeof tenant.name === 'string' && tenant.name.trim() ? tenant.name.trim() : null;
    const wasOn = cards.size > 0;
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
    tx.set(
      tenantRef.collection('billing').doc('default'),
      { autopayEnabled: false, updatedAt: timestamp },
      { merge: true },
    );
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
      metadata: { reason: 'fraud_dispute_autopay_paused', disputeId, autopayWasOn: wasOn },
    });
    return { paused: true, disarmedCards: cards.size };
  });

  if (result.paused) {
    functions.logger.warn('Autopay paused for a fraudulent card dispute', {
      facilityId,
      tenantId,
      disputeId,
      disarmedCards: result.disarmedCards,
    });
  }
  return result;
}

import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { STRIPE_WEBHOOK_REFUSALS_COLLECTION } from '@sfc/functions-shared';

/**
 * The switch that lets the Stripe webhook post card disputes to tenant
 * ledgers: `appConfig/payments.disputeLedgerEnabled`. Off (false, missing,
 * or no document) until a super admin turns it on.
 *
 * Why a switch: production's dispute handler before this change never wrote
 * a connected-account dispute (it looked the charge up without
 * `stripeAccount`), so the first real `dispute_*` ledger rows and `disputed`
 * payments come from this webhook. The code that reads them was changed at
 * the same time and deploys separately: autopay, the delinquency job and the
 * reminders (functions-automation), the portal balance
 * (functions-tenant-lifecycle), the rent reminder text
 * (functions-messaging-twilio) and the app (hosting). Any of those still on
 * the old code would treat a dispute as rent owed: autopay would charge the
 * disputed amount back onto the same card, the delinquency job would add late
 * fees and lock the gate, the portal would ask the tenant to pay it again,
 * and the old app would put it on an invoice. With the switch off the
 * webhook writes none of that, whatever order the codebases deploy in.
 *
 * Turn it on only after every one of those is deployed (see
 * docs/payments_architecture.md, "Dispute ledger switch and deploy order"):
 * in the Firebase console, `appConfig/payments`, set `disputeLedgerEnabled`
 * (boolean) to true.
 * Disputes held while it was off are listed in `stripeWebhookRefusals` with
 * reason `dispute_ledger_off`. Each posts on its next Stripe event (a dispute
 * always sends `charge.dispute.closed` when it ends); to post one sooner,
 * resend one of its `eventIds` from the Stripe Dashboard. A held event is
 * not marked processed, so a resend is not ignored as a duplicate.
 */
export const DISPUTE_LEDGER_CONFIG_COLLECTION = 'appConfig';
export const DISPUTE_LEDGER_CONFIG_DOC = 'payments';
export const DISPUTE_LEDGER_FLAG = 'disputeLedgerEnabled';
export const DISPUTE_LEDGER_OFF_REASON = 'dispute_ledger_off';

/**
 * Whether the webhook may post disputes. A read error is thrown, not taken
 * as off: the webhook returns 500 and Stripe retries, instead of holding a
 * dispute because Firestore blinked.
 */
export async function isDisputeLedgerEnabled(): Promise<boolean> {
  const snap = await admin
    .firestore()
    .collection(DISPUTE_LEDGER_CONFIG_COLLECTION)
    .doc(DISPUTE_LEDGER_CONFIG_DOC)
    .get();
  return snap.exists && snap.get(DISPUTE_LEDGER_FLAG) === true;
}

/** The refusals row for a held dispute: one per account and dispute, like every refusal. */
export function heldDisputeDocId(connectedAccountId: string | null | undefined, disputeId: string): string {
  return `${connectedAccountId || 'platform'}__${disputeId}`;
}

export const HELD_DISPUTE_ACTION =
  'Card dispute not posted to the tenant ledger because appConfig/payments.disputeLedgerEnabled is off. ' +
  'Turn it on once functions automation, tenant-lifecycle, messaging-twilio, integrations, public-website, ' +
  'admin and hosting are all deployed. The dispute then posts on its next Stripe event; to post it sooner, ' +
  'resend one of the eventIds below from the Stripe Dashboard.';

/**
 * Records a dispute event the webhook did not post because the switch is
 * off. Written to stripeWebhookRefusals (which facility and account deletes
 * and the platform purge already clear, and the pre-deploy check lists), so
 * a super admin can see what is waiting. Throws on failure: the webhook then
 * returns 500 and Stripe retries, rather than a held dispute leaving no trace.
 */
export async function recordHeldDispute(params: {
  facilityId: string;
  tenantId: string | null;
  connectedAccountId: string | null | undefined;
  disputeId: string;
  paymentIntentId: string;
  chargeId: string | null;
  eventType: string;
  eventId?: string;
  status: string | null;
  reason: string | null;
  amount: number;
}): Promise<void> {
  const now = admin.firestore.FieldValue.serverTimestamp();
  await admin
    .firestore()
    .collection(STRIPE_WEBHOOK_REFUSALS_COLLECTION)
    .doc(heldDisputeDocId(params.connectedAccountId, params.disputeId))
    .set(
      {
        reason: DISPUTE_LEDGER_OFF_REASON,
        eventType: params.eventType,
        eventId: params.eventId ?? null,
        objectId: params.disputeId,
        facilityId: params.facilityId,
        tenantId: params.tenantId,
        eventAccount: params.connectedAccountId || null,
        paymentIntentId: params.paymentIntentId,
        chargeId: params.chargeId,
        disputeStatus: params.status,
        disputeReason: params.reason,
        amount: params.amount,
        action: HELD_DISPUTE_ACTION,
        eventTypes: admin.firestore.FieldValue.arrayUnion(params.eventType),
        ...(params.eventId ? { eventIds: admin.firestore.FieldValue.arrayUnion(params.eventId) } : {}),
        refusals: admin.firestore.FieldValue.increment(1),
        resolved: false,
        lastRefusedAt: now,
      },
      { merge: true },
    );
  functions.logger.warn('Card dispute held: appConfig/payments.disputeLedgerEnabled is off', {
    disputeId: params.disputeId,
    facilityId: params.facilityId,
    eventType: params.eventType,
    eventId: params.eventId ?? null,
  });
}

/**
 * Closes the held row for a dispute once the webhook has posted it. Nothing
 * to do when it was never held. Best effort: the dispute is on the ledger
 * either way, and the pre-deploy check would only list it again.
 */
export async function resolveHeldDispute(connectedAccountId: string | null | undefined, disputeId: string): Promise<void> {
  const ref = admin
    .firestore()
    .collection(STRIPE_WEBHOOK_REFUSALS_COLLECTION)
    .doc(heldDisputeDocId(connectedAccountId, disputeId));
  try {
    const snap = await ref.get();
    if (!snap.exists || snap.get('reason') !== DISPUTE_LEDGER_OFF_REASON || snap.get('resolved') === true) return;
    await ref.update({
      resolved: true,
      resolvedBy: 'system@stripe-webhook',
      resolvedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  } catch (error) {
    functions.logger.warn('Could not close the held-dispute row', {
      disputeId,
      error: (error as Error)?.message ?? String(error),
    });
  }
}

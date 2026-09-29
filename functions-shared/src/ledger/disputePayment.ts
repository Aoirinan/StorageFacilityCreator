import * as admin from 'firebase-admin';
import { disputeCredit, DISPUTE_LEDGER_TYPE } from './disputeEntries';

/**
 * A payment staff take by hand for a card dispute (charge the card on file,
 * or a public payment link) names the dispute it pays, as `disputeId`.
 *
 * The payment's ledger row then carries `metadata.disputeId`, so it nets
 * against the dispute inside `disputed` (disputeEntries.ts). Untagged, it
 * landed in `collectible` while the dispute stayed in `disputed`: autopay
 * and the delinquency job then saw next month's rent as already paid, and
 * the ledger kept asking staff to collect the dispute a second time.
 *
 * The id is checked against the webhook's own row (`ledgers/dispute_{id}`,
 * stripeWebhookDisputeCreated.ts) because a tagged payment moves money out of
 * what automation collects: tagging an ordinary payment would raise the
 * collectible balance autopay charges. The amount may not be more than the
 * dispute still has out: the excess is money the tenant would have to be
 * refunded, not a payment anyone asked for.
 *
 * A dispute can still end up paid twice (collected by hand, then won, or a
 * link paid after the win): [notifyIfDisputeOverpaid] tells staff to refund
 * it, and until they do it is a credit against rent (disputeEntries.ts).
 *
 * The app's "Record payment for this dispute" (lib/widgets/dispute_payment_dialog.dart,
 * with the amount from lib/providers/ledger_provider.dart openDisputeOutstanding)
 * applies the same limit to cash, check and the other methods it records itself.
 */

/** Stripe dispute ids (`du_…`, older `dp_…`); nothing that could leave the ledgers collection. */
const DISPUTE_ID_PATTERN = /^[A-Za-z0-9_]{1,128}$/;

/** The ledger row the dispute webhook posts when a dispute takes the money back. */
export function disputeLedgerEntryId(disputeId: string): string {
  return `dispute_${disputeId}`;
}

export type DisputePaymentRefusal =
  | 'invalid_dispute_id'
  | 'dispute_not_found'
  | 'dispute_of_another_tenant'
  | 'dispute_not_open'
  | 'amount_over_dispute'
  | 'fraud_dispute_card_charge';

export type DisputePaymentCheck =
  | { ok: true; disputeId: string | null }
  | { ok: false; reason: DisputePaymentRefusal; message: string };

function cents(value: number): number {
  return Math.round(value * 100) / 100;
}

/**
 * What a dispute still has out: its posted rows (the dispute, a reversal,
 * payments already taken for it) summed. Every one carries its
 * `metadata.disputeId`.
 */
export function disputeOutstanding(
  rows: ReadonlyArray<{ status?: unknown; amount?: unknown; metadata?: unknown }>,
  disputeId: string,
): number {
  let total = 0;
  for (const row of rows) {
    if (row.status !== 'posted') continue;
    const metadata = (row.metadata || {}) as { disputeId?: unknown };
    if (metadata.disputeId !== disputeId) continue;
    if (typeof row.amount === 'number' && Number.isFinite(row.amount)) total += row.amount;
  }
  return cents(total);
}

/** The reason Stripe gives for a dispute where the cardholder says they never made the charge. */
const FRAUDULENT_DISPUTE_REASON = 'fraudulent';

/**
 * Whether [raw] (a callable's optional `disputeId`) names a dispute this
 * tenant still owes, and [amount] is no more than it has out. Absent or
 * blank is fine: an ordinary payment.
 *
 * [options.cardOnFile]: the payment would charge the tenant's saved card.
 * Refused for a `fraudulent` dispute: the cardholder has told their bank
 * they never made the charge, so charging a card on file again needs them
 * to pay it themselves (cash, check, or a payment link they complete).
 */
export async function checkDisputeForPayment(
  db: admin.firestore.Firestore,
  facilityId: string,
  tenantId: string,
  raw: unknown,
  amount: number,
  options: { cardOnFile?: boolean } = {},
): Promise<DisputePaymentCheck> {
  if (raw === undefined || raw === null || (typeof raw === 'string' && raw.trim() === '')) {
    return { ok: true, disputeId: null };
  }
  const disputeId = typeof raw === 'string' ? raw.trim() : '';
  if (!DISPUTE_ID_PATTERN.test(disputeId)) {
    return { ok: false, reason: 'invalid_dispute_id', message: 'That is not a card dispute id.' };
  }
  const ledgers = db.collection('facilities').doc(facilityId).collection('ledgers');
  const row = await ledgers.doc(disputeLedgerEntryId(disputeId)).get();
  const data = row.exists ? (row.data() as Record<string, unknown>) : null;
  if (!data || data.type !== DISPUTE_LEDGER_TYPE) {
    return { ok: false, reason: 'dispute_not_found', message: 'That card dispute is not on this facility\'s ledger.' };
  }
  if (data.tenantId !== tenantId) {
    return { ok: false, reason: 'dispute_of_another_tenant', message: 'That card dispute is on another tenant\'s ledger.' };
  }
  const metadata = (data.metadata || {}) as Record<string, unknown>;
  // Voided by staff, or won (the webhook marks the original settled by its
  // reversal): there is nothing left to collect for it.
  if (data.status !== 'posted' || metadata.settledByEntryId) {
    return { ok: false, reason: 'dispute_not_open', message: 'That card dispute has nothing left to collect.' };
  }
  if (options.cardOnFile && metadata.reason === FRAUDULENT_DISPUTE_REASON) {
    return {
      ok: false,
      reason: 'fraud_dispute_card_charge',
      message:
        'The cardholder told their bank they did not make this charge, so it cannot go on the card on file. ' +
        'Take it by cash or check, or send a payment link the tenant pays themselves.',
    };
  }
  const tenantRows = await ledgers.where('tenantId', '==', tenantId).get();
  const outstanding = disputeOutstanding(
    tenantRows.docs.map((doc) => doc.data()),
    disputeId,
  );
  if (outstanding <= 0) {
    return { ok: false, reason: 'dispute_not_open', message: 'That card dispute has already been paid.' };
  }
  if (!(amount > 0) || cents(amount) > outstanding) {
    return {
      ok: false,
      reason: 'amount_over_dispute',
      message: `That card dispute has $${outstanding.toFixed(2)} left to collect.`,
    };
  }
  return { ok: true, disputeId };
}

/** Notifications/{id} for a dispute the tenant has paid twice. */
export const DISPUTE_OVERPAID_NOTIFICATION_PREFIX = 'disputeOverpaid_';

export function disputeOverpaidNotificationId(disputeId: string): string {
  return `${DISPUTE_OVERPAID_NOTIFICATION_PREFIX}${disputeId}`;
}

function disputeOverpaidMessage(credit: number, disputeId: string): string {
  const amount = `$${credit.toFixed(2)}`;
  return (
    `The tenant has paid ${amount} more towards card dispute ${disputeId} than the dispute took back: ` +
    'it was collected by hand (cash, the card on file or a payment link) and then won or voided, ' +
    `so they have paid it twice. Refund ${amount} to them. Until it is refunded it is a credit on ` +
    'their ledger, and autopay and the reminders ask for that much less.'
  );
}

/**
 * Tells staff when the tenant has paid card dispute [disputeId] twice: a
 * payment was taken for it by hand (or by link), and then the facility won
 * it (Stripe returned the money) or staff voided it, or a dispute link was
 * paid after that. Before, the money sat on the ledger as a dispute credit
 * nobody was told about.
 *
 * Writes `Notifications/disputeOverpaid_{disputeId}` (STRIPE_ACTION_REQUIRED)
 * when the tenant's posted rows for the dispute show a credit
 * ([disputeCredit]). Safe to call on every delivery of every event: the
 * notification is only rewritten (and shown unread again) when the amount
 * changes. Returns the credit, 0 when there is none. Throws on Firestore
 * failure, so a webhook caller returns 500 and Stripe retries.
 */
export async function notifyIfDisputeOverpaid(params: {
  db: admin.firestore.Firestore;
  facilityId: string;
  tenantId: string | null | undefined;
  disputeId: string;
  createdBy: string;
  now?: Date;
}): Promise<number> {
  const { db, facilityId, tenantId, disputeId } = params;
  if (!facilityId || !tenantId || !DISPUTE_ID_PATTERN.test(disputeId)) return 0;
  const facilityRef = db.collection('facilities').doc(facilityId);
  const rows = await facilityRef.collection('ledgers').where('tenantId', '==', tenantId).get();
  const credit = disputeCredit(
    rows.docs.map((doc) => doc.data()),
    disputeId,
  );
  if (credit <= 0) return 0;

  const creditCents = Math.round(credit * 100);
  const notificationRef = facilityRef.collection('Notifications').doc(disputeOverpaidNotificationId(disputeId));
  const tenantRef = facilityRef.collection('tenants').doc(tenantId);
  const timestamp = admin.firestore.Timestamp.fromDate(params.now ?? new Date());
  await db.runTransaction(async (tx) => {
    const existing = await tx.get(notificationRef);
    const told = existing.exists ? (existing.get('metadata') as { creditCents?: unknown } | undefined) : undefined;
    // Already told about this amount: leave it, and whether staff read it, alone.
    if (told?.creditCents === creditCents) return;
    const tenantSnap = await tx.get(tenantRef);
    const name = tenantSnap.exists ? tenantSnap.get('name') : null;
    tx.set(notificationRef, {
      facilityId,
      tenantId,
      tenantName: typeof name === 'string' && name.trim() ? name.trim() : null,
      type: 'STRIPE_ACTION_REQUIRED',
      message: disputeOverpaidMessage(credit, disputeId),
      readAt: null,
      createdAt: timestamp,
      createdBy: params.createdBy,
      metadata: { reason: 'dispute_paid_twice', disputeId, creditCents },
    });
  });
  return credit;
}

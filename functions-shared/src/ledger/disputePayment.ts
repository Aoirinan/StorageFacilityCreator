import type * as admin from 'firebase-admin';
import { DISPUTE_LEDGER_TYPE } from './disputeEntries';

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
 * collectible balance autopay charges. For the same reason the amount may not
 * be more than the dispute still has out: the excess would sit in `disputed`
 * as a credit that no rent is ever set against, while autopay kept charging
 * the rent in full.
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
  | 'amount_over_dispute';

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

/**
 * Whether [raw] (a callable's optional `disputeId`) names a dispute this
 * tenant still owes, and [amount] is no more than it has out. Absent or
 * blank is fine: an ordinary payment.
 */
export async function checkDisputeForPayment(
  db: admin.firestore.Firestore,
  facilityId: string,
  tenantId: string,
  raw: unknown,
  amount: number,
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

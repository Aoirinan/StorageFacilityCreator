/**
 * Ledger rows a card dispute writes, and what automation may collect.
 *
 * The Stripe webhook (functions-integrations stripeWebhookDisputeCreated.ts)
 * posts `dispute` (+amount) when a dispute takes the money back out of the
 * facility's account and `dispute_reversal` (-amount) when it comes back. Both
 * stay on the tenant's ledger and in their balance, so staff see what is owed.
 *
 * Automation must leave them out. Autopay summed every posted row and charged
 * the total, so the amount a cardholder had just disputed went straight back
 * onto the same card: re-billing a charged-back amount without new consent,
 * which card-network rules forbid, and on a `fraudulent` dispute a second
 * charge to a possibly stolen card. When the facility then won, the reversal
 * left the tenant having paid the disputed amount twice. A disputed amount is
 * collected by hand, by staff, with the tenant's fresh consent. The one
 * exception is a dispute the tenant has paid twice, which is a credit (see
 * [splitLedgerBalance]).
 *
 * The app has the same rule (lib/models/ledger_entry_model.dart,
 * isDisputeLedgerRow). Both test suites run the cases in
 * src/test/fixtures/disputeLedgerParity.json: change one, change the other.
 */

export const DISPUTE_LEDGER_TYPE = 'dispute';
export const DISPUTE_REVERSAL_LEDGER_TYPE = 'dispute_reversal';

type LedgerRowLike = { type?: unknown; amount?: unknown; metadata?: unknown } | null | undefined;

/**
 * Whether a ledger row belongs to a card dispute: either dispute type, or any
 * row carrying a `metadata.disputeId` (the webhook stamps it on both, and it
 * survives a client that re-labels the type).
 */
export function isDisputeLedgerRow(row: LedgerRowLike): boolean {
  if (!row) return false;
  if (row.type === DISPUTE_LEDGER_TYPE || row.type === DISPUTE_REVERSAL_LEDGER_TYPE) return true;
  const metadata = row.metadata;
  if (metadata && typeof metadata === 'object') {
    const disputeId = (metadata as { disputeId?: unknown }).disputeId;
    if (typeof disputeId === 'string' && disputeId.trim().length > 0) return true;
  }
  return false;
}

function amountOf(row: LedgerRowLike): number {
  const amount = row?.amount;
  return typeof amount === 'number' && Number.isFinite(amount) ? amount : 0;
}

function toCents(value: number): number {
  return Math.round(value * 100) / 100;
}

/** The dispute a row belongs to: its trimmed `metadata.disputeId`, or '' for an old id-less dispute row. */
function disputeKeyOf(row: LedgerRowLike): string {
  const metadata = row?.metadata;
  if (metadata && typeof metadata === 'object') {
    const disputeId = (metadata as { disputeId?: unknown }).disputeId;
    if (typeof disputeId === 'string' && disputeId.trim().length > 0) return disputeId.trim();
  }
  return '';
}

/** The webhook's own rows for a dispute (the money taken back, and returned). */
function isDisputeMovementRow(row: LedgerRowLike): boolean {
  return row?.type === DISPUTE_LEDGER_TYPE || row?.type === DISPUTE_REVERSAL_LEDGER_TYPE;
}

type DisputeGroup = {
  /** Every row of the dispute: what it still has out (negative once overpaid). */
  outstanding: number;
  /** Rows staff added for it (payments taken by hand, refunds of them): what the tenant paid towards it. */
  paid: number;
};

function groupDisputeRows(rows: Iterable<LedgerRowLike>): Map<string, DisputeGroup> {
  const groups = new Map<string, DisputeGroup>();
  for (const row of rows) {
    if (!isDisputeLedgerRow(row)) continue;
    const key = disputeKeyOf(row);
    const group = groups.get(key) ?? { outstanding: 0, paid: 0 };
    const amount = amountOf(row);
    group.outstanding += amount;
    if (!isDisputeMovementRow(row)) group.paid += amount;
    groups.set(key, group);
  }
  return groups;
}

/**
 * A dispute group's credit (zero or negative): money the tenant paid for it
 * beyond what it has out, never more than they actually paid for it. A
 * reversal whose dispute row staff voided is not money anyone paid, so it
 * is no credit (it counts in the total only).
 */
function groupCredit(group: DisputeGroup): number {
  const outstanding = toCents(group.outstanding);
  if (outstanding >= 0) return 0;
  return Math.min(0, Math.max(outstanding, toCents(group.paid)));
}

export type LedgerBalanceSplit = {
  /** Every row: what the tenant owes, as staff see it. */
  total: number;
  /** What open card disputes still have out (never negative): staff collect it by hand. */
  disputed: number;
  /**
   * The rest: the most automation may collect. A dispute the tenant has paid
   * twice (collected by hand, then won) is a credit here.
   */
  collectible: number;
};

/**
 * Splits already-filtered (posted) ledger rows into the disputed part and the
 * part automation may collect. Rounded to cents; non-numeric amounts count as 0.
 *
 * Each dispute is summed on its own (by `metadata.disputeId`):
 *
 * - Money still out on it is `disputed`, left out of what automation collects.
 * - Money the tenant paid for it beyond that (a payment taken by hand or by
 *   link, and then the dispute was won or voided) is a credit in
 *   `collectible`. Kept in `disputed`, it was a credit no rent was ever set
 *   against: autopay charged the next month in full on a $0 balance, and
 *   the reminders and the delinquency job asked for it too. The dispute
 *   webhook tells staff to refund it (disputePayment.ts notifyIfDisputeOverpaid).
 */
export function splitLedgerBalance(rows: ReadonlyArray<LedgerRowLike>): LedgerBalanceSplit {
  let total = 0;
  let collectible = 0;
  for (const row of rows) {
    total += amountOf(row);
    if (!isDisputeLedgerRow(row)) collectible += amountOf(row);
  }
  let disputed = 0;
  for (const group of groupDisputeRows(rows).values()) {
    const outstanding = toCents(group.outstanding);
    if (outstanding > 0) disputed += outstanding;
    else collectible += groupCredit(group);
  }
  return {
    total: toCents(total),
    disputed: toCents(disputed),
    collectible: toCents(collectible),
  };
}

/**
 * How much the tenant has paid for dispute [disputeId] beyond what it took
 * back (zero or positive): the refund staff owe them. Posted rows only.
 */
export function disputeCredit(
  rows: ReadonlyArray<{ status?: unknown; type?: unknown; amount?: unknown; metadata?: unknown }>,
  disputeId: string,
): number {
  const posted = rows.filter((row) => row.status === 'posted' && disputeKeyOf(row) === disputeId && isDisputeLedgerRow(row));
  const group = groupDisputeRows(posted).get(disputeId);
  const credit = group ? -groupCredit(group) : 0;
  return credit > 0 ? toCents(credit) : 0;
}

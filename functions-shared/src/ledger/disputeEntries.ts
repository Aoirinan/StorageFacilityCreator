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
 * collected by hand, by staff, with the tenant's fresh consent.
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

export type LedgerBalanceSplit = {
  /** Every row: what the tenant owes, as staff see it. */
  total: number;
  /** Dispute rows only: positive while a dispute has the money out. */
  disputed: number;
  /** Everything else: the most automation may collect. */
  collectible: number;
};

/**
 * Splits already-filtered (posted) ledger rows into the disputed part and the
 * part automation may collect. Rounded to cents; non-numeric amounts count as 0.
 */
export function splitLedgerBalance(rows: ReadonlyArray<LedgerRowLike>): LedgerBalanceSplit {
  let disputed = 0;
  let collectible = 0;
  for (const row of rows) {
    if (isDisputeLedgerRow(row)) disputed += amountOf(row);
    else collectible += amountOf(row);
  }
  return {
    total: toCents(disputed + collectible),
    disputed: toCents(disputed),
    collectible: toCents(collectible),
  };
}

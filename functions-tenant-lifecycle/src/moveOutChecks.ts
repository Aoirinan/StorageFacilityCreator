import { formatUnitLabel } from '@sfc/functions-shared';

import { TenantUnit, cents, isHeld } from './moveOutTenantFields';

type DocData = Record<string, unknown>;

function text(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

/**
 * The unit a contract was signed for, or '' when it records none. Online
 * move-ins record it in customFields.onlineMoveInContext; a top-level
 * unitId is read too. Contracts made in the app record no unit.
 */
export function contractUnitId(contract: DocData): string {
  const context = (contract.customFields as DocData | undefined)?.onlineMoveInContext as DocData | undefined;
  return text(contract.unitId) || text(context?.unitId);
}

/**
 * Why processMoveOut must not end [contract] for [tenantId]: it is another
 * tenant's. Checked before the "already completed" answer. The screen always
 * sends a matching pair, but a direct call with tenant t1 and t2's contract
 * ended t2's contract and moved t1 out, and t2's real move-out was then
 * answered "already completed" and did nothing. A contract with no tenantId
 * (none is written without one today) is not refused.
 */
export function contractTenantRefusal(contract: DocData, tenantId: string): string | null {
  const owner = text(contract.tenantId);
  if (!owner || owner === tenantId) return null;
  return 'This contract belongs to another tenant, so nothing was moved out. Open the move-out from their own contract.';
}

/**
 * A unit as the owner is told to find it: its number with its area when it
 * has one ("12 (Complex 2)"), as the app's unit lists and pickers name it,
 * else [fallback] (its id). Where numbers repeat across areas "unit 12"
 * names two units, and the refusal below says which one to unassign.
 */
function unitLabel(data: DocData | undefined, fallback: string): string {
  return formatUnitLabel({ number: data?.unitNumber, area: data?.area, includeArea: true }) || fallback;
}

/**
 * Why ending [contract] by vacating [unitId] ([unit], its doc) is refused:
 * the contract was signed for another unit that [tenantId] still holds, so
 * ending it would end their agreement for a unit they keep renting. A
 * contract whose unit they no longer hold (moved to another unit since) may
 * end with the unit they are in.
 */
export function contractUnitRefusal(input: {
  contract: DocData;
  tenantId: string;
  unitId: string;
  unit: DocData;
  linkedUnits: TenantUnit[];
}): string | null {
  const signedFor = contractUnitId(input.contract);
  if (!signedFor || signedFor === input.unitId) return null;
  const kept = input.linkedUnits.find((u) => u.id === signedFor && isHeld(u, input.tenantId));
  if (!kept) return null;
  const keptNumber = unitLabel(kept.data, signedFor);
  const leaving = unitLabel(input.unit, input.unitId);
  return (
    `This contract is for unit ${keptNumber}, which this tenant still rents, so ending it would end ` +
    `their agreement for unit ${keptNumber}. Nothing was moved out. To free unit ${leaving} only, ` +
    `use Units > unit ${leaving} > Unassign Tenant.`
  );
}

/** A finite number, else 0. */
function amountOf(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) ? cents(value) : 0;
}

/**
 * The ledger rows processMoveOut posts for the money side of a move-out,
 * under the ledger's sign rule (every balance is the plain sum of posted
 * amounts: LedgerService.getLedgerBalance, getBalancesForFacility, the
 * server sums): charges positive, payments and credits negative, and a
 * refund positive, since paying money back removes a credit the tenant
 * held. The charge.refunded webhook, processRefund and the app's own
 * move-out path already post refunds positive.
 *
 * [charges] is the screen's net of the move-out lines: rent for days used,
 * fees, and a credit for unused days of a month already billed, so it can
 * be negative. It is posted either way: a negative net used to be dropped,
 * so the credit a refund was paid out of never reached the ledger.
 *
 * The refund is posted only when the owner says it was made (processRefund)
 * by cash, check or ACH. It used to be posted negative, and whether or not
 * it was made: a $50 refund took a -$50 balance to -$100.
 *
 * A card refund is not made or posted here: [cardRefund] is its amount,
 * which the move-out screen then refunds through the processRefund callable
 * (functions-integrations) against the tenant's card payments. That call
 * makes the refund on the facility's Stripe account and posts it to the
 * ledger as `refund_<Stripe refund id>`, the row charge.refunded converges
 * on, so it is counted once. Whatever it cannot refund stays on the ledger
 * as the tenant's credit, and [refundWarning] says what the owner does
 * then. Stripe's webhook alone does not post it for every payment: an
 * online move-in payment carries no tenantId on its PaymentIntent, and a
 * checkout-link payment carries no metadata on it at all. For one that
 * names its tenant (autopay, a saved card, the portal) it does, so the
 * owner is told to look for that row before adding one: "refund in Stripe,
 * then Add entry" counted those refunds twice.
 */
export function moveOutLedgerRows(input: {
  moveOutCharges: unknown;
  moveOutRefund: unknown;
  processRefund?: unknown;
  refundMethod?: unknown;
}): {
  charges: { type: 'moveOutFee' | 'credit'; amount: number; description: string } | null;
  refund: { amount: number; method: string } | null;
  cardRefund: number | null;
  refundWarning: string | null;
} {
  const net = amountOf(input.moveOutCharges);
  const charges =
    net > 0
      ? { type: 'moveOutFee' as const, amount: net, description: 'Move-out charges' }
      : net < 0
        ? { type: 'credit' as const, amount: net, description: 'Move-out credit (unused prorated rent, less any fees)' }
        : null;
  const refund = amountOf(input.moveOutRefund);
  const method = text(input.refundMethod) || 'manual';
  if (input.processRefund !== true || refund <= 0) {
    return { charges, refund: null, cardRefund: null, refundWarning: null };
  }
  if (method === 'creditCard') {
    return {
      charges,
      refund: null,
      cardRefund: refund,
      refundWarning:
        `The $${refund.toFixed(2)} card refund was not made by the move-out, and it stays on their ledger ` +
        'as a credit. Refund it to their card in your Stripe dashboard. Wait a minute, then look at their ' +
        'ledger: Stripe records some card refunds there itself, as a "Refund for charge …" row. Only if none ' +
        'has appeared for it, record it on their ledger (Add entry, type Refund).',
    };
  }
  return { charges, refund: { amount: refund, method }, cardRefund: null, refundWarning: null };
}

/**
 * The card refund a finished move-out left 'pending' on [contract]
 * (`moveOutCardRefund`, which the screen replaces with what it refunded, or
 * with 'manual' when the owner chooses to refund it in Stripe themselves):
 * the move-out committed, but the screen never reported back, most likely
 * because processMoveOut's answer never reached it, so it never refunded
 * the card. A second press is answered alreadyCompleted with no
 * cardRefundDue, so nothing is refunded again on its own; this tells the
 * screen the refund is still owed, so it can say so and ask the owner
 * before making it. [since] is when the move-out was committed (ISO), or
 * null on a record without it. Null when no card refund is pending.
 */
export function pendingCardRefund(contract: DocData): { requested: number; since: string | null } | null {
  const record = contract.moveOutCardRefund as DocData | undefined;
  if (!record || record.status !== 'pending') return null;
  const requested = amountOf(record.requested);
  if (requested <= 0) return null;
  const at = record.at as { toDate?: () => Date } | undefined;
  const since = typeof at?.toDate === 'function' ? at.toDate().toISOString() : null;
  return { requested, since };
}

/**
 * When a move-out that left a card refund to the screen was committed, for
 * the first press to check its refund against (`cardRefundSince`): the
 * [contract] read back after the commit has it as its pending record's
 * `at`. A second session can press Complete in the time between the commit
 * and the first press's answer, be offered the pending refund
 * (pendingCardRefund) and make it. Any refund row on the ledger from then
 * on may be that refund, and the first press planning its own from what
 * is left put it on another payment, or at another amount, under another
 * processRefund key, so Stripe refunded it twice. [startedAt], taken
 * before the transaction, stands in when the record is not there to read:
 * it is earlier, so it rules out no more than the commit would.
 */
export function cardRefundSince(contract: DocData | undefined, startedAt: Date): string {
  return (contract ? pendingCardRefund(contract)?.since : null) ?? startedAt.toISOString();
}

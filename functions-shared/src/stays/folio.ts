/**
 * Folio arithmetic for Stays (spec §8.2): what a direct guest owes, what has
 * been paid, and how each payment splits into pass-through tax and income.
 * Integer cents throughout; nothing here reads or writes Firestore.
 */
import type { StayDoc, StayFolioDoc, StayPaymentStatus } from './contracts';
import { ACTIVE_STAY_STATUSES, OTA_SOURCES } from './contracts';

/** The money fields of a folio this module works on. */
export type FolioMoney = Pick<StayFolioDoc, 'totalCents' | 'taxCents' | 'paidCents' | 'balanceCents'>;

/** Records `cents` against the folio (negative for money given back). Returns a new folio. */
export function applyPayment<F extends FolioMoney>(folio: F, cents: number): F {
  if (!Number.isInteger(cents)) throw new Error('applyPayment: cents must be an integer');
  const paidCents = folio.paidCents + cents;
  return { ...folio, paidCents, balanceCents: folio.totalCents - paidCents };
}

/**
 * The largest folio total the pro-rata split handles exactly in
 * floating-point integers (share × part stays below 2^53). A stay's total
 * is capped well under it (MAX_FOLIO_TOTAL_CENTS in quote.ts).
 */
export const MAX_SPLIT_TOTAL_CENTS = 60_000_000;

/** floor(a / b) for non-negative integers, exact (a < 2^53, b > 0). */
function floorDiv(a: number, b: number): number {
  let q = Math.floor(a / b);
  // Float division can land one off right at an integer boundary.
  while (q * b > a) q--;
  while ((q + 1) * b <= a) q++;
  return q;
}

/**
 * The share of `partCents` (tax, or cleaning) carried by a payment of
 * `amountCents`, pro rata to `totalCents`, when `paidBeforeCents` had already
 * been paid. It is cumulative: the share of everything paid so far is
 * rounded half-up once, and this payment carries the difference, so a folio
 * paid in several instalments carries exactly `partCents` in all, never a
 * cent more or less. Money past the total (an overpayment) carries none, and
 * a refund carries the matching negative share.
 */
export function splitProRata(amountCents: number, partCents: number, totalCents: number, paidBeforeCents: number): number {
  if (![amountCents, partCents, totalCents, paidBeforeCents].every(Number.isInteger)) {
    throw new Error('splitProRata: every amount must be an integer number of cents');
  }
  if (totalCents <= 0 || partCents <= 0) return 0;
  if (totalCents > MAX_SPLIT_TOTAL_CENTS) throw new Error('splitProRata: folio total too large');
  const part = Math.min(partCents, totalCents);
  // round(paid × part / total), half-up; paid is clamped to [0, total].
  const shareOf = (paid: number): number => {
    const clamped = Math.max(0, Math.min(paid, totalCents));
    return floorDiv(2 * clamped * part + totalCents, 2 * totalCents);
  };
  return shareOf(paidBeforeCents + amountCents) - shareOf(paidBeforeCents);
}

/**
 * A payment's pass-through tax and net (net = amount − tax), from the folio
 * as it was before the payment. Pass-through tax is never income.
 */
export function splitTaxProRata(amountCents: number, folio: Pick<FolioMoney, 'taxCents' | 'totalCents' | 'paidCents'>): {
  taxCents: number;
  netCents: number;
} {
  const taxCents = splitProRata(amountCents, folio.taxCents, folio.totalCents, folio.paidCents);
  return { taxCents, netCents: amountCents - taxCents };
}

export interface PaymentStatusOptions {
  /** True when money has been given back and the folio now holds none. */
  refunded?: boolean;
}

/**
 * The stay's payment chip (no amounts on the stay doc itself):
 * - blocks: 'none';
 * - another channel's booking: 'channel_collected' (Airbnb and the rest take the money);
 * - otherwise from the folio: 'paid' when the total is covered, 'partial'
 *   when some is paid, 'refunded' when money was given back and exactly
 *   none is held, 'due' when more was given back than is held (a payment
 *   voided after its refund) or a booking that still holds its nights owes
 *   money, else 'none' (nothing owed, or a cancelled booking never paid).
 */
export function paymentStatusOf(
  folio: Pick<FolioMoney, 'totalCents' | 'paidCents'> | null | undefined,
  stay: Pick<StayDoc, 'kind' | 'source' | 'status'>,
  opts: PaymentStatusOptions = {},
): StayPaymentStatus {
  if (stay.kind !== 'reservation') return 'none';
  if ((OTA_SOURCES as readonly string[]).includes(stay.source)) return 'channel_collected';
  if (!folio) return 'none';
  const { totalCents, paidCents } = folio;
  if (paidCents > 0) return paidCents >= totalCents ? 'paid' : 'partial';
  // Negative paid: the guest was refunded money the folio no longer holds
  // (the check it refunded was voided), so they owe it back. Callers pass
  // `refunded` from the stored chip, which would otherwise keep "refunded".
  if (paidCents < 0) return 'due';
  if (opts.refunded === true) return 'refunded';
  const holdsNights = (ACTIVE_STAY_STATUSES as readonly string[]).includes(stay.status);
  return holdsNights && totalCents > 0 ? 'due' : 'none';
}

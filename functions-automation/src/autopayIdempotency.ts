/**
 * Making an autopay charge safe to retry.
 *
 * The worker charges the card, then writes the ledger payment, then advances
 * the schedule. Those are three separate operations and only the first moves
 * money. If the invocation dies in between — a timeout partway through a large
 * facility, a Firestore write failure — the card has been charged, the balance
 * still reads as owing, and the schedule is still due. The next night then
 * charges the same tenant again for the same rent.
 *
 * The job claim prevents a *redelivered* Firestore event from starting a second
 * run, but not this: the next night is a legitimately new job.
 *
 * The fix is an idempotency key scoped to the scheduled run being paid, not to
 * the moment of the attempt. A retry for the same scheduled run reuses the key,
 * so Stripe returns the original PaymentIntent instead of creating a second
 * charge, and the worker can finish the bookkeeping it failed to complete.
 * A genuinely new month has a different scheduled run, so it charges normally.
 */

/**
 * Idempotency key for one autopay charge.
 *
 * Includes the amount deliberately: if the balance changed between attempts the
 * charge is a different charge, and reusing the key would silently bill the old
 * amount. Stripe rejects a reused key with different parameters, which would be
 * a confusing failure rather than a safe one.
 */
export function autopayIdempotencyKey(params: {
  facilityId: string;
  tenantId: string;
  paymentMethodDocId: string;
  /** The scheduled run this charge is paying for. */
  scheduledRun: Date | null | undefined;
  amountCents: number;
}): string {
  // A missing scheduled run should not collapse every tenant onto one key.
  const period = params.scheduledRun
    ? params.scheduledRun.toISOString().slice(0, 10)
    : 'unscheduled';
  return [
    'autopay',
    params.facilityId,
    params.tenantId,
    params.paymentMethodDocId,
    period,
    String(params.amountCents),
  ].join('_');
}

/**
 * Whether a ledger payment for this PaymentIntent has already been recorded.
 *
 * With idempotency, a retry receives the original succeeded PaymentIntent back.
 * Without this check the worker would then write a second ledger entry for a
 * single charge, turning a prevented double charge into a double *credit* —
 * the tenant's balance would drop twice for one payment.
 */
export function hasLedgerEntryForPayment(
  entries: ReadonlyArray<{ referenceId?: unknown }>,
  paymentIntentId: string,
): boolean {
  if (!paymentIntentId) return false;
  return entries.some((e) => String(e?.referenceId || '') === paymentIntentId);
}

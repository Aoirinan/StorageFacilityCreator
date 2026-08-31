/**
 * Pure decision logic for the scheduled autopay job (`processAutopayPayments`).
 *
 * Extracted from autopayScheduled.ts so it can be unit-tested without Firestore
 * or Stripe. The scheduled job is the only recurring-charge path that actually
 * runs in production, and it moves real money, so the decisions about *whether*
 * and *how much* to charge should be verifiable in isolation.
 */

/** Shape we care about from `facilities/{facilityId}`. */
export interface AutopayFacilityData {
  stripeConnectAccountId?: string;
  stripeStatus?: { chargesEnabled?: boolean };
  billingSettings?: Record<string, unknown>;
}

/** Shape we care about from `paymentMethods/{id}.autopaySchedule`. */
export interface AutopaySchedule {
  amount?: number;
  includeInsurance?: boolean;
  frequency?: string;
  dayOfMonth?: number;
  dayOfWeek?: number;
}

/**
 * Whether a facility is ready to have tenant cards charged.
 *
 * Tenant customers and payment methods are created on the facility's *connected*
 * Stripe account, so charging requires both an account id and charges being
 * enabled on it. Skipping early keeps facilities that never finished Connect
 * onboarding from accruing bogus `autopayLastResult: 'failed'` writes.
 */
export function isFacilityChargeReady(
  facilityData: AutopayFacilityData | undefined | null,
): boolean {
  return Boolean(
    facilityData?.stripeConnectAccountId && facilityData?.stripeStatus?.chargesEnabled,
  );
}

/**
 * Whether an autopay schedule is due.
 *
 * A missing next-run is treated as *not* due: it means the schedule was never
 * initialised, and charging on that basis would be a surprise withdrawal.
 */
export function isAutopayDue(
  nextRun: Date | null | undefined,
  now: Date,
): boolean {
  if (!nextRun) return false;
  return now.getTime() >= nextRun.getTime();
}

/**
 * Sum posted ledger entries into an outstanding balance.
 *
 * Entries are signed: charges positive, payments negative. Non-numeric or
 * missing amounts count as zero rather than poisoning the total with NaN.
 */
export function sumLedgerBalance(
  entries: ReadonlyArray<{ amount?: unknown }>,
): number {
  let balance = 0;
  for (const entry of entries) {
    const amount = entry?.amount;
    if (typeof amount === 'number' && Number.isFinite(amount)) {
      balance += amount;
    }
  }
  return balance;
}

/**
 * How much to charge for one autopay run.
 *
 * A positive fixed `schedule.amount` overrides the ledger balance (that's the
 * "charge me exactly $X monthly" case); otherwise the outstanding balance is
 * used. Insurance is added on top only when the schedule opts in and the
 * facility actually configures an amount.
 */
export function resolveChargeAmount(
  balance: number,
  schedule: AutopaySchedule | undefined | null,
  facilityData: AutopayFacilityData | undefined | null,
): number {
  let amount = balance;

  if (schedule?.amount && schedule.amount > 0) {
    amount = schedule.amount;
  }

  if (schedule?.includeInsurance) {
    const defaultInsurance = facilityData?.billingSettings?.['defaultInsuranceAmount'];
    if (typeof defaultInsurance === 'number' && Number.isFinite(defaultInsurance)) {
      amount += defaultInsurance;
    }
  }

  return roundMoney(amount);
}

/** Only charge a positive amount against a stored payment method. */
/**
 * Smallest charge Stripe accepts in USD. Below this a PaymentIntent is
 * rejected outright, so attempting one is a guaranteed failure.
 */
export const MIN_CHARGEABLE_USD = 0.5;

/**
 * Round a money value to whole cents.
 *
 * Ledger amounts are floating point and prorated rent is
 * monthlyRate * days / daysInMonth, which is rarely exact — six of the ninety
 * three entries in the live facility already carry sub-cent precision. Summing
 * those leaves residue like 1e-15 on an account that is actually settled.
 */
export function roundMoney(value: number): number {
  if (!Number.isFinite(value)) return 0;
  return Math.round(value * 100) / 100;
}

export function shouldAttemptCharge(
  amount: number,
  stripePaymentMethodId: unknown,
): boolean {
  // `amount > 0` let floating-point residue through: a tenant who had paid in
  // full could carry a balance of 1e-15, pass this check, and then be sent to
  // Stripe as a zero-cent charge, which is rejected. That failed every run, and
  // with failure handling now disarming after three declines it would switch
  // off autopay for someone who owed nothing.
  //
  // Rounding to cents first, then requiring Stripe's minimum, means we only
  // attempt charges that can actually succeed. A genuine sub-minimum balance is
  // left to accumulate rather than failing nightly.
  const cents = roundMoney(amount);
  return (
    cents >= MIN_CHARGEABLE_USD &&
    typeof stripePaymentMethodId === 'string' &&
    stripePaymentMethodId.length > 0
  );
}

/**
 * Next run date after a successful charge.
 *
 * `now` is injected rather than read from the clock so the rollover cases
 * (month ends, year boundaries) are testable.
 */
export function calculateNextAutopayRun(
  schedule: AutopaySchedule | undefined | null,
  now: Date,
): Date {
  const frequency = schedule?.frequency || 'monthly';

  if (frequency === 'weekly') {
    const dayOfWeek = schedule?.dayOfWeek ?? 1;
    const daysUntilNext = (dayOfWeek - now.getDay() + 7) % 7;
    const nextRun = new Date(now);
    // Landing on "today" means a week out, not a same-day double charge.
    nextRun.setDate(nextRun.getDate() + (daysUntilNext === 0 ? 7 : daysUntilNext));
    return nextRun;
  }

  const dayOfMonth = schedule?.dayOfMonth ?? 1;
  return new Date(now.getFullYear(), now.getMonth() + 1, dayOfMonth);
}

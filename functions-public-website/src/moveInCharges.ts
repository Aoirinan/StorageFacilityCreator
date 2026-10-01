import * as admin from 'firebase-admin';

export type MoveInChargeLine = {
  type: string;
  description: string;
  amount: number;
};

export type MoveInChargeQuote = {
  lineItems: MoveInChargeLine[];
  totalAmount: number;
  totalCents: number;
  /** The unit's monthly rent the quote was priced from (0 when it has none). */
  monthlyRent: number;
};

function numberFromMap(map: Record<string, unknown> | undefined, keys: string[]): number {
  if (!map) return 0;
  for (const key of keys) {
    const value = map[key];
    if (typeof value === 'number' && Number.isFinite(value)) return value;
    if (typeof value === 'string') {
      const parsed = Number.parseFloat(value);
      if (Number.isFinite(parsed)) return parsed;
    }
  }
  return 0;
}

/**
 * The move-in's month, as the days in it and the days of it billed: the
 * move-in day through the last day, both counted.
 *
 * Calendar days, not a difference of timestamps. This used to measure from
 * the move-in instant to midnight at the start of the month's last day, so a
 * move-in with a time of day on it was billed a day short: 15 Sep at 20:00
 * came to 15 days rather than 16, and the last day of a month to 0 days. A
 * renter who gave no move-in date is priced from the moment checkout runs, so
 * on the 30th or 31st their rent came to $0; with no fees Stripe refused the
 * $0 Checkout and they could not pay online at all.
 *
 * The date is read in UTC, deliberately:
 * - A chosen move-in date reaches the hold as the app's local-midnight ISO
 *   string with no offset, which Cloud Functions (TZ=UTC) stores as UTC
 *   midnight of that date; the move-in page reads it back from
 *   getPublicReservationByToken as a UTC instant, and the confirmation email
 *   prints its UTC date. So a chosen date is a UTC calendar date everywhere.
 * - A renter with no move-in date is priced from the instant checkout runs,
 *   and completePublicMoveIn prices again from that same instant
 *   (checkoutMoveInDate), so both quote the same day whatever the reading.
 *   The move-in page must price the same day to send a total checkout
 *   accepts, so it uses today's UTC date too
 *   (ProrateService.onlineMoveInPricingDate).
 * - The local getters this used before only agreed with that because Cloud
 *   Functions runs in UTC; on any other clock (a developer's machine, the
 *   tests) they priced a different day from production.
 */
export function proratedRentDays(moveInDate: Date): { daysInMonth: number; daysBilled: number } {
  const daysInMonth = daysInUtcMonth(moveInDate);
  return { daysInMonth, daysBilled: daysInMonth - moveInDate.getUTCDate() + 1 };
}

function daysInUtcMonth(date: Date): number {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 0)).getUTCDate();
}

/**
 * Prorated rent for the move-in month. Must give the same amount as the app's
 * ProrateService.calculateProratedRent for the same day, because the move-in
 * page sends its total and checkout refuses one that differs by a cent; both
 * are pinned to test/fixtures/move_in_proration.json.
 */
export function calculateProratedRent(monthlyRate: number, moveInDate: Date): number {
  if (!(monthlyRate > 0)) return 0;
  const { daysInMonth, daysBilled } = proratedRentDays(moveInDate);
  const dailyRate = monthlyRate / daysInMonth;
  // Round to whole cents. Unrounded, this returns values like
  // 14.677419354838708, which is not an amount of money — it enters the ledger
  // at full float precision and leaves residue when the balance is settled.
  //
  // Rounded as the app rounds it (Dart's toStringAsFixed(2), which is
  // JavaScript's toFixed on the web), from the exact value of the double.
  // Math.round(x * 100) rounds the product instead, and differs on a
  // half-cent: $10.01 over 15 of 30 days is 5.005, which the app bills as
  // 5.00 and Math.round as 5.01, so checkout refused the page's total.
  return Number((dailyRate * daysBilled).toFixed(2));
}

function resolveMonthlyRent(
  _reservation: Record<string, unknown>,
  unitData: Record<string, unknown> | undefined,
): number {
  // The rent comes from the unit document and nowhere else.
  //
  // This used to prefer `reservation.metadata.monthlyRate`, and the public hold
  // endpoint copies the caller's metadata object verbatim into the reservation.
  // An unauthenticated caller could therefore name their own rent, pay a quote
  // computed from it, and carry that rate into the tenancy as the ongoing
  // monthly charge. No trusted caller writes that key.
  const unitRate = Number(unitData?.monthlyRate);
  if (Number.isFinite(unitRate) && unitRate > 0) {
    return unitRate;
  }
  const parsedUnitRate = Number.parseFloat(String(unitData?.monthlyRate ?? ''));
  return Number.isFinite(parsedUnitRate) && parsedUnitRate > 0 ? parsedUnitRate : 0;
}

/** Server-authoritative move-in charge quote for public online rental. */
export function computePublicMoveInCharges(params: {
  reservation: Record<string, unknown>;
  unitData?: Record<string, unknown>;
  facilityData?: Record<string, unknown>;
  publicSettings?: Record<string, unknown>;
  moveInDate: Date;
}): MoveInChargeQuote {
  const { reservation, unitData, facilityData, publicSettings, moveInDate } = params;
  const billing = (facilityData?.billingSettings as Record<string, unknown> | undefined) || {};
  const monthlyRent = resolveMonthlyRent(reservation, unitData);
  const lineItems: MoveInChargeLine[] = [];

  const proratedRent = calculateProratedRent(monthlyRent, moveInDate);
  if (proratedRent > 0) {
    lineItems.push({
      type: 'proratedRent',
      description: 'Prorated Rent',
      amount: proratedRent,
    });
  }

  const chargeInsuranceAtMoveIn = publicSettings?.chargeInsuranceAtMoveIn === true;
  const publicInsuranceAmount = Number(publicSettings?.publicInsuranceAmount ?? 0);
  if (chargeInsuranceAtMoveIn && publicInsuranceAmount > 0) {
    lineItems.push({
      type: 'insurance',
      description: 'Insurance',
      amount: publicInsuranceAmount,
    });
  }

  const adminFee = numberFromMap(billing, ['adminFee', 'admin_fee', 'newTenantAdminFee']);
  if (adminFee > 0) {
    lineItems.push({ type: 'adminFee', description: 'Admin Fee', amount: adminFee });
  }

  const moveInFee = numberFromMap(billing, ['moveInFee', 'move_in_fee']);
  if (moveInFee > 0) {
    lineItems.push({ type: 'moveInFee', description: 'Move-In Fee', amount: moveInFee });
  }

  const chargeSecurityDepositAtMoveIn = publicSettings?.chargeSecurityDepositAtMoveIn === true;
  const publicSecurityDepositAmount = Number(publicSettings?.publicSecurityDepositAmount ?? 0);
  const unitSecurityDeposit = Number(unitData?.securityDeposit ?? 0);
  const billingDeposit = numberFromMap(billing, [
    'securityDeposit',
    'security_deposit',
    'depositAmount',
  ]);
  let securityDeposit = 0;
  if (chargeSecurityDepositAtMoveIn) {
    if (publicSecurityDepositAmount > 0) {
      securityDeposit = publicSecurityDepositAmount;
    } else if (unitSecurityDeposit > 0) {
      securityDeposit = unitSecurityDeposit;
    } else if (billingDeposit > 0) {
      securityDeposit = billingDeposit;
    }
  }
  if (securityDeposit > 0) {
    lineItems.push({
      type: 'securityDeposit',
      description: 'Security Deposit',
      amount: securityDeposit,
    });
  }

  const chargeNextMonthAfterMidMonthMoveIn =
    publicSettings?.chargeNextMonthAfterMidMonthMoveIn === true;
  if (chargeNextMonthAfterMidMonthMoveIn && monthlyRent > 0) {
    // The same UTC calendar day the rent was prorated from.
    const daysInMonth = daysInUtcMonth(moveInDate);
    const isAfterHalfway = moveInDate.getUTCDate() > Math.floor(daysInMonth / 2);
    if (isAfterHalfway) {
      lineItems.push({
        type: 'rent',
        description: 'Next Month Rent',
        amount: monthlyRent,
      });
    }
  }

  const totalAmount = lineItems.reduce((sum, item) => sum + item.amount, 0);
  return {
    lineItems,
    totalAmount: Math.round(totalAmount * 100) / 100,
    totalCents: Math.round(totalAmount * 100),
    monthlyRent,
  };
}

/** Whether the facility takes move-in payments online (Stripe Connect set up). */
export function facilityTakesOnlinePayments(facilityData: Record<string, unknown>): boolean {
  const connectAccountId = String(facilityData.stripeConnectAccountId || '').trim();
  const onboardingComplete = facilityData.stripeConnectOnboardingComplete === true;
  return connectAccountId.length > 0 && onboardingComplete;
}

export function isPublicMoveInStripePaymentRequired(
  facilityData: Record<string, unknown>,
  totalAmount: number,
): boolean {
  return facilityTakesOnlinePayments(facilityData) && totalAmount > 0;
}

export const MOVE_IN_NOT_PRICED_MESSAGE =
  'This move-in could not be priced. Contact the facility to finish renting this unit.';

/**
 * A move-in the facility is paid for online that the quote prices at nothing.
 *
 * Rent of any size makes the first day cost something, so a unit with rent
 * quoted at $0 means the pricing went wrong, as it did on the last day of
 * every month. With nothing to pay, completePublicMoveIn takes the no-payment
 * path, so a caller who skipped checkout was moved in for free. Such a quote
 * is refused instead.
 *
 * Not refused, because nothing is owed online by design: a facility that has
 * not set up online payments (the renter pays the facility, and the charges go
 * on their ledger), and a unit with no rent and no fees.
 */
export function isUnpricedPaidMoveIn(
  facilityData: Record<string, unknown>,
  quote: Pick<MoveInChargeQuote, 'totalCents' | 'monthlyRent'>,
): boolean {
  return facilityTakesOnlinePayments(facilityData) && quote.monthlyRent > 0 && quote.totalCents <= 0;
}

export function amountsMatchCents(expectedCents: number, providedAmount: number): boolean {
  const providedCents = Math.round(Number(providedAmount) * 100);
  return Number.isFinite(providedCents) && providedCents === expectedCents;
}

export async function loadPublicMoveInChargeQuote(params: {
  facilityId: string;
  reservation: Record<string, unknown>;
  moveInDate: Date;
}): Promise<MoveInChargeQuote> {
  const { facilityId, reservation, moveInDate } = params;
  const unitId = String(reservation.unitId || '').trim();

  const [facilitySnap, publicSnap, unitSnap] = await Promise.all([
    admin.firestore().collection('facilities').doc(facilityId).get(),
    admin
      .firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('settings')
      .doc('public')
      .get(),
    unitId
      ? admin.firestore().collection('facilities').doc(facilityId).collection('units').doc(unitId).get()
      : Promise.resolve(null),
  ]);

  return computePublicMoveInCharges({
    reservation,
    unitData: unitSnap?.exists ? (unitSnap.data() as Record<string, unknown>) : undefined,
    facilityData: facilitySnap.exists ? (facilitySnap.data() as Record<string, unknown>) : undefined,
    publicSettings: publicSnap.exists ? (publicSnap.data() as Record<string, unknown>) : undefined,
    moveInDate,
  });
}

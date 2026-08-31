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

/** Prorated rent for move-in month (matches ProrateService.calculateProratedRent). */
export function calculateProratedRent(monthlyRate: number, moveInDate: Date): number {
  if (monthlyRate <= 0) return 0;
  const daysInMonth = new Date(moveInDate.getFullYear(), moveInDate.getMonth() + 1, 0).getDate();
  const lastDayOfMonth = new Date(moveInDate.getFullYear(), moveInDate.getMonth() + 1, 0);
  const daysRemaining =
    Math.floor((lastDayOfMonth.getTime() - moveInDate.getTime()) / 86_400_000) + 1;
  const dailyRate = monthlyRate / daysInMonth;
  // Round to whole cents. Unrounded, this returns values like
  // 14.677419354838708, which is not an amount of money — it enters the ledger
  // at full float precision and leaves residue when the balance is settled.
  return Math.round(dailyRate * daysRemaining * 100) / 100;
}

function resolveMonthlyRent(
  reservation: Record<string, unknown>,
  unitData: Record<string, unknown> | undefined,
): number {
  const metadata = (reservation.metadata as Record<string, unknown> | undefined) || {};
  const reservationRate = Number(metadata.monthlyRate);
  if (Number.isFinite(reservationRate) && reservationRate > 0) {
    return reservationRate;
  }
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
    const daysInMonth = new Date(moveInDate.getFullYear(), moveInDate.getMonth() + 1, 0).getDate();
    const isAfterHalfway = moveInDate.getDate() > Math.floor(daysInMonth / 2);
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
  };
}

export function isPublicMoveInStripePaymentRequired(
  facilityData: Record<string, unknown>,
  totalAmount: number,
): boolean {
  const connectAccountId = String(facilityData.stripeConnectAccountId || '').trim();
  const onboardingComplete = facilityData.stripeConnectOnboardingComplete === true;
  return connectAccountId.length > 0 && onboardingComplete && totalAmount > 0;
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

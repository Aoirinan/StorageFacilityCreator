/**
 * Pure decision logic for monthly rent-charge generation.
 *
 * Extracted so the "should this tenant be charged, and have they already been
 * charged this month" rules can be tested without Firestore. Getting the
 * duplicate check wrong bills a tenant twice for the same month.
 */

const MONTH_NAMES = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/**
 * Whether a tenant should have rent raised.
 *
 * Requires an assigned unit and a positive rate. A blank unit number means the
 * tenant record is not actually occupying anything, and a zero or missing rate
 * means there is nothing to bill — charging either would invent revenue.
 */
export function shouldChargeTenant(tenantData: Record<string, any> | undefined | null): boolean {
  if (!tenantData) return false;

  const unitNumber = tenantData.unitNumber;
  if (typeof unitNumber !== 'string' || unitNumber.trim() === '') return false;

  const monthlyRate = tenantData.monthlyRate;
  return typeof monthlyRate === 'number' && Number.isFinite(monthlyRate) && monthlyRate > 0;
}

/**
 * Whether this month's rent charge already exists for a tenant.
 *
 * Matches on the charge metadata rather than the entry date alone: a manually
 * dated adjustment in the same month must not be mistaken for the recurring
 * charge, or the tenant would silently go un-billed.
 */
export function hasRentChargeForMonth(
  ledgerEntries: ReadonlyArray<Record<string, any>>,
  targetMonth: number,
  targetYear: number,
): boolean {
  return ledgerEntries.some((entry) => {
    const entryDate: Date | undefined = entry?.entryDate?.toDate?.();
    if (!entryDate) return false;

    if (entryDate.getMonth() + 1 !== targetMonth) return false;
    if (entryDate.getFullYear() !== targetYear) return false;

    const metadata = entry.metadata || {};
    return (
      metadata.recurringCharge === true &&
      metadata.chargeType === 'monthlyRent' &&
      metadata.month === targetMonth &&
      metadata.year === targetYear
    );
  });
}

/** Human-readable description, e.g. "Monthly Rent - March 2026". */
export function buildRentChargeDescription(targetDate: Date): string {
  return `Monthly Rent - ${MONTH_NAMES[targetDate.getMonth()]} ${targetDate.getFullYear()}`;
}

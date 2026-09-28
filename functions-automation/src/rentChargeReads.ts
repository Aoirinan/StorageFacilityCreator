import * as admin from 'firebase-admin';
import {
  MonthlyRentChargePlan,
  RENT_CHARGE_LEDGER_TYPES,
  isRentChargeForMonth,
  moveInRentCoversForMonth,
  planMonthlyRentCharge,
  rentChargeLedgerWindow,
} from './rentChargeHelpers';

/**
 * What the month's rent charge should be for one tenant, from their ledger:
 * the id of the charge already posted for the month, or the plan
 * (planMonthlyRentCharge) for posting it.
 *
 * Shared by the scheduled job and the generateMonthlyRentCharges callable so
 * the two cannot disagree about what a move-in already charged.
 */
export async function planTenantRentCharge(params: {
  facilityId: string;
  tenantId: string;
  monthlyRate: number;
  year: number;
  month: number;
}): Promise<{ existingChargeId: string } | { existingChargeId: null; plan: MonthlyRentChargePlan }> {
  const { facilityId, tenantId, monthlyRate, year, month } = params;
  const facility = admin.firestore().collection('facilities').doc(facilityId);

  // Bounded to the month and the one before it (see rentChargeLedgerWindow):
  // the month's own charge, and the move-in rent that may cover it. Reading a
  // tenant's whole history is wasted work that grows every month they stay.
  const { start, end } = rentChargeLedgerWindow(year, month);
  const ledgerSnapshot = await facility
    .collection('ledgers')
    .where('tenantId', '==', tenantId)
    .where('type', 'in', [...RENT_CHARGE_LEDGER_TYPES])
    .where('status', '==', 'posted')
    .where('entryDate', '>=', admin.firestore.Timestamp.fromDate(start))
    .where('entryDate', '<', admin.firestore.Timestamp.fromDate(end))
    .get();

  const existing = ledgerSnapshot.docs.find((doc) => isRentChargeForMonth(doc.data(), month, year));
  if (existing) return { existingChargeId: existing.id };

  const covers = moveInRentCoversForMonth(
    ledgerSnapshot.docs.map((doc) => ({ ...doc.data(), id: doc.id })),
    month,
    year,
  );
  if (covers.length === 0) {
    return { existingChargeId: null, plan: planMonthlyRentCharge({ monthlyRate, covers, heldUnitCount: 0 }) };
  }

  // Only for a tenant whose move-in rent covers the month: how many units
  // they rent (as TenantService.linkedUnits), and which covering contracts
  // have since been moved out.
  const [unitsSnapshot, ...contracts] = await Promise.all([
    facility.collection('units').where('tenantId', '==', tenantId).get(),
    ...covers
      .filter((c) => c.contractId !== '')
      .map((c) => facility.collection('contracts').doc(c.contractId).get()),
  ]);
  const heldUnitCount = unitsSnapshot.docs.filter((doc) => doc.data().archived !== true).length;
  const movedOutContractIds = new Set(
    contracts.filter((doc) => doc.exists && doc.data()?.moveOutStatus === 'completed').map((doc) => doc.id),
  );

  return {
    existingChargeId: null,
    plan: planMonthlyRentCharge({ monthlyRate, covers, heldUnitCount, movedOutContractIds }),
  };
}

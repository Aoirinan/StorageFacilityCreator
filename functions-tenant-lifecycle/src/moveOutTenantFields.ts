type DocData = Record<string, unknown>;

/** A unit the moving-out tenant is linked to, as read in the move-out transaction. */
export type TenantUnit = { id: string; data: DocData };

function rateOf(data: DocData | null | undefined): number {
  const rate = data?.monthlyRate;
  return typeof rate === 'number' && Number.isFinite(rate) ? rate : 0;
}

function numberOf(data: DocData | null | undefined): string {
  return String(data?.unitNumber ?? '').trim();
}

/** Occupied by them in some way: a unit marked available with a stale link is not (as in the app). */
function isHeld(unit: TenantUnit, tenantId: string): boolean {
  return (
    unit.data.tenantId === tenantId &&
    String(unit.data.status ?? '') !== 'available' &&
    unit.data.archived !== true
  );
}

/**
 * The tenant fields processMoveOut writes when [unitId] is vacated.
 *
 * Their last unit: the tenancy ends (unitNumber cleared, inactive), rate
 * kept as history, as before. Still renting elsewhere: they stay active,
 * and their monthlyRate loses this unit's rate (never below 0), because a
 * tenant's rate is the sum of the rates of the units they hold and the rent
 * job bills that one number. It used to be left alone, so a tenant who gave
 * up one of two units kept paying for both. A unitNumber that named the
 * vacated unit moves to a unit they still hold; the rent job bills tenants
 * with a unit number, so it is never cleared while they rent another.
 */
export function tenantFieldsAfterMoveOut(input: {
  tenantId: string;
  tenant: DocData;
  unitId: string;
  unit: DocData;
  stillRentsElsewhere: boolean;
  /** The units linked to the tenant, read in the same transaction. */
  linkedUnits: TenantUnit[];
}): DocData {
  const { tenantId, tenant, unitId, unit, stillRentsElsewhere, linkedUnits } = input;
  if (!stillRentsElsewhere) {
    return { unitNumber: '', isActive: false };
  }
  const fields: DocData = {
    monthlyRate: Math.max(0, rateOf(tenant) - rateOf(unit)),
  };
  const vacated = numberOf(unit);
  if (vacated && numberOf(tenant) === vacated) {
    const other = linkedUnits.find((u) => u.id !== unitId && isHeld(u, tenantId) && numberOf(u.data));
    if (other) fields.unitNumber = numberOf(other.data);
  }
  return fields;
}

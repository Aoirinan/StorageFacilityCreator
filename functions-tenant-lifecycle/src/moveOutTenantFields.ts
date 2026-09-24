type DocData = Record<string, unknown>;

/** A unit the moving-out tenant is linked to, as read in the move-out transaction. */
export type TenantUnit = { id: string; data: DocData };

/** A unit's number and monthly rate, as rentAfterUnitChange sums them. */
export type UnitRent = { unitNumber: string; rate: number };

function rateOf(data: DocData | null | undefined): number {
  const rate = data?.monthlyRate;
  return typeof rate === 'number' && Number.isFinite(rate) ? rate : 0;
}

function numberOf(data: DocData | null | undefined): string {
  return String(data?.unitNumber ?? '').trim();
}

/** [x] rounded to the cent: sums of rates drift (100.1 + 150.2 is 250.29999999999998). */
export function cents(x: number): number {
  return Math.round(x * 100) / 100;
}

/** "a", "a and b", "a, b and c" (TenantService.joinReadable). */
function joinReadable(parts: string[]): string {
  if (parts.length <= 1) return parts.join('');
  return `${parts.slice(0, -1).join(', ')} and ${parts[parts.length - 1]}`;
}

function unitsLabel(numbers: string[]): string {
  return `${numbers.length === 1 ? 'unit' : 'units'} ${joinReadable(numbers)}`;
}

/** Occupied by them in some way: a unit marked available with a stale link is not (as in the app). */
export function isHeld(unit: TenantUnit, tenantId: string): boolean {
  return (
    unit.data.tenantId === tenantId &&
    String(unit.data.status ?? '') !== 'available' &&
    unit.data.archived !== true
  );
}

function unitRent(unit: TenantUnit): UnitRent {
  return { unitNumber: numberOf(unit.data), rate: rateOf(unit.data) };
}

/**
 * A tenant's monthly rent once the units in [released] (some of
 * [heldBefore], the units they held) are freed and [added] is added.
 *
 * Decided rule: a tenant's monthlyRate is the sum of the rates of the units
 * they hold, since the rent job bills that one number. It is only kept that
 * way automatically for a tenant it already describes: [current] equal, to
 * the cent, to the rates of [heldBefore]. Subtracting blindly took a tenant
 * billed one rate for two units (every multi-unit tenant from before the
 * rule) to $0 when they moved out of one. For anyone else monthlyRate is
 * null (leave it alone) and notice asks the owner to check it, unless it
 * already is the sum of the units they hold afterwards. An automatic rate is
 * never 0 or less while they hold a unit, and is rounded to the cent. Both
 * null when they hold none afterwards: the tenancy ends, rate kept as history.
 *
 * PARITY: TenantService.rentAfterUnitChange in lib/services/tenant_service.dart.
 * Both test suites run src/test/fixtures/rentAfterUnitChange.json.
 */
export function rentAfterUnitChange(input: {
  tenantName: string;
  current: number;
  heldBefore: UnitRent[];
  released?: UnitRent[];
  added?: UnitRent | null;
}): { monthlyRate: number | null; notice: string | null; needsCheck: boolean } {
  const after = [...input.heldBefore];
  for (const unit of input.released ?? []) {
    const i = after.findIndex((u) => u.unitNumber === unit.unitNumber && u.rate === unit.rate);
    if (i >= 0) after.splice(i, 1);
  }
  if (input.added) after.push(input.added);
  if (after.length === 0) return { monthlyRate: null, notice: null, needsCheck: false };
  const sum = (units: UnitRent[]) => cents(units.reduce((total, u) => total + u.rate, 0));
  const numbers = after.map((u) => u.unitNumber);
  const rate = sum(after);
  const current = cents(input.current);
  if (current === sum(input.heldBefore) && rate > 0) {
    return {
      monthlyRate: rate,
      notice: `Monthly rent is now $${rate.toFixed(2)} for ${unitsLabel(numbers)}.`,
      needsCheck: false,
    };
  }
  if (current === rate && rate > 0) return { monthlyRate: null, notice: null, needsCheck: false };
  return {
    monthlyRate: null,
    notice:
      `Check ${input.tenantName}'s rent: they now hold ${unitsLabel(numbers)}; ` +
      `their rent is $${current.toFixed(2)}.`,
    needsCheck: true,
  };
}

/**
 * What processMoveOut writes to the tenant when [unitId] is vacated, and
 * what it tells the owner about their rent.
 *
 * Their last unit: the tenancy ends (unitNumber cleared, inactive), rate
 * kept as history, as before. Still holding another unit (the same test as
 * the app's recordMoveOut: a unit that names them and is not available; it
 * used to be another active contract, so a tenant given a second unit by
 * Edit Tenant or Units > Assign Tenant was switched off while still in it):
 * they stay active, and the vacated unit's rate comes off theirs under
 * rentAfterUnitChange's rule, only when the unit was theirs (a unit someone
 * else holds, or one already freed, was not). A unitNumber that named the
 * vacated unit moves to a unit they still hold; the rent job bills tenants
 * with a unit number, so it is never cleared while they rent another.
 */
export function tenantFieldsAfterMoveOut(input: {
  tenantId: string;
  tenant: DocData;
  unitId: string;
  unit: DocData;
  /** The units linked to the tenant, read in the same transaction. */
  linkedUnits: TenantUnit[];
}): { fields: DocData; rentNotice: string | null; rentWarning: string | null; endsTenancy: boolean } {
  const { tenantId, tenant, unitId, unit, linkedUnits } = input;
  const stillHeld = linkedUnits.filter((u) => u.id !== unitId && isHeld(u, tenantId));
  if (stillHeld.length === 0) {
    return { fields: { unitNumber: '', isActive: false }, rentNotice: null, rentWarning: null, endsTenancy: true };
  }
  const fields: DocData = {};
  let rentNotice: string | null = null;
  let rentWarning: string | null = null;
  const vacatedUnit: TenantUnit = { id: unitId, data: unit };
  if (isHeld(vacatedUnit, tenantId)) {
    const name = String(tenant.name ?? '').trim() || tenantId;
    const change = rentAfterUnitChange({
      tenantName: name,
      current: rateOf(tenant),
      heldBefore: [...stillHeld, vacatedUnit].map(unitRent),
      released: [unitRent(vacatedUnit)],
    });
    if (change.monthlyRate !== null) fields.monthlyRate = change.monthlyRate;
    if (change.needsCheck) rentWarning = change.notice;
    else rentNotice = change.notice;
  }
  const vacated = numberOf(unit);
  if (vacated && numberOf(tenant) === vacated) {
    const other = stillHeld.find((u) => numberOf(u.data));
    if (other) fields.unitNumber = numberOf(other.data);
  }
  return { fields, rentNotice, rentWarning, endsTenancy: false };
}

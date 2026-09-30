import { isUnitHeldByTenant } from '@sfc/functions-shared';
import type { ActiveTenantUnitClaims } from '@sfc/functions-shared';

/**
 * Someone else has the unit [unitId] ([unit] is its doc), or the owner has it
 * out of service: a status other than available or reserved (a missing one is
 * let through, as move-in always has), a link to a tenant, or an active
 * tenant who claims it ([claims], from readActiveTenantUnitClaims: by their
 * unitId, or with none by number in their area). The public map shows the
 * last two as rented. Renting it would overwrite that tenant or that status,
 * or put a second tenant in the unit, so it is refused before payment and
 * refunded after (completion, and the sweep of unfinished paid move-ins).
 */
export function unitIsTaken(unitId: string, unit: Record<string, unknown>, claims: ActiveTenantUnitClaims): boolean {
  const status = String(unit.status || '').toLowerCase();
  if (status && status !== 'available' && status !== 'reserved') return true;
  return isUnitHeldByTenant(unitId, unit, claims);
}

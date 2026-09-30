/**
 * Which units active tenants hold although the unit doc does not say so (no
 * `tenantId` on it): a tenant added with a unit number and never linked from
 * the unit, an import, a shared parking space. The public map shows such a
 * unit as rented, so it is not offered online.
 *
 * Tenants link to their unit by id (`unitId`), and a facility can number
 * units per area (`unitNumbersRepeatAcrossAreas`), so "12" can be a unit in
 * Complex 2 and another in Complex 3. Matching every active tenant's
 * `unitNumber` against every unit's number marked both 12s rented when one
 * tenant held one of them. The rule, unitId first as the app's tenant
 * lookups read it (TenantService):
 *
 * - An active tenant (`isActive` exactly true) whose `unitId` names one of
 *   [units] holds that unit, and no other.
 * - Otherwise their `unitNumber` (trimmed, ignoring case; read as
 *   `String(unitNumber || '')`, so 101 is '101' and 0 claims nothing) names
 *   every unit so numbered or, when none is numbered so now, every unit
 *   renumbered from it (`legacyUnitNumber`). With a `unitArea`
 *   (areas compared trimmed, spaces collapsed, ignoring case), only the
 *   units in that area, when one is there. A tenant's number that names
 *   several units and no area claims all of them: the map would rather hide
 *   a free unit than rent a taken one.
 *
 * [units] are the facility's live units (not archived), the ones the map is
 * published from.
 *
 * PARITY: FacilityMapV2Service.unitIdsClaimedByActiveTenants in
 * lib/services/facility_map_v2_service.dart. Both writers of
 * publicFacilityMaps/{slug}.units run test/fixtures/public_map_units.json.
 */

type Doc = Record<string, unknown>;

/** A unit doc and its id. */
export interface ClaimableUnit {
  id: string;
  data: Doc;
}

/** Trimmed text, or null when [raw] is not a string or is blank. */
function text(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const trimmed = raw.trim();
  return trimmed === '' ? null : trimmed;
}

/**
 * How unit numbers compare: trimmed, ignoring case; '' for none. A number or
 * boolean reads as its text (an imported 101 is '101'), as the app's
 * textFromField reads it; anything else, such as a map, as none.
 */
function numberKey(raw: unknown): string {
  if (typeof raw !== 'string' && typeof raw !== 'number' && typeof raw !== 'boolean') return '';
  return String(raw).trim().toLowerCase();
}

/**
 * The unit number a tenant doc claims, as the inventory sync has always read
 * it (`String(td.unitNumber || '').trim().toLowerCase()`): 0, false and ''
 * claim nothing; anything else not a string, number or boolean, such as a
 * map, claims nothing either. The app's
 * FacilityMapV2Service.tenantClaimedUnitNumber reads it the same way.
 */
function tenantNumberKey(raw: unknown): string {
  return numberKey(raw || '');
}

/** How areas compare (the app's unitAreaKey); null for no area. */
function areaKey(raw: unknown): string | null {
  const area = text(raw);
  return area === null ? null : area.replace(/\s+/g, ' ').toLowerCase();
}

function addTo(index: Map<string, ClaimableUnit[]>, key: string, unit: ClaimableUnit): void {
  const list = index.get(key);
  if (list) list.push(unit);
  else index.set(key, [unit]);
}

export function unitIdsClaimedByActiveTenants(
  tenants: Iterable<Doc>,
  units: Iterable<ClaimableUnit>,
): Set<string> {
  const ids = new Set<string>();
  const byNumber = new Map<string, ClaimableUnit[]>();
  const byLegacyNumber = new Map<string, ClaimableUnit[]>();
  for (const unit of units) {
    ids.add(unit.id);
    const n = numberKey(unit.data.unitNumber);
    if (n !== '') addTo(byNumber, n, unit);
    const legacy = text(unit.data.legacyUnitNumber);
    if (legacy !== null) addTo(byLegacyNumber, numberKey(legacy), unit);
  }

  const claimed = new Set<string>();
  for (const tenant of tenants) {
    if (tenant.isActive !== true) continue;
    const unitId = text(tenant.unitId);
    if (unitId !== null && ids.has(unitId)) {
      claimed.add(unitId);
      continue;
    }
    const n = tenantNumberKey(tenant.unitNumber);
    if (n === '') continue;
    let named = byNumber.get(n) ?? byLegacyNumber.get(n) ?? [];
    const area = areaKey(tenant.unitArea);
    if (area !== null) {
      const inArea = named.filter((u) => areaKey(u.data.area) === area);
      if (inArea.length > 0) named = inArea;
    }
    for (const unit of named) claimed.add(unit.id);
  }
  return claimed;
}

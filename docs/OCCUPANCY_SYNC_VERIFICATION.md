# Occupancy Sync – Verification & Tests

## Canonical rule

- **A unit is "occupied" only if:** `unit.tenantId` is set **and** that tenant exists in the same facility (`tenant.facilityId` matches).
- If `unit.status == 'occupied'` but `tenantId` is null or the tenant doc does not exist → treat as **not occupied** and **auto-heal** (set unit to available, clear `tenantId` / `tenantName`).

## Data sources (before fix)

- **Dashboard** "Total Units (occupied/available)": from `FacilityStatsService.getFacilityStats()` → `facilities/{id}/stats/current` (cached). Fallback: live query with `units.where(status==occupied)` (no tenant check).
- **Facilities card** "X/Y units occupied": from `FacilityStatsService.computeUnitCounts(facility.id)` + fallback `facility.occupiedUnits`.
- **Root cause of "173 occupied, 0 tenants"**: Cached `stats/current` and `facility.occupiedUnits` were not updated after tenant deletes; occupancy was computed as `unit.status == occupied` without verifying tenant existence.

## What was implemented

1. **Canonical occupancy** in Flutter and Cloud Functions: occupied count = units where `status==occupied` **and** `tenantId` in the set of existing tenant IDs for the facility.
2. **Healing**: Orphan units (occupied but tenant missing) are set to `available` and `tenantId`/`tenantName` cleared. Healing runs when recomputing stats (e.g. `updateFacilityStats`, Cloud Function triggers).
3. **Stale cache fix**: `getFacilityStats()` forces recompute when cache has `totalTenantsActive == 0` and `occupiedUnits > 0`.
4. **Tenant delete cascade**: Already in place – unlink units, then `updateFacilityStats`. Counts stay correct after delete.
5. **Recompute entry points**:
   - **Flutter**: `FacilityStatsService.recomputeFacilityStats(facilityId)`, `recomputeAllFacilitiesStats()`. Facilities screen: "Sync counts" button.
   - **Cloud Functions**: `updateFacilityStatsManual` (single facility), `updateAllFacilityStatsNightly` (all facilities). Both now use canonical occupancy + heal and update `facility.occupiedUnits`.

## Acceptance checklist

- [ ] **Zero tenants** → Facilities card shows `0 / total` occupied; Dashboard shows `0 occupied, N available`.
- [ ] **After importing tenants and assigning units** → Counts match (occupied = number of units with valid tenant).
- [ ] **After deleting all tenants** → Counts drop to 0; no ghost occupancy.
- [ ] **No legacy collection** is used for occupancy (only units + tenants for this facility).
- [ ] **Sidebar / Unit list** use stats from `getFacilityStats` or `computeUnitCounts` (canonical).

## Manual tests

1. **Zero tenants, stale cache**
   - Ensure facility has 0 tenants and some units still have `status: occupied` and `tenantId` set (orphans).
   - Open Dashboard → should show 0 occupied after load (getFacilityStats triggers recompute + heal).
   - Open Facilities → card should show `0 / total` (computeUnitCounts is canonical).
   - Optionally: Facilities → "Sync counts" → then re-open Dashboard/Facilities to confirm.

2. **Tenant delete**
   - Assign a tenant to a unit, note occupied count.
   - Delete that tenant → occupied should decrease by 1; unit should show available.

3. **Recompute all**
   - Go to Facilities → click "Sync counts". Dashboard and facility cards should refresh with correct numbers.

## Automated tests (if added)

- Given facility with 0 tenants and N units with `status==occupied` and `tenantId` set: after `recomputeFacilityStats`, `getFacilityStats` returns `occupiedUnits: 0` and those units are updated to `available` with `tenantId` cleared.
- Given unit with `tenantId` pointing to missing tenant: recompute clears the unit and occupied count excludes it.
- Deleting a tenant clears linked unit(s) and recompute shows updated counts.

## Files touched

- `lib/services/facility_stats_service.dart` – canonical counts, heal, `getFacilityStats` stale check, `recomputeFacilityStats` / `recomputeAllFacilitiesStats`.
- `lib/services/unit_service.dart` – `clearTenantFromUnitsBatch`.
- `lib/providers/dashboard_provider.dart` – fallback path uses canonical occupancy.
- `lib/screens/facility_management_screen.dart` – "Sync counts" button.
- `functions/src/facility_stats.ts` – canonical occupancy, heal, update `facility.occupiedUnits` when writing stats.

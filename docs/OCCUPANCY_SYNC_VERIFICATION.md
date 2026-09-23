# Occupancy Sync – Verification & Tests

## Canonical rule (one definition, every screen)

`FacilityStatsService.countUnits(nonArchivedUnits, allTenantIds)` in Flutter and `isRentableUnit` + `countCanonicalOccupied` in `functions-facility-ops/src/facility_stats.ts`:

- **Total** = unit docs that are not archived and not staff-only (`publicListingEnabled != false`, the "List on public website" switch). Office, manager-residence and personal-use units are left out.
- **Occupied** = of those, `status == 'occupied'` **and** `tenantId` is the id of a tenant doc that exists in the facility, **active or archived**. Archiving a tenant does not free the unit.
- **Vacant** = Total − Occupied (reserved and maintenance count as vacant).
- An occupied unit whose tenant doc is missing is an **orphan**: not counted, and healed (set to `available`, `tenantId` / `tenantName` cleared) by the Cloud Function only.

## Where each screen gets its numbers

- **Dashboard** (`dashboardStatsProvider`, autoDispose, reloads on each visit and after returning from tenant/contract detail): computed live from the facility's unit and tenant lists with `countUnits`. The "Total Units" card notes how many staff-only units exist and are not counted. The cached `facilities/{id}/stats/current` doc is not read: no Firestore rule lets clients read it.
- **Units list header**: `countUnits` over the unit and tenant streams already on screen, e.g. `72 / 78 rentable units occupied (4 staff-only not counted)`. The table rows include staff-only units.
- **Facilities card**: `FacilityStatsService.computeUnitCounts` (same rule), memoized per facility on the mirrored counts; falls back to the facility-doc mirror while loading.
- **Facility-doc mirror** (`facility.occupiedUnits`, `facility.unitDocCount`; used by search, super admin, the card fallback): written only by the Cloud Function, same rule.

## Who writes stats and heals orphans

Only the Cloud Function (`functions-facility-ops`):

- `onUnitWrite` / `onTenantWrite` (coalesced, 15 s window) and `updateAllFacilityStatsNightly`.
- `updateFacilityStatsManual`, called by the app's **Sync counts** buttons (`FacilityStatsService.recomputeAllFacilitiesStats`). The caller must have access to the facility (owner, `roles` map, `managers` map, active `user_roles` row) or carry the `superadmin` claim.
- A pass reads units, then all tenants, then active tenants, and heals only after every read has succeeded. A failed read throws; nothing (not even zeros) is written.

The client never heals or writes stats. `FacilityStatsService.updateFacilityStats` is a no-op kept for existing callers: its writes were always denied, and its client-side heal could free rented units from a capped, name-ordered tenant list that returns `[]` on error.

## Acceptance checklist

- [ ] Dashboard, Units list header and Facilities card show the same Total and Occupied for a facility.
- [ ] A facility with staff-only units shows them in the Units table, not in the totals, with the "staff-only not counted" note.
- [ ] A unit held by an archived tenant counts as occupied everywhere.
- [ ] **Zero tenants** → Facilities card shows `0 / total` occupied; Dashboard shows `0 occupied, N vacant`.
- [ ] **After deleting a tenant** → occupied drops by one on the next dashboard visit; the Cloud Function frees the unit if it was left linked.
- [ ] **Sync counts** reports failure (red) if any facility's server recompute fails, never "updated".

## Manual tests

1. **Orphan unit**: set a unit to `occupied` with a `tenantId` that does not exist. Dashboard and Units header do not count it. Within seconds of the write (or after Sync counts) the unit is `available`.
2. **Tenant delete**: assign a tenant to a unit, note occupied count, delete the tenant, return to the dashboard: occupied is one lower.
3. **Sync counts**: click it on the dashboard or Facilities page; the facility cards and the dashboard refresh.

## Automated tests

- `test/facility_stats_logic_test.dart`: `countUnits`, `cachedUnitTotalDrifted`, Sync counts messages and failure tally.
- `test/unit_counts_header_test.dart`, `test/dashboard_load_test.dart`, `test/active_facility_provider_test.dart`, `test/late_overdue_list_test.dart`, `test/chunked_parallel_test.dart`.
- `functions-facility-ops/src/test/facility_stats.test.ts` (archived exclusion, heal scope, no zeros on read failure) and `facility_stats_manual.test.ts` (access check).

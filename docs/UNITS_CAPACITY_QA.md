# Units / Capacity Consistency – QA Checklist

## Summary of changes

- **Reconcile:** `FacilityStatsService.reconcileUnitsToCapacity(facilityId)` heals orphan occupancy and refreshes stats. It does **not** create placeholder unit documents up to `facility.totalUnits` (that was removed so new sites are not filled with empty rows). Optional: `materializeMissingUnitDocumentsUpToCapacity` creates 001…N rows to match capacity (e.g. legacy / special imports).
- **Sync counts:** "Sync counts" on the dashboard runs heal + stats for each facility (no mass unit creation).
- **Facility edit:** Saving a new `totalUnits` still calls reconcile (heal + stats only); change capacity on the facility doc without auto-creating unit rows.
- **Unit List:** Denominator is always facility capacity (`totalUnits`). Occupied = canonical (unit.status==occupied and tenant exists). Display: `occupied / totalCapacity units`.
- **Edit Unit:** Unit List and Unit Detail "Edit" open `/units/edit` with unit as extra → `UnitCreationScreen(facilityId, unit)`.
- **View Details:** Unchanged → `/units/detail?facilityId=&unitId=`.

## QA checklist

- [ ] **Facility totalUnits = 200** → After "Sync counts", `facilities/{id}.totalUnits` is still 200; `units` subcollection may have **fewer** than 200 documents until you add units.
- [ ] **Dashboard:** "Unit capacity" shows 200; occupied + vacant = 200 (using capacity, not unit doc count).
- [ ] **Facilities card:** Shows `X/200` and matches Unit List occupied/200.
- [ ] **Unit List:** Shows `X / 200 units` (not 173 or unit doc count as denominator).
- [ ] **Edit from Unit List:** "Edit" opens unit edit screen; save updates unit and returns; counts stay correct.
- [ ] **Edit from Unit Detail:** "Edit" opens same unit edit screen.
- [ ] **View Details:** Opens unit detail; no legacy/dead routes.
- [ ] **Dark mode:** Unit List search field and labels readable; scrollbars visible where needed.
- [ ] **Contract PDF upload:** Spinner stops on completion (fixed earlier).

## Canonical counts

- **totalCapacity** = `facility.totalUnits`
- **occupiedCount** = units where `status == 'occupied'` AND `tenantId` references an existing active tenant
- **availableCount** = totalCapacity - occupiedCount
- Do not mix tenantCount with occupiedCount.

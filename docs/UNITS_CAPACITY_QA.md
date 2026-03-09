# Units / Capacity Consistency – QA Checklist

## Summary of changes

- **Reconcile:** `FacilityStatsService.reconcileUnitsToCapacity(facilityId)` creates missing unit docs so `unitDocsCount == facility.totalUnits`. Heals orphan occupancy, then creates units with default unitNumber (1, 2, … or 001, 002 if existing use 3+ digits). Does not delete when count > capacity.
- **Sync counts:** "Sync counts" on Facilities screen now runs reconcile for each facility, then updates stats.
- **Facility edit:** Saving facility with a new `totalUnits` runs reconcile so unit count matches capacity.
- **Unit List:** Denominator is always facility capacity (`totalUnits`). Occupied = canonical (unit.status==occupied and tenant exists). Display: `occupied / totalCapacity units`.
- **Edit Unit:** Unit List and Unit Detail "Edit" open `/units/edit` with unit as extra → `UnitCreationScreen(facilityId, unit)`.
- **View Details:** Unchanged → `/units/detail?facilityId=&unitId=`.

## QA checklist

- [ ] **Facility totalUnits = 200** → After "Sync counts" (or after editing facility and saving), units collection count == 200.
- [ ] **Dashboard:** Total Units = 200; occupied + available = 200.
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

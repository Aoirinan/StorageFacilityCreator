# Backfill: Recompute Facility Counts (Idempotent)

## Purpose

Bring a facility's cached counts up to date:

- `facilities/{id}/stats/current`: `totalUnits` (internal-use and archived units left out), `occupiedUnits`, `availableUnits`, `totalTenantsActive`, revenue and past-due counts.
- The facility-doc mirror, `facility.occupiedUnits` and `facility.unitDocCount`, which search, super admin and the Facilities card fallback read.

Counts follow the one rule in [OCCUPANCY_SYNC_VERIFICATION.md](OCCUPANCY_SYNC_VERIFICATION.md): archived and internal-use (`internalUse == true`) units are not counted, units with "List on public website" off are, and a unit held by an archived tenant is occupied. `facility.totalUnits` (the capacity an owner types in) is never read or written.

After deploying a change to the counting rule, the mirror keeps the old numbers for a facility until its next unit or tenant write or the 2 AM nightly run. Run Option 2 (or 3) for each facility to bring it up to date at once.

Safe to run more than once. It is not read-only: a pass also **heals orphan units** (an `occupied` unit whose tenant doc is missing is set to `available`, and its `tenantId` and `tenantName` are cleared). Each heal is conditional on the unit not having changed since the pass read it, so a move-in that lands mid-pass is left alone.

Only the Cloud Functions in `functions-facility-ops` write these; the app does not. No Firestore rule lets a client write `stats/current`. An owner's client could write `occupiedUnits` and `unitDocCount` on the facility doc (the rules do not forbid those keys), but no app code does, and `FacilityStatsService.updateFacilityStats` is a no-op. Calling it backfills nothing.

## Option 1: Wait for it (no action)

- `onUnitWrite` / `onTenantWrite` recompute a facility after any unit or tenant write.
- `updateAllFacilityStatsNightly` recomputes every facility at 2 AM America/New_York.

## Option 2: Sync counts in the app

Click **Sync counts** on the dashboard or the Facilities page. It calls `FacilityStatsService.recomputeAllFacilitiesStats()`, which calls the `updateFacilityStatsManual` callable once per facility the signed-in user can see, and reports how many failed. From code, `FacilityStatsService.recomputeFacilityStats(facilityId)` does one facility and throws if the server did not finish.

The callable requires access to the facility (owner, `roles` map, `managers` map, active `user_roles` row) or the `superadmin` claim, and returns only `{ success: true }`.

## Option 3: Outside the app

`initialize_facility_stats.ps1` prints console and CLI options for calling `updateFacilityStatsManual` with `{ "facilityId": "..." }`. Whatever the route, the call must carry the auth of a user with access to that facility, or the `superadmin` claim.

## After backfill

- Dashboard, Units list header and Facilities card show the same Total and Occupied for each facility.
- `facility.unitDocCount` equals the facility's counted unit total (non-archived, not internal-use).

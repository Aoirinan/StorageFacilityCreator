# Backfill: Recompute Facility Counts (Idempotent)

## Purpose

Ensure every facility has correct cached stats so that:
- **totalUnits** in `facilities/{id}/stats/current` matches **facility.totalUnits** when set (> 0).
- **occupiedUnits** and **totalTenantsActive** are recomputed from current units and tenants.

This is **idempotent**: safe to run multiple times. It overwrites only the stats document, not facility.totalUnits.

## Option 1: Cloud Function (recommended)

If you have `updateFacilityStatsManual` (or equivalent) deployed:

```bash
# Single facility
firebase functions:call updateFacilityStatsManual --data '{"facilityId":"YOUR_FACILITY_ID"}'

# For all facilities, run from Firebase Console or a one-off Node script that:
# 1. Lists all facilities
# 2. For each facilityId, calls updateFacilityStatsManual({ facilityId })
```

## Option 2: Client app (one-off)

From the Flutter app (e.g. a debug screen or main):

1. Get all facility IDs the user can access: `FacilityService.getUserFacilities()`.
2. For each facility: `await FacilityStatsService.updateFacilityStats(facilityId);`
3. Log success/failure per facility.

No production data is deleted; only `facilities/{id}/stats/current` is written.

## Option 3: PowerShell / manual

See **initialize_facility_stats.ps1** for options to trigger stats via Firebase Console or CLI per facility.

## After backfill

- Dashboard and facility list should show **facility.totalUnits** when set (e.g. 200).
- Unit list header and Manager Overlock counts stay in sync with facility stats.

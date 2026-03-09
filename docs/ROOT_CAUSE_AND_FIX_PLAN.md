# Root Cause & Fix Plan – SFC Data-Sync and UI Fixes

## Data model (current)

- **Facility**: `facilities/{id}` – fields include `totalUnits` (user-set capacity), `occupiedUnits` (cached count).
- **Units**: `facilities/{facilityId}/units/{unitId}` – `tenantId`, `tenantName` (denormalized), `status`, `mapLayout` (x, y, width, height), `dimensions` (width, height, depth).
- **Tenants**: `facilities/{facilityId}/tenants/{tenantId}` – `facilityId`, `unitNumber`, etc. No `unitId`; link is unit → tenant via `unit.tenantId`.
- **Stats**: `facilities/{facilityId}/stats/current` – cached `totalUnits`, `occupiedUnits`, `totalTenantsActive`, etc.
- **Map shapes**: Map editor stores unit positions in unit docs (`mapLayout`); unit records are the source of truth for existence.

## Why facility totals didn’t match

- **Cause**: `totalUnits` is set on the facility (e.g. 200), but:
  1. **Facility list** used `FacilityStatsService.computeUnitCounts()`, which returns `(units.length, occupied)` and does **not** use `facility.totalUnits`, so the list showed unit count instead of capacity.
  2. **Stats doc** `stats/current` is filled by `computeFacilityStats()`, which does use `facility.totalUnits` when > 0; if stats were never recomputed after setting totalUnits, or were written before that, cached `totalUnits` could be wrong.
  3. **Dashboard** reads from `getFacilityStats()` which recomputes when `cachedTotalUnits != facility.totalUnits`; so the main gap was facility list and any UI that didn’t use facility.totalUnits for the denominator.
- **Fix**: Use `facility.totalUnits` as the single source of truth for “total units” everywhere when > 0. Facility list subtitle: use `facility.totalUnits` for total and only take occupied from compute/stats. Unit list header: show “X / facility.totalUnits” (occupied from stats or compute). Ensure after facility edit we call `FacilityStatsService.updateFacilityStats()` so `stats/current` is updated.

## Why deleted tenants still appeared (ghost data)

- **Cause**: Deleting a tenant only removed the document from `facilities/{fid}/tenants/{tid}`. Units that referenced that tenant still had `tenantId` and `tenantName` set, so:
  - Unit list showed `unit.tenantName` (ghost name).
  - Manager Overlock showed all units and used `unit.tenantName` and `tenantMap[unit.tenantId]`; for deleted tenants `tenantMap` had no entry but `unit.tenantName` still showed.
- **Fix**:
  1. **Cascade on tenant delete**: Before or after deleting the tenant doc, find all units in that facility with `tenantId == deletedTenantId`, clear `tenantId`/`tenantName`, set status to available, clear move-in date, then update facility counts.
  2. **Defensive UI**: In Manager Overlock (and optionally Unit List), treat “unit has tenantId but tenant not in current tenant list” as no tenant: show “—” and optionally filter those units out of the overlock list so only “live” tenant–unit pairs appear. Prefer cascade so data is consistent everywhere.

## Why unit list / unit details felt “old” and unassign was unclear

- **Cause**: Unit Detail is a separate route with its own Scaffold/AppBar; Unassign existed in the popup menu but wasn’t obvious, and after unassign we didn’t refresh facility counts.
- **Fix**: Keep route; add a clear “Remove tenant from unit” action (button or prominent menu) that calls `UnitService.removeTenantFromUnit()`, then refresh facility stats. Ensure Unit Detail uses current design (theme, back button). Optionally add “Unassign” in Unit List row actions.

## Map editor

- **Tooltip vertical text**: Layout or constraint was forcing narrow width so text stacked. Fix: ensure tooltip content has sensible max width and `softWrap: true` so text wraps horizontally.
- **“Add Rectangle”**: Rename to “Add Unit” (or “Add Unit Shape”).
- **Dimensions**: Unit model already has `dimensions` and `mapLayout` (width/height). Ensure map editor reads/writes these and that they are editable and persist.

## Contracts

- **“View Map” under Contracts**: Remove from Contracts tab (wrong place).
- **Templates duplicated nav**: Contract templates screen is likely wrapped in a layout that already has sidebar; fix so only one sidebar/nav renders.
- **Add default vs Create template**: “Add default templates” = seed predefined template docs; “Create template” = open builder/upload. Split into two actions and UI states.
- **“No tenants found”**: Ensure tenant dropdown uses `TenantService.getTenantsForFacility(selectedFacilityId)` with the same facility as the contract, and that we only consider active tenants if that’s the intended behavior. Add logging and defensive handling for empty or wrong facility.

## Settings

- **Notifications**: Merge “Notification settings” and “Notifications” into one route; keep one screen that toggles persist and actually affects behavior.
- **Appearance**: Wire theme mode (light/dark/system) to a persisted per-user setting and apply on load/refresh.

## AI guardrails

- **Cause**: Guardrails were too strict.
- **Fix**: Add a configurable strictness (e.g. 0–100) via remote config / env / Firestore, with a lower default; keep safety filters but allow tuning without redeploy.

## Implementation summary

| Area | Change |
|------|--------|
| Tenant delete | Cascade: unlink units (clear tenantId/tenantName, status=available), then update facility stats; add logging. |
| Facility totals | Use `facility.totalUnits` for total everywhere when > 0; facility list subtitle and unit list header use it; trigger stats update after facility edit. |
| Stats | Ensure `computeFacilityStats` and `getFacilityStats` use `facility.totalUnits` when > 0; backfill script to recompute all facility stats. |
| Overlock / Unit list | Filter out “ghost” units (tenantId set but tenant not in facilityTenantsProvider); display tenant name from tenantMap when present, else “—”. |
| Unit Detail | Use `removeTenantFromUnit` for unassign; after unassign/assign refresh facility counts; add visible “Remove tenant from unit” action. |
| Map | Tooltip wrap; “Add Unit” label; persist and edit unit dimensions. |
| Contracts | Remove View Map; fix templates layout; split Add default / Create template; fix tenant lookup and logging. |
| Settings | Single notifications screen; appearance persisted and applied. |
| AI | Configurable strictness (remote/config). |
| Backfill | Idempotent script to recompute facility stats for all facilities. |
| Tests | Count recompute; tenant delete cascade; unassign from unit; contract tenant lookup. |

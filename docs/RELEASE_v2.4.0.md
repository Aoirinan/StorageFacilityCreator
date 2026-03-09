# Release v2.4.0 (Build 20260208)

**Deployed:** 2026-02-08  
**Hosting URL:** https://storage-facility-creator.web.app

## Data-sync & UI fixes

- **Facility totals:** `totalUnits` on facility is the single source of truth; dashboard, facility list, and unit list header show it consistently. Stats refresh after facility edit.
- **Tenant delete cascade:** Deleting a tenant unlinks all units referencing that tenant (clears tenantId/tenantName, sets status available), then refreshes facility counts. No more ghost tenants.
- **Manager Overlock & Unit List:** Only show current tenants; units whose tenant was deleted are filtered out. Tenant names come from live tenant data.
- **Unit Detail:** Unassign uses `removeTenantFromUnit`; facility counts refresh; providers invalidated so UI updates.
- **Map editor:** Tooltip text wraps horizontally; button label is “Add Unit” (was “Add Rectangle”).
- **Contracts:** View Map button removed from Contracts tab; Contract Templates use single nav (no double sidebar); “Add default templates” vs “Create template” are separate actions; New Contract tenant picker shows active tenants with clearer messaging and logging.
- **Settings:** Single “Notifications” entry with facility picker when multiple facilities; Appearance theme (Light/Dark/System) persists via SharedPreferences and applies immediately and on refresh.
- **AI Assistant:** Configurable strictness (0–100) in Firestore `appConfig/aiAssistant` field `strictnessLevel`; default 60; lower values relax client-side topic check slightly (e.g. longer non-keyword messages allowed).

## Backfill & tests

- **Backfill:** See `docs/BACKFILL_FACILITY_COUNTS.md` for idempotent options to recompute facility stats.
- **QA checklist:** `docs/QA_CHECKLIST_SYNC_UI.md`
- **Unit test:** `test/facility_stats_logic_test.dart` for `effectiveTotalUnits` (facility capacity vs unit count).

## Version

- **App:** 2.4.0+20260208  
- **Build:** Flutter web → `build/web` → Firebase Hosting

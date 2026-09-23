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
- **Facilities card**: `FacilityStatsService.computeUnitCounts` (same rule), memoized per facility on the mirrored counts; falls back to the facility-doc mirror while loading. A result that disagrees with the mirror (a failed read comes back as zeros) is shown but not kept, so the next rebuild reads again.
- **Dashboard per facility**: `facilityUnitCounts` in `dashboard_provider.dart`, which is `countUnits` over every unit and every tenant doc.
- **Settings → Onboarding** checklist: `onboardingProgressProvider`, one `limit(1)` unit probe and one active-tenant probe per facility. It does not load the dashboard.
- **Facility-doc mirror** (`facility.occupiedUnits`, `facility.unitDocCount`; used by search, super admin, the card fallback): written only by the Cloud Function, same rule.
- **Tenant lists behind the client counts** (`TenantService.getTenantsForFacility` and its streams): unordered reads of up to 5,000 tenant docs, sorted by name client-side with unnamed tenants last. They used to be capped at 250 and ordered by `name`, which dropped the rest and every doc with no name, so those tenants' units counted as empty.
- **Unit lists behind the client counts** (`UnitService.getUnitsForFacility` and `getUnitsForFacilityStream`): unordered reads of up to 5,000 unit docs; archived units (`(archived ?? false) != false`, the Cloud Function's test) are dropped from the whole read, and the rest sorted by unit number client-side. They used to be capped at 400 and ordered by `unitNumber`, with archived units using up the cap and units with no `unitNumber` left out.
- Both reads open their collection through `FacilitySubcollections` (`lib/services/facility_subcollections.dart`). A facility that reaches 5,000 tenant or unit docs is reported once (debug log and Sentry via `FlutterError.onError`).
- **Active tenant**: a tenant doc whose `isActive` is exactly `true` (`TenantModel.isActiveField`). That is what every `where('isActive', isEqualTo: true)` query, the Cloud Function and the server jobs use. A doc with no `isActive` (e.g. a partial doc a server merge-write recreated after its tenant was deleted) is not active anywhere; the app used to read it as active, so the dashboard counted it and the server did not. It still counts as a tenant doc for occupancy, on both sides.

## Who writes stats and heals orphans

Only the Cloud Function (`functions-facility-ops`):

- `onUnitWrite` / `onTenantWrite` (coalesced, 15 s window) and `updateAllFacilityStatsNightly`. When a coalesced pass fails, writes that landed during it get one retry; if it still fails, the claim is released to a 5 s backoff, so a write after that recomputes rather than waiting out the window, and a failure that keeps happening cannot run passes back to back.
- A facility whose doc no longer exists is skipped: no claim (so `stats/recompute` is not recreated), no heal, nothing persisted. The facility-doc update runs before `stats/current` is written, so a facility deleted mid-pass does not get `stats/current` back.
- `updateFacilityStatsManual`, called by the app's **Sync counts** buttons (`FacilityStatsService.recomputeAllFacilitiesStats`). The caller must have access to the facility (owner, `roles` map, `managers` map, active `user_roles` row) or carry the `superadmin` claim. It returns only `{ success: true }`; the stats (revenue, past due) are not sent back.
- A pass reads units, then all tenants, then active tenants, and heals only after every read has succeeded. A failed read throws; nothing (not even zeros) is written.
- Each orphan heal is a separate update with the unit's read `updateTime` as a precondition. A unit that changed since the read (e.g. a move-in relinked it) or was deleted is skipped; its own write triggers another pass.
- An active tenant doc with unreadable dates (no `createdAt`, or a non-Timestamp `paidThrough`) is logged and left out of the past-due counts; it no longer fails the facility's pass. A non-number `monthlyRate` counts as 0.

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

- `test/facility_stats_logic_test.dart`: `countUnits`, `cachedUnitTotalDrifted`, `countsMatchFacilityMirror`, Sync counts messages (an empty facility list is an error) and failure tally.
- `test/tenant_facility_read_test.dart` (`getTenantsForFacility` and both streams on a fake collection: no 250 cap, no name ordering, unnamed tenants kept, bound reported, the active tenant rule), `test/unit_facility_read_test.dart` (`getUnitsForFacility` and its stream: no 400 cap, no `unitNumber` ordering, archived dropped from the whole read), `test/dashboard_load_test.dart` (`loadDashboardStats` on fake collections, and `facilityUnitCounts`), `test/unit_counts_header_test.dart` (header and rows keep the last tenant list through a stream error), `test/keyed_memo_test.dart` (`callKeeping`), `test/settings_onboarding_test.dart`, `test/active_facility_provider_test.dart`, `test/late_overdue_list_test.dart`, `test/chunked_parallel_test.dart`.
- `functions-facility-ops/src/test/facility_stats.test.ts` (archived exclusion, heal scope, heal preconditions sent by the production heal, `updateTime` carried by the production read, deleted facilities, bad tenant docs, no zeros on read failure), `facility_stats_coalesce.test.ts` (retry, claim release to a backoff, no claim for a deleted facility) and `facility_stats_manual.test.ts` (access check, success-only response).

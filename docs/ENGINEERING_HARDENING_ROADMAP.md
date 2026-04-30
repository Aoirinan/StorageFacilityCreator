# Engineering hardening roadmap

This document is the recommended order of work for: **repo hygiene**, **explicit readiness (no timing hacks)**, **modular routing**, **server-side data integrity**, and a **repository boundary**. Each phase should ship as **one or more small PRs** with staging smoke tests—not one giant merge.

## Principles

1. **One risk axis per release** where possible (e.g. do not combine a Firestore migration and a large router rewrite in the same cut).
2. **Staging first**: Firebase staging project (or faithful emulators) + a short smoke checklist for auth, facility picker, billing/payments, invites, public pay/move-in, Stripe returns, super-admin.
3. **Idempotent server work**: migrations and backfills must be safe to run twice; log counts; prefer dry-run in admin tooling first.
4. **Measure before deleting client logic**: ship server path → verify in staging/prod → then remove client backfills.

## Phase A — Repo hygiene (fast, low risk)

**Goal:** Generated output never enters the index; CI enforces it.

- Root `.gitignore` already excludes `build/`, `.dart_tool/`, `functions/lib/`, `.firebase/`. Keep it authoritative.
- CI: `node scripts/check_tracked_generated_artifacts.js` (fails if `git ls-files` lists paths under those prefixes).
- If anything is already tracked: `git rm -r --cached <paths>` once, then commit.

**Done when:** PRs cannot merge with tracked artifacts; clean clone + local build leaves `git status` clean.

## Phase B — Readiness without fixed delays (incremental)

**Goal:** After `getOrCreateAccountForCurrentUser()`, rely on **invalidation + provider futures/streams**, not `Future.delayed` for synchronization.

- **Batch 1 (done in repo as template):** Billing-adjacent list screens that used a 500ms delay before `userFacilitiesProvider(uid).future` now call `ref.invalidate(userFacilitiesProvider(uid))` first.
- **Batch 2:** Remaining `Future.delayed` usages—classify each:
  - **Sync hack** → replace with real state (await correct future, `ref.listen`, stream subscription, or retry with backoff tied to errors).
  - **Intentional UX** (e.g. “show success for 2s”) → keep but document in a one-line comment so it is not mistaken for synchronization.
- **Batch 3:** `late_dashboard`, `insurance_screen`, `facility_management_screen`, and other account→facility flows: same pattern as Batch 1 where applicable.

**Done when:** No undocumented post-account delays; throttled-network smoke passes on staging.

## Phase C — GoRouter modularization (mechanical, behavior-preserving)

**Goal:** Smaller files; **same URLs and redirect behavior**.

- Extract: route table(s), `routeGuard`, refresh/auth wiring, deep-link helpers—mirror structure already noted in `app_router.dart`.
- Add a short **redirect regression list** (bookmark URLs) and run through it after each extract.

**Done when:** `go_router` entry file is thin; no intentional behavior diff (diff guards carefully).

## Phase D — Server-side data integrity

**Goal:** Schema repair and one-time fixes **not** in client hot paths.

- Inventory client “repair” paths (e.g. facility field backfills); for each, design a **Function trigger, scheduled job, or one-off migration** (idempotent).
- Run against **staging snapshots**; add logging/metrics; roll out; monitor.
- Remove or narrow client code only after the server path is proven.

**Done when:** New users and old data are corrected without depending on a specific app version opening a screen.

## Phase E — Repository / domain layer (ongoing)

**Goal:** Screens depend on stable APIs; Firestore field names stay behind one layer per aggregate.

- Pick one aggregate at a time (e.g. `Facility`, then `Tenant`, then `Invoice`).
- Introduce a thin repository; **delegate** from existing `*Service` static methods initially (no big-bang).
- Move call sites only when the repository matches current query behavior exactly.

**Done when:** Refactors to queries touch one module; optional unit tests on repositories with fake backends.

## Phase F — tighten CI (after noise is manageable)

- Flip **`flutter analyze`** to blocking on `main` once the worst legacy issues are triaged.
- Add a few **golden-path** tests (auth + facility load + one payment/billing flow) to catch regressions from Phases B–E.

## Suggested timeline (indicative)

| Phase | Calendar (solo / part-time) |
|-------|-----------------------------|
| A     | Part of one day            |
| B     | Several PRs over 1–2 weeks |
| C     | 2–5 days                    |
| D     | Ongoing; highest care      |
| E     | Weeks; parallel with features |
| F     | After A–B or when analyze is clean |

## Smoke checklist (minimum)

- [ ] Sign in / sign out / session refresh  
- [ ] Account creation path (new user)  
- [ ] Facility list + switcher  
- [ ] Invoices / payments / deposits (one screen each)  
- [ ] Invite accept + role facility  
- [ ] Public payment or move-in link (if enabled)  
- [ ] Stripe return deep link (if applicable)  
- [ ] Super-admin or internal tools you rely on  

Update this list as product surface grows.

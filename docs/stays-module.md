# Stays module (short-term rentals)

Stays lets a facility run nightly rentals alongside storage: vacation rentals, cabins, and RV and tent sites. It covers listings, a booking engine with per-night locks, turnover tasks for cleaners, manual payments, and iCal calendar sync (import from, and export to, the big booking channels).

It is kept apart from the storage side of the app. Guests are not tenants, and stays never write to units, ledgers, invoices or Stripe. Stays sends no email or texts; its owner notices are in-app only (`facilities/{id}/Notifications`). `scripts/check_stays_isolation.cjs` enforces this in CI.

## Where it lives

- `functions-stays/`: its own Cloud Functions codebase (`stays`), with no secrets and no VPC connector.
- `functions-shared/src/stays/`, `functions-shared/src/net/safeFetch.ts`: shared contracts, date and lock logic, and the SSRF-safe feed fetcher.
- `firestore-rules-src/facilities/50-57-stay*.rules`, the `stayTaskPhotos` block in `storage.rules`, and the Stays entries in `firestore.indexes.json`.
- `lib/models/stays/`, `lib/services/stays/`, `lib/screens/stays/`, `lib/widgets/stays/`, `lib/router/stays_routes.dart`.

## Status: merged, switched off

Everything is off by default. Two separate gates must both be opened before anything shows or runs.

1. **App UI: the `shortTermRentals` feature flag** (`appConfig/featureFlags`), default `false`. While it is off or still loading, every Stays URL shows "Page not found", nothing links to Stays, and the Stays permissions are hidden from the Roles tab.
2. **Server: `staysServerConfig/current`** (super admin only, set in the console). If the doc is missing or cannot be read, the gate fails closed. `staysGetAvailability` answers "not available", every other callable refuses with `module_not_available`, the 30-minute scheduler enqueues nothing, the sync worker and triggers do nothing, and `/api/ical/**` returns 404 (no export links exist) or 503. A facility also needs `stayControls/current.moduleEnabled == true`, which only the setup flow sets once the server gate allows that facility. Until then the Firestore and Storage rules refuse every client create of a Stays doc or turnover photo.

`staysServerConfig/current.killSwitch = true` pauses everything without a deploy.

## Deploy order

`deploy.ps1` deploys all functions before indexes and rules, so the first Stays release uses explicit steps:

1. `firebase deploy --only firestore:indexes`, then wait until every new index is READY.
2. `firebase deploy --only firestore:rules,storage`.
3. `firebase deploy --only functions:stays`. This creates the new codebase, including one Cloud Scheduler job (`staysScheduledSync`, every 30 minutes).
4. `flutter build web --release`, then `firebase deploy --only hosting`. Hosting carries the `/api/ical/**` rewrite to `staysIcalExport`, so it must come after step 3.

After that, `deploy.ps1` includes the `stays` codebase like any other.

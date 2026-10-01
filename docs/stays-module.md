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

## Setup, calendars and the calendar view (app)

Built so far on the app side: setup, channel management and a month calendar. There is no sidebar entry yet. An owner or manager opens `/stays?facilityId=<id>`, and while the module is off that page offers **Set up Stays** (only when `staysGetAvailability` says the facility is allowed).

1. **Setup** (`/stays/setup`) has five steps.
   1. **Time zone.** Nothing is pre-selected. The facility's own zone is offered as "Use it", but the owner must still press **Confirm**. That calls `staysSetControls` with `confirmTimeZone: true`. A zone that differs from the facility's setting shows a warning before and after.
   2. **Listings.** Each listing is a name, a kind (home, house, cabin or RV site), a short code and an optional nightly rate, saved through `staysSaveListing` with one `requestId` per dialog.
   3. **Turn on.** This sets `moduleEnabled` through `staysSetControls`. The server connects calendars only when the module is on, so this comes before calendars.
   4. **Calendars.** These are the same per-listing cards as the Calendars page.
   5. **Done.** A summary, with a link to the calendar.
2. **Calendars** (`/stays/channels`, owner/manager) has two parts.
   - **Two switches:**
     - "Check calendars every 30 minutes" (`icalSyncEnabled`). It is offered only once a calendar has been connected. The very first calendar turns it on, as the rollout plan says; after that, if checks are off, adding a calendar asks instead of turning them back on.
     - "Send your SFC calendar to other sites" (`icalExportEnabled`). `staysSetControls` turns it on only for a facility listed in `staysServerConfig/current.exportAllowlist` (a super admin adds it after the shadow week; a missing field allows nobody), and `staysGetAvailability` reports `exportAllowed`. Elsewhere the switch is locked with "Contact support to turn on calendar sending". Turning it off is always allowed.
   - **Per listing:**
     - Imported calendars show when they were last checked and synced, the last problem in words, and when the channel last fetched our export link. Each has **Sync now** and **Remove**.
     - **Add a calendar** previews the feed (`dryRun`) before connecting it.
     - SFC export links show what they send and when they were last fetched. **Copy** goes through the audited `staysGetExportUrl`. **Make an SFC link** sends a `requestId`, so a retry cannot create a second live token.
     - The wording says plainly that channels read our link on their own schedule, often only every few hours.
3. **Calendar** (the hub's Calendar tab) shows one listing's month.
   - How nights are drawn:
     - bookings are filled in their source's colour;
     - owner and maintenance blocks are hatched grey;
     - channel "Not available" blocks are a faint hatch (soft), and echoes are fainter still;
     - bookings removed from a feed are outlined amber;
     - a night two hard stays claim is striped red.
   - A banner lists the listing's double bookings from the engine's `conflict` data.
   - Tapping a night shows everything on it.
   - Owners and managers can **Block dates** (`staysCreateStay`, kind `owner_block` or `maintenance_block`) and remove a block they made (`staysCancelStay`). The server asks before a block covers a channel's own block, and when a channel could sell the dates before it reads ours.
   - The Listings tab shows the facility-wide conflict banner and flags each listing.

## Deploy order

`deploy.ps1` deploys all functions before indexes and rules, so the first Stays release uses explicit steps:

1. `firebase deploy --only firestore:indexes`, then wait until every new index is READY.
2. `firebase deploy --only firestore:rules,storage`.
3. `firebase deploy --only functions:stays`. This creates the new codebase, including one Cloud Scheduler job (`staysScheduledSync`, every 30 minutes).
4. `flutter build web --release`, then `firebase deploy --only hosting`. Hosting carries the `/api/ical/**` rewrite to `staysIcalExport`, so it must come after step 3.

After that, `deploy.ps1` includes the `stays` codebase like any other.

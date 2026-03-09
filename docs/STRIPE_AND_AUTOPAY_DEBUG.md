# Stripe & Autopay – Where Things Live and How to Debug

## Where Stripe status is stored

- **Backend (single source of truth):**
  - Facility doc: `facilities/{facilityId}` with field `stripeConnectAccountId` (string, e.g. `acct_xxx`).
  - Cloud Function `stripeConnectGetStatus` reads that field, calls Stripe API `accounts.retrieve()`, then writes back to the facility doc:
    - `stripeStatus` (state, chargesEnabled, payoutsEnabled, detailsSubmitted, currentlyDue, pastDue, updatedAt)
    - `stripeConnectOnboardingComplete` (bool)
  - No separate `integrations/stripe` sub-doc; everything is on the facility doc.

- **Flutter (Payments / Autopay):**
  - **Single source:** `StripeConnectService.refreshStatus(facilityId)` → callable `stripeConnectGetStatus`.
  - Cached in `stripeConnectStatusProvider(facilityId)` (FutureProvider, autoDispose). When you leave Payments or change facility, the provider is disposed; when you return, it refetches.
  - If Stripe Connect onboarding screen shows "Account Connected", it invalidates `stripeConnectStatusProvider(facilityId)` so Payments will refetch and show connected when you open Payments → Autopay.

## Debugging "Stripe not connected" when Connect page says connected

1. **Same facility?**
   - Payments uses `_selectedFacilityId` (facility dropdown on Transactions tab; Autopay tab uses the same facility).
   - Initial facility is chosen as: active facility if in list, else first facility. Ensure the facility you connected in Stripe Connect is the one selected in Payments (check dropdown on Transactions tab).

2. **Doc path:**
   - Status is read via callable `stripeConnectGetStatus` with `facilityId`. There is no user-level Stripe doc; it’s always facility-level.
   - If you see "not connected" only for one facility, confirm that `facilities/{thatFacilityId}` has `stripeConnectAccountId` set (e.g. in Firebase Console or via a quick Cloud Function log).

3. **Stale cache:**
   - Use "Refresh status" in the Autopay tab (shown when status load fails), or invalidate in code: `ref.invalidate(stripeConnectStatusProvider(facilityId))`.
   - After completing Stripe Connect onboarding, the onboarding screen invalidates the provider for that facility so the next open of Payments should show connected.

## Listeners and avoiding duplicate / crash

- **Autopay events:** `autopayEventsProvider(facilityId)` is a **StreamProvider.autoDispose.family**. Only one stream per `facilityId`; when no one watches (e.g. you switch facility or leave Payments), the stream is cancelled. We do not create Firestore listeners in `build()`; they live inside the provider.
- **Empty facilityId:** If `facilityId` is null/empty, `AutopayService.watchAutopayEvents` returns `Stream.empty()` and we never attach a listener, so no invalid path or permission-denied from an empty path.
- **Confirming listeners aren’t duplicated:** In debug, watch for multiple logs of the same Firestore snapshot; with autoDispose, switching facility or navigating away should cancel the previous stream. No manual `StreamSubscription` in widgets; all listening is via Riverpod.

## Routes and nav

- **Payments (Transactions):** Only place for money ops. Tabs: Transactions | Autopay. Autopay Activity is a section inside the Autopay tab, not a separate left-nav item.
- **Autopay Activity** and **Notifications** are not in the sidebar. Legacy URLs redirect: `/autopay-activity` → `/payments?tab=autopay`, `/notifications` → `/settings/notifications`.

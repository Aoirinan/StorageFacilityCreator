# Public Rental Links Plan

## Phase 1 Audit Findings

- Existing public rental flow already exists through `PublicRentalPortalScreen` and `PublicMoveInScreen`.
- Existing checkout/move-in handoff already exists through `PublicRentalService.createReservation()` and `PublicRentalService.completePublicMoveIn()`.
- Public map snapshots in `publicFacilityMaps` are already the safe anonymous read model and are governed by `firestore.rules`.
- Direct anonymous reads for `facilities/{facilityId}` and `facilities/{facilityId}/units` are blocked by rules, so public rental inventory must use the published snapshot path.
- Internal map/editor flows (`FacilityMapEditorScreen`, `FacilityMapBuilderV2Screen`, `UnitsMapEntryScreen`) remain unchanged and internal-only.

## Implementation Approach

- Keep the internal facility map as-is for owner/staff operations.
- Add hosted public rental routes under `/f/:facilitySlug/...`:
  - `/f/:facilitySlug/rent`
  - `/f/:facilitySlug/available-units`
  - `/f/:facilitySlug/:categorySlug`
- Rework public rental page loading to use `publicFacilityMaps` (safe read model) instead of direct facility/unit collection reads.
- Extend facility public settings with rental-specific controls:
  - `publicRentalsEnabled`
  - `publicPricingEnabled`
  - `publicUnitNumbersEnabled`
  - `allowAutoAssign`
  - `allowUnitSelection`
  - `showAvailabilityCount`
  - `hideUnavailableTypes`
  - `enabledPublicUnitTypes`
  - `publicRentalSlug`
- Keep existing move-in checkout and backend logic by continuing to call current reservation/move-in services.

## Phase 2+ Wiring

- Snapshot publish now includes rental-facing facility branding/contact metadata and the new public rental settings in `publicSettings`.
- Snapshot units now include public-friendly fields (`unitType`, `categorySlug`, `size`, `description`, and conditional public unit number display).
- Rental route template in snapshot now points to `/f/:slug/rent`.

## Admin UX

- Facility edit now includes a new **Public Rental Links** section:
  - enable/disable public rentals
  - toggle pricing, unit numbers, auto-assign, unit selection, availability counts
  - choose publicly visible unit types
  - set rental slug
  - copy hosted links
  - preview public page
  - save + publish snapshot

## Security Notes

- Public pages read only from `publicFacilityMaps` (anonymous-safe collection).
- Private collections (`facilities`, `units`, tenant/payment/admin data) remain protected by existing Firestore rules.

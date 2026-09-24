# Website Factory MVP (Non-Breaking)

This MVP adds a website layer without changing existing renter or operator flows.

## New endpoints

- `GET /api/public-website?slug=<slug>`
  - Firebase Hosting rewrite to `getPublicWebsiteConfig`.
  - Returns public, website-safe JSON from `publicFacilityMaps`.
- `GET /w/<slug>`
  - Firebase Hosting rewrite to `renderPublicWebsite`.
  - Returns a minimal, templated public HTML page powered by the same public snapshot.

## Rent and reserve actions

- Every public surface offers a rental only when `createPublicReservationHold` would take one:
  the owner's switch (`settings/public.publicRentalsEnabled`, exactly `true`) and room under the
  active-tenant cap (`facilityAcceptsPublicRentals` in `functions-public-website/src/publicRentalGate.ts`).
- When that is false, `/w/<slug>` shows "Call to rent" (or "Contact us to rent") in place of every
  rent/reserve button, and `/api/public-website` returns `onlineRentalsEnabled: false` and
  `rentUrl: null`. The app's public pages read the published copy of the switch
  (`facilityTakesOnlineRentals` in `lib/models/facility_map_v2_models.dart`).

## Domain mapping support

- Both endpoints also accept domain-based lookup:
  - `?domain=rent.example.com`
  - Host header lookup when used on a mapped custom domain.
- Lookup path:
  1. `facilities/{facilityId}/settings/public.customDomain`
  2. `facilities/{facilityId}/mapEngine/meta.publicSlug`
  3. `publicFacilityMaps/{slug}`

## Why this is safe

- Additive only: no mutation of existing data flow.
- Existing app URLs and wording are unchanged.
- Website rendering depends only on published public snapshot data.

## Next steps

1. Expand HTML template into multi-section layout (amenities, testimonials, contact, map).
2. Add publish controls for website-specific content fields.
3. Add automated custom-domain provisioning/verification workflow.

## Super admin: custom domains

Internal checklist and customer DNS email template: [SUPERADMIN_CUSTOM_DOMAIN_WEBSITE.md](./SUPERADMIN_CUSTOM_DOMAIN_WEBSITE.md). In the app: **Super Admin → Custom domain** tab.

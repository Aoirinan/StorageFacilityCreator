# Website Factory MVP (Non-Breaking)

This MVP adds a website layer without changing existing renter or operator flows.

## New endpoints

- `GET /api/public-website?slug=<slug>`
  - Firebase Hosting rewrite to `getPublicWebsiteConfig`.
  - Returns public, website-safe JSON from `publicFacilityMaps`.
- `GET /w/<slug>`
  - Firebase Hosting rewrite to `renderPublicWebsite`.
  - Returns a minimal, cookie-cutter HTML page powered by the same public snapshot.

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

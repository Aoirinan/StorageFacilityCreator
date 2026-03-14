# Safe Regression Report

Date: 2026-03-14

## Was App Logic Touched?

- **No** app/business runtime logic was modified.
- Changes were constrained to:
  - `marketing/` Next.js pages/components/config
  - documentation deliverables in repo root

## Why This Is Safe

- No edits to Flutter app routing/state/business services (`lib/` core runtime).
- No edits to Cloud Functions integration runtime (`functions/src/index.ts` and integration modules unchanged).
- No edits to Firebase rules/hosting rewrites/security policies.
- Existing integration implementations (Stripe, Twilio, SendGrid, QuickBooks) were preserved.

## What Was Verified

- `npm run lint` in `marketing/` completed successfully.
- `npm run build` in `marketing/` completed successfully.
- `npm run lint` and `npm run build` were rerun successfully after additional refinement edits.
- `npm run lint` and `npm run build` were rerun successfully again after design-system consistency updates.
- `npm --prefix marketing run check:release` initially failed on a missing `/why-sfc` footer link; footer link was restored and the check now passes.
- `npm --prefix functions run check:quickbooks` passed.
- `npm --prefix functions test` passed (includes QuickBooks and messaging compliance helper tests).
- Build output confirms all key routes still resolve, including:
  - Core pages (`/`, `/features`, `/pricing`, `/security`, `/faq`, `/contact`)
  - Legal pages (`/terms`, `/privacy`, `/cookies`, `/acceptable-use`, `/billing`, `/sms-terms`, `/esign-disclosure`, `/subprocessors`, `/dpa`)
  - Positioning/support pages (`/integrations`, `/why-sfc`, `/product-tour`, `/migration`, `/compare`)
  - SEO routes (`/robots.txt`, `/sitemap.xml`)
- Contact API route remained present (`/api/contact`) after edits.
- IDE lints report no current lint issues under `marketing/src`.

## Known Residual Risk

- Root-level app and functions regression tests were not executed in this pass to avoid touching production runtime surfaces.
- Existing legacy large PNG assets still exist in repo (now bypassed for nav/logo usage on marketing site, but still available on disk).
- Legal text quality improved structurally, but attorney validation remains required for jurisdiction-specific legal sufficiency.
- Full Flutter static analysis currently reports a large pre-existing issue backlog (`flutter analyze` returned 3293 issues across app code). This was observed during verification and not introduced by marketing-site changes.

## Recommended Manual Checks

- Verify all top-level marketing navigation and footer links in browser.
- Confirm CTA flows:
  - "Start Free Trial" (`/contact?intent=trial`)
  - "Book a Demo" (`/contact?intent=demo`)
  - "View Product Tour" (`/product-tour`)
- Confirm `/compare` redirects correctly to `/why-sfc`.
- Verify login redirect path still reaches app login destination.
- Submit a contact form test lead and verify outbound notification payload includes SMS consent state when phone is entered.
- Spot-check Product Tour, Migration, and Security pages on mobile for card layout and section rhythm consistency.
- Spot-check legal pages for readability and cross-link integrity.
- Run mobile viewport smoke checks (header menu, cards, legal tables, CTA blocks).

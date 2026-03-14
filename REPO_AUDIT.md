# Storage Facility Creator Repo Audit (Phase 1)

Date: 2026-03-14  
Scope: Full pre-edit audit of marketing website, legal/compliance routes, app boundaries, integration surfaces, and risk areas before major edits.

## 1) Repository Structure Map

- `marketing/` - Public Next.js site (marketing, legal, SEO, contact form endpoint).
- `lib/` - Flutter production app (auth, dashboard, billing, messaging, tenant ops, integrations UI).
- `functions/` - Firebase Cloud Functions (Stripe, Twilio, SendGrid, QuickBooks, admin, webhooks).
- `web/` - Flutter web host files (`index.html`, Stripe helpers, invite/version pages).
- `assets/` - Flutter image assets (`assets/images/logo.png`, `assets/images/demo.png`).
- `firebase.json`, `firestore.rules`, `storage.rules` - production hosting/security controls.

## 2) Public Marketing Page Inventory

### Public routes (`marketing/src/app`)

- `/` -> `page.tsx`
- `/features` -> `features/page.tsx`
- `/pricing` -> `pricing/page.tsx`
- `/security` -> `security/page.tsx`
- `/faq` -> `faq/page.tsx`
- `/contact` -> `contact/page.tsx`
- `/login` -> `login/page.tsx` (redirects to hosted app URL)
- `/integrations` -> `integrations/page.tsx`
- `/product-tour` -> `product-tour/page.tsx`
- `/why-sfc` -> `why-sfc/page.tsx`
- `/migration` -> `migration/page.tsx`
- `/terms` -> `terms/page.tsx`
- `/privacy` -> `privacy/page.tsx`
- `/cookies` -> `cookies/page.tsx`
- `/acceptable-use` -> `acceptable-use/page.tsx`
- `/billing` -> `billing/page.tsx`
- `/sms-terms` -> `sms-terms/page.tsx`
- `/esign-disclosure` -> `esign-disclosure/page.tsx`
- `/subprocessors` -> `subprocessors/page.tsx`
- `/dpa` -> `dpa/page.tsx`
- `/api/contact` -> `api/contact/route.ts`

### Legal/compliance routes present

- Terms of Service, Privacy Policy, Cookie Policy, Acceptable Use, Billing & Refund, SMS Terms, E-Sign Disclosure, Subprocessors, DPA.
- All legal URLs already exist and must be preserved in place.

## 3) Navigation, CTA, Footer Audit

### Header nav items

- `Features`, `Pricing`, `Integrations`, `Security`, `FAQ`.
- `Login` points to `/login` (marketing redirect route).

### CTA system (from `marketing/src/config/site.ts`)

- Primary: `Start Free Trial` -> `/contact?intent=trial`
- Secondary: `Book a Demo` -> `/contact?intent=demo`
- Tertiary: `View Product Tour` -> `/product-tour`

### Footer links

- Product: `/product-tour`, `/integrations`, `/why-sfc`, `/features`, `/pricing`, `/faq`, `/migration`
- Legal: `/terms`, `/privacy`, `/cookies`, `/acceptable-use`, `/billing`, `/sms-terms`, `/esign-disclosure`
- Trust: `/security`, `/subprocessors`, `/dpa`

### CTA consistency observations

- Core CTA hierarchy is now mostly standardized.
- Mobile menu includes primary CTA + login, but secondary CTA is not surfaced there.
- Several pages still use direct `<a href>` for internal links where `Link` could improve consistency.

## 4) Metadata / SEO / Routing Audit

### Current implementation

- Global metadata in `marketing/src/app/layout.tsx`:
  - Title template, description, Open Graph, Twitter, robots, icon.
- Page-level metadata exists for all major pages and legal pages reviewed.
- `robots.ts` and `sitemap.ts` exist and include all key routes.
- Structured data:
  - Homepage includes `Organization` + `SoftwareApplication` JSON-LD.
  - FAQ page includes `FAQPage` JSON-LD.

### Page title/description coverage

- Home: inherited from layout metadata.
- Features, Pricing, Security, FAQ, Integrations, Why SFC, Product Tour, Migration: explicit metadata present.
- Contact uses `contact/layout.tsx` metadata.
- Legal pages all define metadata.

### SEO gaps/opportunities

- OG images are configured but all pages currently reuse same screenshot.
- No `BreadcrumbList` schema yet.
- Homepage has schema + strong content links; other pages can gain richer internal link sections.

## 5) Public Images, Assets, and Performance-Sensitive Files

### Marketing public assets

- `marketing/public/demo.png` (~97 KB)
- `marketing/public/sfc_dashboard_hero_clean.png` (~97 KB)
- `marketing/public/logo.png` (~2.1 MB)
- `marketing/public/Storage unit shield with checkmark.png` (~2.1 MB)

### App assets

- `assets/images/demo.png` (~97 KB)
- `assets/images/logo.png` (~2.1 MB)

### Performance findings

- Logo is oversized for nav/favicon use and duplicated in both app/marketing assets.
- `next.config.js` already enables modern image formats (`avif`, `webp`).
- Hero/product screenshots are moderate size; biggest win is logo optimization and per-page OG image strategy.

## 6) Shared Layout / Design System Components

### Marketing shared components

- `layout.tsx`, `globals.css`, `Header.tsx`, `Footer.tsx`, `Section.tsx`, `CtaButton.tsx`, `PageCtaBand.tsx`, `DemoFrame.tsx`, `LegalLinksPanel.tsx`, `A2pSnippet.tsx`, `config/site.ts`.

### Marketing vs app sharing

- Marketing (Next.js) and app (Flutter) do not share UI component code.
- They share brand assets and brand messaging themes only.
- This isolation supports safe additive marketing changes with low app regression risk.

## 7) Analytics / Tracking / Schema Audit

### Marketing tracking

- No Google Analytics, GTM, Segment, PostHog, or Plausible detected in `marketing/src`.
- Cookie policy claims no third-party analytics; current code aligns with that claim.

### Non-marketing observability

- App + functions include operational logging and Sentry usage in backend/runtime paths.

### Structured data

- Present: `Organization`, `SoftwareApplication`, `FAQPage`.
- Missing opportunity: breadcrumb schema on key marketing pages.

## 8) Integration and External Service Audit (Code-Verified)

### Stripe

- Functions: Stripe secret/webhook/publishable secret handling in `functions/src/index.ts`.
- Billing callables exported, including setup intents, one-time payments, autopay, connected-account payments.
- App: Stripe services and UI screens in `lib/services/*stripe*` and payment screens.

### Twilio

- Functions: Twilio params/client in `functions/src/index.ts` and messaging flows.
- App: SMS and messaging services/screens (`texting_setup`, `sms_conversations`, related services).

### SendGrid

- Functions: `@sendgrid/mail` integration with `sendEmail` / digest and related mail flows.
- Marketing contact route: sends via SendGrid API when `SENDGRID_API_KEY` exists; logs only in local dev.

### QuickBooks

- Functions: dedicated module `functions/src/accounting/quickbooks.ts` with OAuth + sync logic.
- Exported callables in `functions/src/index.ts`:
  - `getQuickBooksConnectionStatus`
  - `getQuickBooksConnectUrl`
  - `completeQuickBooksConnect`
  - `disconnectQuickBooks`
  - `syncInvoiceToQuickBooks`
  - `syncPaymentToQuickBooks`
  - `setQuickBooksAutoSync`
- App: `lib/services/quickbooks_service.dart` and `lib/screens/quickbooks_integration_screen.dart`.

### Other external services observed

- Firebase Auth/Firestore/Storage/Functions.
- OpenAI integration in functions.
- Sentry in app/functions.

## 9) App Routes and Production-Sensitive Boundaries

### App route surface (Flutter)

- Public app routes include `/`, `/login`, `/signup`, `/tenant-portal`, `/contracts/sign`, `/pay`, `/rental`, `/public-move-in`, `/facility/:facilityId`.
- Authenticated app surface is extensive (`/dashboard`, `/billing`, `/ledger`, `/messaging`, `/reports`, `/insurance`, `/stripe-connect`, etc.).

### High-risk files (must protect)

- `lib/router/*`, `lib/main.dart`, auth providers/services.
- `functions/src/index.ts`, `functions/src/stripe/tenant_billing.ts`, `functions/src/accounting/quickbooks.ts`.
- `firebase.json`, `firestore.rules`, `storage.rules`.
- `web/stripe_embedded.html`, `web/stripe_card_capture.html`.

## 10) Accessibility Audit (Code-Visible)

### Strengths

- Skip-to-content link exists in `layout.tsx`.
- Focus-visible styles are defined globally.
- Contact form labels are present and success/error messaging uses status/alert roles.
- Minimum tap target utility exists (`.tap-target`).

### Gaps/opportunities

- Emoji-only icons in feature cards are decorative but not semantically rich.
- Some internal links still use raw anchors; can normalize.
- CTA and heading hierarchy should be re-reviewed page-by-page after content polish.
- Contact form includes legal links but no explicit SMS opt-in checkbox where SMS context is introduced.

## 11) Mobile Responsiveness Audit (Code-Visible)

- Header has responsive desktop/mobile nav.
- Sections and grid layouts use responsive breakpoints and spacing.
- Legal tables use `overflow-x-auto`.
- Potential refinements: mobile menu CTA completeness, long legal prose readability rhythm, screenshot card spacing consistency on smaller widths.

## 12) Compliance Content Audit (SMS / E-Sign / Privacy)

### SMS

- A2P-style text is centralized (`A2P_COMPLIANCE_PARAGRAPH`) and reused in `A2pSnippet`.
- SMS terms include consent, frequency, STOP/HELP, rates disclosure, and logging metadata references.
- Forms and FAQ reference SMS terms/privacy.

### E-Sign

- E-sign page has broad required sections: consent, system requirements, withdrawal, paper copies, retention, contact updates.
- Opportunity: tighten readability and reduce paragraph density.

### Privacy/Cookies/Subprocessors/DPA

- Policies are comprehensive and cross-linked.
- Cookie policy says no third-party analytics currently, matching code.
- Subprocessors table structure is present and usable.
- DPA request process exists.

## 13) Safe Implementation Strategy (Pre-Edit)

1. Keep all legal URLs and login/app routing stable.
2. Limit major edits to `marketing/` pages/components/styles and supporting docs.
3. Do not modify app routing, auth, billing, or integration logic unless a small compatibility fix is unavoidable.
4. Prefer additive, in-place marketing/legal refinement over structural rewrites.
5. Preserve env-var behavior in `marketing/src/app/api/contact/route.ts` and functions integrations.
6. Improve content clarity, visual polish, SEO metadata, and accessibility with backward-compatible UI changes.
7. Optimize heavy marketing assets without changing functional route behavior.

## 14) Short Implementation Plan (Pause Point)

### Batch A: Safe shared-shell polish

- Refine `Header`, `Footer`, `CtaButton`, `PageCtaBand`, `globals.css`, `site.ts` for consistent premium presentation and CTA hierarchy.

### Batch B: Core conversion pages

- Enhance `/`, `/features`, `/pricing`, `/security`, `/faq` content/design and internal linking.

### Batch C: Supporting positioning pages

- Refine `/integrations`, `/why-sfc`, `/product-tour`, `/migration` with stronger but factual positioning.

### Batch D: Legal consistency pass

- Improve readability and section consistency for all legal pages in place (no route changes).

### Batch E: SEO + accessibility + performance

- Tighten page metadata consistency, OG strategy, heading semantics, keyboard/accessibility details, and optimize oversized image assets.

### Batch F: Verification and deliverables

- Run marketing lint/build checks and route/link smoke checks.
- Finalize `CHANGELOG.md`, `FILES_NOT_CHANGED.md`, `COMPETITIVE_POSITIONING_NOTES.md`, `LEGAL_CONTENT_REVIEW.md`, `SAFE_REGRESSION_REPORT.md`.

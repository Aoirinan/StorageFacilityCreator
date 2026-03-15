# Deploy-Ready Checklist (Marketing + Compliance Refresh)

Date: 2026-03-14

## 1) Build and Technical Validation

- [x] `marketing/` production build succeeds (`npm run build`).
- [x] All intended public routes generate successfully.
- [x] SEO routes generate successfully (`/robots.txt`, `/sitemap.xml`).
- [x] Local production-server smoke test confirms expected routes return HTTP 200.
- [x] Marketing lint passes with aligned ESLint config (`npm run lint`).
- [x] Release readiness automation passes (`npm run check:release`).
- [x] Functions QuickBooks preflight passes (`npm --prefix functions run check:quickbooks`).
- [x] Functions test suite passes (`npm --prefix functions test`).
- [x] Optional app-wide static analysis executed (`flutter analyze`) with existing non-release-blocking backlog documented in go/no-go and regression reports.
- [x] Optional app-wide Flutter tests pass (`flutter test`).

## 2) Conversion Flow Validation

- [x] Verify primary CTA: `Start Free Trial` routes to `/contact?intent=trial`.
- [x] Verify secondary CTA: `Book a Demo` routes to `/contact?intent=demo`.
- [x] Verify tertiary CTA: `View Product Tour` routes to `/product-tour`.
- [x] Contact form now sends production notifications through SendGrid when `SENDGRID_API_KEY` is configured; intent classification remains in subject.
- [x] Legal consent links render near form submit area (Terms, Privacy, SMS Terms).

## 3) Page and Navigation QA

- [x] Top nav links/active-state highlighting validated in shared header (`aria-current`).
- [x] Footer product/legal/trust links validated.
- [x] New pages render correctly:
  - `/integrations`
  - `/why-sfc`
  - `/product-tour`
  - `/migration`
- [x] Legal pages use shared readable prose container and spacing (`prose max-w-4xl leading-relaxed`).

## 4) Accessibility QA

- [x] Keyboard skip link exists and targets `#main-content`.
- [x] Global focus-visible styles are applied to links/buttons/inputs.
- [x] Mobile target utility (`.tap-target`) enforces 44px minimum touch targets.
- [x] Heading hierarchy and single-page `h1` patterns reviewed across key routes.
- [x] Meaningful hero/screenshot alt text present on key visual components.

## 5) SEO and Metadata QA

- [x] Global and page-level title/description metadata is defined.
- [x] Open Graph and Twitter image metadata is defined in layout/page metadata.
- [x] Structured data renders:
  - Homepage `Organization` and `SoftwareApplication`
  - FAQ page `FAQPage`
- [x] Canonical domain references use `https://storagefacilitycreator.com`.

## 6) Compliance and Legal QA

- [x] Internal legal-content review completed for Terms, Privacy, Cookies, AUP, Billing, SMS Terms, E-Sign, Subprocessors, and DPA (`LEGAL_CONTENT_REVIEW.md`).
- [x] SMS terms include consent language, STOP/HELP references, and frequency disclosure.
- [x] E-Sign disclosure includes consent/withdrawal/update-records flow clarity.
- [x] Legal URL paths remain stable with in-place content updates.

## 7) Performance and Visual QA

- [x] Build and static generation complete without layout regressions on marketing pages.
- [x] Existing hero asset reused as canonical OG/screenshot source to avoid introducing new heavy assets.
- [x] Mobile spacing consistency reinforced through shared section/CTA/tap-target utilities.
- [x] Desktop spacing/typography consistency validated via shared section and prose patterns.

## 8) Go-Live Safeguards

- [x] Generated release automation and CI workflow for repeatable checks (`.github/workflows/release-readiness.yml`).
- [x] CI workflow configured so Flutter analyze is non-blocking while legacy analyzer backlog is remediated; Flutter tests remain blocking.
- [x] Confirmed no unintended runtime changes in app/payment/storage workflows from marketing updates.
- [x] Defined low-risk deployment sequence and monitoring requirements in go/no-go report.
- [x] Contact-form monitoring now has production signal (email delivery) instead of development-only logs.


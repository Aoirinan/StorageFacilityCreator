# Planned Files To Change (Post-Audit, 2026-03-14)

Scope: safe, additive marketing/compliance refactor only.  
Guardrail: no production app/auth/billing/integration logic changes unless explicitly required and documented.

## Batch 1 - Shared marketing shell and CTA consistency

- `marketing/src/config/site.ts` - tighten sitewide copy, CTA microcopy, trust messaging, nav/footer constants.
- `marketing/src/components/Header.tsx` - refine navigation clarity and mobile CTA hierarchy.
- `marketing/src/components/Footer.tsx` - improve trust and legal discoverability presentation.
- `marketing/src/components/CtaButton.tsx` - ensure consistent primary/secondary/tertiary behavior.
- `marketing/src/components/PageCtaBand.tsx` - align reusable conversion band language.
- `marketing/src/components/Section.tsx` - spacing rhythm consistency if needed.
- `marketing/src/components/LegalLinksPanel.tsx` - consistency and usability polish.
- `marketing/src/components/DemoFrame.tsx` - screenshot framing/performance safety improvements.
- `marketing/src/app/globals.css` - accessibility/focus/mobile refinements.
- `marketing/src/app/layout.tsx` - metadata/internal-linking consistency and safe global shell enhancements.

## Batch 2 - Core conversion pages

- `marketing/src/app/page.tsx` - homepage trust, positioning, section polish, conversion flow tightening.
- `marketing/src/app/features/page.tsx` - stronger sectioned feature narrative and operator-focused value copy.
- `marketing/src/app/pricing/page.tsx` - premium pricing presentation and conversion/support FAQ polish.
- `marketing/src/app/security/page.tsx` - trust architecture, provider clarity, and legal links block polish.
- `marketing/src/app/faq/page.tsx` - buyer-question structure and answer consistency review.
- `marketing/src/app/contact/page.tsx` - form/consent/support copy clarity and UX polish (preserve API behavior).
- `marketing/src/app/contact/layout.tsx` - metadata wording consistency if needed.

## Batch 3 - Supporting marketing pages (already existing)

- `marketing/src/app/integrations/page.tsx` - stronger truthful integration framing.
- `marketing/src/app/why-sfc/page.tsx` - neutral competitive positioning polish.
- `marketing/src/app/product-tour/page.tsx` - guided screenshot narrative improvements.
- `marketing/src/app/migration/page.tsx` - migration expectations and onboarding clarity.

## Batch 4 - Legal/compliance pages (in-place updates only)

- `marketing/src/app/terms/page.tsx`
- `marketing/src/app/privacy/page.tsx`
- `marketing/src/app/cookies/page.tsx`
- `marketing/src/app/acceptable-use/page.tsx`
- `marketing/src/app/billing/page.tsx`
- `marketing/src/app/sms-terms/page.tsx`
- `marketing/src/app/esign-disclosure/page.tsx`
- `marketing/src/app/subprocessors/page.tsx`
- `marketing/src/app/dpa/page.tsx`

Rationale: improve readability, consistency, and cross-linking while preserving legal intent and routes.

## Batch 5 - SEO and platform support

- `marketing/src/app/sitemap.ts` - route inclusion/frequency/priority validation updates if needed.
- `marketing/src/app/robots.ts` - crawl directive and sitemap host consistency.
- `marketing/src/app/login/page.tsx` - preserve redirect behavior; only metadata/copy-safe changes if required.
- `marketing/next.config.js` - safe image/perf-related config adjustments only if beneficial.

## Batch 6 - Assets

- `marketing/public/logo.png` (or replacement optimized asset) - reduce weight and preserve branding.
- `marketing/public/sfc_dashboard_hero_clean.png` and related screenshots - optimization and consistent usage.
- Optional additional OG/marketing assets in `marketing/public/` if generated with consistent branding.

## Batch 7 - Required mission deliverables to finalize

- `CHANGELOG.md` - complete file-by-file change record.
- `FILES_NOT_CHANGED.md` - reviewed but intentionally untouched files with reasons.
- `COMPETITIVE_POSITIONING_NOTES.md` - market-facing strengths, gaps, and roadmap-safe framing.
- `LEGAL_CONTENT_REVIEW.md` - legal consistency/SMS/E-sign review notes and attorney questions.
- `SAFE_REGRESSION_REPORT.md` - what was touched, why, what was verified, and residual risks.

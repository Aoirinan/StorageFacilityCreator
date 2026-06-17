# Marketing Site Upgrade — Audit & Plan (STEP 1)

## 1. Current structure audit

### App structure (`marketing/src/`)
- **Routes:** `/` (page.tsx), `/features`, `/pricing`, `/contact`, `/faq`, `/security`, `/privacy`, `/terms`
- **Layout:** Root layout with Inter font, Header, main, Footer. Global CSS with `--primary`, `--surface`, focus-visible utilities.
- **Config:** `site.ts` — SITE_NAME, APP_LOGIN_URL, LOGO_PATH, DEMO_IMAGE_PATH, HERO_*, PRICE_MONTHLY, TRIAL_*, TRUST_STRIP_ITEMS, EXTRA_DEMO_IMAGES (empty), A2P_COMPLIANCE_PARAGRAPH, SUPPORT_EMAIL, SUPPORT_PHONE.
- **API:** `POST /api/contact` — validates name, email, facilityName; logs in dev; ready for mailer hook.

### Shared components
| Component   | Role |
|------------|------|
| **Section** | `<section>` with optional `tint` (bg-surface), `id`, `className`. Inner `max-w-6xl px-4 sm:px-6 lg:px-8 py-16 sm:py-20`. |
| **CtaButton** | Link with `primary` (blue) or secondary (border) styles. Default href `/contact`. |
| **DemoFrame** | Browser chrome (3 dots) + `next/image` in 4:3/video aspect. Optional `src`/`alt`/`priority`. Uses DEMO_IMAGE_PATH. |
| **Header** | Sticky, logo + nav (Features, Pricing, Security, FAQ, Contact) + “Schedule a Demo” + Login. Mobile hamburger. |
| **Footer** | Logo, Privacy / Terms / Contact, support email/phone, version. |
| **A2pSnippet** | SMS compliance text; `brief` for home, full for FAQ/Privacy/Terms. |

### Design system patterns (current)
- **Typography:** H1 `text-3xl sm:text-4xl lg:text-5xl font-bold text-slate-900`; H2 `text-2xl sm:text-3xl` or `text-xl`; body `text-slate-600`, `text-lg` for leads.
- **Spacing:** Section padding `py-16 sm:py-20`; content `max-w-6xl`; gaps `gap-4` to `gap-12`.
- **Colors:** `primary` (#2563eb), `primary-dark` (#1d4ed8), `surface` (#f1f5f9), slate scale.
- **Buttons:** Primary = `bg-primary text-white hover:bg-primary-dark`; secondary = border + white bg. Rounded-lg, px-5 py-2.5 text-sm font-medium.
- **Cards:** `rounded-xl bg-white p-6 shadow-xs border border-slate-100`.

### Assets in `public/`
- `logo.png` — used in Header/Footer
- `demo.png` — current hero/demo image
- `sfc_dashboard_hero_clean.png` — available dashboard screenshot
- `Storage unit shield with checkmark.png` — available for trust/security

---

## 2. Proposed section outline by page

### Home (/)
1. **Hero** — H1 + subhead + 2 CTAs (Schedule Demo, Login) + hero screenshot (ScreenshotFrame with sfc_dashboard_hero_clean or demo).
2. **Social proof strip** — “Built for operators like you” + 4 trust bullets (flat rate, no onboarding, trial, opt-in SMS). No fake logos; optional “X+ facilities” / “X units under management” placeholders later.
3. **Problem → Solution** — 3 pains (spreadsheets, missed payments, per-unit pricing) → 3 outcomes (one place, late notices in seconds, flat rate).
4. **Feature grid** — 6–9 cards with short benefit-first copy and icons (tenants/units, billing, reminders, delinquency, autopay, reports, map/units, messaging, contracts).
5. **How it works** — 3 steps: Set up facility → Add tenants (or import) → Automate & track.
6. **Deep feature sections** — 3–5 alternating left/right blocks with ScreenshotFrame + caption + 2–3 callouts each (e.g. Dashboard, Unit map, Delinquency, Autopay, Late notice).
7. **Integrations** — Stripe for payments; optional SMS/email. One short line each.
8. **Security & reliability teaser** — 2–3 bullets + link to /security.
9. **Testimonials** — 2–3 quote cards. If not real: “Sample feedback” or “Example testimonials” label.
10. **FAQ preview** — 3 questions + “More FAQs” link to /faq.
11. **Final CTA block** — “Ready to try it?” + Schedule Demo.

### Features (/features)
1. **Page hero** — H1 + subhead.
2. **Feature categories** — Grouped as: Daily operations (tenants, units, map) | Billing & payments (charges, ledger, autopay) | Delinquency & compliance (late fees, notices, overlock) | Communication (SMS/email, templates) | Reporting & oversight (dashboards, occupancy, audit).
3. **Deep dives with screenshots** — 4–6 features with ScreenshotFrame + bullets (placeholder images where needed).
4. **What you get out of the box** — Bullet list of included capabilities (no competitor names).
5. **Built for single-site and multi-site** — One short section.
6. **Migration made simple** — CSV import + support; link to contact.
7. **CTA** — Schedule a Demo.

### Pricing (/pricing)
1. **Page hero** — H1 + subhead.
2. **Main plan** — Single flat rate ($75/mo) in a card; what’s included list (all features, no per-unit, trial, no onboarding).
3. **Optional add-ons** — If any (e.g. extra facilities, support tier); else “All-inclusive” message.
4. **Pricing FAQ** — 3–4 questions (billing cycle, cancel, refunds, enterprise).
5. **CTA + contact for enterprise** — Schedule Demo; “Need a custom plan? Contact us.”

### Contact (/contact)
1. **Page hero** — H1 + subhead.
2. **Form** — Name, email, facility name, phone (optional), unit count (optional), message (optional). Validation + success/error state (existing).
3. **Alternative contact** — Email + phone from site config.

### FAQ (/faq)
1. **Page hero** — H1 + subhead.
2. **Categories:** Billing & pricing (3–4) | Autopay & payments (2–3) | Migration & setup (2–3) | Security & data (2–3) | Support (2) | Messaging / SMS (3–4). Total 12–18 Qs.
3. **SMS consent block** — A2pSnippet (full).
4. **CTA** — Schedule a Demo.

### Security (/security)
1. **Page hero** — H1 + subhead.
2. **Plain-language sections:** Payments (Stripe; we don’t store card numbers) | Data (encryption in transit, where stored) | Access (roles, least-privilege) | Backups & monitoring (only if true) | Incident response (how to contact).
3. **Messaging** — Opt-in, STOP/HELP, A2pSnippet.
4. **CTA** — Schedule a Demo.

### Privacy & Terms
- **Privacy / Terms:** Keep legal meaning; improve readability only (subheads, list formatting, no substantive change).

---

## 3. Copy rewrite plan

### Headlines / subheads / CTAs
- **Hero H1:** Move from price-first to benefit-first. Option: “Run your storage facility from one place. Billing, tenants, and late notices—without the headache.” Subhead: mention flat $75, trial, no onboarding; one line on SMS opt-in.
- **Primary CTA:** Keep “Schedule a Demo” (matches contact form). Secondary: “Login” (existing).
- **Trust strip:** Keep flat rate, no onboarding, trial; add “Migration support” or “CSV import” if we want a 5th item.
- **Feature cards:** Benefit-first one-liners (e.g. “See paid, owes, and empty at a glance” for dashboard).
- **How it works:** Same 3 steps; tighten to “Set up your facility” / “Add tenants or import from CSV” / “Automate reminders and track payments.”
- **Remove:** Vague “we take data protection seriously” without specifics. Replace with concrete security teaser bullets.

### What to add (copy)
- “Migration made simple” — CSV import + support.
- Explicit benefits: “Generate late notices in seconds,” “Turn autopay on or off when Stripe is connected,” “Mark units overlocked instantly,” “Mobile-friendly while walking the property.”
- Objection handling: “No per-unit pricing,” “Cancel anytime,” “All features included in one flat rate.”
- Security: “Payments handled by Stripe” (we don’t store card numbers); “Data encrypted in transit”; “Role-based access.”

### What to avoid
- “#1” or unverifiable superlatives.
- Named competitor comparison tables or product-specific superiority claims on public pages (use neutral “typical legacy pattern” framing on `/compare` instead).
- Changing legal meaning in Privacy/Terms.

---

## 4. Visual plan: screenshots and ScreenshotFrame

### Reusable component: ScreenshotFrame
- **Props:** `src` (optional), `alt`, `caption`, `callouts?: string[]`, `priority?: boolean`, `placeholder?: string` (if no src, show skeleton with label).
- **Styling:** Rounded corners (e.g. rounded-xl), subtle shadow, optional browser chrome (reuse DemoFrame pattern). Responsive: full width on mobile, constrained on desktop. Use `next/image` when `src` provided; when `placeholder` only, div with aspect ratio + label text.
- **A11y:** `alt` for image; caption as `<figcaption>`; callouts as list if present.

### Screenshot slots (8–12 total)

| # | Location        | Content / placeholder label        | Caption idea |
|---|-----------------|-------------------------------------|--------------|
| 1 | Home hero       | Dashboard (sfc_dashboard_hero_clean or demo) | “Your command center: units, tenants, and revenue at a glance.” |
| 2 | Home deep dive  | Tenant profile                     | “Tenant details, lease, and payment history in one place.” |
| 3 | Home deep dive  | Unit map editor                    | “Visual map of your facility. Drag-and-drop unit status.” |
| 4 | Home deep dive  | Delinquency dashboard              | “Past-due list and late notices in seconds.” |
| 5 | Home deep dive  | Autopay settings                   | “Turn tenant autopay on or off when Stripe is connected.” |
| 6 | Home “See it in action” | Late notice generator       | “Generate and send late notices without leaving the app.” |
| 7 | Features        | Unit list / map                    | “Unit list and map editor for single or multiple facilities.” |
| 8 | Features        | Ledger / billing                   | “Ledger view: charges, payments, and balance per tenant.” |
| 9 | Features        | Overlock list                      | “Overlock and lien workflow in one place.” |
|10 | Features        | Reports / occupancy                | “Occupancy and revenue reports by facility.” |

**Placeholder labels when no image:** “Tenant profile,” “Unit map editor,” “Delinquency dashboard,” “Autopay settings,” “Late notice generator,” “Overlock list,” “Reports & occupancy.”

**Real assets to use:** `demo.png`, `sfc_dashboard_hero_clean.png`. Prefer `sfc_dashboard_hero_clean.png` for hero if it’s the best dashboard shot.

---

## 5. Implementation order (STEP 2–5)

1. **Design system** — Button (primary/secondary/ghost), Container, Section (keep, maybe add narrow variant), Heading/Subheading. Tailwind only; extract where it improves readability.
2. **ScreenshotFrame** — Implement with placeholder support; use next/image when src provided.
3. **site.ts** — New copy constants for hero, trust strip, problem/solution, feature blurbs, testimonials (sample), FAQ preview. Add HERO_IMAGE_PATH or use existing DEMO_IMAGE_PATH / sfc_dashboard.
4. **Home** — Rebuild sections in order; plug ScreenshotFrames; add JSON-LD SoftwareApplication; metadata.
5. **Features** — Restructure with categories, deep dives, ScreenshotFrames, “What you get,” single/multi-site, migration, CTA.
6. **Pricing** — What’s included list, pricing FAQ, enterprise CTA.
7. **Contact** — Keep form; ensure validation messages and success state are clear; add alt contact block.
8. **FAQ** — Expand to 12–18 Qs; categorize; keep A2P block and CTA.
9. **Security** — Rewrite with Stripe, encryption, access, backups (if true), incident contact; keep messaging + A2P.
10. **Metadata** — Per-route title/description/OG; JSON-LD on home only. Accessibility: headings, focus, aria where needed.

---

*End of STEP 1. Proceeding to implementation (STEP 2–5).*

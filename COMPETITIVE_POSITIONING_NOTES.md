# Competitive Positioning Notes

Date: 2026-03-14

## Current Differentiators To Market Now

- Flat monthly pricing simplicity (no per-unit framing in public copy).
- Practical self-storage operations workflow focus (tenants, units, billing, delinquency, messaging, reporting).
- Compliance transparency (published legal, privacy, SMS, subprocessors, and DPA pages).
- Real-world integrations confirmed in codebase:
  - Stripe
  - Twilio
  - SendGrid
  - QuickBooks
- Independent and multi-facility operator positioning without enterprise bloat language.

## Competitor-Expectation Feature Assessment

- Tenant portal: **Exists (partial-to-live)**  
  - Public and portal route structures exist in app.
  - Market as available, but avoid over-claiming exact workflow depth without implementation discovery.

- Online move-in / online rental: **Exists (partial-to-live)**  
  - Public move-in/rental routes and related services are present.
  - Market carefully as supported workflows, not fully automated universal e-commerce onboarding.

- Autopay management: **Exists (live)**  
  - Stripe-backed autopay service and billing callables present.
  - Safe to market now.

- Delinquency workflow automation: **Exists (live/strong)**  
  - Multiple delinquency and lien workflow paths in app.
  - Safe to market now with practical wording.

- CRM / lead tracking: **Partial**  
  - Some lead/source screens exist, but not framed as a full sales CRM platform.
  - Market as operational visibility, not full CRM suite.

- Unit map editor: **Exists (live)**  
  - Dedicated facility map editor routes/screens present.
  - Safe to market now.

- Document templates and e-sign packet workflows: **Exists (partial-to-live)**  
  - Contract template and signing flows exist.
  - Market as e-sign/document workflow support, avoid overpromising advanced packet orchestration.

- Access control integrations: **Partial/uncertain live breadth**  
  - Access/gate related app surfaces exist.
  - Market cautiously as workflow support; avoid implying broad hardware ecosystem compatibility.

- Insurance workflows: **Exists (partial-to-live)**  
  - Insurance screens/workflows exist in app.
  - Do not make heavy claims on automation breadth without deeper product validation.

- Multi-facility dashboards: **Exists (live)**  
  - Facility-level and cross-facility flows are represented.
  - Safe to market now.

- Reporting analytics: **Exists (live)**  
  - Reporting routes and related screens are present.
  - Safe to market now.

- Additional accounting integrations beyond QuickBooks: **Not present/uncertain**  
  - Market QuickBooks now; avoid claiming additional accounting systems.

## Recommended Market-Now vs Later

### Market now

- Flat-rate pricing
- Core operations (tenants/units/billing)
- Delinquency workflows
- Messaging and consent-aware SMS
- Reporting visibility
- Security/compliance transparency
- Stripe/Twilio/SendGrid/QuickBooks integrations
- Comparison positioning via `/why-sfc` and `/compare` using neutral criteria language (no named competitor claims on public pages).

### Market carefully (qualified language)

- Tenant portal
- Online move-in/rental
- E-sign/document workflows
- Access/gate related workflows

### Hold for roadmap/internal validation

- Full CRM/lead management suite claims
- Broad access-control hardware integration claims
- Additional accounting integrations not verified in current codebase

## Copy Guardrails Applied

- Keep competitor comparisons broad and neutral (no unsupported product-specific competitor claims).
- Public `/compare` uses SFC vs. "typical legacy pattern" columns — no named vendor superiority tables.
- Prefer "supports", "available", and "confirm in implementation review" wording where capability depth can vary by configuration.
- Do not claim certifications, legal guarantees, or integration breadth beyond code-verified providers and workflows.

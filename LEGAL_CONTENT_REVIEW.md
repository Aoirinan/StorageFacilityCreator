# Legal Content Review

Date: 2026-03-14

## What Changed

## SMS Terms / Consent Consistency

- Preserved and reinforced core SMS compliance language already in place:
  - Express opt-in requirement
  - Message frequency varies
  - Message and data rates may apply
  - STOP to opt out
  - HELP for help
  - Consent not a condition of purchase/service (in central snippet)
- Added/updated consistency touchpoints:
  - `marketing/src/app/contact/page.tsx` now includes an explicit SMS consent checkbox statement with STOP/HELP/rates/not-condition language.
  - `marketing/src/app/api/contact/route.ts` now includes submitted SMS consent state in lead payload context when phone is provided.
  - `marketing/src/app/sms-terms/page.tsx` clarifies that opt-back-in requires a new consent action.
  - FAQ/contact/home/security remain linked to SMS terms and privacy references.

## E-Sign Disclosure

- Preserved existing detailed legal structure and intent.
- No legal obligations or rights language was removed.
- No unsupported legal claims were added.

## Privacy / Cookies / Policy Consistency

- Policy discoverability structure remains intact across legal pages.
- Cookie policy remains aligned with current marketing implementation (no third-party tracker detected in code review).
- Cookie policy still states no third-party analytics deployment on the marketing site unless updated later.

## Subprocessors / DPA

- Preserved existing provider table and data categories.
- Updated DPA wording to avoid hard legal-review SLA promises:
  - Replaced fixed "respond within 14 business days" wording with "aim to respond promptly based on request volume and review requirements."

## Readability/Structure Improvements (Legal Pages)

- Added short top-of-page summary paragraphs on:
  - `terms`
  - `privacy`
  - `cookies`
- Goal: faster scannability for buyers/legal reviewers without changing substantive policy commitments.
- Applied a shared legal readability wrapper class across legal policy pages to keep line-length and reading rhythm consistent.

## Attorney Review Questions (Human Legal Review Recommended)

- Confirm the exact legal sufficiency of all SMS consent wording for your jurisdictions and messaging programs.
- Confirm whether "consent not a condition of service" should appear on every consent collection surface in app and website flows.
- Validate E-Sign paper-copy fee language and withdrawal process requirements for target jurisdictions.
- Confirm retention/deletion wording aligns with operational policy and contractual commitments.
- Confirm any state-specific storage-industry notice requirements (lien/delinquency communications) are fully covered.

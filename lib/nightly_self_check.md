# Nightly Self-Check Checklist

## 1. Test & Health Checks
- [ ] Run full test suite (`npm test` / `flutter test` / etc.)
- [ ] Fix any failing tests related to:
  - [ ] Facility & unit management
  - [ ] Tenant management
  - [ ] Billing & invoicing

## 2. TODO / FIXME Cleanup
- [ ] Search for "TODO" and "FIXME"
- [ ] Pick top 3–5 items that impact stability and fix them
- [ ] Convert any unclear TODOs into clear next steps

## 3. Core Flows Manual Sanity
- [ ] Create and edit a facility
- [ ] Create and edit a unit
- [ ] Assign a tenant to a unit
- [ ] Generate or update an invoice for a tenant

## 4. Code Quality
- [ ] Remove unused imports and variables in touched files
- [ ] Extract duplicate logic into helpers
- [ ] Add brief comments to non-obvious logic

## 5. Summary
- [ ] Append changes/fixes to a short log in this file or a separate `NIGHTLY_LOG.md`

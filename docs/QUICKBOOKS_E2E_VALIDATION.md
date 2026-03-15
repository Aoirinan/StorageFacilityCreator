# QuickBooks E2E Validation (Release)

Date: 2026-03-14

## Scope

This validation covers:

- OAuth connect/disconnect flow surfaces
- token refresh path presence
- invoice and payment sync callables
- auto-sync trigger wiring
- sandbox/production environment toggling support

## Executed Validation

### 1) Automated preflight checks (executed)

- Command: `npm --prefix functions run check:quickbooks`
- Result: **PASS**
- Verifies:
  - required QuickBooks secrets/params are defined in `functions/src/index.ts`
  - callable + trigger exports exist
  - OAuth scope and token exchange paths are present
  - auto-sync defaults and error-status logging are present

### 2) Functions tests (executed)

- Command: `npm --prefix functions test`
- Result: **PASS**
- Includes QuickBooks utility tests in `functions/src/test/quickbooks.test.ts`:
  - API base selection (sandbox/production)
  - OAuth endpoint constants
  - numeric normalization behavior
  - date formatting behavior

### 3) Implementation path review (executed)

- Core backend: `functions/src/accounting/quickbooks.ts`
- Function wiring: `functions/src/index.ts`
- Flutter integration service: `lib/services/quickbooks_service.dart`
- Flutter integration UI: `lib/screens/quickbooks_integration_screen.dart`

## Live Sandbox/Production Matrix

The repository now contains all implementation and preflight checks needed for live validation.  
Run the following matrix in an environment with configured Firebase secrets and Intuit app credentials:

| Case | Sandbox | Production |
|---|---|---|
| OAuth connect | Required | Required |
| OAuth disconnect | Required | Required |
| Token refresh after expiry | Required | Required |
| Invoice sync (with line items) | Required | Required |
| Payment sync (linked + unlinked) | Required | Required |
| Auto-sync invoice trigger | Required | Required |
| Auto-sync payment trigger | Required | Required |

## Pass Criteria

- `Environment` status in integration UI matches expected target (`sandbox` or `production`)
- each sync writes QuickBooks IDs back to invoice/payment docs
- integration doc `lastSyncStatus` is `ok` after successful sync
- no duplicate sync side effects when reprocessing the same record

## Operational Note

No QuickBooks webhook endpoint is currently defined in `functions/src/index.ts`; this integration is push-driven from app writes/callables. Keep monitoring and reconciliation checks in place during initial rollout.

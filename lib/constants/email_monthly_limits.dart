/// Canonical monthly caps for transactional email volume (per facility).
///
/// Cloud Functions enforce the same values in
/// `functions/src/constants/emailMonthlyLimits.ts` — update both when changing policy.
/// CI: `node scripts/check_email_monthly_limits_parity.js` (repo root)
/// Firestore backfill: `cd functions && npm run migrate:email-limits -- --dry-run`
library;

const int kEmailMonthlyLimitTrialing = 500;
const int kEmailMonthlyLimitPaid = 5000;

/// Resolves the default cap from subscription state (matches backend `trialing` check).
int emailMonthlyLimitForAccount({required bool isTrialing}) =>
    isTrialing ? kEmailMonthlyLimitTrialing : kEmailMonthlyLimitPaid;

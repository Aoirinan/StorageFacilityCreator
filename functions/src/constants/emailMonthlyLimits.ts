/**
 * Canonical monthly caps for transactional email volume (per facility).
 * Must match `lib/constants/email_monthly_limits.dart`.
 * CI: `node scripts/check_email_monthly_limits_parity.js` (repo root)
 * One-off Firestore sync: `cd functions && npm run migrate:email-limits -- --dry-run`
 */

export const EMAIL_MONTHLY_LIMIT_TRIALING = 500;
export const EMAIL_MONTHLY_LIMIT_PAID = 5000;

export function emailMonthlyLimitForAccount(isTrialing: boolean): number {
  return isTrialing ? EMAIL_MONTHLY_LIMIT_TRIALING : EMAIL_MONTHLY_LIMIT_PAID;
}

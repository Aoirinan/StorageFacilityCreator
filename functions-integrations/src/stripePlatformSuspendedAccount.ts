import * as functions from 'firebase-functions/v1';

/** What a suspended owner is told when they try to start or change billing. */
export const SUSPENDED_ACCOUNT_BILLING_MESSAGE =
  'This account is suspended, and subscribing or paying does not restore access. ' +
  'Contact support@storagefacilitycreator.com to restore it.';

/**
 * The refusal's `details.reason`. The app shows the message for it
 * (ErrorMessageHelper) instead of its generic failed-precondition text.
 */
export const SUSPENDED_ACCOUNT_REASON = 'account_suspended';

/**
 * Refuses to start platform billing for a suspended account: a subscription
 * checkout (the account's, a facility's, or the website add-on) or a trial.
 * Suspension is a super admin's decision that paying does not lift, and the
 * checkout callables used to take the money (a $75 subscription) while the app
 * stayed locked. Cancelling and the billing portal stay open, so a suspended
 * owner can still stop being charged.
 */
export function refuseBillingForSuspendedAccount(account: Record<string, unknown>): void {
  if (account.suspended === true) {
    throw new functions.https.HttpsError('failed-precondition', SUSPENDED_ACCOUNT_BILLING_MESSAGE, {
      reason: SUSPENDED_ACCOUNT_REASON,
    });
  }
}

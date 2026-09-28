/**
 * Who may send tenant messages on the platform's shared toll-free number.
 *
 * Every facility sends on that one number until its own number is registered
 * and approved. The toll-free is verified and carries any facility's traffic
 * with the facility name prefixed, so there is no carrier reason to stop a
 * facility using it once its trial ends.
 *
 * Decision from the owner (2026-09-27): facilities keep using the shared
 * number after their trial. The earlier rule refused a paying facility that
 * had not filed its own registration, which in practice turned texting off at
 * the end of every trial. What remains:
 *
 *   - the account must be in good standing: trialing, active (paying, or in
 *     Stripe's past-due retry window), or billing-exempt. A cancelled,
 *     suspended or never-approved account does not text on our number;
 *   - one facility's traffic on the shared number stays under a monthly
 *     ceiling, so a single operator cannot put the number at risk for all.
 *
 * Consent, STOP and quiet hours are enforced in the send paths themselves and
 * are unchanged by this file.
 */

export type SharedNumberRefusal = 'account_inactive' | 'shared_cap';

export interface SharedNumberDecision {
  allowed: boolean;
  refusal?: SharedNumberRefusal;
  /** Said to the operator, so it names the next action rather than a rule. */
  message?: string;
}

/** The facility owner's account standing, as the shared-number rule reads it. */
export interface SharedNumberAccountStanding {
  /** `subscriptionStatus` from facilityCreatorAccounts, as stored. */
  subscriptionStatus?: string | null;
  /** Account- or facility-level billingExempt, exactly true. */
  billingExempt?: boolean;
  /** Account `suspended`, exactly true. */
  suspended?: boolean;
}

export interface SharedNumberInputs {
  /** True when the message will go out on the facility's own approved number. */
  usesOwnNumber: boolean;
  /**
   * The owner's account. Null when the facility has no linked account or the
   * account could not be read: treated as in good standing, because refusing
   * to send over our own read failure is the worse mistake.
   */
  account: SharedNumberAccountStanding | null;
  /** Tenant messages already sent on the shared number this calendar month. */
  sharedSendsThisMonth: number;
  /** Ceiling for one facility's monthly traffic on the shared number. */
  sharedMonthlyCap: number;
}

/** Subscription statuses that count as a live account. */
const ACTIVE_STATUSES = new Set(['trialing', 'active', 'pastdue', 'past_due']);

/** Whether the account may use the shared number at all. */
export function isAccountInGoodStanding(account: SharedNumberAccountStanding | null): boolean {
  if (account == null) return true;
  if (account.suspended === true) return false;
  if (account.billingExempt === true) return true;
  const status = String(account.subscriptionStatus ?? '').trim().toLowerCase();
  return ACTIVE_STATUSES.has(status);
}

/**
 * Decides whether one tenant message may go out on the shared number.
 *
 * A facility on its own approved number is never limited here — it is sending
 * under its own registration, and the ordinary per-facility usage caps still
 * apply elsewhere.
 */
export function decideSharedNumberSend(input: SharedNumberInputs): SharedNumberDecision {
  if (input.usesOwnNumber) {
    return { allowed: true };
  }

  if (!isAccountInGoodStanding(input.account)) {
    return {
      allowed: false,
      refusal: 'account_inactive',
      message:
        'Texting is not available because this facility\'s subscription is not ' +
        'active. Reactivate the subscription to send texts again.',
    };
  }

  if (input.sharedSendsThisMonth >= input.sharedMonthlyCap) {
    return {
      allowed: false,
      refusal: 'shared_cap',
      message:
        'This facility has reached its monthly limit for texts sent on the ' +
        'shared number. Registering the facility\'s own number removes the ' +
        'limit; until then, texting resumes next month.',
    };
  }

  return { allowed: true };
}

/**
 * Who may send tenant messages on the platform's shared toll-free number.
 *
 * Every facility sends on that one number until its own number is registered
 * and approved. That is the right answer for a trial — it works on day one
 * with no filing — and the wrong answer indefinitely, for two reasons.
 *
 * The first is carrier-facing. One shared number carrying many businesses'
 * tenant traffic means a single complaint or audit against it stops texting
 * for every customer at once, rather than for the one that caused it.
 *
 * The second is structural, and is what got the 10DLC campaign rejected with
 * 30909: the call to action belongs to a facility the reviewer cannot reach.
 * The fix is for each operator to register their own brand and number, so the
 * brand, the campaign and the consent all belong to the business whose tenants
 * are being texted.
 *
 * This file is the rule in the send path rather than in a document, because a
 * policy nobody enforces is a policy that quietly stops being true.
 */

/** Statuses that mean a facility has filed and is waiting on the carrier. */
const IN_PROGRESS_STATUSES = new Set([
  'pending',
  'pending_review',
  'in_review',
  'submitted',
  'verifying',
  'in-progress',
  'in_progress',
]);

export type SharedNumberRefusal = 'registration_required' | 'shared_cap';

export interface SharedNumberDecision {
  allowed: boolean;
  refusal?: SharedNumberRefusal;
  /** Said to the operator, so it names the next action rather than a rule. */
  message?: string;
}

export interface SharedNumberInputs {
  /** True when the message will go out on the facility's own approved number. */
  usesOwnNumber: boolean;
  /** `a2pStatus` from the facility document. */
  a2pStatus?: string | null;
  /** Whether the operator can even start a registration right now. */
  registrationAvailable: boolean;
  /** Whether the facility's account is still inside its free trial. */
  inTrial: boolean;
  /** Tenant messages already sent on the shared number this calendar month. */
  sharedSendsThisMonth: number;
  /** Ceiling for one facility's monthly traffic on the shared number. */
  sharedMonthlyCap: number;
}

export function isRegistrationInProgress(a2pStatus?: string | null): boolean {
  const status = (a2pStatus ?? '').trim().toLowerCase();
  return IN_PROGRESS_STATUSES.has(status);
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

  const filed = isRegistrationInProgress(input.a2pStatus);

  // A paying facility that has not even started its registration is the case
  // this rule exists for. One that has filed keeps sending while the carrier
  // takes its two weeks — punishing them for our queue would be perverse.
  if (!input.inTrial && !filed && input.registrationAvailable) {
    return {
      allowed: false,
      refusal: 'registration_required',
      message:
        'Texting for this facility needs its own registered number now that ' +
        'the trial has ended. Start it in Settings > Texting setup — it takes ' +
        'a few minutes to file and up to two weeks for the carrier to approve. ' +
        'Email reminders are unaffected.',
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

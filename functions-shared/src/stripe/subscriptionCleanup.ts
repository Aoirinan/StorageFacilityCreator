/**
 * Cancelling the Stripe subscriptions behind a facility or an account when it
 * goes away.
 *
 * Until this existed, nothing did. Deleting a facility, offboarding one, or
 * deleting a whole account all left the subscription live in Stripe, so a
 * customer who left kept being charged with no account left to explain the
 * charge. The delete dialog told the operator to go and cancel it by hand,
 * which is a manual step in a money path, which is a step someone forgets.
 *
 * Three different subscription ids can be attached to one customer, and all
 * three have to be dealt with:
 *   facilities/{id}.stripePlatformSubscriptionId   the $75 per-facility plan
 *   facilities/{id}.stripeWebsiteSubscriptionId    the $25 public website add-on
 *   facilityCreatorAccounts/{id}.stripeSubscriptionId  the legacy account plan
 */

export type SubscriptionLabel = 'platform' | 'website' | 'account';

export interface CancellableSubscription {
  id: string;
  label: SubscriptionLabel;
}

export type CancelStatus = 'canceled' | 'already_gone' | 'failed';

export interface CancelOutcome {
  id: string;
  label: SubscriptionLabel;
  status: CancelStatus;
  error?: string;
}

/** Just enough of the Stripe client to cancel, so tests need no Stripe. */
export interface SubscriptionCanceller {
  subscriptions: { cancel: (id: string) => Promise<unknown> };
}

function trimmed(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

/**
 * Every subscription id reachable from a facility and its account, deduped.
 *
 * Deduping matters: deleting an account walks its facilities, and two
 * facilities on one legacy account both point at the same account
 * subscription. Cancelling it twice turns the second call into a confusing
 * error for something that already worked.
 */
export function collectSubscriptionsToCancel(
  facility?: Record<string, unknown> | null,
  account?: Record<string, unknown> | null,
): CancellableSubscription[] {
  const out: CancellableSubscription[] = [];
  const seen = new Set<string>();

  const push = (raw: unknown, label: SubscriptionLabel) => {
    const id = trimmed(raw);
    if (!id || seen.has(id)) return;
    seen.add(id);
    out.push({ id, label });
  };

  if (facility) {
    push(facility.stripePlatformSubscriptionId, 'platform');
    push(facility.stripeWebsiteSubscriptionId, 'website');
  }
  if (account) {
    push(account.stripeSubscriptionId, 'account');
  }
  return out;
}

/**
 * True when Stripe is telling us the subscription is already gone or already
 * finished. Not a failure: the goal is "this is not billing anyone", and it
 * is not. Treating it as an error would make a retried cleanup look broken.
 */
export function isAlreadyEndedError(error: unknown): boolean {
  const e = error as { code?: string; statusCode?: number; message?: string } | null;
  if (!e) return false;
  if (e.code === 'resource_missing') return true;
  const message = (e.message || '').toLowerCase();
  return (
    message.includes('no such subscription') ||
    message.includes('already been canceled') ||
    message.includes('already been cancelled') ||
    (message.includes('canceled') && message.includes('cannot be'))
  );
}

/**
 * Cancels each subscription, carrying on past individual failures.
 *
 * One dead id must not stop the rest: a half-cleaned customer is the state
 * this whole module exists to prevent.
 */
export async function cancelSubscriptions(
  stripe: SubscriptionCanceller,
  subscriptions: CancellableSubscription[],
): Promise<CancelOutcome[]> {
  const outcomes: CancelOutcome[] = [];
  for (const sub of subscriptions) {
    try {
      await stripe.subscriptions.cancel(sub.id);
      outcomes.push({ id: sub.id, label: sub.label, status: 'canceled' });
    } catch (error) {
      if (isAlreadyEndedError(error)) {
        outcomes.push({ id: sub.id, label: sub.label, status: 'already_gone' });
      } else {
        outcomes.push({
          id: sub.id,
          label: sub.label,
          status: 'failed',
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }
  }
  return outcomes;
}

/** One line per cleanup, for the log and the admin summary. */
export function summarizeCancelOutcomes(outcomes: CancelOutcome[]): string {
  if (outcomes.length === 0) return 'no subscriptions attached';
  return outcomes
    .map((o) => `${o.label} ${o.id}: ${o.status}${o.error ? ` (${o.error})` : ''}`)
    .join('; ');
}

export function anyCancelFailed(outcomes: CancelOutcome[]): boolean {
  return outcomes.some((o) => o.status === 'failed');
}

/**
 * Decides whether a live subscription still has something to bill for.
 *
 * Used by the reconciliation sweep. Deliberately conservative: a subscription
 * is only orphaned when its metadata names a facility or account AND that
 * record is gone. A subscription with no metadata is left alone, because we
 * cannot prove it belongs to anything, and cancelling a paying customer by
 * mistake is far worse than leaving one stray record for a human to read.
 */
export function isOrphanedSubscription(input: {
  metadata?: Record<string, string> | null;
  facilityExists: (facilityId: string) => boolean;
  accountExists: (accountId: string) => boolean;
}): boolean {
  const facilityId = trimmed(input.metadata?.facilityId);
  const accountId = trimmed(input.metadata?.accountId);
  if (!facilityId && !accountId) return false;
  if (facilityId) return !input.facilityExists(facilityId);
  return !input.accountExists(accountId);
}

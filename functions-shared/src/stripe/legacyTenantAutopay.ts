import * as functions from 'firebase-functions/v1';
import { isAlreadyEndedError } from './subscriptionCleanup';

/**
 * A tenant's leftover AutoPay subscription on the PLATFORM Stripe account
 * (facilities/{id}/tenants|oldTenants/{id}/billing/default.stripeSubscriptionId),
 * from when AutoPay was a Stripe Subscription rather than the nightly job.
 * Left running beside the nightly job it double-bills the tenant, and once a
 * facility is gone it bills them with no record anywhere.
 *
 * Every place that switches AutoPay off, disconnects a facility or deletes
 * one goes through here. Several used to delete or null the id without
 * cancelling anything, so a live subscription vanished from the one check
 * (the facility delete refusal) that looks for it.
 */

/** Just enough of the Stripe client to cancel and look up a subscription, so tests need no Stripe. */
export interface LegacySubscriptionStripe {
  subscriptions: {
    cancel(id: string): Promise<unknown>;
    retrieve(id: string): Promise<{ status?: string | null }>;
  };
}

/** 'none': there was no id. 'cancelled': it is not billing (cancelled now, or already gone). 'failed': it may be. */
export type LegacyCancelOutcome = 'none' | 'cancelled' | 'failed';

/** The legacy subscription id on a billing/default doc, or ''. */
export function legacySubscriptionId(billing: Record<string, unknown> | null | undefined): string {
  const id = billing?.stripeSubscriptionId;
  return typeof id === 'string' ? id.trim() : '';
}

/**
 * Cancels [billing]'s legacy subscription, if it has one. Safe to run again:
 * one Stripe says is gone, cancelled or expired counts as cancelled. The
 * caller deletes the id only when the outcome is not 'failed'.
 */
export async function cancelLegacyAutopaySubscription(
  stripe: () => LegacySubscriptionStripe,
  where: { facilityId: string; tenantId: string },
  billing: Record<string, unknown> | null | undefined,
): Promise<LegacyCancelOutcome> {
  const id = legacySubscriptionId(billing);
  if (!id) return 'none';
  const client = stripe();
  try {
    await client.subscriptions.cancel(id);
    functions.logger.warn('Cancelled legacy platform-account AutoPay subscription', { ...where, subscriptionId: id });
    return 'cancelled';
  } catch (error: unknown) {
    if (isAlreadyEndedError(error)) return 'cancelled';
    try {
      const subscription = await client.subscriptions.retrieve(id);
      if (subscription.status === 'canceled' || subscription.status === 'incomplete_expired') return 'cancelled';
    } catch (lookup: unknown) {
      if (isAlreadyEndedError(lookup)) return 'cancelled';
    }
    functions.logger.error('Legacy AutoPay subscription not cancelled; it may still be billing', {
      ...where,
      subscriptionId: id,
      error: error instanceof Error ? error.message : String(error),
    });
    return 'failed';
  }
}

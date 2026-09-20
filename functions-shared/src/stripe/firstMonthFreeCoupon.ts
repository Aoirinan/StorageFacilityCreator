import * as functions from 'firebase-functions/v1';
import type Stripe from 'stripe';

/**
 * Stable coupon id for the public "30-day trial + first month free" offer.
 *
 * The marketing site, Terms, and Billing page all promise that the first paid month
 * after the 30-day trial is free. Checkout applies this coupon so the first
 * post-trial invoice is $0. `duration: 'once'` means the discount is consumed by the
 * first invoice that carries a charge; the $0 trial-start invoice does not consume it.
 */
export const FIRST_MONTH_FREE_COUPON_ID = 'sfc_first_month_free';

function isResourceMissing(error: unknown): boolean {
  const err = error as { code?: string; statusCode?: number } | undefined;
  return err?.code === 'resource_missing' || err?.statusCode === 404;
}

/**
 * Returns the coupon id, creating the coupon on first use. Safe to call on every
 * checkout: the id is fixed, so concurrent creates collapse to one coupon.
 */
export async function getOrCreateFirstMonthFreeCouponId(stripe: Stripe): Promise<string> {
  try {
    const existing = await stripe.coupons.retrieve(FIRST_MONTH_FREE_COUPON_ID);
    if (existing.valid) {
      return existing.id;
    }
    functions.logger.warn('First-month-free coupon exists but is no longer valid', {
      couponId: existing.id,
    });
    return existing.id;
  } catch (error: unknown) {
    if (!isResourceMissing(error)) {
      throw error;
    }
  }

  try {
    const created = await stripe.coupons.create(
      {
        id: FIRST_MONTH_FREE_COUPON_ID,
        name: 'First month free',
        percent_off: 100,
        duration: 'once',
        metadata: { type: 'new_operator_first_month_free' },
      },
      { idempotencyKey: `coupon_${FIRST_MONTH_FREE_COUPON_ID}` },
    );
    functions.logger.info('Created first-month-free coupon', { couponId: created.id });
    return created.id;
  } catch (error: unknown) {
    // A concurrent checkout may have created it between our retrieve and create.
    const err = error as { code?: string };
    if (err?.code === 'resource_already_exists') {
      return FIRST_MONTH_FREE_COUPON_ID;
    }
    throw error;
  }
}

/**
 * Id of the retired `sfc_first_month_free` coupon (100% off, duration once).
 *
 * Checkout no longer attaches it: a `once` coupon is spent on the $0 invoice Stripe
 * finalizes when a trialing subscription is created, so the first paid month was never
 * discounted (https://docs.stripe.com/billing/subscriptions/coupons.md, "Coupon
 * duration"). The free month is now extra trial time; see `platformCheckoutTrial.ts`.
 *
 * The id is kept only to recognise Checkout Sessions created before that change, so the
 * webhook still records their free month as used. Do not attach it to new checkouts.
 */
export const FIRST_MONTH_FREE_COUPON_ID = 'sfc_first_month_free';

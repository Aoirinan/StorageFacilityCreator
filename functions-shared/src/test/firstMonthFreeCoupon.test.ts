import test from 'node:test';
import assert from 'node:assert/strict';
import type Stripe from 'stripe';
import { FIRST_MONTH_FREE_COUPON_ID, getOrCreateFirstMonthFreeCouponId } from '../stripe/firstMonthFreeCoupon';

type Calls = { retrieve: string[]; create: Stripe.CouponCreateParams[] };

function fakeStripe(opts: { existing?: Partial<Stripe.Coupon> | null; createError?: unknown }): {
  stripe: Stripe;
  calls: Calls;
} {
  const calls: Calls = { retrieve: [], create: [] };
  const stripe = {
    coupons: {
      retrieve: async (id: string) => {
        calls.retrieve.push(id);
        if (opts.existing) return { id, valid: true, ...opts.existing } as Stripe.Coupon;
        const err = new Error('No such coupon') as Error & { code: string; statusCode: number };
        err.code = 'resource_missing';
        err.statusCode = 404;
        throw err;
      },
      create: async (params: Stripe.CouponCreateParams) => {
        calls.create.push(params);
        if (opts.createError) throw opts.createError;
        return { id: params.id, valid: true } as Stripe.Coupon;
      },
    },
  } as unknown as Stripe;
  return { stripe, calls };
}

test('reuses the existing coupon without creating another', async () => {
  const { stripe, calls } = fakeStripe({ existing: {} });
  const id = await getOrCreateFirstMonthFreeCouponId(stripe);
  assert.equal(id, FIRST_MONTH_FREE_COUPON_ID);
  assert.deepEqual(calls.retrieve, [FIRST_MONTH_FREE_COUPON_ID]);
  assert.equal(calls.create.length, 0);
});

test('creates a 100% off, once-only coupon with the fixed id when missing', async () => {
  const { stripe, calls } = fakeStripe({ existing: null });
  const id = await getOrCreateFirstMonthFreeCouponId(stripe);
  assert.equal(id, FIRST_MONTH_FREE_COUPON_ID);
  assert.equal(calls.create.length, 1);
  const params = calls.create[0];
  assert.equal(params.id, FIRST_MONTH_FREE_COUPON_ID);
  assert.equal(params.percent_off, 100);
  // 'once' is what makes the first paid invoice after the trial free.
  assert.equal(params.duration, 'once');
});

test('tolerates a concurrent create of the same coupon', async () => {
  const dup = new Error('Coupon already exists') as Error & { code: string };
  dup.code = 'resource_already_exists';
  const { stripe } = fakeStripe({ existing: null, createError: dup });
  const id = await getOrCreateFirstMonthFreeCouponId(stripe);
  assert.equal(id, FIRST_MONTH_FREE_COUPON_ID);
});

test('surfaces unexpected Stripe errors instead of swallowing them', async () => {
  const boom = new Error('rate limited') as Error & { code: string };
  boom.code = 'rate_limit';
  const { stripe } = fakeStripe({ existing: null, createError: boom });
  await assert.rejects(() => getOrCreateFirstMonthFreeCouponId(stripe), /rate limited/);
});

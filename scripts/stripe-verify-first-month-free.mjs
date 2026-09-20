#!/usr/bin/env node
/**
 * Verifies the public "30-day trial + first month free" offer end to end in Stripe
 * TEST mode using a test clock, without touching live data.
 *
 * What it checks:
 *   1. Coupon `sfc_first_month_free` (100% off, duration once) exists or gets created.
 *   2. A subscription with trial_period_days=30 and that coupon produces a $0 trial invoice.
 *   3. After advancing the clock past the trial, the first real invoice is $0 (coupon consumed).
 *   4. After advancing another month, the second invoice charges the full price.
 *
 * Usage (after `stripe login` so the CLI holds a fresh test key, or with an explicit key):
 *   STRIPE_SECRET_KEY=sk_test_... node scripts/stripe-verify-first-month-free.mjs
 *   node scripts/stripe-verify-first-month-free.mjs   # reads the key from `stripe config --list`
 *
 * Exits non-zero if any expectation fails. Cleans up the test clock (which deletes the
 * customer and subscription it created).
 */
import { execSync } from 'node:child_process';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// The Stripe SDK is not a root dependency; borrow the copy functions-integrations already has.
const require = createRequire(
  path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'functions-integrations', 'package.json'),
);
const Stripe = require('stripe');

const COUPON_ID = 'sfc_first_month_free';
const LOOKUP_KEY = 'sfc_base_monthly_75';
const TRIAL_DAYS = 30;
const DAY = 24 * 60 * 60;

function resolveKey() {
  const fromEnv = (process.env.STRIPE_SECRET_KEY ?? '').trim();
  if (fromEnv) return fromEnv;
  try {
    const out = execSync('stripe config --list', { encoding: 'utf8' });
    const m = out.match(/test_mode_api_key\s*=\s*'([^']+)'/);
    if (m) return m[1];
  } catch {
    /* fall through */
  }
  throw new Error('No test key: set STRIPE_SECRET_KEY or run `stripe login`.');
}

function assert(cond, msg) {
  if (!cond) {
    console.error(`FAIL: ${msg}`);
    process.exitCode = 1;
    throw new Error(msg);
  }
  console.log(`ok   ${msg}`);
}

async function waitForClock(stripe, clockId) {
  for (let i = 0; i < 60; i++) {
    const c = await stripe.testHelpers.testClocks.retrieve(clockId);
    if (c.status === 'ready') return c;
    await new Promise((r) => setTimeout(r, 1500));
  }
  throw new Error('Test clock did not become ready in time');
}

async function main() {
  const key = resolveKey();
  if (!key.startsWith('sk_test_') && !key.startsWith('rk_test_')) {
    throw new Error('Refusing to run: key is not a TEST mode key.');
  }
  const stripe = new Stripe(key);

  // 1. Coupon
  let coupon;
  try {
    coupon = await stripe.coupons.retrieve(COUPON_ID);
  } catch (e) {
    if (e?.code !== 'resource_missing') throw e;
    coupon = await stripe.coupons.create({ id: COUPON_ID, name: 'First month free', percent_off: 100, duration: 'once' });
  }
  assert(coupon.percent_off === 100 && coupon.duration === 'once', 'coupon is 100% off, duration once');

  // Price
  const prices = await stripe.prices.list({ lookup_keys: [LOOKUP_KEY], limit: 1 });
  let price = prices.data[0];
  if (!price) {
    const product = await stripe.products.create({ name: 'SFC Base Plan - First Facility (verify)' });
    price = await stripe.prices.create({
      product: product.id,
      unit_amount: 7500,
      currency: 'usd',
      recurring: { interval: 'month' },
      lookup_key: LOOKUP_KEY,
    });
  }

  // 2. Customer on a test clock + subscription shaped like Checkout would create it
  const start = Math.floor(Date.now() / 1000);
  const clock = await stripe.testHelpers.testClocks.create({ frozen_time: start, name: 'verify first month free' });
  try {
    const customer = await stripe.customers.create({
      email: 'verify-first-month-free@example.com',
      test_clock: clock.id,
      payment_method: 'pm_card_visa',
      invoice_settings: { default_payment_method: 'pm_card_visa' },
    });
    const sub = await stripe.subscriptions.create({
      customer: customer.id,
      items: [{ price: price.id }],
      trial_period_days: TRIAL_DAYS,
      discounts: [{ coupon: COUPON_ID }],
    });
    assert(sub.status === 'trialing', 'subscription starts trialing');

    const trialInvoices = await stripe.invoices.list({ subscription: sub.id, limit: 10 });
    assert(trialInvoices.data.every((i) => i.amount_due === 0), 'trial-start invoice(s) are $0');
    const subAfterTrialStart = await stripe.subscriptions.retrieve(sub.id);
    assert(
      (subAfterTrialStart.discounts ?? []).length === 1,
      'coupon is still attached after the $0 trial invoice (not consumed early)',
    );

    // 3. Past trial end
    await stripe.testHelpers.testClocks.advance(clock.id, { frozen_time: start + (TRIAL_DAYS + 1) * DAY });
    await waitForClock(stripe, clock.id);
    let invoices = await stripe.invoices.list({ subscription: sub.id, limit: 10 });
    let charged = invoices.data.filter((i) => i.amount_due > 0);
    const firstPostTrial = invoices.data
      .filter((i) => i.billing_reason === 'subscription_cycle')
      .sort((a, b) => a.created - b.created)[0];
    assert(!!firstPostTrial, 'an invoice was generated at trial end');
    assert(firstPostTrial.amount_due === 0, `first post-trial invoice is $0 (was ${firstPostTrial.amount_due})`);
    assert(firstPostTrial.total_discount_amounts?.some((d) => d.amount === 7500), 'first post-trial invoice shows $75 discount');
    assert(charged.length === 0, 'nothing charged through the free month');

    // 4. Following month
    await stripe.testHelpers.testClocks.advance(clock.id, { frozen_time: start + (TRIAL_DAYS + 33) * DAY });
    await waitForClock(stripe, clock.id);
    invoices = await stripe.invoices.list({ subscription: sub.id, limit: 10 });
    charged = invoices.data.filter((i) => i.amount_due > 0);
    assert(charged.length === 1 && charged[0].amount_due === 7500, 'second month charges the full $75');

    console.log('\nAll checks passed: 30-day trial, then first month free, then $75/month.');
  } finally {
    await stripe.testHelpers.testClocks.del(clock.id).catch(() => {});
  }
}

main().catch((e) => {
  console.error(e.message ?? e);
  process.exitCode = 1;
});

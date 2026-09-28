#!/usr/bin/env node
/**
 * Verifies the public "30-day trial, then first month free" offer in Stripe TEST mode
 * on test clocks, without touching live data. The open question it answers: does a
 * `duration: 'once'` coupon get spent on the $0 trial invoice, or kept for the first
 * paid invoice?
 *
 * Scenarios (one test clock each, shaped like the subscription Checkout creates):
 *   A. Card at signup: trial_period_days=30 + coupon.
 *   B. App trial still running: trial_end = the app trial's end (10 days out here) + coupon.
 *   C. App trial already over: no trial + coupon.
 * For each: the trial invoice (if any) is $0, the coupon survives it, the first
 * post-trial invoice is $0 with a $75 discount, and the month after charges $75.
 *
 * Usage (the Stripe project must be named explicitly; the CLI may hold several accounts):
 *   stripe login --project-name "storage facility creator"
 *   node scripts/stripe-verify-first-month-free.mjs --project-name "storage facility creator"
 *   # or: STRIPE_PROJECT_NAME="storage facility creator" node scripts/stripe-verify-first-month-free.mjs
 *
 * The TEST key is read from `stripe config --list --project-name <name>`. Before creating
 * anything the script prints the Stripe account's display name and id and waits for you
 * to type "yes". Exits non-zero if any expectation fails. Each test clock is deleted at
 * the end, which deletes the customer and subscription made on it.
 */
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import path from 'node:path';
import readline from 'node:readline/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';

const COUPON_ID = 'sfc_first_month_free';
const LOOKUP_KEY = 'sfc_base_monthly_75';
const PRICE_CENTS = 7500;
const DAY = 24 * 60 * 60;

/** `--project-name <name>`, `--project-name=<name>`, or STRIPE_PROJECT_NAME. */
export function resolveProjectName(argv, env) {
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--project-name') return (argv[i + 1] ?? '').trim();
    if (a.startsWith('--project-name=')) return a.slice('--project-name='.length).trim();
  }
  return (env.STRIPE_PROJECT_NAME ?? '').trim();
}

function unquote(s) {
  const t = s.trim();
  if ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'"))) return t.slice(1, -1);
  return t;
}

/**
 * Pulls the test-mode key for `projectName` out of `stripe config --list` output.
 * The CLI prints either just that project's keys, or (for the default profile) the whole
 * config file with one [section] per project. Never falls back to another section's key.
 */
export function parseTestKeyForProject(output, projectName) {
  const entries = [];
  const sections = new Set();
  let section = null;
  for (const raw of output.split(/\r?\n/)) {
    const line = raw.trim();
    const header = line.match(/^\[(.+)\]$/);
    if (header) {
      section = unquote(header[1]);
      sections.add(section);
      continue;
    }
    const kv = line.match(/^test_mode_api_key\s*=\s*(.+)$/);
    if (kv) entries.push({ section, key: unquote(kv[1]) });
  }
  if (sections.size > 0) {
    const mine = entries.filter((e) => e.section === projectName);
    if (mine.length !== 1) {
      throw new Error(
        `No single test_mode_api_key for project "${projectName}" in the Stripe CLI config ` +
          `(sections found: ${[...sections].join(', ') || 'none'}). ` +
          `Run: stripe login --project-name "${projectName}"`,
      );
    }
    return mine[0].key;
  }
  if (entries.length !== 1) {
    throw new Error(
      `Expected exactly one test_mode_api_key for project "${projectName}", found ${entries.length}. ` +
        `Run: stripe login --project-name "${projectName}"`,
    );
  }
  return entries[0].key;
}

function readTestKey(projectName) {
  let out;
  try {
    out = execFileSync('stripe', ['config', '--list', '--project-name', projectName], { encoding: 'utf8' });
  } catch (e) {
    throw new Error(`Could not run the Stripe CLI (stripe config --list --project-name): ${e.message ?? e}`);
  }
  const key = parseTestKeyForProject(out, projectName);
  if (!key.startsWith('sk_test_') && !key.startsWith('rk_test_')) {
    throw new Error('Refusing to run: the project key is not a TEST mode key.');
  }
  return key;
}

async function confirmAccount(stripe, projectName) {
  const account = await stripe.accounts.retrieveCurrent();
  const displayName =
    account.settings?.dashboard?.display_name || account.business_profile?.name || '(no display name)';
  console.log(`Stripe CLI project: ${projectName}`);
  console.log(`Stripe account:     ${displayName} (${account.id}), TEST mode`);
  console.log('This creates a coupon/price if missing, plus test clocks, customers and subscriptions.');
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  try {
    const answer = (await rl.question('Type "yes" to continue: ')).trim().toLowerCase();
    if (answer !== 'yes') throw new Error('Not confirmed; nothing was created.');
  } finally {
    rl.close();
  }
}

class Checks {
  constructor(label) {
    this.label = label;
    this.failed = 0;
  }
  check(cond, msg) {
    if (cond) {
      console.log(`  ok   ${msg}`);
    } else {
      this.failed += 1;
      console.error(`  FAIL ${msg}`);
    }
    return cond;
  }
}

async function waitForClock(stripe, clockId) {
  for (let i = 0; i < 60; i++) {
    const c = await stripe.testHelpers.testClocks.retrieve(clockId);
    if (c.status === 'ready') return c;
    await new Promise((r) => setTimeout(r, 1500));
  }
  throw new Error('Test clock did not become ready in time');
}

async function advance(stripe, clockId, frozenTime) {
  await stripe.testHelpers.testClocks.advance(clockId, { frozen_time: frozenTime });
  await waitForClock(stripe, clockId);
}

function discountTotal(invoice) {
  return (invoice.total_discount_amounts ?? []).reduce((sum, d) => sum + (d.amount ?? 0), 0);
}

/**
 * One scenario on its own test clock. `trialDays` is 0 for "no trial"; `trialParams`
 * builds the subscription's trial fields from the clock's start time.
 */
async function runScenario(stripe, price, { label, trialDays, trialParams }) {
  console.log(`\n${label}`);
  const c = new Checks(label);
  const start = Math.floor(Date.now() / 1000);
  const clock = await stripe.testHelpers.testClocks.create({ frozen_time: start, name: `verify first month free: ${label}`.slice(0, 100) });
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
      discounts: [{ coupon: COUPON_ID }],
      ...trialParams(start),
    });

    let invoices = await stripe.invoices.list({ subscription: sub.id, limit: 10 });
    if (trialDays > 0) {
      c.check(sub.status === 'trialing', `subscription starts trialing (was ${sub.status})`);
      c.check(invoices.data.every((i) => i.amount_due === 0), 'trial-start invoice(s) are $0');
      const afterTrialStart = await stripe.subscriptions.retrieve(sub.id);
      c.check(
        (afterTrialStart.discounts ?? []).length === 1,
        'coupon is still attached after the $0 trial invoice (not spent on the trial)',
      );

      await advance(stripe, clock.id, start + (trialDays + 1) * DAY);
      invoices = await stripe.invoices.list({ subscription: sub.id, limit: 10 });
    } else {
      c.check(sub.status === 'active', `subscription starts active, no trial (was ${sub.status})`);
    }

    const firstPaidPeriod = invoices.data
      .filter((i) => i.billing_reason === (trialDays > 0 ? 'subscription_cycle' : 'subscription_create'))
      .sort((a, b) => a.created - b.created)[0];
    if (c.check(!!firstPaidPeriod, 'an invoice exists for the first paid month')) {
      c.check(firstPaidPeriod.amount_due === 0, `first paid-month invoice is $0 (was ${firstPaidPeriod.amount_due})`);
      c.check(
        discountTotal(firstPaidPeriod) === PRICE_CENTS,
        `first paid-month invoice shows the $75 discount (was ${discountTotal(firstPaidPeriod)})`,
      );
    }
    c.check(invoices.data.every((i) => i.amount_due === 0), 'nothing charged through the free month');

    await advance(stripe, clock.id, start + (trialDays + 33) * DAY);
    invoices = await stripe.invoices.list({ subscription: sub.id, limit: 10 });
    const charged = invoices.data.filter((i) => i.amount_due > 0);
    c.check(
      charged.length === 1 && charged[0].amount_due === PRICE_CENTS,
      `the month after the free month charges the full $75 (charged: ${charged.map((i) => i.amount_due).join(', ') || 'none'})`,
    );
  } catch (e) {
    c.check(false, `scenario errored: ${e.message ?? e}`);
  } finally {
    await stripe.testHelpers.testClocks.del(clock.id).catch(() => {});
  }
  return c.failed;
}

async function main() {
  const projectName = resolveProjectName(process.argv.slice(2), process.env);
  if (!projectName) {
    throw new Error(
      'Name the Stripe project explicitly: --project-name "storage facility creator" ' +
        '(or STRIPE_PROJECT_NAME). The first key in the CLI config may belong to another account.',
    );
  }
  const key = readTestKey(projectName);

  // The Stripe SDK is not a root dependency; borrow the copy functions-integrations already has.
  const require = createRequire(
    path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'functions-integrations', 'package.json'),
  );
  const Stripe = require('stripe');
  const stripe = new Stripe(key);

  await confirmAccount(stripe, projectName);

  // Coupon
  let coupon;
  try {
    coupon = await stripe.coupons.retrieve(COUPON_ID);
  } catch (e) {
    if (e?.code !== 'resource_missing') throw e;
    coupon = await stripe.coupons.create({ id: COUPON_ID, name: 'First month free', percent_off: 100, duration: 'once' });
  }
  if (!(coupon.percent_off === 100 && coupon.duration === 'once')) {
    throw new Error(`Coupon ${COUPON_ID} is not 100% off, duration once.`);
  }
  console.log(`ok   coupon ${COUPON_ID} is 100% off, duration once`);

  // Price
  const prices = await stripe.prices.list({ lookup_keys: [LOOKUP_KEY], limit: 1 });
  let price = prices.data[0];
  if (!price) {
    const product = await stripe.products.create({ name: 'SFC Base Plan - First Facility (verify)' });
    price = await stripe.prices.create({
      product: product.id,
      unit_amount: PRICE_CENTS,
      currency: 'usd',
      recurring: { interval: 'month' },
      lookup_key: LOOKUP_KEY,
    });
  }
  if (price.unit_amount !== PRICE_CENTS) {
    throw new Error(`Price ${LOOKUP_KEY} is ${price.unit_amount} cents, expected ${PRICE_CENTS}.`);
  }

  const APP_TRIAL_DAYS_LEFT = 10;
  const scenarios = [
    {
      label: 'A. card at signup: trial_period_days=30 + coupon',
      trialDays: 30,
      trialParams: () => ({ trial_period_days: 30 }),
    },
    {
      label: `B. app trial running: trial_end = app trial end (${APP_TRIAL_DAYS_LEFT} days out) + coupon`,
      trialDays: APP_TRIAL_DAYS_LEFT,
      trialParams: (start) => ({ trial_end: start + APP_TRIAL_DAYS_LEFT * DAY }),
    },
    {
      label: 'C. app trial over: no trial + coupon',
      trialDays: 0,
      trialParams: () => ({}),
    },
  ];

  let failed = 0;
  for (const s of scenarios) failed += await runScenario(stripe, price, s);

  if (failed > 0) {
    console.error(`\n${failed} check(s) failed. If the coupon was spent on the $0 trial invoice (A/B), ` +
      'see the PR "fallback" note: apply the coupon at trial end from the webhook instead.');
    process.exitCode = 1;
  } else {
    console.log('\nAll checks passed: each path gives one trial, then one free month, then $75/month.');
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch((e) => {
    console.error(e.message ?? e);
    process.exitCode = 1;
  });
}

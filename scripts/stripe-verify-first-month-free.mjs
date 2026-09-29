#!/usr/bin/env node
/**
 * Verifies the public "30-day trial + first month free" offer in Stripe TEST mode on
 * test clocks, without touching live data.
 *
 * The free month is delivered as trial time, not a coupon: checkout sets the Stripe
 * `trial_end` 30 days past the end of the owner's trial, and attaches no discount. (A
 * `once` coupon is spent on the $0 invoice a trialing subscription finalizes at creation;
 * see https://docs.stripe.com/billing/subscriptions/coupons.md, "Coupon duration".)
 *
 * Each scenario runs the real checkout decision (`decidePlatformCheckoutOffer` from
 * functions-shared, as vendored into functions-integrations) for a fake account at the
 * clock's start time, then creates the subscription Checkout would create from it:
 *   A. Card at signup (no trial record): trial_end = start + 30 + 30 days.
 *   B. App trial running, 10 days left: trial_end = app trial end + 30 days.
 *   C. App trial over, free month unused: trial_end = start + 30 days.
 *   D. Resubscribe, free month already used: no trial, charged at once.
 * For A-C: the subscription is trialing with exactly that trial_end, no discount and
 * `firstMonthFree: 'true'` metadata; nothing is charged up to a day before trial_end;
 * the first invoice after trial_end is the full $75 with no discount. For D: the first
 * invoice is the full $75 with no discount.
 *
 * Usage (the Stripe project must be named explicitly; the CLI may hold several accounts):
 *   npm ci --prefix functions-shared
 *   node scripts/vendor-functions-shared.cjs
 *   npm ci --prefix functions-integrations
 *   stripe login --project-name "storage facility creator"
 *   node scripts/stripe-verify-first-month-free.mjs --project-name "storage facility creator"
 *   # or: STRIPE_PROJECT_NAME="storage facility creator" node scripts/stripe-verify-first-month-free.mjs
 *
 * The TEST key is read from `stripe config --list --project-name <name>`. Before creating
 * anything the script prints the Stripe account's display name and id and waits for you
 * to type "yes". Exits non-zero if any expectation fails. Each test clock is deleted at
 * the end, which deletes the customer and subscription made on it. It creates the $75
 * test price if missing, and no coupon.
 */
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import path from 'node:path';
import readline from 'node:readline/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';

const LOOKUP_KEY = 'sfc_base_monthly_75';
const PRICE_CENTS = 7500;
const DAY = 24 * 60 * 60;
/** Test clocks advance at most two billing intervals at a time; stay well inside that. */
const MAX_ADVANCE_SECONDS = 25 * DAY;

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
 * For a named project the CLI prints a `[<name>]` header and that profile's keys; for the
 * default profile it prints the whole config file, one [section] per project. Only a key
 * under a header matching `projectName` is accepted; output with no headers is refused.
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
  // Without a [section] header there is no proof the key belongs to this project (the
  // CLI may have fallen back to another profile), so refuse rather than guess.
  if (sections.size === 0) {
    throw new Error(
      `The Stripe CLI output has no [section] headers, so the key cannot be tied to project "${projectName}". ` +
        `Refusing. Check: stripe config --list --project-name "${projectName}"`,
    );
  }
  const mine = entries.filter((e) => e.section === projectName);
  if (mine.length !== 1) {
    throw new Error(
      `No single test_mode_api_key for project "${projectName}" in the Stripe CLI config ` +
        `(sections found: ${[...sections].join(', ')}). ` +
        `Run: stripe login --project-name "${projectName}"`,
    );
  }
  return mine[0].key;
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

/** functions-integrations' require: the Stripe SDK and the vendored functions-shared live there. */
function integrationsRequire() {
  return createRequire(
    path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'functions-integrations', 'package.json'),
  );
}

/** The checkout decision code exactly as functions-integrations deploys it. */
export function loadOfferModule() {
  try {
    return integrationsRequire()('@sfc/functions-shared/stripe/platformCheckoutTrial');
  } catch (e) {
    throw new Error(
      'Could not load @sfc/functions-shared from functions-integrations. Run: npm ci --prefix functions-shared && ' +
        `node scripts/vendor-functions-shared.cjs && npm ci --prefix functions-integrations (${e.message ?? e})`,
    );
  }
}

/**
 * The scenarios for a clock frozen at `startSec`: each runs the real decision for a fake
 * account and says what Stripe must end up with. Pure, so it can be checked offline.
 */
export function buildScenarios(offerModule, startSec) {
  const nowMs = startSec * 1000;
  const APP_TRIAL_DAYS_LEFT = 10;
  const defs = [
    {
      label: 'A. card at signup: 30-day trial, then the free month',
      account: { subscriptionStatus: 'pendingApproval' },
      expectedTrialEnd: startSec + 60 * DAY,
      expectFreeMonth: true,
    },
    {
      label: `B. app trial running (${APP_TRIAL_DAYS_LEFT} days left): app trial end + 30 days`,
      account: {
        subscriptionStatus: 'trialing',
        subscriptionTrialEnd: nowMs + APP_TRIAL_DAYS_LEFT * DAY * 1000,
        platformTrialUsedAt: nowMs - 20 * DAY * 1000,
      },
      expectedTrialEnd: startSec + (APP_TRIAL_DAYS_LEFT + 30) * DAY,
      expectFreeMonth: true,
    },
    {
      label: 'C. app trial over, free month unused: now + 30 days',
      account: {
        subscriptionStatus: 'cancelled',
        subscriptionTrialEnd: nowMs - 3 * DAY * 1000,
        platformTrialUsedAt: nowMs - 33 * DAY * 1000,
      },
      expectedTrialEnd: startSec + 30 * DAY,
      expectFreeMonth: true,
    },
    {
      label: 'D. resubscribe, free month already used: no trial',
      account: {
        subscriptionStatus: 'cancelled',
        subscriptionTrialEnd: nowMs - 60 * DAY * 1000,
        platformTrialUsedAt: nowMs - 90 * DAY * 1000,
        platformFirstMonthFreeUsedAt: nowMs - 60 * DAY * 1000,
        stripeSubscriptionIdClearedFrom: 'sub_fake_old',
      },
      expectedTrialEnd: null,
      expectFreeMonth: false,
    },
  ];
  return defs.map((d) => {
    const offer = offerModule.decidePlatformCheckoutOffer({
      account: d.account,
      facilities: [],
      defaultTrialDays: offerModule.DEFAULT_PLATFORM_TRIAL_DAYS,
      nowMs,
    });
    return {
      ...d,
      offer,
      subscriptionParams: {
        ...offerModule.platformCheckoutTrialSubscriptionData(offer.trial),
        metadata: offerModule.platformCheckoutOfferMetadata(offer.trial),
      },
    };
  });
}

async function confirmAccount(stripe, projectName) {
  const account = await stripe.accounts.retrieveCurrent();
  const displayName =
    account.settings?.dashboard?.display_name || account.business_profile?.name || '(no display name)';
  console.log(`Stripe CLI project: ${projectName}`);
  console.log(`Stripe account:     ${displayName} (${account.id}), TEST mode`);
  console.log('This creates a price if missing, plus test clocks, customers and subscriptions.');
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

/** Advances the clock to `target` in steps small enough for Stripe to accept. */
async function advanceTo(stripe, clockId, target) {
  let clock = await stripe.testHelpers.testClocks.retrieve(clockId);
  while (clock.frozen_time < target) {
    const next = Math.min(target, clock.frozen_time + MAX_ADVANCE_SECONDS);
    await stripe.testHelpers.testClocks.advance(clockId, { frozen_time: next });
    clock = await waitForClock(stripe, clockId);
  }
}

function discountTotal(invoice) {
  return (invoice.total_discount_amounts ?? []).reduce((sum, d) => sum + (d.amount ?? 0), 0);
}

function hasNoDiscount(sub) {
  return (sub.discounts ?? []).length === 0 && !sub.discount;
}

async function listInvoices(stripe, subscriptionId) {
  const list = await stripe.invoices.list({ subscription: subscriptionId, limit: 20 });
  return list.data.sort((a, b) => a.created - b.created);
}

/** One scenario on its own test clock. */
async function runScenario(stripe, price, startSec, scenario) {
  // Every scenario's clock starts at the same `startSec` its decision was made for.
  const { label, offer, subscriptionParams, expectedTrialEnd, expectFreeMonth } = scenario;
  console.log(`\n${label}`);
  const c = new Checks(label);
  c.check(
    (offer.trial.trialEndSeconds ?? null) === expectedTrialEnd,
    `decision: ${offer.trial.kind}, trial_end ${offer.trial.trialEndSeconds ?? 'none'} (expected ${expectedTrialEnd ?? 'none'})`,
  );
  c.check(offer.firstMonthFree === expectFreeMonth, `decision: firstMonthFree ${offer.firstMonthFree}`);
  c.check(!('trial_period_days' in subscriptionParams), 'decision sends no trial_period_days');

  const clock = await stripe.testHelpers.testClocks.create({
    frozen_time: startSec,
    name: `verify first month free: ${label}`.slice(0, 100),
  });
  try {
    const customer = await stripe.customers.create({
      email: 'verify-first-month-free@example.com',
      test_clock: clock.id,
      payment_method: 'pm_card_visa',
      invoice_settings: { default_payment_method: 'pm_card_visa' },
    });
    // What Checkout creates from the session's subscription_data: no discounts.
    const sub = await stripe.subscriptions.create({
      customer: customer.id,
      items: [{ price: price.id }],
      ...subscriptionParams,
    });
    c.check(hasNoDiscount(sub), 'subscription carries no coupon or discount');
    c.check(
      sub.metadata?.firstMonthFree === String(expectFreeMonth),
      `subscription metadata firstMonthFree = ${sub.metadata?.firstMonthFree}`,
    );

    if (expectedTrialEnd !== null) {
      c.check(sub.status === 'trialing', `subscription starts trialing (was ${sub.status})`);
      c.check(sub.trial_end === expectedTrialEnd, `subscription trial_end ${sub.trial_end} = expected ${expectedTrialEnd}`);
      let invoices = await listInvoices(stripe, sub.id);
      c.check(invoices.every((i) => i.amount_due === 0), 'trial-start invoice(s) are $0');

      // A day before the trial (app trial + free month) ends: still nothing charged.
      await advanceTo(stripe, clock.id, expectedTrialEnd - DAY);
      const before = await stripe.subscriptions.retrieve(sub.id);
      c.check(before.status === 'trialing', `a day before trial_end the subscription is still trialing (was ${before.status})`);
      invoices = await listInvoices(stripe, sub.id);
      c.check(invoices.every((i) => i.amount_due === 0), 'nothing charged through the trial and the free month');

      // A day after: the first invoice is the full price, with no discount.
      await advanceTo(stripe, clock.id, expectedTrialEnd + DAY);
      invoices = await listInvoices(stripe, sub.id);
      const firstPaid = invoices.find((i) => i.billing_reason === 'subscription_cycle');
      if (c.check(!!firstPaid, 'an invoice exists for the first month after trial_end')) {
        c.check(firstPaid.amount_due === PRICE_CENTS, `first invoice after trial_end is $75 (was ${firstPaid.amount_due})`);
        c.check(discountTotal(firstPaid) === 0, `first invoice after trial_end has no discount (was ${discountTotal(firstPaid)})`);
        // The invoice's own period_start is the period just ended; its line holds the billed month.
        const billedFrom = (firstPaid.lines?.data ?? []).find((l) => l.amount > 0)?.period?.start;
        c.check(billedFrom === expectedTrialEnd, `it bills the month starting at trial_end (line period start ${billedFrom})`);
      }
      const charged = invoices.filter((i) => i.amount_due > 0);
      c.check(charged.length === 1, `exactly one charge so far (charged: ${charged.map((i) => i.amount_due).join(', ') || 'none'})`);
    } else {
      c.check(sub.status === 'active', `subscription starts active, no trial (was ${sub.status})`);
      c.check(!sub.trial_end, 'subscription has no trial_end');
      const invoices = await listInvoices(stripe, sub.id);
      const first = invoices.find((i) => i.billing_reason === 'subscription_create');
      if (c.check(!!first, 'an invoice exists at creation')) {
        c.check(first.amount_due === PRICE_CENTS, `it charges the full $75 at once (was ${first.amount_due})`);
        c.check(discountTotal(first) === 0, `it has no discount (was ${discountTotal(first)})`);
      }
    }
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
  const offerModule = loadOfferModule();
  const key = readTestKey(projectName);

  // The Stripe SDK is not a root dependency; borrow the copy functions-integrations already has.
  const Stripe = integrationsRequire()('stripe');
  const stripe = new Stripe(key);

  await confirmAccount(stripe, projectName);

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

  const startSec = Math.floor(Date.now() / 1000);
  let failed = 0;
  for (const s of buildScenarios(offerModule, startSec)) failed += await runScenario(stripe, price, startSec, s);

  if (failed > 0) {
    console.error(`\n${failed} check(s) failed.`);
    process.exitCode = 1;
  } else {
    console.log('\nAll checks passed: the trial and the free month are one Stripe trial, then $75/month with no discount.');
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch((e) => {
    console.error(e.message ?? e);
    process.exitCode = 1;
  });
}

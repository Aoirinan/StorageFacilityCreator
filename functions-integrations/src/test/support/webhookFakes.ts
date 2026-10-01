import * as path from 'node:path';
import type Stripe from 'stripe';
import { Timestamp } from 'firebase-admin/firestore';
import {
  buildPublicLinkPaymentIntentMetadata,
  getStripeClient,
  registerStripeKeysProvider,
} from '@sfc/functions-shared';
import { FakeFirestore, installFakeFirestore } from '@sfc/functions-shared/testing/fakeFirestore';

export const TOKEN = 'a'.repeat(48);
export const ACCOUNT = 'acct_facility1';
export const LINK_PATH = `publicPaymentLinks/${TOKEN}`;
export const LEDGERS = 'facilities/f1/ledgers';
export const PAYMENTS = 'facilities/f1/payments';

registerStripeKeysProvider({
  getSecretKey: () => 'sk_test_fake_for_unit_tests',
  getPublishableKey: () => 'pk_test_fake_for_unit_tests',
});

/**
 * Stripe objects that exist only on the account they were made on, like the
 * real API: a lookup without `stripeAccount` misses a connected-account charge.
 */
export class FakeStripeObjects {
  readonly objects = new Map<string, unknown>();
  readonly calls: Array<{ resource: string; id: string; stripeAccount: string | null }> = [];

  put(account: string | null, id: string, object: unknown): void {
    this.objects.set(`${account || 'platform'}:${id}`, object);
  }

  install(): void {
    const client = getStripeClient() as unknown as Record<string, Record<string, unknown>>;
    const lookup = (resource: string) => async (id: string, params?: unknown, options?: Stripe.RequestOptions) => {
      // Like the SDK, accept request options in the params position too
      // (`retrieve(id, { stripeAccount })`), as the refund handler calls it.
      const paramsAsOptions = params && typeof params === 'object' && 'stripeAccount' in params
        ? (params as Stripe.RequestOptions)
        : undefined;
      const account = (options ?? paramsAsOptions)?.stripeAccount || null;
      this.calls.push({ resource, id, stripeAccount: account });
      const found = this.objects.get(`${account || 'platform'}:${id}`);
      if (!found) {
        throw Object.assign(new Error(`No such ${resource}: '${id}'`), { type: 'StripeInvalidRequestError', statusCode: 404 });
      }
      return found;
    };
    client.paymentIntents.retrieve = lookup('payment_intent');
    client.charges.retrieve = lookup('charge');
    client.paymentMethods.retrieve = lookup('payment_method');
    client.subscriptions.retrieve = lookup('subscription');
    // Saving a card sets it as the customer's default: record, and fail like
    // Stripe when the customer is not on that account.
    client.customers.update = async (id: string, _params?: unknown, options?: Stripe.RequestOptions) => {
      const account = options?.stripeAccount || null;
      this.calls.push({ resource: 'customer.update', id, stripeAccount: account });
      if (!this.objects.has(`${account || 'platform'}:${id}`)) {
        throw Object.assign(new Error(`No such customer: '${id}'`), { type: 'StripeInvalidRequestError', statusCode: 404 });
      }
      return this.objects.get(`${account || 'platform'}:${id}`);
    };
  }
}

export function event<T>(
  type: string,
  object: T,
  account?: string,
  id = `evt_${Math.random().toString(36).slice(2)}`,
  livemode = true,
): Stripe.Event {
  return { id, type, account, livemode, data: { object } } as unknown as Stripe.Event;
}

/** Every write the fake applied outside the refusal records. */
export function writesOutsideRefusals(fake: FakeFirestore) {
  return fake.writes.filter((w) => !w.path.startsWith('stripeWebhookRefusals/'));
}

export function linkSession(id: string, paymentIntent: string): Stripe.Checkout.Session {
  return {
    id,
    object: 'checkout.session',
    status: 'complete',
    payment_status: 'paid',
    amount_total: 4200,
    currency: 'usd',
    payment_intent: paymentIntent,
    livemode: false,
    metadata: { facilityId: 'f1', tenantId: 't1', type: 'public_payment_link', paymentLinkToken: TOKEN },
  } as unknown as Stripe.Checkout.Session;
}

export function linkPaymentIntent(id: string): Stripe.PaymentIntent {
  return {
    id,
    object: 'payment_intent',
    amount: 4200,
    currency: 'usd',
    status: 'succeeded',
    metadata: buildPublicLinkPaymentIntentMetadata('f1', 't1', TOKEN),
  } as unknown as Stripe.PaymentIntent;
}

/**
 * A facility on ACCOUNT, tenant t1, and a pending $42 link that issued cs_1
 * and cs_2. The dispute ledger switch (appConfig/payments) is on, as it is
 * once every codebase is deployed; [options.disputeLedger] false leaves it off.
 */
export function setup(link: Record<string, unknown> = {}, options: { disputeLedger?: boolean } = {}) {
  const fake = new FakeFirestore();
  installFakeFirestore(fake);
  if (options.disputeLedger !== false) fake.seed('appConfig/payments', { disputeLedgerEnabled: true });
  fake.seed('facilities/f1', { name: 'Test Storage', stripeConnectAccountId: ACCOUNT, stripeConnectOnboardingComplete: true });
  fake.seed('facilities/f1/tenants/t1', { name: 'Pat Tenant' });
  fake.seed(LINK_PATH, {
    facilityId: 'f1',
    tenantId: 't1',
    amount: 42,
    description: 'Balance',
    token: TOKEN,
    status: 'pending',
    paymentIntentId: null,
    paidAt: null,
    checkoutSessionId: 'cs_1',
    checkoutSessionIds: ['cs_1', 'cs_2'],
    expiresAt: Timestamp.fromDate(new Date('2099-01-01T00:00:00Z')),
    ...link,
  });
  const stripe = new FakeStripeObjects();
  stripe.install();
  return { fake, stripe };
}

type ConsoleSink = Record<'debug' | 'info' | 'log' | 'warn' | 'error', (line: string) => void>;

/**
 * Every line firebase-functions' logger writes while [run] runs, with its
 * severity. The logger's methods cannot be replaced, but it writes through
 * this table, so the test swaps the table's sinks.
 */
export async function captureLogs(run: () => Promise<unknown>): Promise<Array<{ severity: string; message: string }>> {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const common = require(path.join(path.dirname(require.resolve('firebase-functions/v1')), '..', 'logger', 'common.js')) as {
    UNPATCHED_CONSOLE: ConsoleSink;
  };
  const sinks = common.UNPATCHED_CONSOLE;
  const saved = { ...sinks };
  const lines: Array<{ severity: string; message: string }> = [];
  for (const key of Object.keys(sinks) as Array<keyof ConsoleSink>) {
    sinks[key] = (line: string) => {
      const entry = JSON.parse(line) as { severity?: string; message?: string };
      lines.push({ severity: entry.severity ?? key, message: entry.message ?? '' });
    };
  }
  try {
    await run();
  } finally {
    Object.assign(sinks, saved);
  }
  return lines;
}

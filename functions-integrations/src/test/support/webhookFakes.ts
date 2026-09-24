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
  }
}

export function event<T>(type: string, object: T, account?: string, id = `evt_${Math.random().toString(36).slice(2)}`): Stripe.Event {
  return { id, type, account, data: { object } } as unknown as Stripe.Event;
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

/** A facility on ACCOUNT, tenant t1, and a pending $42 link that issued cs_1 and cs_2. */
export function setup(link: Record<string, unknown> = {}) {
  const fake = new FakeFirestore();
  installFakeFirestore(fake);
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

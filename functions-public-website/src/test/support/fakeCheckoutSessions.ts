import type Stripe from 'stripe';
import type { CheckoutSessionsApi } from '../../publicPaymentCheckoutSession';

type FakeSession = {
  id: string;
  account: string;
  status: 'open' | 'complete' | 'expired';
  payment_status: 'paid' | 'unpaid';
  expires_at: number;
  url: string;
  metadata: Record<string, string>;
  payment_intent: string | null;
  amount_total: number;
  currency: string;
  livemode: boolean;
  params: Stripe.Checkout.SessionCreateParams;
};

/**
 * Stripe Checkout Sessions on connected accounts, as far as the payment-link
 * code uses them: create (honouring idempotency keys the way Stripe does),
 * retrieve and expire scoped to the account, and time-based expiry.
 */
export class FakeCheckoutSessions {
  private readonly sessions = new Map<string, FakeSession>();
  private readonly idempotent = new Map<string, { paramsJson: string; sessionId: string }>();
  private counter = 0;
  nowMs = Date.parse('2026-09-23T12:00:00Z');
  createCalls: Array<{ params: Stripe.Checkout.SessionCreateParams; options: Stripe.RequestOptions }> = [];
  retrieveCalls: Array<{ id: string; options: Stripe.RequestOptions }> = [];
  expireCalls: string[] = [];
  /** When set, the next create throws this instead. */
  failNextCreate: Error | null = null;
  /** When set, the next retrieve throws this instead (a timeout, an outage). */
  failNextRetrieve: Error | null = null;
  /**
   * When set, runs once at the start of the next create: something that
   * happens while the request is on its way to Stripe (a revoke, another tab).
   */
  duringNextCreate: (() => Promise<void> | void) | null = null;

  get now(): Date {
    return new Date(this.nowMs);
  }

  advance(ms: number): void {
    this.nowMs += ms;
  }

  /** Sessions Stripe would let someone pay right now. */
  payable(): string[] {
    return [...this.sessions.values()]
      .filter((s) => s.status === 'open' && s.expires_at * 1000 > this.nowMs)
      .map((s) => s.id);
  }

  created(): string[] {
    return [...this.sessions.keys()];
  }

  /** The tenant completes payment on Stripe's page. */
  pay(id: string, paymentIntentId: string): void {
    const s = this.sessions.get(id);
    if (!s || s.status !== 'open' || s.expires_at * 1000 <= this.nowMs) {
      throw new Error(`session ${id} cannot be paid`);
    }
    s.status = 'complete';
    s.payment_status = 'paid';
    s.payment_intent = paymentIntentId;
  }

  /** Add a session made some other way (for example before the fix). */
  inject(session: Partial<FakeSession> & { id: string; account: string }): void {
    this.sessions.set(session.id, {
      status: 'open',
      payment_status: 'unpaid',
      expires_at: Math.floor(this.nowMs / 1000) + 24 * 3600,
      url: `https://checkout.stripe.test/${session.id}`,
      metadata: {},
      payment_intent: null,
      amount_total: 0,
      currency: 'usd',
      livemode: false,
      params: {} as Stripe.Checkout.SessionCreateParams,
      ...session,
    });
  }

  private view(s: FakeSession): Stripe.Checkout.Session {
    // Stripe flips an open session to expired shortly after expires_at.
    if (s.status === 'open' && s.expires_at * 1000 <= this.nowMs) s.status = 'expired';
    return {
      id: s.id,
      object: 'checkout.session',
      status: s.status,
      payment_status: s.payment_status,
      expires_at: s.expires_at,
      url: s.status === 'open' ? s.url : null,
      metadata: { ...s.metadata },
      payment_intent: s.payment_intent,
      amount_total: s.amount_total,
      currency: s.currency,
      livemode: s.livemode,
    } as unknown as Stripe.Checkout.Session;
  }

  private notFound(id: string): Error {
    return Object.assign(new Error(`No such checkout.session: '${id}'`), {
      type: 'StripeInvalidRequestError',
      code: 'resource_missing',
      statusCode: 404,
    });
  }

  api(): CheckoutSessionsApi {
    return {
      create: async (params, options) => {
        await new Promise<void>((resolve) => setImmediate(resolve));
        const during = this.duringNextCreate;
        this.duringNextCreate = null;
        if (during) await during();
        this.createCalls.push({ params, options });
        const account = String(options.stripeAccount || 'platform');
        const key = options.idempotencyKey ? `${account}:${options.idempotencyKey}` : null;
        const paramsJson = JSON.stringify(params);
        if (key && this.idempotent.has(key)) {
          const prior = this.idempotent.get(key)!;
          if (prior.paramsJson !== paramsJson) {
            throw Object.assign(new Error('Keys for idempotent requests can only be used with the same parameters'), {
              type: 'StripeIdempotencyError',
            });
          }
          return this.view(this.sessions.get(prior.sessionId)!);
        }
        if (this.failNextCreate) {
          const error = this.failNextCreate;
          this.failNextCreate = null;
          throw error;
        }
        if (typeof params.expires_at === 'number') {
          const lead = params.expires_at * 1000 - this.nowMs;
          if (lead < 30 * 60 * 1000 || lead > 24 * 3600 * 1000) {
            throw Object.assign(new Error('expires_at must be 30 minutes to 24 hours away'), {
              type: 'StripeInvalidRequestError',
            });
          }
        }
        const id = `cs_test_${++this.counter}`;
        const lineItem = params.line_items?.[0];
        this.sessions.set(id, {
          id,
          account,
          status: 'open',
          payment_status: 'unpaid',
          expires_at: params.expires_at ?? Math.floor(this.nowMs / 1000) + 24 * 3600,
          url: `https://checkout.stripe.test/${id}`,
          metadata: { ...(params.metadata as Record<string, string>) },
          payment_intent: null,
          amount_total: Number(lineItem?.price_data?.unit_amount ?? 0) * Number(lineItem?.quantity ?? 1),
          currency: 'usd',
          livemode: false,
          params,
        });
        if (key) this.idempotent.set(key, { paramsJson, sessionId: id });
        return this.view(this.sessions.get(id)!);
      },
      retrieve: async (id, _params, options) => {
        await new Promise<void>((resolve) => setImmediate(resolve));
        this.retrieveCalls.push({ id, options });
        if (this.failNextRetrieve) {
          const error = this.failNextRetrieve;
          this.failNextRetrieve = null;
          throw error;
        }
        const s = this.sessions.get(id);
        if (!s || s.account !== String(options.stripeAccount || 'platform')) throw this.notFound(id);
        return this.view(s);
      },
      expire: async (id, _params, options) => {
        await new Promise<void>((resolve) => setImmediate(resolve));
        this.expireCalls.push(id);
        const s = this.sessions.get(id);
        if (!s || s.account !== String(options.stripeAccount || 'platform')) throw this.notFound(id);
        this.view(s);
        if (s.status !== 'open') {
          throw Object.assign(new Error(`Only Checkout Sessions with a status of open can be expired (${s.status})`), {
            type: 'StripeInvalidRequestError',
          });
        }
        s.status = 'expired';
        return this.view(s);
      },
    };
  }
}

/**
 * The Stripe webhook records a paid online move-in for the public website to
 * complete, so a renter who pays and never comes back from Stripe is still
 * moved in. Stripe delivers events at least once.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';

type Doc = Record<string, unknown>;

/** Just enough Firestore for the recorder: documents by path, and `create()` refusing one that exists. */
class FakeFirestore {
  readonly docs = new Map<string, Doc>();
  creates = 0;

  collection(name: string) {
    return {
      doc: (id: string) => {
        const path = `${name}/${id}`;
        return {
          create: async (data: Doc) => {
            this.creates += 1;
            if (this.docs.has(path)) {
              throw Object.assign(new Error('6 ALREADY_EXISTS: Document already exists'), { code: 6 });
            }
            this.docs.set(path, { ...data });
          },
          get: async () => ({ exists: this.docs.has(path), data: () => this.docs.get(path) }),
          set: async (data: Doc) => {
            this.docs.set(path, { ...(this.docs.get(path) || {}), ...data });
          },
        };
      },
    };
  }
}

function installFakeFirestore(fake: FakeFirestore): void {
  const firestoreFn = Object.assign(() => fake, {
    FieldValue: { serverTimestamp: () => 'server-timestamp' },
  });
  Object.defineProperty(admin, 'firestore', { configurable: true, writable: true, value: firestoreFn });
}

function moveInSession(overrides: Doc = {}): Stripe.Checkout.Session {
  return {
    id: 'cs_move_in',
    object: 'checkout.session',
    mode: 'payment',
    metadata: {
      type: 'public_move_in',
      reservationId: 'res-1',
      moveInToken: 'token-stays-on-the-session',
      facilityId: 'fac-1',
    },
    payment_status: 'paid',
    payment_intent: 'pi_move_in',
    amount_total: 100,
    currency: 'usd',
    livemode: true,
    ...overrides,
  } as unknown as Stripe.Checkout.Session;
}

function completedEvent(session: Stripe.Checkout.Session, account: string | undefined, id = 'evt_1'): Stripe.Event {
  return {
    id,
    type: 'checkout.session.completed',
    ...(account ? { account } : {}),
    data: { object: session },
  } as unknown as Stripe.Event;
}

const RECORD_PATH = 'publicMoveInCheckouts/cs_move_in';

test('a paid move-in checkout is recorded, keyed by its session, for the public website to complete', async () => {
  const fake = new FakeFirestore();
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { recordPaidPublicMoveInCheckout } = require('../stripeWebhookPublicMoveIn') as typeof import('../stripeWebhookPublicMoveIn');

  const outcome = await recordPaidPublicMoveInCheckout(moveInSession(), 'acct_facility', 'evt_1', fake as never);

  assert.equal(outcome, 'recorded');
  const record = fake.docs.get(RECORD_PATH);
  assert.equal(record?.status, 'paid');
  assert.equal(record?.reservationId, 'res-1');
  assert.equal(record?.facilityId, 'fac-1');
  assert.equal(record?.connectedAccountId, 'acct_facility');
  assert.equal(record?.paymentIntentId, 'pi_move_in');
  assert.equal(record?.stripeEventId, 'evt_1');
  assert.equal(JSON.stringify(record).includes('token-stays-on-the-session'), false);
});

test('a redelivered event changes nothing, even after the move-in has moved the record on', async () => {
  const fake = new FakeFirestore();
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { recordPaidPublicMoveInCheckout } = require('../stripeWebhookPublicMoveIn') as typeof import('../stripeWebhookPublicMoveIn');
  await recordPaidPublicMoveInCheckout(moveInSession(), 'acct_facility', 'evt_1', fake as never);
  fake.docs.set(RECORD_PATH, { ...fake.docs.get(RECORD_PATH), status: 'completed', tenantId: 'tenant-1' });

  // The same event again, and the same session under a new event id.
  assert.equal(await recordPaidPublicMoveInCheckout(moveInSession(), 'acct_facility', 'evt_1', fake as never), 'duplicate');
  assert.equal(await recordPaidPublicMoveInCheckout(moveInSession(), 'acct_facility', 'evt_2', fake as never), 'duplicate');

  const record = fake.docs.get(RECORD_PATH);
  assert.equal(record?.status, 'completed');
  assert.equal(record?.tenantId, 'tenant-1');
  assert.equal(record?.stripeEventId, 'evt_1');
});

test('a move-in checkout event with no connected account, or unpaid, is not recorded', async () => {
  const fake = new FakeFirestore();
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { recordPaidPublicMoveInCheckout } = require('../stripeWebhookPublicMoveIn') as typeof import('../stripeWebhookPublicMoveIn');

  assert.equal(await recordPaidPublicMoveInCheckout(moveInSession(), undefined, 'evt_1', fake as never), 'ignored');
  assert.equal(
    await recordPaidPublicMoveInCheckout(moveInSession({ payment_status: 'unpaid' }), 'acct_facility', 'evt_1', fake as never),
    'ignored',
  );
  assert.equal(fake.creates, 0);
});

test('a failed write fails the webhook, so Stripe sends the event again', async () => {
  const fake = new FakeFirestore();
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { recordPaidPublicMoveInCheckout } = require('../stripeWebhookPublicMoveIn') as typeof import('../stripeWebhookPublicMoveIn');
  const failing = {
    collection: () => ({
      doc: () => ({
        create: async () => {
          throw Object.assign(new Error('14 UNAVAILABLE'), { code: 14 });
        },
      }),
    }),
  };

  await assert.rejects(
    () => recordPaidPublicMoveInCheckout(moveInSession(), 'acct_facility', 'evt_1', failing as never),
    /UNAVAILABLE/,
  );
  assert.equal(fake.docs.size, 0);
});

test('the webhook sends a connected account\'s move-in checkout to the recorder, not to subscription handling', async () => {
  const fake = new FakeFirestore();
  installFakeFirestore(fake);
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { dispatchStripeWebhookEvent } = require('../stripeWebhook') as typeof import('../stripeWebhook');

  await dispatchStripeWebhookEvent(completedEvent(moveInSession(), 'acct_facility'));
  // Delivered again: still one record.
  await dispatchStripeWebhookEvent(completedEvent(moveInSession(), 'acct_facility'));

  assert.deepEqual([...fake.docs.keys()], [RECORD_PATH]);
  assert.equal(fake.docs.get(RECORD_PATH)?.connectedAccountId, 'acct_facility');
});

test('a platform subscription checkout is not recorded as a move-in', async () => {
  const fake = new FakeFirestore();
  installFakeFirestore(fake);
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { dispatchStripeWebhookEvent } = require('../stripeWebhook') as typeof import('../stripeWebhook');

  // No accountId: subscription handling logs and returns without calling Stripe.
  await dispatchStripeWebhookEvent(
    completedEvent(moveInSession({ metadata: { facilityId: 'fac-1' }, mode: 'subscription' }), undefined),
  );

  assert.equal(fake.creates, 0);
  assert.equal(fake.docs.size, 0);
});

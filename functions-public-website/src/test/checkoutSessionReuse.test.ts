/**
 * A second press of the move-in page's pay button gets the Checkout Session
 * the first press made, not another one.
 *
 * On 2026-09-24, in a live $1 move-in at Keepsake, the first press opened no
 * window, the renter pressed again, and the reservation had two open, payable
 * sessions 14 seconds apart. Paying both takes the money twice:
 * completePublicMoveIn's one-payment-one-move-in record refuses the second
 * payment only after it has been taken.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { Timestamp } from 'firebase-admin/firestore';
import firebaseFunctionsTest from 'firebase-functions-test';
import { computePublicMoveInCharges } from '../moveInCharges';
import {
  CHECKOUT_ALREADY_PAID_MESSAGE,
  CHECKOUT_SESSION_ACCOUNT_FIELD,
  CHECKOUT_SESSION_ID_FIELD,
  MIN_REUSE_MINUTES,
} from '../checkoutSessionReuse';
import { CHECKOUT_RUN_OUT_MESSAGE } from '../checkoutHold';
import { MAX_ACTIVE_TENANTS_PER_FACILITY } from '../tenantCapacity';
import { InMemoryFirestore, installInMemoryFirestore } from './support/inMemoryFirestore';

const testEnv = firebaseFunctionsTest({ projectId: 'in-memory-test' });
const callableContext = { app: { appId: 'test-app-check' } };

const FACILITY = 'fac-reuse';
const UNIT = 'unit-reuse';
const RESERVATION = 'res-reuse';
const TOKEN = 'reuse-move-in-token-0123456789';
const ACCOUNT = 'acct_reuse';
const UNIT_PATH = `facilities/${FACILITY}/units/${UNIT}`;
const HOLD_PATH = `facilities/${FACILITY}/mapEngine/activeHolds/items/${UNIT}`;
const RESERVATION_PATH = `publicReservations/${RESERVATION}`;
const MINUTE = 60 * 1000;
const NOT_AVAILABLE = 'Unit is not currently available';

const FACILITY_DATA = {
  name: 'Reuse Storage',
  stripeConnectAccountId: ACCOUNT,
  stripeConnectOnboardingComplete: true,
};

const UNIT_DATA = { status: 'available', unitNumber: 'R1', unitType: 'standard', monthlyRate: 100 };

/**
 * The completed move-in form, as the page sends it, for a checkout that saves
 * the form before payment. A checkout that does not ignores it.
 */
const MOVE_IN_FORM = {
  name: 'Rita Renter',
  email: 'renter@example.com',
  phone: '5551234567',
  address: '1 Main St',
  city: 'Springfield',
  state: 'IL',
  zipCode: '62701',
  country: 'US',
  emergencyContactName: 'Ed Emergency',
  emergencyContactPhone: '5559876543',
  signaturePngBase64:
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  signatureSignedAt: '2026-09-24T12:00:00.000Z',
  enrollAutopayInterest: false,
};

type FakeSession = {
  id: string;
  /** The connected account it is on; asked for on another, Stripe has no such session. */
  account: string;
  url: string;
  status: 'open' | 'complete' | 'expired';
  payment_status: 'unpaid' | 'paid';
  amount_total: number;
  expires_at: number;
  metadata: Record<string, string>;
  /** The PaymentIntent it was paid with, once paid. */
  payment_intent?: string;
};

type CheckoutResult = { checkoutUrl: string; sessionId: string };

/**
 * Loads publicMoveIn against [inMemory], with Stripe's Checkout Sessions on
 * connected accounts kept in `sessions`. [beforeCreate] runs as each session
 * is being made.
 */
function loadPublicMoveIn(inMemory: InMemoryFirestore, beforeCreate?: () => Promise<void>) {
  installInMemoryFirestore(inMemory);
  const sessions = new Map<string, FakeSession>();
  const calls: string[] = [];
  const onAccount = (id: string, options: { stripeAccount?: string } | undefined): FakeSession => {
    const session = sessions.get(id);
    if (!session || session.account !== options?.stripeAccount) {
      throw Object.assign(new Error(`No such checkout.session: '${id}'`), {
        type: 'StripeInvalidRequestError',
        code: 'resource_missing',
      });
    }
    return session;
  };
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const shared = require('@sfc/functions-shared') as typeof import('@sfc/functions-shared');
  Object.defineProperty(shared, 'getStripeClient', {
    configurable: true,
    writable: true,
    value: () =>
      ({
        checkout: {
          sessions: {
            create: async (params: Record<string, any>, options?: { stripeAccount?: string }) => {
              calls.push('create');
              await beforeCreate?.();
              const id = `cs_test_${sessions.size + 1}`;
              const session: FakeSession = {
                id,
                account: String(options?.stripeAccount),
                url: `https://checkout.example/${id}`,
                status: 'open',
                payment_status: 'unpaid',
                amount_total: params.line_items[0].price_data.unit_amount,
                expires_at: params.expires_at,
                metadata: { ...params.metadata },
              };
              sessions.set(id, session);
              return { ...session };
            },
            retrieve: async (id: string, _params?: unknown, options?: { stripeAccount?: string }) => {
              calls.push(`retrieve ${id}`);
              return { ...onAccount(id, options) };
            },
            expire: async (id: string, _params?: unknown, options?: { stripeAccount?: string }) => {
              calls.push(`expire ${id}`);
              const session = onAccount(id, options);
              if (session.status !== 'open') {
                throw Object.assign(new Error('Only an open Checkout Session can be expired.'), {
                  type: 'StripeInvalidRequestError',
                });
              }
              session.status = 'expired';
              return { ...session };
            },
          },
        },
      }) as unknown as ReturnType<typeof shared.getStripeClient>,
  });
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const moveIn = require('../publicMoveIn') as typeof import('../publicMoveIn');
  return {
    sessions,
    calls,
    /** A press of the pay button: the amount the page shows, from the unit as it is now. */
    checkout: async (overrides: Record<string, unknown> = {}) =>
      (await testEnv.wrap(moveIn.createPublicMoveInCheckout)(
        {
          reservationId: RESERVATION,
          token: TOKEN,
          amount: quoteCents(inMemory) / 100,
          moveInForm: MOVE_IN_FORM,
          ...overrides,
        },
        callableContext,
      )) as CheckoutResult,
  };
}

function minutesFromNow(minutes: number): Timestamp {
  return Timestamp.fromDate(new Date(Date.now() + minutes * MINUTE));
}

/** A facility taking online payments, its unit, and a reservation holding it. */
function seed(inMemory: InMemoryFirestore) {
  inMemory.seed(`facilities/${FACILITY}`, FACILITY_DATA);
  inMemory.seed(UNIT_PATH, UNIT_DATA);
  const expiresAt = minutesFromNow(10);
  inMemory.seed(RESERVATION_PATH, {
    facilityId: FACILITY,
    unitId: UNIT,
    unitNumber: 'R1',
    status: 'pending',
    moveInToken: TOKEN,
    moveInDate: Timestamp.fromDate(new Date(2026, 8, 25)),
    reservedAt: minutesFromNow(-5),
    expiresAt,
    email: 'renter@example.com',
    name: 'Rita Renter',
    phone: '5551234567',
    metadata: {},
  });
  inMemory.seed(HOLD_PATH, { facilityId: FACILITY, unitId: UNIT, reservationId: RESERVATION, status: 'pending', expiresAt });
}

function quoteCents(inMemory: InMemoryFirestore): number {
  const reservation = inMemory.read(RESERVATION_PATH) as Record<string, unknown>;
  return computePublicMoveInCharges({
    reservation,
    unitData: inMemory.read(UNIT_PATH),
    facilityData: FACILITY_DATA,
    moveInDate: (reservation.moveInDate as Timestamp).toDate(),
  }).totalCents;
}

function update(inMemory: InMemoryFirestore, path: string, fields: Record<string, unknown>) {
  inMemory.seed(path, { ...inMemory.read(path), ...fields });
}

function updateUnit(inMemory: InMemoryFirestore, fields: Record<string, unknown>) {
  update(inMemory, UNIT_PATH, fields);
}

function recordedSession(inMemory: InMemoryFirestore): unknown {
  return inMemory.read(RESERVATION_PATH)?.[CHECKOUT_SESSION_ID_FIELD];
}

function openSessions(sessions: Map<string, FakeSession>): string[] {
  return [...sessions.values()].filter((s) => s.status === 'open').map((s) => s.id);
}

function refusedWith(code: string, message: string) {
  return (err: unknown): boolean => {
    const e = err as { code?: string; message?: string };
    assert.equal(e.code, code);
    assert.equal(e.message, message);
    return true;
  };
}

test('a second call returns the same session', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory);
  const { checkout, sessions, calls } = loadPublicMoveIn(inMemory);

  const first = await checkout();
  const second = await checkout();

  assert.deepEqual(second, first);
  assert.deepEqual(calls, ['create', `retrieve ${first.sessionId}`]);
  assert.deepEqual(openSessions(sessions), [first.sessionId]);
  assert.equal(recordedSession(inMemory), first.sessionId);
  assert.equal(inMemory.read(RESERVATION_PATH)?.[CHECKOUT_SESSION_ACCOUNT_FIELD], ACCOUNT);
});

test('a paid session is not reused, and no second one is made to pay again', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory);
  const { checkout, sessions, calls } = loadPublicMoveIn(inMemory);
  const first = await checkout();
  Object.assign(sessions.get(first.sessionId)!, { status: 'complete', payment_status: 'paid' });

  await assert.rejects(checkout, refusedWith('failed-precondition', CHECKOUT_ALREADY_PAID_MESSAGE));

  assert.deepEqual(calls, ['create', `retrieve ${first.sessionId}`]);
  assert.equal(sessions.size, 1);
  assert.equal(recordedSession(inMemory), first.sessionId);
});

test('a paid session whose payment moved the renter in is still not followed by another', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory);
  const { checkout, sessions, calls } = loadPublicMoveIn(inMemory);
  const first = await checkout();
  Object.assign(sessions.get(first.sessionId)!, { status: 'complete', payment_status: 'paid', payment_intent: 'pi_used' });
  // Its one-use record, as a completed move-in writes it: no refund on it.
  inMemory.seed('publicMoveInPayments/pi_used', {
    paymentIntentId: 'pi_used',
    facilityId: FACILITY,
    reservationId: RESERVATION,
    tenantId: 'tenant-1',
    contractId: 'contract-1',
  });

  await assert.rejects(checkout, refusedWith('failed-precondition', CHECKOUT_ALREADY_PAID_MESSAGE));

  assert.deepEqual(calls, ['create', `retrieve ${first.sessionId}`]);
  assert.equal(sessions.size, 1);
  assert.equal(recordedSession(inMemory), first.sessionId);
});

test('a paid session whose payment completion refunded is followed by a new one, in any refund state', async () => {
  for (const status of ['pending', 'refunded', 'failed']) {
    const inMemory = new InMemoryFirestore();
    seed(inMemory);
    const { checkout, sessions, calls } = loadPublicMoveIn(inMemory);
    const first = await checkout();
    Object.assign(sessions.get(first.sessionId)!, { status: 'complete', payment_status: 'paid', payment_intent: 'pi_refunded' });
    // As completion writes it on refusing the payment for changed charges,
    // which leaves the reservation open to pay the new amount.
    inMemory.seed('publicMoveInPayments/pi_refunded', {
      paymentIntentId: 'pi_refunded',
      facilityId: FACILITY,
      reservationId: RESERVATION,
      tenantId: null,
      contractId: null,
      refund: { status, refusal: 'charges-changed', unitId: UNIT, unitNumber: 'R1', renterName: 'Rita Renter' },
    });

    const second = await checkout();

    assert.notEqual(second.sessionId, first.sessionId, status);
    assert.deepEqual(calls, ['create', `retrieve ${first.sessionId}`, 'create'], status);
    assert.deepEqual(openSessions(sessions), [second.sessionId], status);
    assert.equal(recordedSession(inMemory), second.sessionId, status);
  }
});

test('an expired session is not reused: a new one is made and recorded', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory);
  const { checkout, sessions, calls } = loadPublicMoveIn(inMemory);
  const first = await checkout();
  sessions.get(first.sessionId)!.status = 'expired';

  const second = await checkout();

  assert.notEqual(second.sessionId, first.sessionId);
  assert.equal(second.checkoutUrl, sessions.get(second.sessionId)?.url);
  assert.deepEqual(calls, ['create', `retrieve ${first.sessionId}`, 'create']);
  assert.deepEqual(openSessions(sessions), [second.sessionId]);
  assert.equal(recordedSession(inMemory), second.sessionId);
});

test('an open session for a different amount is expired and replaced', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory);
  const { checkout, sessions, calls } = loadPublicMoveIn(inMemory);
  const first = await checkout();
  const firstCents = sessions.get(first.sessionId)!.amount_total;
  // The owner changes the rate before the renter pays, so the page now
  // shows, and the server now quotes, another amount.
  updateUnit(inMemory, { monthlyRate: 150 });
  assert.notEqual(quoteCents(inMemory), firstCents);

  const second = await checkout();

  assert.notEqual(second.sessionId, first.sessionId);
  assert.deepEqual(calls, ['create', `retrieve ${first.sessionId}`, `expire ${first.sessionId}`, 'create']);
  assert.equal(sessions.get(first.sessionId)?.status, 'expired');
  assert.equal(sessions.get(second.sessionId)?.amount_total, quoteCents(inMemory));
  assert.deepEqual(openSessions(sessions), [second.sessionId]);
  assert.equal(recordedSession(inMemory), second.sessionId);
});

test('an open session with too little time left to pay is expired and replaced', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory);
  const { checkout, sessions, calls } = loadPublicMoveIn(inMemory);
  const first = await checkout();
  sessions.get(first.sessionId)!.expires_at = Math.floor((Date.now() + (MIN_REUSE_MINUTES - 1) * MINUTE) / 1000);

  const second = await checkout();

  assert.notEqual(second.sessionId, first.sessionId);
  assert.deepEqual(calls, ['create', `retrieve ${first.sessionId}`, `expire ${first.sessionId}`, 'create']);
  assert.deepEqual(openSessions(sessions), [second.sessionId]);
});

// Each way checkout refuses because the move-in cannot go ahead, once a
// session has been made. Paid, that session would take money for a move-in
// that is refused, so the refusal expires it.
for (const [why, change, message] of [
  ['the unit has been rented', (m) => updateUnit(m, { status: 'occupied' }), NOT_AVAILABLE],
  ['the unit is off the public website', (m) => updateUnit(m, { publicListingEnabled: false }), NOT_AVAILABLE],
  ['the reservation was cancelled', (m) => update(m, RESERVATION_PATH, { status: 'cancelled' }), 'Reservation is not active'],
  ['the reservation has run out', (m) => update(m, RESERVATION_PATH, { expiresAt: minutesFromNow(-1) }), 'Reservation has expired'],
  ['the facility is gone', (m) => m.getStore().delete(`facilities/${FACILITY}`), 'Facility not found'],
  [
    'the facility is full',
    (m) => {
      for (let i = 0; i < MAX_ACTIVE_TENANTS_PER_FACILITY; i++) {
        m.seed(`facilities/${FACILITY}/tenants/t${i}`, { isActive: true });
      }
    },
    'This facility is not taking online move-ins right now. Please contact the facility.',
  ],
  [
    'the renter is on a do-not-rent list',
    (m) => m.seed('global_dnr_entries/g1', { status: 'active', email: 'renter@example.com', fullName: '', phone: '' }),
    'Online move-in is not available. Please contact the facility directly.',
  ],
] as Array<[string, (m: InMemoryFirestore) => void, string]>) {
  test(`a refusal because ${why} is not handed the open session, and expires it`, async () => {
    const inMemory = new InMemoryFirestore();
    seed(inMemory);
    const { checkout, sessions, calls } = loadPublicMoveIn(inMemory);
    const first = await checkout();
    change(inMemory);

    await assert.rejects(checkout, (err: unknown) => {
      assert.equal((err as { message?: string }).message, message);
      return true;
    });

    // Refused before Stripe is asked for the session, which is then expired.
    assert.deepEqual(calls, ['create', `expire ${first.sessionId}`]);
    assert.equal(sessions.get(first.sessionId)?.status, 'expired');
  });
}

// Refusals that say nothing about the move-in leave the session as it is:
// the renter may be paying it in another tab.
for (const [why, overrides, code] of [
  ['a caller without the move-in token', { token: 'someone-elses-token-0123456789' }, 'permission-denied'],
  ['a page showing an old amount', { amount: 999 }, 'invalid-argument'],
] as Array<[string, Record<string, unknown>, string]>) {
  test(`a refusal of ${why} leaves the open session payable`, async () => {
    const inMemory = new InMemoryFirestore();
    seed(inMemory);
    const { checkout, sessions, calls } = loadPublicMoveIn(inMemory);
    const first = await checkout();

    await assert.rejects(() => checkout(overrides), (err: unknown) => {
      assert.equal((err as { code?: string }).code, code);
      return true;
    });

    assert.deepEqual(calls, ['create']);
    assert.deepEqual(openSessions(sessions), [first.sessionId]);
  });
}

test('a refusal because the hold is out of time leaves the open session payable', async () => {
  // Checkout will not stretch the hold for a new session past three hours,
  // but the session made earlier is inside the hold made for it, and paid
  // it still completes the move-in.
  const inMemory = new InMemoryFirestore();
  seed(inMemory);
  const { checkout, sessions, calls } = loadPublicMoveIn(inMemory);
  const first = await checkout();
  update(inMemory, RESERVATION_PATH, { reservedAt: minutesFromNow(-170) });

  await assert.rejects(checkout, refusedWith('failed-precondition', CHECKOUT_RUN_OUT_MESSAGE));

  assert.deepEqual(calls, ['create']);
  assert.deepEqual(openSessions(sessions), [first.sessionId]);
});

test('a refusal not listed as ending checkout leaves the session payable', async () => {
  // A new failed-precondition refusal (here, a page too old to send the
  // move-in form) does not expire sessions until it is listed.
  const inMemory = new InMemoryFirestore();
  seed(inMemory);
  const { checkout, sessions } = loadPublicMoveIn(inMemory);
  const first = await checkout();
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { expireRecordedSessionOnRefusal } = require('../checkoutSessionReuse') as typeof import('../checkoutSessionReuse');
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const functions = require('firebase-functions/v1') as typeof import('firebase-functions/v1');
  const refuses = expireRecordedSessionOnRefusal(async () => {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Please refresh this page, then fill in the move-in form before paying.',
    );
  });

  await assert.rejects(() => refuses({ reservationId: RESERVATION, token: TOKEN }, callableContext as never));

  assert.deepEqual(openSessions(sessions), [first.sessionId]);
});

test('only a caller holding the move-in token can have a refusal expire the session', async () => {
  // Checkout checks the token before it can refuse for any other reason. The
  // expiry checks it again, so a refusal that someday comes first does not
  // let anyone with a reservation id end a renter's payment.
  const inMemory = new InMemoryFirestore();
  seed(inMemory);
  const { checkout, sessions, calls } = loadPublicMoveIn(inMemory);
  const first = await checkout();
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { expireRecordedSessionOnRefusal } = require('../checkoutSessionReuse') as typeof import('../checkoutSessionReuse');
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const functions = require('firebase-functions/v1') as typeof import('firebase-functions/v1');
  const refuses = expireRecordedSessionOnRefusal(async () => {
    throw new functions.https.HttpsError('failed-precondition', NOT_AVAILABLE);
  });

  await assert.rejects(() => refuses({ reservationId: RESERVATION, token: 'not-the-token' }, callableContext as never));
  assert.deepEqual(openSessions(sessions), [first.sessionId]);

  await assert.rejects(() => refuses({ reservationId: RESERVATION, token: TOKEN }, callableContext as never));
  assert.deepEqual(calls, ['create', `expire ${first.sessionId}`]);
});

test('a caller without App Check cannot have its refusal expire the session', async () => {
  // Checkout refuses such a caller with failed-precondition before it reads
  // anything; the expiry must not do for it what checkout will not.
  const inMemory = new InMemoryFirestore();
  seed(inMemory);
  const { checkout, sessions, calls } = loadPublicMoveIn(inMemory);
  const first = await checkout();
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const moveIn = require('../publicMoveIn') as typeof import('../publicMoveIn');

  await assert.rejects(
    () =>
      testEnv.wrap(moveIn.createPublicMoveInCheckout)(
        { reservationId: RESERVATION, token: TOKEN, amount: quoteCents(inMemory) / 100, moveInForm: MOVE_IN_FORM },
        {},
      ),
    refusedWith('failed-precondition', 'App Check token required. Please update your app.'),
  );

  assert.deepEqual(calls, ['create']);
  assert.deepEqual(openSessions(sessions), [first.sessionId]);
});

test('a session on the facility\'s previous Stripe account is expired there, not handed back', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory);
  const { checkout, sessions, calls } = loadPublicMoveIn(inMemory);
  const first = await checkout();
  update(inMemory, `facilities/${FACILITY}`, { stripeConnectAccountId: 'acct_new' });

  const second = await checkout();

  assert.deepEqual(calls, ['create', `retrieve ${first.sessionId}`, `expire ${first.sessionId}`, 'create']);
  assert.equal(sessions.get(first.sessionId)?.status, 'expired');
  assert.equal(sessions.get(second.sessionId)?.account, 'acct_new');
  assert.equal(inMemory.read(RESERVATION_PATH)?.[CHECKOUT_SESSION_ACCOUNT_FIELD], 'acct_new');
});

test('a session paid on the facility\'s previous Stripe account is not followed by another', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory);
  const { checkout, sessions, calls } = loadPublicMoveIn(inMemory);
  const first = await checkout();
  Object.assign(sessions.get(first.sessionId)!, { status: 'complete', payment_status: 'paid' });
  update(inMemory, `facilities/${FACILITY}`, { stripeConnectAccountId: 'acct_new' });

  await assert.rejects(checkout, refusedWith('failed-precondition', CHECKOUT_ALREADY_PAID_MESSAGE));

  assert.deepEqual(calls, ['create', `retrieve ${first.sessionId}`]);
});

test('a session recorded without its account is found on the facility\'s account', async () => {
  // Recorded by a checkout from before the account was recorded with it.
  const inMemory = new InMemoryFirestore();
  seed(inMemory);
  const { checkout, sessions, calls } = loadPublicMoveIn(inMemory);
  const first = await checkout();
  const reservation = { ...inMemory.read(RESERVATION_PATH) };
  delete reservation[CHECKOUT_SESSION_ACCOUNT_FIELD];
  inMemory.seed(RESERVATION_PATH, reservation);

  assert.deepEqual(await checkout(), first);
  updateUnit(inMemory, { status: 'occupied' });
  await assert.rejects(checkout, refusedWith('failed-precondition', NOT_AVAILABLE));

  assert.deepEqual(calls, ['create', `retrieve ${first.sessionId}`, `expire ${first.sessionId}`]);
  assert.equal(sessions.get(first.sessionId)?.status, 'expired');
});

test('when Stripe cannot say what state the recorded session is in, no second one is made', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory);
  const { checkout, sessions, calls } = loadPublicMoveIn(inMemory);
  const first = await checkout();
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const shared = require('@sfc/functions-shared') as typeof import('@sfc/functions-shared');
  const stripe = shared.getStripeClient() as unknown as { checkout: { sessions: Record<string, unknown> } };
  const retrieveDown = async () => {
    calls.push('retrieve failed');
    throw Object.assign(new Error('An error occurred with our connection to Stripe.'), {
      type: 'StripeConnectionError',
    });
  };
  Object.defineProperty(shared, 'getStripeClient', {
    configurable: true,
    writable: true,
    value: () => ({ checkout: { sessions: { ...stripe.checkout.sessions, retrieve: retrieveDown } } }),
  });

  await assert.rejects(
    checkout,
    refusedWith('failed-precondition', 'Payment could not be started. Please contact the facility directly.'),
  );

  assert.deepEqual(calls, ['create', 'retrieve failed']);
  assert.deepEqual(openSessions(sessions), [first.sessionId]);
});

test('a recorded session Stripe does not have is replaced', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory);
  inMemory.seed(RESERVATION_PATH, { ...inMemory.read(RESERVATION_PATH), [CHECKOUT_SESSION_ID_FIELD]: 'cs_gone' });
  const { checkout, calls } = loadPublicMoveIn(inMemory);

  const result = await checkout();

  assert.deepEqual(calls, ['retrieve cs_gone', 'create']);
  assert.equal(recordedSession(inMemory), result.sessionId);
});

test('two presses at once leave one payable session, and both get it', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory);
  // Both calls are making a session before either has recorded one.
  let making = 0;
  let bothMaking!: () => void;
  const bothAreMaking = new Promise<void>((resolve) => {
    bothMaking = resolve;
  });
  const { checkout, sessions, calls } = loadPublicMoveIn(inMemory, async () => {
    making += 1;
    if (making === 2) bothMaking();
    await bothAreMaking;
  });

  const [a, b] = await Promise.all([checkout(), checkout()]);

  assert.deepEqual(a, b);
  assert.equal(calls.filter((c) => c === 'create').length, 2);
  assert.deepEqual(openSessions(sessions), [a.sessionId]);
  assert.equal(recordedSession(inMemory), a.sessionId);
});

test.after(() => {
  testEnv.cleanup();
});

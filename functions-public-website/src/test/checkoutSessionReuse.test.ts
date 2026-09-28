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
  CHECKOUT_SESSION_ID_FIELD,
  MIN_REUSE_MINUTES,
} from '../checkoutSessionReuse';
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
  url: string;
  status: 'open' | 'complete' | 'expired';
  payment_status: 'unpaid' | 'paid';
  amount_total: number;
  expires_at: number;
  metadata: Record<string, string>;
};

type CheckoutResult = { checkoutUrl: string; sessionId: string };

/**
 * Loads publicMoveIn against [inMemory], with Stripe's Checkout Sessions on
 * the facility's account kept in `sessions`. [beforeCreate] runs as each
 * session is being made.
 */
function loadPublicMoveIn(inMemory: InMemoryFirestore, beforeCreate?: () => Promise<void>) {
  installInMemoryFirestore(inMemory);
  const sessions = new Map<string, FakeSession>();
  const calls: string[] = [];
  const onAccount = (options: { stripeAccount?: string } | undefined) =>
    assert.equal(options?.stripeAccount, ACCOUNT, 'the session is on the facility\'s account');
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
              onAccount(options);
              calls.push('create');
              await beforeCreate?.();
              const id = `cs_test_${sessions.size + 1}`;
              const session: FakeSession = {
                id,
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
              onAccount(options);
              calls.push(`retrieve ${id}`);
              const session = sessions.get(id);
              if (!session) {
                throw Object.assign(new Error(`No such checkout.session: '${id}'`), {
                  type: 'StripeInvalidRequestError',
                  code: 'resource_missing',
                });
              }
              return { ...session };
            },
            expire: async (id: string, _params?: unknown, options?: { stripeAccount?: string }) => {
              onAccount(options);
              calls.push(`expire ${id}`);
              const session = sessions.get(id);
              if (!session || session.status !== 'open') {
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
    checkout: async () =>
      (await testEnv.wrap(moveIn.createPublicMoveInCheckout)(
        { reservationId: RESERVATION, token: TOKEN, amount: quoteCents(inMemory) / 100, moveInForm: MOVE_IN_FORM },
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

function updateUnit(inMemory: InMemoryFirestore, fields: Record<string, unknown>) {
  inMemory.seed(UNIT_PATH, { ...inMemory.read(UNIT_PATH), ...fields });
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

for (const [why, unitFields] of [
  ['rented', { status: 'occupied' }],
  ['taken off the public website', { publicListingEnabled: false }],
] as Array<[string, Record<string, unknown>]>) {
  test(`an open session is not handed back once the unit has been ${why}`, async () => {
    const inMemory = new InMemoryFirestore();
    seed(inMemory);
    const { checkout, calls } = loadPublicMoveIn(inMemory);
    await checkout();
    updateUnit(inMemory, unitFields);

    await assert.rejects(checkout, refusedWith('failed-precondition', NOT_AVAILABLE));

    // Refused before Stripe is asked for the session.
    assert.deepEqual(calls, ['create']);
  });
}

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

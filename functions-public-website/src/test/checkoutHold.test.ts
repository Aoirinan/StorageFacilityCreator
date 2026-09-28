/**
 * A renter who pays keeps the unit long enough to finish moving in.
 *
 * The hold (at most 15 minutes public, 60 portal) had to cover choosing the
 * unit, paying on Stripe's page, which stayed payable for 24 hours, and then
 * filling in and signing the move-in form. When it lapsed first, the renter
 * had paid, reopening the link said the reservation had expired, and
 * completePublicMoveIn refused them, while the unit was free to be held and
 * rented by someone else.
 */
import test, { mock } from 'node:test';
import assert from 'node:assert/strict';
import { Timestamp } from 'firebase-admin/firestore';
import firebaseFunctionsTest from 'firebase-functions-test';
import { computePublicMoveInCharges } from '../moveInCharges';
import { CHECKOUT_RUN_OUT_MESSAGE } from '../checkoutHold';
import { InMemoryFirestore, installInMemoryFirestore } from './support/inMemoryFirestore';

const testEnv = firebaseFunctionsTest({ projectId: 'in-memory-test' });
const callableContext = { app: { appId: 'test-app-check' } };

const FACILITY = 'fac-hold';
const UNIT = 'unit-hold';
const RESERVATION = 'res-hold';
const TOKEN = 'hold-move-in-token-0123456789';
const ACCOUNT = 'acct_hold';
const UNIT_PATH = `facilities/${FACILITY}/units/${UNIT}`;
const HOLD_PATH = `facilities/${FACILITY}/mapEngine/activeHolds/items/${UNIT}`;
const RESERVATION_PATH = `publicReservations/${RESERVATION}`;
const MINUTE = 60 * 1000;
const EXPIRED = 'Reservation has expired';
const NOT_AVAILABLE = 'Unit is not currently available';
const OTHER_RESERVATION = 'This payment was made for a different reservation. Contact the facility.';
const NOT_STARTED = 'Payment could not be started. Please contact the facility directly.';

/** Stripe Connect is set up, so the move-in is paid through Checkout. */
const FACILITY_DATA = {
  name: 'Hold Storage',
  stripeConnectAccountId: ACCOUNT,
  stripeConnectOnboardingComplete: true,
};

const UNIT_DATA = { status: 'available', unitNumber: 'H1', unitType: 'standard', monthlyRate: 100 };

/** How checkout tags the PaymentIntent it creates. */
const TAGGED = { type: 'public_move_in', reservationId: RESERVATION };

type StripeCall = { method: string; id?: string; params?: Record<string, any>; options?: Record<string, any> };

/** A Checkout Session as Stripe holds it. */
type FakeSession = {
  status: 'open' | 'complete' | 'expired';
  payment_status?: 'paid' | 'unpaid';
  payment_intent?: string;
  metadata?: Record<string, string>;
  amount_total?: number;
};

type StripeStub = {
  /** On the PaymentIntent the renter paid with, or given for each PaymentIntent id. */
  paymentMetadata?: Record<string, string> | ((paymentIntentId: string) => Record<string, string>);
  /** Checkout Sessions Stripe knows, by id. */
  sessions?: Record<string, FakeSession>;
  /** checkout.sessions.create fails with this. */
  createError?: Error;
  /** Runs inside checkout.sessions.create, as another request writing meanwhile. */
  onCreate?: () => void;
};

/**
 * Loads publicMoveIn against [inMemory], with Stripe replaced by a recorder.
 * A payment received is the amount of the last session checkout created, or
 * the reservation's quote when none was.
 */
function loadPublicMoveIn(inMemory: InMemoryFirestore, stub: StripeStub = {}) {
  installInMemoryFirestore(inMemory);
  const stripeCalls: StripeCall[] = [];
  const sessions = stub.sessions ?? {};
  const createdAmounts: number[] = [];
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const shared = require('@sfc/functions-shared') as typeof import('@sfc/functions-shared');
  Object.defineProperty(shared, 'getStripeClient', {
    configurable: true,
    writable: true,
    value: () =>
      ({
        checkout: {
          sessions: {
            create: async (params: Record<string, any>, options: Record<string, any>) => {
              stripeCalls.push({ method: 'checkout.sessions.create', params, options });
              stub.onCreate?.();
              if (stub.createError) throw stub.createError;
              const id = `cs_new_${stripeCalls.filter((c) => c.method === 'checkout.sessions.create').length}`;
              sessions[id] = { status: 'open', metadata: params.metadata };
              createdAmounts.push(params.line_items[0].price_data.unit_amount);
              return { id, url: `https://checkout.example/${id}` };
            },
            retrieve: async (id: string, _params: Record<string, any>, options: Record<string, any>) => {
              stripeCalls.push({ method: 'checkout.sessions.retrieve', id, options });
              const session = sessions[id];
              if (!session) throw Object.assign(new Error('No such checkout.session'), { code: 'resource_missing' });
              return { id, currency: 'usd', payment_status: 'unpaid', ...session };
            },
          },
        },
        refunds: {
          create: async (params: Record<string, any>) => {
            stripeCalls.push({ method: 'refunds.create', params });
            return { id: 're_hold', status: 'succeeded' };
          },
        },
        paymentIntents: {
          retrieve: async (paymentIntentId: string) => {
            stripeCalls.push({ method: 'paymentIntents.retrieve' });
            return {
              id: paymentIntentId,
              amount_received: createdAmounts.length > 0 ? createdAmounts[createdAmounts.length - 1] : quoteCents(inMemory),
              status: 'succeeded',
              metadata: typeof stub.paymentMetadata === 'function'
                ? stub.paymentMetadata(paymentIntentId)
                : stub.paymentMetadata ?? {},
            };
          },
        },
      }) as unknown as ReturnType<typeof shared.getStripeClient>,
  });
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const moveIn = require('../publicMoveIn') as typeof import('../publicMoveIn');
  return {
    stripeCalls,
    sessions,
    open: () => testEnv.wrap(moveIn.getPublicReservationByToken)({ token: TOKEN }, callableContext),
    /** Checkout for this reservation, or for [as] (priced as this one: seed them alike). */
    checkout: (as: { reservationId: string; token: string } = { reservationId: RESERVATION, token: TOKEN }) =>
      testEnv.wrap(moveIn.createPublicMoveInCheckout)(
        { ...as, amount: checkoutQuoteCents(inMemory) / 100 },
        callableContext,
      ) as Promise<{ checkoutUrl?: string; sessionId?: string }>,
    confirm: (sessionId: string) =>
      testEnv.wrap(moveIn.confirmPublicMoveInCheckout)(
        { reservationId: RESERVATION, token: TOKEN, sessionId },
        callableContext,
      ) as Promise<{ success?: boolean; paymentIntentId?: string }>,
    complete: (overrides: Record<string, unknown> = {}) =>
      testEnv.wrap(moveIn.completePublicMoveIn)(
        {
          reservationId: RESERVATION,
          token: TOKEN,
          name: 'Rita Renter',
          email: 'renter@example.com',
          phone: '5551234567',
          paymentIntentId: 'pi_hold',
          signaturePngBase64:
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
          ...overrides,
        },
        callableContext,
      ) as Promise<{ success?: boolean; tenantId?: string }>,
  };
}

function minutesFromNow(minutes: number): Timestamp {
  return Timestamp.fromDate(new Date(Date.now() + minutes * MINUTE));
}

/**
 * A facility, its unit and a reservation holding it. [expiresInMinutes] is
 * when the hold ends (negative: it has lapsed); [checkoutStarted] is whether
 * the renter has been to Stripe's page.
 */
function seed(
  inMemory: InMemoryFirestore,
  opts: {
    expiresInMinutes: number;
    reservedMinutesAgo?: number;
    checkoutStarted?: boolean;
    reservation?: Record<string, unknown>;
  },
) {
  inMemory.seed(`facilities/${FACILITY}`, FACILITY_DATA);
  inMemory.seed(UNIT_PATH, UNIT_DATA);
  const expiresAt = minutesFromNow(opts.expiresInMinutes);
  inMemory.seed(RESERVATION_PATH, {
    facilityId: FACILITY,
    unitId: UNIT,
    unitNumber: 'H1',
    status: 'pending',
    moveInToken: TOKEN,
    moveInDate: Timestamp.fromDate(new Date(2026, 8, 25)),
    reservedAt: minutesFromNow(-(opts.reservedMinutesAgo ?? 5)),
    expiresAt,
    email: 'renter@example.com',
    name: 'Rita Renter',
    metadata: {},
    ...(opts.checkoutStarted ? { checkoutUpdatedAt: minutesFromNow(-(opts.reservedMinutesAgo ?? 5) + 1) } : {}),
    ...opts.reservation,
  });
  seedHold(inMemory, RESERVATION, expiresAt);
}

function seedHold(inMemory: InMemoryFirestore, reservationId: string, expiresAt: Timestamp) {
  inMemory.seed(HOLD_PATH, { facilityId: FACILITY, unitId: UNIT, reservationId, status: 'pending', expiresAt });
}

const SOMEONE_ELSE = { reservationId: 'res-someone-else', token: 'someone-else-token-0123456789' };

/**
 * Another renter's reservation, holding the unit until [expiresAt] and priced
 * as this one is. [goneToPay]: they have started checkout, so they may be
 * paying.
 */
function seedSomeoneElse(inMemory: InMemoryFirestore, expiresAt: Timestamp, goneToPay: boolean) {
  inMemory.seed(`publicReservations/${SOMEONE_ELSE.reservationId}`, {
    facilityId: FACILITY,
    unitId: UNIT,
    unitNumber: 'H1',
    status: 'pending',
    moveInToken: SOMEONE_ELSE.token,
    moveInDate: Timestamp.fromDate(new Date(2026, 8, 25)),
    reservedAt: minutesFromNow(-2),
    expiresAt,
    email: 'someone@example.com',
    name: 'Someone Else',
    metadata: {},
    ...(goneToPay ? { checkoutUpdatedAt: minutesFromNow(-1) } : {}),
  });
  seedHold(inMemory, SOMEONE_ELSE.reservationId, expiresAt);
}

/**
 * What the reservation's move-in costs from [date], by default the date
 * checkout would price it from: its move-in date, else the date a checkout
 * recorded, else today.
 */
function quoteCents(inMemory: InMemoryFirestore, date?: Date): number {
  const reservation = inMemory.read(RESERVATION_PATH) as Record<string, unknown>;
  const recorded = (reservation.moveInDate ?? reservation.checkoutMoveInDate) as Timestamp | undefined;
  return computePublicMoveInCharges({
    reservation,
    unitData: inMemory.read(UNIT_PATH),
    facilityData: FACILITY_DATA,
    moveInDate: date ?? recorded?.toDate() ?? new Date(),
  }).totalCents;
}

/** What a checkout started now charges: from the move-in date, else today (not a date an earlier checkout recorded). */
function checkoutQuoteCents(inMemory: InMemoryFirestore): number {
  const moveInDate = inMemory.read(RESERVATION_PATH)?.moveInDate as Timestamp | null | undefined;
  return quoteCents(inMemory, moveInDate?.toDate() ?? new Date());
}

function millisOf(value: unknown): number {
  return value instanceof Date ? value.getTime() : (value as Timestamp).toMillis();
}

function expiryOf(inMemory: InMemoryFirestore, path: string): number {
  return (inMemory.read(path)?.expiresAt as Timestamp).toMillis();
}

function refusedWith(message: string, code = 'failed-precondition') {
  return (err: unknown): boolean => {
    const e = err as { code?: string; message?: string };
    assert.equal(e.code, code);
    assert.equal(e.message, message);
    return true;
  };
}

function methods(stripeCalls: StripeCall[]): string[] {
  return stripeCalls.map((c) => c.method);
}

function assertNoMoveIn(inMemory: InMemoryFirestore) {
  assert.equal(inMemory.listCollection(`facilities/${FACILITY}/tenants`).length, 0);
  assert.equal(inMemory.read(UNIT_PATH)?.status, 'available');
}

/** A Checkout Session of this reservation that Stripe shows paid. */
function paidSession(paymentIntent = 'pi_hold'): FakeSession {
  return {
    status: 'complete',
    payment_status: 'paid',
    payment_intent: paymentIntent,
    metadata: { type: 'public_move_in', reservationId: RESERVATION, moveInToken: TOKEN },
    amount_total: 2333,
  };
}

// Checkout

test('checkout gives Stripe a 35-minute page and holds the unit 10 minutes past it', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: 10 });
  const { checkout, stripeCalls } = loadPublicMoveIn(inMemory);
  const before = Date.now();

  await checkout();

  const params = stripeCalls[0]?.params as Record<string, any>;
  assert.deepEqual(methods(stripeCalls), ['checkout.sessions.create']);
  const sessionExpiresMs = params.expires_at * 1000;
  // Stripe accepts 30 minutes to 24 hours.
  assert.ok(sessionExpiresMs >= before + 30 * MINUTE + 60 * 1000);
  assert.ok(sessionExpiresMs <= before + 36 * MINUTE);
  // The payment says which reservation it is for, and carries neither the
  // token nor facilityId (the refund webhook posts a ledger row for that).
  assert.deepEqual(params.payment_intent_data?.metadata, TAGGED);
  // Long enough to come back from the page and confirm; the hour to finish
  // is given only for a session Stripe shows paid. Before: a full hour after
  // the page for every checkout, paid or not.
  for (const path of [RESERVATION_PATH, HOLD_PATH]) {
    const afterPage = expiryOf(inMemory, path) - sessionExpiresMs;
    assert.ok(afterPage >= 10 * MINUTE - 1000, `${path} ends before the renter is back`);
    assert.ok(afterPage < 10 * MINUTE + 1000, `${path} held past the return window`);
  }
  assert.equal(inMemory.read(HOLD_PATH)?.reservationId, RESERVATION);
});

test('checkout holds the unit again when its hold has gone', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: 10 });
  inMemory.getStore().delete(HOLD_PATH);
  const { checkout } = loadPublicMoveIn(inMemory);

  await checkout();

  assert.equal(inMemory.read(HOLD_PATH)?.reservationId, RESERVATION);
  assert.equal(expiryOf(inMemory, HOLD_PATH), expiryOf(inMemory, RESERVATION_PATH));
});

test('checkout never shortens a hold that already runs longer', async () => {
  const inMemory = new InMemoryFirestore();
  // Held for longer than checkout would (a confirmed payment extends it).
  seed(inMemory, { expiresInMinutes: 100 });
  const heldUntil = expiryOf(inMemory, HOLD_PATH);
  const { checkout } = loadPublicMoveIn(inMemory);

  await checkout();

  assert.equal(expiryOf(inMemory, RESERVATION_PATH), heldUntil);
  assert.equal(expiryOf(inMemory, HOLD_PATH), heldUntil);
});

test('checkout can extend a portal-length hold that is nearly over', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: 1, reservedMinutesAgo: 59 });
  const { checkout, stripeCalls } = loadPublicMoveIn(inMemory);

  await checkout();

  assert.equal(stripeCalls.length, 1);
});

test('checkout will not keep a unit held past three hours, and Stripe is not called', async () => {
  // Checkout holds 45 minutes: begun 134 minutes after the unit was chosen
  // it ends at 179, begun at 136 it would end at 181.
  for (const [reservedMinutesAgo, allowed] of [[134, true], [136, false]] as Array<[number, boolean]>) {
    const inMemory = new InMemoryFirestore();
    seed(inMemory, { expiresInMinutes: 20, reservedMinutesAgo, checkoutStarted: true });
    const heldUntil = expiryOf(inMemory, RESERVATION_PATH);
    const { checkout, stripeCalls } = loadPublicMoveIn(inMemory);

    if (allowed) {
      await checkout();
      assert.equal(stripeCalls.length, 1);
      continue;
    }
    await assert.rejects(checkout, refusedWith(CHECKOUT_RUN_OUT_MESSAGE));

    assert.deepEqual(stripeCalls, []);
    assert.equal(expiryOf(inMemory, RESERVATION_PATH), heldUntil);
    assert.equal(expiryOf(inMemory, HOLD_PATH), heldUntil);
  }
});

test('checkout is refused while another renter holds the unit, and Stripe is not called', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: 10 });
  seedHold(inMemory, 'res-someone-else', minutesFromNow(10));
  const { checkout, stripeCalls } = loadPublicMoveIn(inMemory);

  await assert.rejects(checkout, refusedWith(NOT_AVAILABLE));

  assert.deepEqual(stripeCalls, []);
  assert.equal(inMemory.read(HOLD_PATH)?.reservationId, 'res-someone-else');
  assert.equal(inMemory.read(RESERVATION_PATH)?.checkoutUpdatedAt, undefined);
});

test('a reservation cancelled while checkout was being set up never reaches Stripe', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: 10 });
  const heldUntil = expiryOf(inMemory, HOLD_PATH);
  const { checkout, stripeCalls } = loadPublicMoveIn(inMemory);
  // Cancelled after checkout first read it as pending, before it holds the unit.
  inMemory.beforeTransaction = (n) => {
    if (n === 1) inMemory.seed(RESERVATION_PATH, { ...inMemory.read(RESERVATION_PATH), status: 'cancelled' });
  };

  await assert.rejects(checkout, refusedWith('Reservation is not active'));

  assert.deepEqual(stripeCalls, []);
  assert.equal(expiryOf(inMemory, HOLD_PATH), heldUntil);
  assert.equal(inMemory.read(RESERVATION_PATH)?.expectedCheckoutAmountCents, undefined);
});

test('when Stripe refuses the session, the hold ends when it was going to, not 45 minutes on', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: 10 });
  const heldUntil = expiryOf(inMemory, HOLD_PATH);
  const { checkout } = loadPublicMoveIn(inMemory, { createError: new Error('This account cannot create sessions') });

  await assert.rejects(checkout, refusedWith(NOT_STARTED));

  // Before: held on for over an hour and a half with nothing anyone could pay.
  assert.equal(expiryOf(inMemory, RESERVATION_PATH), heldUntil);
  assert.equal(expiryOf(inMemory, HOLD_PATH), heldUntil);
  assert.equal(inMemory.read(HOLD_PATH)?.reservationId, RESERVATION);
  // Never went to a page, so it is not kept open for a payment that cannot exist.
  assert.equal(inMemory.read(RESERVATION_PATH)?.checkoutUpdatedAt, undefined);
});

test('when Stripe refuses the session, a hold checkout created is removed', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: 10 });
  inMemory.getStore().delete(HOLD_PATH);
  const { checkout } = loadPublicMoveIn(inMemory, { createError: new Error('Stripe is down') });

  await assert.rejects(checkout, refusedWith(NOT_STARTED));

  assert.equal(inMemory.read(HOLD_PATH), undefined);
});

test('when Stripe refuses the session, a hold extended again meanwhile is left alone', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: 10 });
  const extended = minutesFromNow(90);
  const { checkout } = loadPublicMoveIn(inMemory, {
    // A confirmed payment extended the hold while this checkout waited on Stripe.
    onCreate: () => {
      seedHold(inMemory, RESERVATION, extended);
      inMemory.seed(RESERVATION_PATH, { ...inMemory.read(RESERVATION_PATH), expiresAt: extended });
    },
    createError: new Error('Stripe is down'),
  });

  await assert.rejects(checkout, refusedWith(NOT_STARTED));

  assert.equal(expiryOf(inMemory, HOLD_PATH), extended.toMillis());
  assert.equal(expiryOf(inMemory, RESERVATION_PATH), extended.toMillis());
});

test('when Stripe refuses the session, the price an earlier checkout made its session for is put back', async () => {
  const inMemory = new InMemoryFirestore();
  // An earlier checkout, whose session may still be paid in another tab.
  const earlier = {
    expectedCheckoutAmountCents: 1999,
    checkoutMoveInDate: Timestamp.fromDate(new Date(2026, 8, 23)),
    checkoutUpdatedAt: minutesFromNow(-4),
    checkoutAttemptId: 'attempt-earlier',
  };
  seed(inMemory, { expiresInMinutes: 40, reservation: earlier });
  const { checkout } = loadPublicMoveIn(inMemory, { createError: new Error('Stripe is down') });

  await assert.rejects(checkout, refusedWith(NOT_STARTED));

  // Left priced by the failed attempt, completing the earlier session's
  // payment would be refused as 'charges changed' and refunded.
  const reservation = inMemory.read(RESERVATION_PATH) as Record<string, unknown>;
  for (const [field, value] of Object.entries(earlier)) {
    assert.deepEqual(reservation[field], value, field);
  }
});

test('when Stripe refuses the session, what a later checkout wrote is left alone', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: 10 });
  const later = {
    expectedCheckoutAmountCents: 4242,
    checkoutMoveInDate: Timestamp.fromDate(new Date(2026, 8, 26)),
    checkoutAttemptId: 'attempt-later',
  };
  const { checkout } = loadPublicMoveIn(inMemory, {
    // A second tab's checkout ran while this one waited on Stripe.
    onCreate: () => inMemory.seed(RESERVATION_PATH, { ...inMemory.read(RESERVATION_PATH), ...later }),
    createError: new Error('Stripe is down'),
  });

  await assert.rejects(checkout, refusedWith(NOT_STARTED));

  const reservation = inMemory.read(RESERVATION_PATH) as Record<string, unknown>;
  for (const [field, value] of Object.entries(later)) {
    assert.deepEqual(reservation[field], value, field);
  }
  assert.notEqual(reservation.checkoutUpdatedAt, undefined);
});

// Confirming a paid session

test('confirming a paid session holds the unit an hour for the renter to finish', async () => {
  const inMemory = new InMemoryFirestore();
  // Paid near the end of the page: checkout's hold has minutes left.
  seed(inMemory, { expiresInMinutes: 3, checkoutStarted: true });
  const { confirm } = loadPublicMoveIn(inMemory, { sessions: { cs_paid: paidSession() } });
  const before = Date.now();

  const result = await confirm('cs_paid');

  assert.equal(result.paymentIntentId, 'pi_hold');
  // Before: the hold ran out three minutes later, while the renter filled in the form.
  for (const path of [RESERVATION_PATH, HOLD_PATH]) {
    assert.ok(expiryOf(inMemory, path) >= before + 60 * MINUTE, `${path} ends before the renter can finish`);
    assert.ok(expiryOf(inMemory, path) <= Date.now() + 60 * MINUTE);
  }
  assert.equal(inMemory.read(HOLD_PATH)?.reservationId, RESERVATION);
});

for (const [why, setUp] of [
  ['lapsed', (inMemory: InMemoryFirestore) => seedHold(inMemory, RESERVATION, minutesFromNow(-5))],
  ['gone', (inMemory: InMemoryFirestore) => inMemory.getStore().delete(HOLD_PATH)],
  ['lapsed, and was another renter\'s', (inMemory: InMemoryFirestore) => seedHold(inMemory, 'res-before', minutesFromNow(-5))],
] as Array<[string, (inMemory: InMemoryFirestore) => void]>) {
  test(`confirming a paid session holds the unit again when the hold has ${why}`, async () => {
    const inMemory = new InMemoryFirestore();
    seed(inMemory, { expiresInMinutes: -5, checkoutStarted: true });
    setUp(inMemory);
    const { confirm } = loadPublicMoveIn(inMemory, { sessions: { cs_paid: paidSession() } });

    await confirm('cs_paid');

    // Before: nothing held the unit while the renter re-entered the form,
    // and a renter who held it meanwhile had them refused after paying.
    assert.equal(inMemory.read(HOLD_PATH)?.reservationId, RESERVATION);
    assert.ok(expiryOf(inMemory, HOLD_PATH) > Date.now() + 59 * MINUTE);
    assert.ok(expiryOf(inMemory, RESERVATION_PATH) > Date.now() + 59 * MINUTE);
  });
}

test('confirming a paid session does not take the unit from a renter who holds it now and has gone to pay', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: -5, checkoutStarted: true });
  const theirs = minutesFromNow(10);
  seedSomeoneElse(inMemory, theirs, true);
  const lapsedAt = expiryOf(inMemory, RESERVATION_PATH);
  const { confirm } = loadPublicMoveIn(inMemory, { sessions: { cs_paid: paidSession() } });

  // Still confirmed: the renter goes on to completion, which refunds them if
  // the other renter still has the unit.
  const result = await confirm('cs_paid');

  assert.equal(result.paymentIntentId, 'pi_hold');
  assert.equal(inMemory.read(HOLD_PATH)?.reservationId, SOMEONE_ELSE.reservationId);
  assert.equal(expiryOf(inMemory, HOLD_PATH), theirs.toMillis());
  assert.equal(expiryOf(inMemory, RESERVATION_PATH), lapsedAt);
});

test('confirming a paid session takes the unit from a holder who has not gone to pay, whose checkout is then refused', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: -5, checkoutStarted: true });
  seedSomeoneElse(inMemory, minutesFromNow(10), false);
  const { confirm, checkout, stripeCalls } = loadPublicMoveIn(inMemory, { sessions: { cs_paid: paidSession() } });

  await confirm('cs_paid');

  // Before: the holder, who had paid nothing, kept the unit; this renter,
  // who had, was refunded at completion, or both paid and one was refunded.
  assert.equal(inMemory.read(HOLD_PATH)?.reservationId, RESERVATION);
  assert.ok(expiryOf(inMemory, HOLD_PATH) > Date.now() + 59 * MINUTE);
  assert.ok(expiryOf(inMemory, RESERVATION_PATH) > Date.now() + 59 * MINUTE);
  await assert.rejects(() => checkout(SOMEONE_ELSE), refusedWith(NOT_AVAILABLE));
  assert.deepEqual(methods(stripeCalls), ['checkout.sessions.retrieve']);
});

test('confirming an unpaid session holds nothing', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: 3, checkoutStarted: true });
  const heldUntil = expiryOf(inMemory, HOLD_PATH);
  const { confirm } = loadPublicMoveIn(inMemory, {
    sessions: { cs_open: { ...paidSession(), status: 'open', payment_status: 'unpaid' } },
  });

  await assert.rejects(() => confirm('cs_open'), refusedWith('Checkout is not paid (status: unpaid)'));

  assert.equal(expiryOf(inMemory, HOLD_PATH), heldUntil);
});

test('confirming a paid session of a completed reservation holds nothing', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: -5, checkoutStarted: true, reservation: { status: 'completed' } });
  inMemory.getStore().delete(HOLD_PATH);
  const { confirm } = loadPublicMoveIn(inMemory, { sessions: { cs_paid: paidSession() } });

  await confirm('cs_paid');

  assert.equal(inMemory.read(HOLD_PATH), undefined);
});

// Reopening the move-in link

test('a reservation that went to checkout still opens after its hold lapses', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: -30, reservedMinutesAgo: 120, checkoutStarted: true });
  const { open } = loadPublicMoveIn(inMemory);

  const result = (await open()) as { found?: boolean };

  assert.equal(result.found, true);
  assert.equal(inMemory.read(RESERVATION_PATH)?.status, 'pending');
});

test('a reservation that never went to checkout expires when its hold lapses', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: -1 });
  const { open } = loadPublicMoveIn(inMemory);

  const result = (await open()) as { found?: boolean };

  assert.equal(result.found, false);
  assert.equal(inMemory.read(RESERVATION_PATH)?.status, 'expired');
});

test('a day after its hold lapsed, a reservation that went to checkout expires', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: -25 * 60, reservedMinutesAgo: 27 * 60, checkoutStarted: true });
  const { open } = loadPublicMoveIn(inMemory);

  const result = (await open()) as { found?: boolean };

  assert.equal(result.found, false);
  assert.equal(inMemory.read(RESERVATION_PATH)?.status, 'expired');
});

// Finishing the move-in

test('a renter who paid finishes the move-in after their hold lapsed', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: -20, reservedMinutesAgo: 120, checkoutStarted: true });
  const { complete, stripeCalls } = loadPublicMoveIn(inMemory, { paymentMetadata: { reservationId: RESERVATION } });

  const result = await complete();

  assert.equal(result.success, true);
  assert.deepEqual(methods(stripeCalls), ['paymentIntents.retrieve']);
  assert.equal(inMemory.read(UNIT_PATH)?.status, 'occupied');
  assert.equal(inMemory.read(UNIT_PATH)?.tenantId, result.tenantId);
  // Its hold went with the move-in.
  assert.equal(inMemory.read(HOLD_PATH), undefined);
});

test('a move-in leaves alone a hold another renter has on the unit', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: 20, checkoutStarted: true });
  const theirs = minutesFromNow(10);
  seedHold(inMemory, 'res-someone-else', theirs);
  const { complete } = loadPublicMoveIn(inMemory, { paymentMetadata: TAGGED });

  assert.equal((await complete()).success, true);

  // Before: whatever hold was on the unit was deleted after the commit.
  assert.equal(inMemory.read(HOLD_PATH)?.reservationId, 'res-someone-else');
  assert.equal(expiryOf(inMemory, HOLD_PATH), theirs.toMillis());
});

test('a payment made for another reservation does not finish a move-in whose hold lapsed', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: -20, reservedMinutesAgo: 120, checkoutStarted: true });
  const { complete } = loadPublicMoveIn(inMemory, { paymentMetadata: { reservationId: 'res-other' } });

  // Refused for any move-in, lapsed or not, by the one-payment-one-move-in check.
  await assert.rejects(() => complete(), refusedWith(OTHER_RESERVATION));

  assertNoMoveIn(inMemory);
});

test('a paid renter whose hold lapsed cannot take a unit held by someone paying for it, and is refunded', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: -20, reservedMinutesAgo: 120, checkoutStarted: true });
  seedSomeoneElse(inMemory, minutesFromNow(10), true);
  const { complete, stripeCalls } = loadPublicMoveIn(inMemory, { paymentMetadata: TAGGED });

  await assert.rejects(() => complete(), (err: any) => {
    assert.equal(err.code, 'failed-precondition');
    // Before: told the unit had been rented or taken out of service.
    assert.match(err.message, /^Your hold on this unit ran out, and another renter is now paying for it/);
    return true;
  });

  assertNoMoveIn(inMemory);
  assert.deepEqual(methods(stripeCalls), ['paymentIntents.retrieve', 'refunds.create']);
  assert.equal(inMemory.read(HOLD_PATH)?.reservationId, SOMEONE_ELSE.reservationId);
  const use = inMemory.read('publicMoveInPayments/pi_hold') as Record<string, any>;
  assert.equal(use.refund.refusal, 'unit-held');
  const alert = inMemory.read(`facilities/${FACILITY}/Notifications/move-in-refund-pi_hold`) as Record<string, any>;
  assert.match(alert.message, /because their hold on the unit ran out and another renter was paying for it\./);
});

test('a paid renter whose hold lapsed moves in over a holder who has not gone to pay, whose checkout is then refused', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: -20, reservedMinutesAgo: 120, checkoutStarted: true });
  seedSomeoneElse(inMemory, minutesFromNow(10), false);
  const { complete, checkout, stripeCalls } = loadPublicMoveIn(inMemory, { paymentMetadata: TAGGED });

  // Before: refunded for a holder who had paid nothing, and the unit sat
  // empty when they walked away.
  const result = await complete();

  assert.equal(result.success, true);
  assert.equal(inMemory.read(UNIT_PATH)?.tenantId, result.tenantId);
  await assert.rejects(() => checkout(SOMEONE_ELSE), refusedWith(NOT_AVAILABLE));
  assert.deepEqual(methods(stripeCalls), ['paymentIntents.retrieve']);
});

test('a paid renter whose hold lapsed moves in over the live hold of a reservation since cancelled', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: -20, reservedMinutesAgo: 120, checkoutStarted: true });
  // They went to pay, then gave up; their hold was left behind.
  seedSomeoneElse(inMemory, minutesFromNow(10), true);
  const theirs = `publicReservations/${SOMEONE_ELSE.reservationId}`;
  inMemory.seed(theirs, { ...inMemory.read(theirs), status: 'cancelled' });
  const { complete } = loadPublicMoveIn(inMemory, { paymentMetadata: TAGGED });

  const result = await complete();

  assert.equal(result.success, true);
  assert.equal(inMemory.read(UNIT_PATH)?.tenantId, result.tenantId);
});

for (const [why, hold] of [
  ['has run out', { expiresAt: minutesFromNow(-5) }],
  ['has no expiry', {}],
] as Array<[string, Record<string, unknown>]>) {
  test(`a paid renter whose hold lapsed moves in when another renter's hold on the unit ${why}`, async () => {
    const inMemory = new InMemoryFirestore();
    seed(inMemory, { expiresInMinutes: -20, reservedMinutesAgo: 120, checkoutStarted: true });
    // They went to pay, but their hold keeps the unit from no one.
    seedSomeoneElse(inMemory, minutesFromNow(-5), true);
    inMemory.seed(HOLD_PATH, { facilityId: FACILITY, unitId: UNIT, reservationId: SOMEONE_ELSE.reservationId, ...hold });
    const { complete, stripeCalls } = loadPublicMoveIn(inMemory, { paymentMetadata: TAGGED });

    const result = await complete();

    assert.equal(result.success, true);
    assert.equal(inMemory.read(UNIT_PATH)?.tenantId, result.tenantId);
    assert.deepEqual(methods(stripeCalls), ['paymentIntents.retrieve']);
    // It goes with the move-in, as this renter's own would.
    assert.equal(inMemory.read(HOLD_PATH), undefined);
  });
}

test('a move-in whose hold lapsed is refused without a payment, and left open for one', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: -20, reservedMinutesAgo: 120, checkoutStarted: true });
  const { complete, stripeCalls } = loadPublicMoveIn(inMemory, { paymentMetadata: TAGGED });

  await assert.rejects(
    () => complete({ paymentIntentId: undefined, skipPayment: true }),
    refusedWith(EXPIRED),
  );

  assertNoMoveIn(inMemory);
  assert.deepEqual(stripeCalls, []);
  assert.equal(inMemory.read(RESERVATION_PATH)?.status, 'pending');
});

// Priced once

for (const [why, finishAfterMinutes] of [
  ['twenty minutes later, just after midnight', 20],
  ['the next evening, after the hold lapsed', 23 * 60],
] as Array<[string, number]>) {
  test(`a renter with no move-in date who paid before midnight finishes ${why}, at the price they paid`, async (t) => {
    // Proration changes at midnight, server time (UTC in production): 23:50
    // on 24 September prices 7 days of September, 00:10 on the 25th prices 6.
    const beforeMidnight = new Date(2026, 8, 24, 23, 50).getTime();
    mock.timers.enable({ apis: ['Date'], now: beforeMidnight });
    t.after(() => mock.timers.reset());
    const inMemory = new InMemoryFirestore();
    seed(inMemory, { expiresInMinutes: 10, reservation: { moveInDate: null } });
    const { checkout, complete, stripeCalls } = loadPublicMoveIn(inMemory, { paymentMetadata: TAGGED });

    await checkout();
    const paidCents = stripeCalls[0].params?.line_items[0].price_data.unit_amount;
    mock.timers.setTime(beforeMidnight + finishAfterMinutes * MINUTE);
    assert.notEqual(quoteCents(inMemory, new Date()), paidCents, 'the test must cross a change in the price');

    const result = await complete();

    // Before: priced again for the 25th, refused as 'charges changed' and refunded.
    assert.equal(result.success, true);
    assert.deepEqual(methods(stripeCalls), ['checkout.sessions.create', 'paymentIntents.retrieve']);
    const ledgers = inMemory
      .listCollection(`facilities/${FACILITY}/ledgers`)
      .map((path) => inMemory.read(path) as Record<string, any>);
    const charged = ledgers.filter((l) => l.type !== 'payment').reduce((sum, l) => sum + Math.round(l.amount * 100), 0);
    assert.equal(charged, paidCents);
    // Dated the day that was priced.
    assert.equal((inMemory.read(UNIT_PATH)?.moveInDate as Date).getDate(), 24);
  });
}

// A renter who gave no move-in date

test('checkout records the date it priced a move-in with no move-in date from', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: 10 });
  inMemory.seed(RESERVATION_PATH, { ...inMemory.read(RESERVATION_PATH), moveInDate: null });
  const { checkout } = loadPublicMoveIn(inMemory);
  const before = Date.now();

  await checkout();

  const reservation = inMemory.read(RESERVATION_PATH) as Record<string, unknown>;
  const priced = millisOf(reservation.checkoutMoveInDate);
  assert.ok(priced >= before && priced <= Date.now());
  assert.equal(reservation.expectedCheckoutAmountCents, quoteCents(inMemory, new Date(priced)));
});

test('a renter with no move-in date who paid finishes after the day changed', async () => {
  // Completion priced the move-in from today again, so a renter who paid at
  // 23:50 UTC and finished at 00:10 was refused as "charges changed".
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: 30, reservedMinutesAgo: 60, checkoutStarted: true });
  const today = quoteCents(inMemory, new Date());
  const pricedOn = [2, 3, 5, 10]
    .map((days) => new Date(Date.now() - days * 24 * 60 * MINUTE))
    .find((date) => quoteCents(inMemory, date) !== today);
  assert.ok(pricedOn, 'no earlier date prices differently from today');
  inMemory.seed(RESERVATION_PATH, {
    ...inMemory.read(RESERVATION_PATH),
    moveInDate: null,
    checkoutMoveInDate: Timestamp.fromDate(pricedOn),
    expectedCheckoutAmountCents: quoteCents(inMemory, pricedOn),
  });
  const { complete } = loadPublicMoveIn(inMemory, { paymentMetadata: TAGGED });

  const result = await complete();

  assert.equal(result.success, true);
  assert.equal(inMemory.read(UNIT_PATH)?.status, 'occupied');
  assert.equal(millisOf(inMemory.read(UNIT_PATH)?.moveInDate), pricedOn.getTime());
});

// Two paid renters, one unit

test('of two paid renters finishing on one unit at once, one moves in and the other is refused', async () => {
  // Both holds lapsed after checkout, so both pass the checks made before
  // the transaction; the unit was set occupied without being read again.
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: -40, reservedMinutesAgo: 120, checkoutStarted: true });
  const other = 'res-hold-other';
  const otherToken = 'hold-move-in-token-other-0123456789';
  inMemory.seed(`publicReservations/${other}`, {
    ...inMemory.read(RESERVATION_PATH),
    moveInToken: otherToken,
    name: 'Olly Other',
    email: 'other@example.com',
    expiresAt: minutesFromNow(-20),
  });
  seedHold(inMemory, other, minutesFromNow(-20));
  const { complete, stripeCalls } = loadPublicMoveIn(inMemory, {
    paymentMetadata: (id) => ({ type: 'public_move_in', reservationId: id === 'pi_other' ? other : RESERVATION }),
  });

  const results = await Promise.allSettled([
    complete({ paymentIntentId: 'pi_first' }),
    complete({
      reservationId: other,
      token: otherToken,
      name: 'Olly Other',
      email: 'other@example.com',
      paymentIntentId: 'pi_other',
    }),
  ]);

  const refused = results.filter((r): r is PromiseRejectedResult => r.status === 'rejected');
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  assert.equal(refused.length, 1);
  // Refused after paying, so refunded, not just turned away.
  assert.match(String((refused[0].reason as { message?: string }).message),
    /^This unit was rented or taken out of service while you were paying/);
  const refunds = stripeCalls.filter((c) => c.method === 'refunds.create');
  assert.equal(refunds.length, 1);
  assert.equal(inMemory.listCollection(`facilities/${FACILITY}/tenants`).length, 1);
  const tenantId = inMemory.read(UNIT_PATH)?.tenantId;
  const movedIn = inMemory.read(`facilities/${FACILITY}/tenants/${tenantId}`) as Record<string, unknown>;
  // The refund is the other renter's payment, never the one that moved in.
  const refundedPayment = refunds[0].params?.payment_intent;
  assert.equal(refundedPayment, movedIn.name === 'Olly Other' ? 'pi_first' : 'pi_other');
});

test.after(() => {
  testEnv.cleanup();
});

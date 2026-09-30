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
import { computePublicMoveInCharges, MOVE_IN_NOT_PRICED_MESSAGE } from '../moveInCharges';
import {
  CHECKOUT_RUN_OUT_MESSAGE,
  CHECKOUT_SESSION_MINUTES,
  FINISH_AFTER_PAYMENT_MINUTES,
} from '../checkoutHold';
import { InMemoryFirestore, installInMemoryFirestore } from './support/inMemoryFirestore';

const testEnv = firebaseFunctionsTest({ projectId: 'in-memory-test' });
const callableContext = { app: { appId: 'test-app-check' } };

const FACILITY = 'fac-hold';
const UNIT = 'unit-hold';
const RESERVATION = 'res-hold';
const TOKEN = 'hold-move-in-token-0123456789';
const UNIT_PATH = `facilities/${FACILITY}/units/${UNIT}`;
const HOLD_PATH = `facilities/${FACILITY}/mapEngine/activeHolds/items/${UNIT}`;
const RESERVATION_PATH = `publicReservations/${RESERVATION}`;
const MINUTE = 60 * 1000;
const EXPIRED = 'Reservation has expired';
const NOT_AVAILABLE = 'Unit is not currently available';
const OTHER_RESERVATION = 'This payment was made for a different reservation. Contact the facility.';

/** Stripe Connect is set up, so the move-in is paid through Checkout. */
const FACILITY_DATA = {
  name: 'Hold Storage',
  stripeConnectAccountId: 'acct_hold',
  stripeConnectOnboardingComplete: true,
};

const UNIT_DATA = { status: 'available', unitNumber: 'H1', unitType: 'standard', monthlyRate: 100 };

type StripeCall = { method: string; params?: Record<string, any> };

/**
 * Loads publicMoveIn against [inMemory], with Stripe replaced by a recorder.
 * [paymentMetadata] is the metadata on the PaymentIntent the renter paid with,
 * or a function giving it for each PaymentIntent id.
 */
function loadPublicMoveIn(
  inMemory: InMemoryFirestore,
  paymentMetadata: Record<string, string> | ((paymentIntentId: string) => Record<string, string>) = {},
) {
  installInMemoryFirestore(inMemory);
  const stripeCalls: StripeCall[] = [];
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const shared = require('@sfc/functions-shared') as typeof import('@sfc/functions-shared');
  Object.defineProperty(shared, 'getStripeClient', {
    configurable: true,
    writable: true,
    value: () =>
      ({
        checkout: {
          sessions: {
            create: async (params: Record<string, any>) => {
              stripeCalls.push({ method: 'checkout.sessions.create', params });
              return { id: 'cs_test', url: 'https://checkout.example/cs_test' };
            },
          },
        },
        paymentIntents: {
          retrieve: async (paymentIntentId: string) => {
            stripeCalls.push({ method: 'paymentIntents.retrieve' });
            return {
              id: paymentIntentId,
              amount_received: quoteCents(inMemory),
              status: 'succeeded',
              metadata: typeof paymentMetadata === 'function' ? paymentMetadata(paymentIntentId) : paymentMetadata,
            };
          },
        },
      }) as unknown as ReturnType<typeof shared.getStripeClient>,
  });
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const moveIn = require('../publicMoveIn') as typeof import('../publicMoveIn');
  return {
    stripeCalls,
    open: () => testEnv.wrap(moveIn.getPublicReservationByToken)({ token: TOKEN }, callableContext),
    checkout: () =>
      testEnv.wrap(moveIn.createPublicMoveInCheckout)(
        { reservationId: RESERVATION, token: TOKEN, amount: quoteCents(inMemory) / 100 },
        callableContext,
      ),
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
      ),
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
  opts: { expiresInMinutes: number; reservedMinutesAgo?: number; checkoutStarted?: boolean },
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
  });
  seedHold(inMemory, RESERVATION, expiresAt);
}

function seedHold(inMemory: InMemoryFirestore, reservationId: string, expiresAt: Timestamp) {
  inMemory.seed(HOLD_PATH, { facilityId: FACILITY, unitId: UNIT, reservationId, status: 'pending', expiresAt });
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

function millisOf(value: unknown): number {
  return value instanceof Date ? value.getTime() : (value as Timestamp).toMillis();
}

function expiryOf(inMemory: InMemoryFirestore, path: string): number {
  return (inMemory.read(path)?.expiresAt as Timestamp).toMillis();
}

function refusedWith(message: string) {
  return (err: unknown): boolean => {
    const e = err as { code?: string; message?: string };
    assert.equal(e.code, 'failed-precondition');
    assert.equal(e.message, message);
    return true;
  };
}

function assertNoMoveIn(inMemory: InMemoryFirestore) {
  assert.equal(inMemory.listCollection(`facilities/${FACILITY}/tenants`).length, 0);
  assert.equal(inMemory.read(UNIT_PATH)?.status, 'available');
}

// Checkout

test('checkout gives Stripe a short-lived page and holds the unit past it', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: 10 });
  const { checkout, stripeCalls } = loadPublicMoveIn(inMemory);
  const before = Date.now();

  await checkout();

  const params = stripeCalls[0]?.params as Record<string, any>;
  assert.equal(stripeCalls.length, 1);
  const sessionExpiresMs = params.expires_at * 1000;
  // Stripe accepts 30 minutes to 24 hours.
  assert.ok(sessionExpiresMs >= before + 30 * MINUTE + 60 * 1000);
  assert.ok(sessionExpiresMs <= before + (CHECKOUT_SESSION_MINUTES + 1) * MINUTE);
  // The payment says which reservation it is for, and does not carry the token.
  assert.deepEqual(params.payment_intent_data?.metadata, {
    type: 'public_move_in',
    reservationId: RESERVATION,
    facilityId: FACILITY,
  });
  // Both the reservation and the unit's hold outlast the page by the time to finish.
  for (const path of [RESERVATION_PATH, HOLD_PATH]) {
    const afterPage = expiryOf(inMemory, path) - sessionExpiresMs;
    assert.ok(afterPage >= FINISH_AFTER_PAYMENT_MINUTES * MINUTE, `${path} ends before the renter can finish`);
    assert.ok(afterPage < FINISH_AFTER_PAYMENT_MINUTES * MINUTE + 1000);
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

test('checkout can extend a portal-length hold that is nearly over', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: 1, reservedMinutesAgo: 59 });
  const { checkout, stripeCalls } = loadPublicMoveIn(inMemory);

  await checkout();

  assert.equal(stripeCalls.length, 1);
});

test('checkout will not keep a unit held past three hours, and Stripe is not called', async () => {
  const inMemory = new InMemoryFirestore();
  // Still held, by restarting checkout, two hours after the unit was chosen.
  seed(inMemory, { expiresInMinutes: 20, reservedMinutesAgo: 120, checkoutStarted: true });
  const heldUntil = expiryOf(inMemory, RESERVATION_PATH);
  const { checkout, stripeCalls } = loadPublicMoveIn(inMemory);

  await assert.rejects(checkout, refusedWith(CHECKOUT_RUN_OUT_MESSAGE));

  assert.deepEqual(stripeCalls, []);
  assert.equal(expiryOf(inMemory, RESERVATION_PATH), heldUntil);
  assert.equal(expiryOf(inMemory, HOLD_PATH), heldUntil);
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
  const { complete, stripeCalls } = loadPublicMoveIn(inMemory, { reservationId: RESERVATION });

  const result = (await complete()) as { success?: boolean; tenantId?: string };

  assert.equal(result.success, true);
  assert.deepEqual(stripeCalls.map((c) => c.method), ['paymentIntents.retrieve']);
  assert.equal(inMemory.read(UNIT_PATH)?.status, 'occupied');
  assert.equal(inMemory.read(UNIT_PATH)?.tenantId, result.tenantId);
});

for (const [why, metadata, refusal] of [
  // Refused for any move-in, lapsed or not, by the one-payment-one-move-in check.
  ['made for another reservation', { reservationId: 'res-other' }, OTHER_RESERVATION],
  // Accepted for a live hold, since payments taken before checkout tagged
  // them name no reservation, but not to finish after the hold lapsed.
  ['that names no reservation', {}, EXPIRED],
] as Array<[string, Record<string, string>, string]>) {
  test(`a payment ${why} does not finish a move-in whose hold lapsed`, async () => {
    const inMemory = new InMemoryFirestore();
    seed(inMemory, { expiresInMinutes: -20, reservedMinutesAgo: 120, checkoutStarted: true });
    const { complete } = loadPublicMoveIn(inMemory, metadata);

    await assert.rejects(() => complete(), refusedWith(refusal));

    assertNoMoveIn(inMemory);
  });
}

test('a paid renter whose hold lapsed cannot take a unit someone else now holds', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: -20, reservedMinutesAgo: 120, checkoutStarted: true });
  seedHold(inMemory, 'res-someone-else', minutesFromNow(10));
  const { complete, stripeCalls } = loadPublicMoveIn(inMemory, { reservationId: RESERVATION });

  await assert.rejects(() => complete(), refusedWith(NOT_AVAILABLE));

  assertNoMoveIn(inMemory);
  assert.deepEqual(stripeCalls, []);
  assert.equal(inMemory.read(HOLD_PATH)?.reservationId, 'res-someone-else');
});

test('a move-in whose hold lapsed is refused without a payment, and left open for one', async () => {
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: -20, reservedMinutesAgo: 120, checkoutStarted: true });
  const { complete, stripeCalls } = loadPublicMoveIn(inMemory, { reservationId: RESERVATION });

  await assert.rejects(
    () => complete({ paymentIntentId: undefined, skipPayment: true }),
    refusedWith(EXPIRED),
  );

  assertNoMoveIn(inMemory);
  assert.deepEqual(stripeCalls, []);
  assert.equal(inMemory.read(RESERVATION_PATH)?.status, 'pending');
});

// A renter who gave no move-in date

/**
 * Runs [fn] with the clock stopped at [iso]. A renter with no move-in date is
 * priced from the moment checkout runs, so these tests fix that moment rather
 * than pass or fail by the day they run: the first of them failed on the 30th
 * of the month, when the rent came to $0.
 */
async function atTime<T>(iso: string, fn: () => Promise<T>): Promise<T> {
  mock.timers.enable({ apis: ['Date'], now: new Date(iso) });
  try {
    return await fn();
  } finally {
    mock.timers.reset();
  }
}

/** Seeds a reservation for a renter who gave no move-in date. */
function seedWithNoMoveInDate(inMemory: InMemoryFirestore) {
  seed(inMemory, { expiresInMinutes: 10 });
  inMemory.seed(RESERVATION_PATH, { ...inMemory.read(RESERVATION_PATH), moveInDate: null });
}

function ledgerEntries(inMemory: InMemoryFirestore): Record<string, unknown>[] {
  return inMemory
    .listCollection(`facilities/${FACILITY}/ledgers`)
    .map((docPath) => inMemory.read(docPath) as Record<string, unknown>);
}

test('checkout records the date it priced a move-in with no move-in date from', async () => {
  await atTime('2026-09-15T20:00:00Z', async () => {
    const inMemory = new InMemoryFirestore();
    seedWithNoMoveInDate(inMemory);
    const { checkout } = loadPublicMoveIn(inMemory);

    await checkout();

    const reservation = inMemory.read(RESERVATION_PATH) as Record<string, unknown>;
    const priced = millisOf(reservation.checkoutMoveInDate);
    assert.equal(priced, Date.parse('2026-09-15T20:00:00Z'));
    assert.equal(reservation.expectedCheckoutAmountCents, quoteCents(inMemory, new Date(priced)));
    // The 15th through the 30th: 16 of 30 days of $100. Measured from 20:00
    // to midnight at the start of the 30th, this was 15 days.
    assert.equal(reservation.expectedCheckoutAmountCents, 5333);
  });
});

test('checkout on the last day of a month at 20:00 charges a day, not $0', async () => {
  // Priced at 0 days, the total came to $0 and checkout refused it, so a
  // renter with no move-in date could not pay online on the 30th or 31st.
  await atTime('2026-09-30T20:00:00Z', async () => {
    const inMemory = new InMemoryFirestore();
    seedWithNoMoveInDate(inMemory);
    const { checkout, stripeCalls } = loadPublicMoveIn(inMemory);

    await checkout();

    const reservation = inMemory.read(RESERVATION_PATH) as Record<string, unknown>;
    assert.equal(reservation.expectedCheckoutAmountCents, 333);
    const session = stripeCalls.find((c) => c.method === 'checkout.sessions.create');
    assert.equal(session?.params?.line_items?.[0]?.price_data?.unit_amount, 333);
  });
});

test('a renter who paid on the last day and finished after midnight is billed the day checkout priced', async () => {
  await atTime('2026-09-30T23:55:00Z', async () => {
    const inMemory = new InMemoryFirestore();
    seedWithNoMoveInDate(inMemory);
    const { checkout, complete } = loadPublicMoveIn(inMemory, { reservationId: RESERVATION });
    await checkout();
    assert.equal(inMemory.read(RESERVATION_PATH)?.expectedCheckoutAmountCents, 333);

    mock.timers.tick(10 * MINUTE); // 00:05 on 1 Oct: today would price all of October.
    const result = (await complete()) as { success?: boolean };

    assert.equal(result.success, true);
    const rent = ledgerEntries(inMemory).filter((e) => e.type === 'proratedRent');
    assert.deepEqual(rent.map((e) => e.amount), [3.33]);
    assert.equal(millisOf(inMemory.read(UNIT_PATH)?.moveInDate), Date.parse('2026-09-30T23:55:00Z'));
  });
});

// Nothing to pay

test('a renter moving in on the last day of a month cannot skip paying', async () => {
  // The last day priced at $0, so with no fees completion took the
  // nothing-to-pay path and moved in a caller who never went to checkout.
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: 10 });
  inMemory.seed(RESERVATION_PATH, {
    ...inMemory.read(RESERVATION_PATH),
    moveInDate: Timestamp.fromDate(new Date('2026-09-30T20:00:00Z')),
  });
  const { complete } = loadPublicMoveIn(inMemory);

  await assert.rejects(
    () => complete({ skipPayment: true, paymentIntentId: undefined }),
    refusedWith('Payment is required to complete this move-in.'),
  );
  assertNoMoveIn(inMemory);
});

test('a unit with rent priced at nothing is not handed over unpaid', async () => {
  // Too little rent to come to a cent for the one day left in the month.
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: 10 });
  inMemory.seed(UNIT_PATH, { ...UNIT_DATA, monthlyRate: 0.1 });
  inMemory.seed(RESERVATION_PATH, {
    ...inMemory.read(RESERVATION_PATH),
    moveInDate: Timestamp.fromDate(new Date('2026-09-30T12:00:00Z')),
  });
  const { complete } = loadPublicMoveIn(inMemory);

  await assert.rejects(
    () => complete({ skipPayment: true, paymentIntentId: undefined }),
    refusedWith(MOVE_IN_NOT_PRICED_MESSAGE),
  );
  assertNoMoveIn(inMemory);
});

test('a facility that takes no payment online still moves a renter in without paying', async () => {
  // The charges go on the renter's ledger, to be paid to the facility.
  const inMemory = new InMemoryFirestore();
  seed(inMemory, { expiresInMinutes: 10 });
  inMemory.seed(`facilities/${FACILITY}`, { name: 'Hold Storage' });
  inMemory.seed(RESERVATION_PATH, {
    ...inMemory.read(RESERVATION_PATH),
    moveInDate: Timestamp.fromDate(new Date('2026-09-30T20:00:00Z')),
  });
  const { complete } = loadPublicMoveIn(inMemory);

  const result = (await complete({ skipPayment: true, paymentIntentId: undefined })) as { success?: boolean };

  assert.equal(result.success, true);
  const rent = ledgerEntries(inMemory).filter((e) => e.type === 'proratedRent');
  assert.deepEqual(rent.map((e) => e.amount), [3.33]);
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
  const { complete } = loadPublicMoveIn(inMemory, { reservationId: RESERVATION });

  const result = (await complete()) as { success?: boolean };

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
  const { complete } = loadPublicMoveIn(inMemory, (id) => ({
    reservationId: id === 'pi_other' ? other : RESERVATION,
  }));

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
  assert.equal((refused[0].reason as { message?: string }).message, 'Unit is no longer available');
  assert.equal(inMemory.listCollection(`facilities/${FACILITY}/tenants`).length, 1);
});

test.after(() => {
  testEnv.cleanup();
});

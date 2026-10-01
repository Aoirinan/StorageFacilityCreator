/**
 * A renter who pays for an online move-in and never finishes it.
 *
 * Nothing server-side reacted to a paid Checkout Session: confirmation and
 * completion ran only when the renter came back. A renter who paid at minute
 * 34 of their checkout and closed the tab lost the unit when checkout's hold
 * lapsed at minute 45, their money stayed with the owner, and the owner was
 * told nothing; a later renter could then hold and pay for the unit, and the
 * first payer, if they came back, was refunded as 'unit-held'.
 *
 * Now the Connect webhook (functions-integrations, running the shared
 * recordPaidPublicMoveInCheckout exercised here) records the payment and
 * holds the unit for the payer until 24 hours after payment, and the
 * 15-minute sweep tells the owner, then refunds the payment once it can no
 * longer be used or the day is up. Completion and the sweep decide in
 * transactions on the payment's use record, so a payment moves someone in or
 * is refunded, never both. Also here: checkout reads the unit in its
 * transaction, refund outcomes are never downgraded, a pending refund is
 * looked at again, a failed one is retried a bounded number of times,
 * confirming a paid session holds the unit no longer than a day after
 * payment, and a refund is resumed on the account that took the payment.
 * All data is invented.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { Timestamp } from 'firebase-admin/firestore';
import * as admin from 'firebase-admin';
import firebaseFunctionsTest from 'firebase-functions-test';
import { computePublicMoveInCharges } from '../moveInCharges';
import { InMemoryFirestore, installInMemoryFirestore } from './support/inMemoryFirestore';

const testEnv = firebaseFunctionsTest({ projectId: 'in-memory-test' });
const callableContext = { app: { appId: 'test-app-check' } };

const FACILITY = 'fac-unfinished';
const UNIT = 'unit-unfinished';
const RESERVATION = 'res-unfinished';
const TOKEN = 'unfinished-move-in-token-0123456789';
const ACCOUNT = 'acct_unfinished';
const PI = 'pi_unfinished';
const SESSION = 'cs_unfinished';
const UNIT_PATH = `facilities/${FACILITY}/units/${UNIT}`;
const RESERVATION_PATH = `publicReservations/${RESERVATION}`;
const HOLD_PATH = `facilities/${FACILITY}/mapEngine/activeHolds/items/${UNIT}`;
const USE_PATH = `publicMoveInPayments/${PI}`;
const PAID_PATH = `publicMoveInPaidCheckouts/${PI}`;
const REFUND_ALERT_PATH = `facilities/${FACILITY}/Notifications/move-in-refund-${PI}`;
const UNFINISHED_ALERT_PATH = `facilities/${FACILITY}/Notifications/move-in-unfinished-${PI}`;
const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const NOT_AVAILABLE = 'Unit is not currently available';
const SIGNATURE =
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

const FACILITY_DATA = {
  name: 'Unfinished Storage',
  stripeConnectAccountId: ACCOUNT,
  stripeConnectOnboardingComplete: true,
};
const PUBLIC_SETTINGS = { publicRentalsEnabled: true };
const UNIT_DATA = { status: 'available', unitNumber: 'U1', unitType: 'standard', monthlyRate: 100 };
const TAGGED = { type: 'public_move_in', reservationId: RESERVATION };

type FakeSession = {
  status: 'open' | 'complete' | 'expired';
  payment_status: 'paid' | 'unpaid';
  payment_intent?: string;
  created?: number;
  amount_total?: number;
  metadata?: Record<string, string>;
};

type RefundObject = { id: string; status: string; failure_reason?: string };

type Stub = {
  sessions: Record<string, FakeSession>;
  /** On the PaymentIntent, as Stripe holds it. */
  intentMetadata?: Record<string, string>;
  /** The PaymentIntent's creation (seconds), as an expanded session shows it; default the session's. */
  intentCreatedSeconds?: number;
  /** refunds.create answers this (an Error is thrown). Default: made. */
  refundAnswer?: (attempt: number) => RefundObject | Error;
  /** Runs inside refunds.create, before it answers. */
  onRefund?: () => void;
  /** refunds.retrieve answers this. */
  refundLookup?: () => RefundObject;
};

type Calls = {
  refunds: Array<{ params: Record<string, any>; options: Record<string, any> }>;
  refundLookups: Array<{ id: string; options: Record<string, any> }>;
  sessionRetrieves: string[];
  sessionCreates: number;
};

function quoteCents(inMemory: InMemoryFirestore): number {
  const reservation = inMemory.read(RESERVATION_PATH) as Record<string, any>;
  return computePublicMoveInCharges({
    reservation,
    unitData: inMemory.read(UNIT_PATH),
    facilityData: inMemory.read(`facilities/${FACILITY}`),
    publicSettings: PUBLIC_SETTINGS,
    moveInDate: (reservation.moveInDate as Timestamp).toDate(),
  }).totalCents;
}

/**
 * A facility taking card payments online, and a reservation whose checkout
 * started [startedMinutesAgo]: its 35-minute Checkout Session recorded, and
 * its hold ending 10 minutes after that page closes, as checkout leaves it.
 */
function seedCheckout(inMemory: InMemoryFirestore, startedMinutesAgo = 34, reservation: Record<string, unknown> = {}) {
  const started = Date.now() - startedMinutesAgo * MINUTE;
  const holdUntil = Timestamp.fromMillis(started + 45 * MINUTE);
  inMemory.seed(`facilities/${FACILITY}`, FACILITY_DATA);
  inMemory.seed(`facilities/${FACILITY}/settings/public`, PUBLIC_SETTINGS);
  inMemory.seed(UNIT_PATH, UNIT_DATA);
  inMemory.seed(RESERVATION_PATH, {
    facilityId: FACILITY,
    unitId: UNIT,
    unitNumber: 'U1',
    status: 'pending',
    moveInToken: TOKEN,
    moveInDate: Timestamp.fromDate(new Date(2026, 8, 25)),
    reservedAt: Timestamp.fromMillis(started - 5 * MINUTE),
    expiresAt: holdUntil,
    email: 'rita@example.com',
    name: 'Rita Renter',
    metadata: {},
    checkoutUpdatedAt: Timestamp.fromMillis(started),
    checkoutSessionId: SESSION,
    checkoutSessionAccountId: ACCOUNT,
    checkoutSessionExpiresAt: Timestamp.fromMillis(started + 35 * MINUTE),
    ...reservation,
  });
  inMemory.seed(RESERVATION_PATH, {
    ...inMemory.read(RESERVATION_PATH),
    expectedCheckoutAmountCents: quoteCents(inMemory),
  });
  inMemory.seed(HOLD_PATH, { facilityId: FACILITY, unitId: UNIT, reservationId: RESERVATION, status: 'pending', expiresAt: holdUntil });
}

function paidSession(inMemory: InMemoryFirestore, createdMinutesAgo = 34): FakeSession {
  return {
    status: 'complete',
    payment_status: 'paid',
    payment_intent: PI,
    created: Math.floor((Date.now() - createdMinutesAgo * MINUTE) / 1000),
    amount_total: quoteCents(inMemory),
    metadata: { type: 'public_move_in', reservationId: RESERVATION, moveInToken: TOKEN, facilityId: FACILITY },
  };
}

function load(inMemory: InMemoryFirestore, stub: Stub) {
  installInMemoryFirestore(inMemory);
  const calls: Calls = { refunds: [], refundLookups: [], sessionRetrieves: [], sessionCreates: 0 };
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const shared = require('@sfc/functions-shared') as typeof import('@sfc/functions-shared');
  Object.defineProperty(shared, 'getStripeClient', {
    configurable: true,
    writable: true,
    value: () =>
      ({
        checkout: {
          sessions: {
            create: async () => {
              calls.sessionCreates += 1;
              return { id: `cs_created_${calls.sessionCreates}`, url: 'https://checkout.example/new' };
            },
            retrieve: async (id: string, params: { expand?: string[] } | undefined, options: Record<string, any>) => {
              calls.sessionRetrieves.push(id);
              assert.equal(options?.stripeAccount, ACCOUNT);
              const session = stub.sessions[id];
              if (!session) throw Object.assign(new Error('No such checkout.session'), { code: 'resource_missing' });
              // Expanded as confirmation asks: the PaymentIntent object, with its creation.
              const expanded = params?.expand?.includes('payment_intent') && session.payment_intent
                ? { payment_intent: { id: session.payment_intent, created: stub.intentCreatedSeconds ?? session.created } }
                : {};
              return { id, currency: 'usd', ...session, ...expanded };
            },
            list: async () => ({ data: [] }),
            expire: async () => ({}),
          },
        },
        paymentIntents: {
          retrieve: async (id: string) => ({
            id,
            status: 'succeeded',
            amount_received: quoteCents(inMemory),
            metadata: stub.intentMetadata ?? TAGGED,
          }),
        },
        refunds: {
          create: async (params: Record<string, any>, options: Record<string, any>) => {
            calls.refunds.push({ params, options });
            stub.onRefund?.();
            const answer = stub.refundAnswer?.(calls.refunds.length) ?? { id: `re_${calls.refunds.length}`, status: 'succeeded' };
            if (answer instanceof Error) throw answer;
            return answer;
          },
          retrieve: async (id: string, _params: unknown, options: Record<string, any>) => {
            calls.refundLookups.push({ id, options });
            return stub.refundLookup ? stub.refundLookup() : { id, status: 'succeeded' };
          },
        },
      }) as unknown as ReturnType<typeof shared.getStripeClient>,
  });
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const moveIn = require('../publicMoveIn') as typeof import('../publicMoveIn');
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const sweeps = require('../unfinishedPaidMoveInSweep') as typeof import('../unfinishedPaidMoveInSweep');
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const refunds = require('../paidMoveInRefund') as typeof import('../paidMoveInRefund');
  return {
    calls,
    shared,
    /** checkout.session.completed from the Connect destination, as functions-integrations records it. */
    webhook: (paidAt = new Date(Date.now() - MINUTE)) =>
      shared.recordPaidPublicMoveInCheckout(admin.firestore(), {
        paymentIntentId: PI,
        checkoutSessionId: SESSION,
        reservationId: RESERVATION,
        facilityId: FACILITY,
        connectAccountId: ACCOUNT,
        amountCents: quoteCents(inMemory),
        paidAt,
        now: new Date(),
        holdMinutes: 'until-cap',
        recordedBy: 'stripeWebhook',
      }),
    confirm: () =>
      testEnv.wrap(moveIn.confirmPublicMoveInCheckout)(
        { reservationId: RESERVATION, token: TOKEN },
        callableContext,
      ) as Promise<{ paid?: boolean; paymentIntentId?: string }>,
    complete: () =>
      testEnv.wrap(moveIn.completePublicMoveIn)(
        {
          reservationId: RESERVATION,
          token: TOKEN,
          name: 'Rita Renter',
          email: 'rita@example.com',
          phone: '5551234567',
          signaturePngBase64: SIGNATURE,
          paymentIntentId: PI,
        },
        callableContext,
      ) as Promise<{ success?: boolean; tenantId?: string }>,
    checkout: () =>
      testEnv.wrap(moveIn.createPublicMoveInCheckout)(
        { reservationId: RESERVATION, token: TOKEN, amount: quoteCents(inMemory) / 100 },
        callableContext,
      ) as Promise<{ checkoutUrl?: string }>,
    /** Another renter holding the unit from the public map. */
    holdAsSomeoneElse: () =>
      testEnv.wrap(moveIn.createPublicReservationHold)(
        { facilityId: FACILITY, unitId: UNIT, email: 'olly@example.com', name: 'Olly Other' },
        callableContext,
      ),
    settle: (minutesFromNow: number) => sweeps.settleUnfinishedPaidMoveIns(new Date(Date.now() + minutesFromNow * MINUTE)),
    findUnreported: () => sweeps.findPaidSessionsNobodyReported(new Date()),
    refundSweep: (minutesFromNow: number) => refunds.sweepStalledMoveInRefunds(new Date(Date.now() + minutesFromNow * MINUTE)),
    refunds,
  };
}

function millisOf(value: unknown): number {
  return (value as Timestamp).toMillis();
}

function tenants(inMemory: InMemoryFirestore): string[] {
  return inMemory.listCollection(`facilities/${FACILITY}/tenants`);
}

function unfinishedAlerts(inMemory: InMemoryFirestore): string[] {
  return inMemory.listCollection(`facilities/${FACILITY}/Notifications`).filter((p) => p.includes('move-in-unfinished-'));
}

function assertFirstRefundCall(call: Calls['refunds'][number]) {
  assert.equal(call.params.payment_intent, PI);
  assert.equal(call.params.amount, undefined);
  assert.equal(call.options.stripeAccount, ACCOUNT);
  assert.equal(call.options.idempotencyKey, `public_move_in_refund_${PI}`);
}

// Finding 1: a paid session nobody comes back for

test('a renter who pays and closes the tab keeps the unit past checkout\'s hold, the owner is told once, and a day on they are refunded exactly once', async () => {
  const inMemory = new InMemoryFirestore();
  // Paid at minute 34 of the checkout: checkout's hold ends at minute 45.
  seedCheckout(inMemory, 34);
  const { webhook, holdAsSomeoneElse, settle, refundSweep, complete, calls } = load(inMemory, {
    sessions: { [SESSION]: paidSession(inMemory) },
  });
  const paidAt = new Date(Date.now() - MINUTE);

  assert.equal(await webhook(paidAt), 'held');

  // Before: the hold lapsed 11 minutes later, and the unit went back on the map.
  for (const path of [HOLD_PATH, RESERVATION_PATH]) {
    assert.equal(millisOf(inMemory.read(path)?.expiresAt), paidAt.getTime() + 24 * HOUR, path);
  }
  await assert.rejects(() => holdAsSomeoneElse(), (err: any) => {
    assert.equal(err.code, 'already-exists');
    return true;
  });

  // Half an hour after paying: the owner is told, once, and nothing is refunded.
  assert.deepEqual(await settle(31), { refunded: 0, alerted: 1, closed: 0, skipped: 0 });
  assert.deepEqual(await settle(46), { refunded: 0, alerted: 0, closed: 0, skipped: 0 });
  assert.deepEqual(unfinishedAlerts(inMemory), [UNFINISHED_ALERT_PATH]);
  const alert = inMemory.read(UNFINISHED_ALERT_PATH) as Record<string, any>;
  assert.equal(alert.type, 'ONLINE_MOVE_IN_REVIEW');
  assert.equal(alert.readAt, null);
  assert.match(alert.message, /^Rita Renter paid \$\d+\.\d\d online for unit U1 but has not finished moving in\./);
  assert.match(alert.message, /The unit is held for them until 24 hours after their payment\./);
  assert.match(alert.message, /the payment is refunded to them automatically/);
  assert.deepEqual(calls.refunds, []);

  // A day after paying: refunded once, the reservation ended and the unit released.
  const outcome = await settle(24 * 60 + 1);
  assert.deepEqual(outcome, { refunded: 1, alerted: 0, closed: 0, skipped: 0 });
  assert.equal(calls.refunds.length, 1);
  assertFirstRefundCall(calls.refunds[0]);
  const use = inMemory.read(USE_PATH) as Record<string, any>;
  assert.equal(use.tenantId, null);
  assert.equal(use.refund.refusal, 'not-finished');
  assert.equal(use.refund.status, 'refunded');
  assert.equal(inMemory.read(RESERVATION_PATH)?.status, 'cancelled');
  assert.equal(inMemory.read(RESERVATION_PATH)?.cancelReason, 'paid-move-in-refused:not-finished');
  assert.equal(inMemory.read(HOLD_PATH), undefined);
  assert.equal(inMemory.read(PAID_PATH), undefined);
  assert.match(String(inMemory.read(REFUND_ALERT_PATH)?.message), /did not finish moving in online within 24 hours of paying/);
  const resolved = inMemory.read(UNFINISHED_ALERT_PATH) as Record<string, any>;
  assert.notEqual(resolved.readAt, null);
  assert.equal(resolved.metadata.resolution, 'refunded');

  // Nothing more, however often the sweeps run.
  assert.deepEqual(await settle(25 * 60), { refunded: 0, alerted: 0, closed: 0, skipped: 0 });
  await refundSweep(25 * 60);
  assert.equal(calls.refunds.length, 1);

  // The renter coming back later is told, and not moved in.
  await assert.rejects(() => complete(), (err: any) => {
    assert.match(err.message, /^This move-in was not finished within 24 hours of paying, so it was cancelled\./);
    assert.match(err.message, /has been refunded to your card/);
    return true;
  });
  assert.deepEqual(tenants(inMemory), []);
  assert.equal(calls.refunds.length, 1);
});

test('a renter who pays, is chased by the owner and finishes is moved in, and the sweep only tidies up', async () => {
  const inMemory = new InMemoryFirestore();
  seedCheckout(inMemory, 34);
  const { webhook, settle, confirm, complete, calls } = load(inMemory, { sessions: { [SESSION]: paidSession(inMemory) } });

  await webhook();
  assert.equal((await settle(31)).alerted, 1);

  const found = await confirm();
  assert.equal(found.paymentIntentId, PI);
  const result = await complete();
  assert.equal(result.success, true);

  assert.deepEqual(await settle(46), { refunded: 0, alerted: 0, closed: 1, skipped: 0 });
  assert.deepEqual(calls.refunds, []);
  assert.equal(inMemory.read(PAID_PATH), undefined);
  assert.equal(inMemory.read(UNIT_PATH)?.tenantId, result.tenantId);
  const resolved = inMemory.read(UNFINISHED_ALERT_PATH) as Record<string, any>;
  assert.match(resolved.message, /Rita Renter paid online for unit U1 and has now finished moving in\./);
  assert.notEqual(resolved.readAt, null);
  assert.equal(resolved.metadata.resolution, 'moved-in');
});

for (const order of ['webhook first', 'confirmation first']) {
  test(`the webhook and the renter's confirmation at once (${order}) record one paid checkout and hold the unit a day from payment`, async () => {
    const inMemory = new InMemoryFirestore();
    seedCheckout(inMemory, 34);
    const paidAt = new Date(Math.floor((Date.now() - MINUTE) / 1000) * 1000);
    const { webhook, confirm } = load(inMemory, {
      sessions: { [SESSION]: { ...paidSession(inMemory), created: undefined } },
      // The payment a second after the webhook's event: the webhook's time is the earliest.
      intentCreatedSeconds: paidAt.getTime() / 1000 + 1,
    });

    const runs = [() => webhook(paidAt), () => confirm()];
    if (order !== 'webhook first') runs.reverse();
    await Promise.all(runs.map((run) => run()));

    assert.deepEqual(inMemory.listCollection('publicMoveInPaidCheckouts'), [PAID_PATH]);
    const paid = inMemory.read(PAID_PATH) as Record<string, any>;
    // The earliest time either saw: the webhook's.
    assert.equal(millisOf(paid.paidAt), paidAt.getTime());
    const reservation = inMemory.read(RESERVATION_PATH) as Record<string, any>;
    assert.equal(reservation.checkoutPaidPaymentIntentId, PI);
    assert.equal(millisOf(reservation.checkoutPaidAt), paidAt.getTime());
    // The webhook's day, never shortened by the confirmation's hour.
    assert.equal(millisOf(inMemory.read(HOLD_PATH)?.expiresAt), paidAt.getTime() + 24 * HOUR);
    assert.equal(millisOf(reservation.expiresAt), paidAt.getTime() + 24 * HOUR);
    assert.equal(inMemory.read(HOLD_PATH)?.reservationId, RESERVATION);
  });
}

test('a webhook retried after the renter moved in holds nothing again, and the sweep refunds nothing', async () => {
  const inMemory = new InMemoryFirestore();
  seedCheckout(inMemory, 34);
  const { webhook, confirm, complete, settle, calls } = load(inMemory, { sessions: { [SESSION]: paidSession(inMemory) } });

  await confirm();
  const result = await complete();
  assert.equal(inMemory.read(HOLD_PATH), undefined);

  assert.equal(await webhook(), 'settled');

  // Before any fix, a late webhook re-holding the rented unit would keep it off the map for a day.
  assert.equal(inMemory.read(HOLD_PATH), undefined);
  assert.equal(inMemory.read(RESERVATION_PATH)?.status, 'completed');
  assert.equal(inMemory.read(UNIT_PATH)?.tenantId, result.tenantId);
  assert.deepEqual(await settle(31), { refunded: 0, alerted: 0, closed: 1, skipped: 0 });
  assert.deepEqual(calls.refunds, []);
  assert.deepEqual(unfinishedAlerts(inMemory), []);
});

for (const first of ['sweep', 'renter']) {
  test(`a renter finishing just as the sweep refunds at the day's end (${first} first) is moved in or refunded, never both`, async () => {
    const inMemory = new InMemoryFirestore();
    seedCheckout(inMemory, 34);
    const { webhook, settle, complete, calls } = load(inMemory, { sessions: { [SESSION]: paidSession(inMemory) } });
    await webhook();

    const sweep = () => settle(24 * 60 + 1).then(() => 'swept');
    const renter = () => complete().then(() => 'moved in', (err: Error) => `refused: ${err.message}`);
    await Promise.all(first === 'sweep' ? [sweep(), renter()] : [renter(), sweep()]);

    const use = inMemory.read(USE_PATH) as Record<string, any>;
    const movedIn = tenants(inMemory).length;
    if (use.refund) {
      assert.equal(movedIn, 0);
      // Both may ask Stripe (the sweep, and the completion that found its
      // decision), always with the one key, so Stripe refunds once.
      assert.ok(calls.refunds.length >= 1);
      calls.refunds.forEach(assertFirstRefundCall);
      assert.equal(use.refund.status, 'refunded');
      assert.equal(inMemory.read(UNIT_PATH)?.status, 'available');
    } else {
      assert.equal(movedIn, 1);
      assert.equal(use.tenantId, inMemory.read(UNIT_PATH)?.tenantId);
      assert.deepEqual(calls.refunds, []);
    }
    assert.equal(inMemory.read(PAID_PATH), undefined);
  });
}

test('the sweep refunds straight away a paid renter whose unit the owner has rented to someone else', async () => {
  const inMemory = new InMemoryFirestore();
  seedCheckout(inMemory, 34);
  const { webhook, settle, calls } = load(inMemory, { sessions: { [SESSION]: paidSession(inMemory) } });
  await webhook();
  inMemory.seed(UNIT_PATH, { ...UNIT_DATA, status: 'occupied', tenantId: 'tenant-walk-in', tenantName: 'Wally Walkin' });

  assert.deepEqual(await settle(31), { refunded: 1, alerted: 0, closed: 0, skipped: 0 });

  assert.equal(calls.refunds.length, 1);
  assertFirstRefundCall(calls.refunds[0]);
  assert.equal((inMemory.read(USE_PATH) as Record<string, any>).refund.refusal, 'unit-taken');
  assert.equal(inMemory.read(UNIT_PATH)?.tenantId, 'tenant-walk-in');
  assert.deepEqual(unfinishedAlerts(inMemory), []);
});

test('the sweep does not refund a payment Stripe does not show to be the reservation\'s', async () => {
  const inMemory = new InMemoryFirestore();
  seedCheckout(inMemory, 34);
  const { webhook, settle, calls } = load(inMemory, {
    sessions: { [SESSION]: paidSession(inMemory) },
    intentMetadata: { type: 'public_move_in', reservationId: 'res-someone-else' },
  });
  await webhook();

  assert.deepEqual(await settle(24 * 60 + 1), { refunded: 0, alerted: 0, closed: 0, skipped: 1 });

  assert.deepEqual(calls.refunds, []);
  assert.equal(inMemory.read(USE_PATH), undefined);
  assert.ok(inMemory.read(PAID_PATH));
});

test('a paid session neither the webhook nor the renter reported is found once its page has closed, once', async () => {
  const inMemory = new InMemoryFirestore();
  // Checkout 50 minutes ago: the page closed 15 minutes ago, the hold 5 minutes ago.
  seedCheckout(inMemory, 50);
  const session = paidSession(inMemory, 50);
  const { findUnreported, settle, calls } = load(inMemory, { sessions: { [SESSION]: session } });

  assert.deepEqual(await findUnreported(), { recorded: 1, checked: 1 });

  assert.deepEqual(calls.sessionRetrieves, [SESSION]);
  const paid = inMemory.read(PAID_PATH) as Record<string, any>;
  assert.equal(paid.recordedBy, 'moveInSweep');
  assert.equal(paid.connectAccountId, ACCOUNT);
  // Held again for the payer, a day from the session's creation (no later than the payment).
  assert.equal(millisOf(inMemory.read(HOLD_PATH)?.expiresAt), (session.created as number) * 1000 + 24 * HOUR);
  assert.equal(inMemory.read(RESERVATION_PATH)?.checkoutSessionSweptId, SESSION);

  // Asked about once.
  assert.deepEqual(await findUnreported(), { recorded: 0, checked: 0 });
  assert.deepEqual(calls.sessionRetrieves, [SESSION]);
  // And settled like one the webhook reported.
  assert.equal((await settle(0)).alerted, 1);
});

test('an unpaid session whose page has closed is looked at once, and nothing is recorded or held', async () => {
  const inMemory = new InMemoryFirestore();
  seedCheckout(inMemory, 50);
  const holdBefore = inMemory.read(HOLD_PATH);
  const { findUnreported, calls } = load(inMemory, {
    sessions: { [SESSION]: { ...paidSession(inMemory, 50), status: 'expired', payment_status: 'unpaid', payment_intent: undefined } },
  });

  assert.deepEqual(await findUnreported(), { recorded: 0, checked: 1 });
  assert.deepEqual(await findUnreported(), { recorded: 0, checked: 0 });

  assert.deepEqual(calls.sessionRetrieves, [SESSION]);
  assert.equal(inMemory.read(PAID_PATH), undefined);
  assert.deepEqual(inMemory.read(HOLD_PATH), holdBefore);
});

// Finding 2: checkout reads the unit in its transaction

for (const [why, change] of [
  ['another renter completed onto it', (inMemory: InMemoryFirestore) =>
    inMemory.seed(UNIT_PATH, { ...UNIT_DATA, status: 'occupied', tenantId: 'tenant-first', tenantName: 'Fay First' })],
  ['an active tenant was given it', (inMemory: InMemoryFirestore) =>
    inMemory.seed(`facilities/${FACILITY}/tenants/tenant-first`, { isActive: true, unitId: UNIT, unitNumber: 'U1' })],
] as Array<[string, (inMemory: InMemoryFirestore) => void]>) {
  test(`checkout is refused in its transaction when ${why} after checkout's first look, and no session is made`, async () => {
    const inMemory = new InMemoryFirestore();
    seedCheckout(inMemory, 2, {
      checkoutUpdatedAt: null,
      checkoutSessionId: null,
      checkoutSessionAccountId: null,
      checkoutSessionExpiresAt: null,
      expiresAt: Timestamp.fromMillis(Date.now() + 8 * MINUTE),
    });
    const { checkout, calls } = load(inMemory, { sessions: {} });
    // After checkout's first look at the unit, while its transaction runs.
    let changed = false;
    inMemory.beforeCommit = ({ readPaths }) => {
      if (!changed && readPaths.includes(RESERVATION_PATH) && readPaths.includes(HOLD_PATH)) {
        changed = true;
        change(inMemory);
      }
    };

    // Before: the unit was checked only before the transaction, so this
    // renter got a payable session for a unit someone else now had.
    await assert.rejects(() => checkout(), (err: any) => {
      assert.equal(err.code, 'failed-precondition');
      assert.equal(err.message, NOT_AVAILABLE);
      return true;
    });

    assert.equal(changed, true);
    assert.equal(calls.sessionCreates, 0);
    assert.equal(inMemory.read(RESERVATION_PATH)?.checkoutUpdatedAt, null);
    assert.equal(inMemory.read(RESERVATION_PATH)?.expectedCheckoutAmountCents, quoteCents(inMemory));
  });
}

// Finding 3: refund outcomes

test('a refund another finisher recorded as made is never overwritten as failed', async () => {
  const inMemory = new InMemoryFirestore();
  seedCheckout(inMemory, 34);
  inMemory.seed(UNIT_PATH, { ...UNIT_DATA, status: 'occupied', tenantId: 'tenant-walk-in' });
  const { complete, calls } = load(inMemory, {
    sessions: {},
    // While this request fails, another finisher (the sweep, a retried
    // completion) has Stripe make the refund and records it.
    onRefund: () => {
      const use = inMemory.read(USE_PATH) as Record<string, any>;
      inMemory.seed(USE_PATH, { ...use, refund: { ...use.refund, status: 'refunded', refundId: 're_elsewhere', attempts: 1 } });
    },
    refundAnswer: () => new Error('connection reset'),
  });

  await assert.rejects(() => complete(), (err: any) => {
    assert.match(err.message, /has been refunded to your card/);
    return true;
  });

  assert.equal(calls.refunds.length, 1);
  const refund = (inMemory.read(USE_PATH) as Record<string, any>).refund;
  assert.equal(refund.status, 'refunded');
  assert.equal(refund.refundId, 're_elsewhere');
  // The owner is not told to refund by hand a payment already refunded.
  assert.doesNotMatch(String(inMemory.read(REFUND_ALERT_PATH)?.message), /failed/);
  assert.notEqual((inMemory.read(REFUND_ALERT_PATH) as Record<string, any>).metadata?.refundStatus, 'failed');
});

test('a refund Stripe shows pending is recorded as pending, looked at again by the sweep, and recorded when made', async () => {
  const inMemory = new InMemoryFirestore();
  seedCheckout(inMemory, 34);
  inMemory.seed(UNIT_PATH, { ...UNIT_DATA, status: 'occupied', tenantId: 'tenant-walk-in' });
  const stub: Stub = {
    sessions: {},
    refundAnswer: () => ({ id: 're_slow', status: 'pending' }),
    refundLookup: () => ({ id: 're_slow', status: 'pending' }),
  };
  const { complete, refundSweep, calls } = load(inMemory, stub);

  // Before: recorded as refunded when Stripe had only accepted it.
  await assert.rejects(() => complete(), (err: any) => {
    assert.match(err.message, /is being refunded to your card/);
    assert.equal(err.details.refunded, false);
    return true;
  });
  let refund = (inMemory.read(USE_PATH) as Record<string, any>).refund;
  assert.equal(refund.status, 'pending');
  assert.equal(refund.refundId, 're_slow');
  assert.equal(refund.stripeStatus, 'pending');
  assert.match(String(inMemory.read(REFUND_ALERT_PATH)?.message), /Stripe has accepted the refund and shows it as pending/);

  // Decided long enough ago for the sweep to look (records keep a server timestamp).
  inMemory.seed(USE_PATH, { ...inMemory.read(USE_PATH), createdAt: Timestamp.fromMillis(Date.now() - 20 * MINUTE) });
  await refundSweep(0);
  assert.equal(calls.refunds.length, 1, 'looked up, not asked for again');
  assert.deepEqual(calls.refundLookups.map((l) => [l.id, l.options.stripeAccount]), [['re_slow', ACCOUNT]]);
  assert.equal((inMemory.read(USE_PATH) as Record<string, any>).refund.status, 'pending');

  stub.refundLookup = () => ({ id: 're_slow', status: 'succeeded' });
  await refundSweep(15);
  refund = (inMemory.read(USE_PATH) as Record<string, any>).refund;
  assert.equal(refund.status, 'refunded');
  assert.equal(calls.refunds.length, 1);
  assert.match(String(inMemory.read(REFUND_ALERT_PATH)?.message), /refunded to them automatically/);
  assert.equal((inMemory.read(REFUND_ALERT_PATH) as Record<string, any>).metadata?.refundStatus, 'refunded');
});

test('a failed refund is retried by the sweep with a new key each time, four requests in all, then left to the owner', async () => {
  const inMemory = new InMemoryFirestore();
  seedCheckout(inMemory, 34);
  inMemory.seed(UNIT_PATH, { ...UNIT_DATA, status: 'occupied', tenantId: 'tenant-walk-in' });
  const { complete, refundSweep, calls } = load(inMemory, {
    sessions: {},
    refundAnswer: () => Object.assign(new Error('Insufficient funds in the connected account'), { code: 'balance_insufficient' }),
  });

  await assert.rejects(() => complete(), /The facility has been told and will refund/);

  let minutesOn = 0;
  for (let attempt = 2; attempt <= 4; attempt += 1) {
    const due = (inMemory.read(USE_PATH) as Record<string, any>).refund.retryAt as Timestamp;
    // Not before it is due.
    await refundSweep(minutesOn);
    assert.equal(calls.refunds.length, attempt - 1);
    minutesOn = Math.ceil((due.toMillis() - Date.now()) / MINUTE) + 1;
    await refundSweep(minutesOn);
    assert.equal(calls.refunds.length, attempt);
    assert.equal(calls.refunds[attempt - 1].options.idempotencyKey, `public_move_in_refund_${PI}_attempt_${attempt}`);
  }

  const refund = (inMemory.read(USE_PATH) as Record<string, any>).refund;
  assert.equal(refund.status, 'failed');
  assert.equal(refund.attempts, 4);
  assert.equal(refund.retryAt, null);
  const message = String(inMemory.read(REFUND_ALERT_PATH)?.message);
  assert.match(message, /The automatic refund failed 4 times \(Insufficient funds in the connected account\)\./);
  assert.match(message, new RegExp(`Refund payment ${PI} in your Stripe dashboard\\.`));

  // Given up: no more requests, however long the sweep runs.
  await refundSweep(minutesOn + 3 * 24 * 60);
  assert.equal(calls.refunds.length, 4);
  assertFirstRefundCall(calls.refunds[0]);
});

// Finding 4: confirming a paid session holds the unit no longer than a day after payment

test('confirming a paid session near the end of the day after payment holds the unit only until then', async () => {
  const inMemory = new InMemoryFirestore();
  const paidAt = Math.floor((Date.now() - (23 * HOUR + 30 * MINUTE)) / 1000) * 1000;
  seedCheckout(inMemory, 24 * 60, {
    checkoutPaidPaymentIntentId: PI,
    checkoutPaidAt: Timestamp.fromMillis(paidAt),
    expiresAt: Timestamp.fromMillis(Date.now() - 5 * MINUTE),
  });
  inMemory.seed(HOLD_PATH, { ...inMemory.read(HOLD_PATH), expiresAt: Timestamp.fromMillis(Date.now() - 5 * MINUTE) });
  const { confirm } = load(inMemory, {
    sessions: { [SESSION]: paidSession(inMemory, 24 * 60) },
    intentCreatedSeconds: paidAt / 1000,
  });

  // Before: an hour from each confirmation, however long ago the payment was.
  await confirm();
  await confirm();

  for (const path of [HOLD_PATH, RESERVATION_PATH]) {
    assert.equal(millisOf(inMemory.read(path)?.expiresAt), paidAt + 24 * HOUR, path);
  }
});

test('confirming a paid session more than a day after payment holds nothing', async () => {
  const inMemory = new InMemoryFirestore();
  const lapsed = Timestamp.fromMillis(Date.now() - 60 * MINUTE);
  seedCheckout(inMemory, 26 * 60, {
    checkoutPaidPaymentIntentId: PI,
    checkoutPaidAt: Timestamp.fromMillis(Date.now() - 25 * HOUR),
    expiresAt: lapsed,
  });
  inMemory.seed(HOLD_PATH, { ...inMemory.read(HOLD_PATH), expiresAt: lapsed });
  const { confirm } = load(inMemory, { sessions: { [SESSION]: paidSession(inMemory, 26 * 60) } });

  const found = await confirm();

  // Still reported paid: completion moves them in if the unit is free, or refunds them.
  assert.equal(found.paymentIntentId, PI);
  assert.equal(millisOf(inMemory.read(HOLD_PATH)?.expiresAt), lapsed.toMillis());
  assert.equal(millisOf(inMemory.read(RESERVATION_PATH)?.expiresAt), lapsed.toMillis());
  // Recorded for the sweep, which refunds it as not finished.
  assert.ok(inMemory.read(PAID_PATH));
});

// Finding 5: the account a refund is resumed on

test('a refund resumed after the facility moved Stripe accounts is made on the account that took the payment', async () => {
  const inMemory = new InMemoryFirestore();
  seedCheckout(inMemory, 34);
  const record = {
    paymentIntentId: PI,
    facilityId: FACILITY,
    reservationId: RESERVATION,
    tenantId: null,
    amountReceivedCents: 2500,
    connectAccountId: ACCOUNT,
    refund: { status: 'pending', refusal: 'unit-taken', unitId: UNIT, unitNumber: 'U1', renterName: 'Rita Renter' },
    createdAt: Timestamp.fromMillis(Date.now() - 20 * MINUTE),
  };
  inMemory.seed(USE_PATH, record);
  const { refunds, calls } = load(inMemory, { sessions: {} });

  // The caller passes the facility's account now; the record's is the one holding the payment.
  await assert.rejects(
    () => refunds.resumePaidMoveInRefund({ facilityId: FACILITY, connectAccountId: 'acct_moved_since' }, PI, record),
    /has been refunded to your card/,
  );

  assert.equal(calls.refunds.length, 1);
  assertFirstRefundCall(calls.refunds[0]);
});

// A refund or card dispute made in Stripe before the renter finished: the
// Connect webhook records it on the payment's use record, with no tenant
// (functions-integrations moveInPaymentTenant.ts).

const RETURNED_IN_STRIPE: Array<[string, Record<string, unknown>]> = [
  ['refunded in part from the Dashboard', {
    untenantedRefunds: { re_dashboard: { amountCents: 1000, status: 'succeeded', connectedAccountId: ACCOUNT } },
  }],
  ['disputed', {
    untenantedDisputes: { du_early: { amountCents: 2500, status: 'needs_response', reason: 'fraudulent', connectedAccountId: ACCOUNT } },
  }],
];

for (const [label, recorded] of RETURNED_IN_STRIPE) {
  test(`a payment ${label} before the renter finished is not read as a move-in, and nothing refunds it`, async () => {
    const inMemory = new InMemoryFirestore();
    seedCheckout(inMemory, 34);
    const { webhook, settle, complete, calls, refunds } = load(inMemory, { sessions: { [SESSION]: paidSession(inMemory) } });
    await webhook();
    assert.equal((await settle(31)).alerted, 1);

    inMemory.seed(USE_PATH, {
      paymentIntentId: PI,
      facilityId: FACILITY,
      reservationId: RESERVATION,
      ...recorded,
      updatedBy: 'system@stripe-webhook',
    });
    assert.deepEqual(await settle(46), { refunded: 0, alerted: 0, closed: 1, skipped: 0 });

    // Before: rewritten to "...and has now finished moving in." and marked read.
    const alert = inMemory.read(UNFINISHED_ALERT_PATH) as Record<string, any>;
    assert.doesNotMatch(alert.message, /has now finished moving in/);
    assert.match(alert.message, /^Rita Renter paid online for unit U1, and then part or all of the payment was refunded in Stripe, or the charge was disputed/);
    assert.match(alert.message, /will not be refunded automatically/);
    assert.equal(alert.readAt, null);
    assert.equal(alert.metadata.resolution, 'returned');
    // Before: deleted as if the renter had moved in.
    assert.ok(inMemory.read(PAID_PATH));
    // Written once, however often the sweep runs.
    const written = JSON.stringify(inMemory.read(UNFINISHED_ALERT_PATH));
    await settle(60);
    assert.equal(JSON.stringify(inMemory.read(UNFINISHED_ALERT_PATH)), written);

    // The renter coming back is told what happened (before: that the payment
    // had completed a move-in), and is not moved in.
    await assert.rejects(() => complete(), (err: any) => {
      assert.equal(err.message, refunds.PAYMENT_RETURNED_BEFORE_MOVE_IN_MESSAGE);
      return true;
    });
    // The same when completion would have refused and refunded it.
    inMemory.seed(UNIT_PATH, { ...UNIT_DATA, monthlyRate: 150 });
    await assert.rejects(() => complete(), (err: any) => {
      assert.equal(err.message, refunds.PAYMENT_RETURNED_BEFORE_MOVE_IN_MESSAGE);
      return true;
    });
    assert.deepEqual(tenants(inMemory), []);

    // A day after paying the record goes. Nothing was ever refunded here: the
    // webhook told the owner to deal with it in Stripe.
    assert.deepEqual(await settle(24 * 60 + 1), { refunded: 0, alerted: 0, closed: 1, skipped: 0 });
    assert.equal(inMemory.read(PAID_PATH), undefined);
    assert.equal(JSON.stringify(inMemory.read(UNFINISHED_ALERT_PATH)), written);
    assert.deepEqual(calls.refunds, []);
    assert.equal((inMemory.read(USE_PATH) as Record<string, any>).refund, undefined);
  });
}

test.after(() => {
  testEnv.cleanup();
});

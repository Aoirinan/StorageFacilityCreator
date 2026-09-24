/**
 * Checkout is refused for a unit that is no longer available, before Stripe is
 * called.
 *
 * Only completePublicMoveIn re-checked the unit, and it runs after Checkout has
 * taken the payment. A unit rented, unlisted, set to internal use, archived or
 * deleted while it was held left a renter who had paid with no tenancy, and the
 * owner to refund them by hand.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { Timestamp } from 'firebase-admin/firestore';
import firebaseFunctionsTest from 'firebase-functions-test';
import { computePublicMoveInCharges } from '../moveInCharges';
import { InMemoryFirestore, installInMemoryFirestore } from './support/inMemoryFirestore';

const testEnv = firebaseFunctionsTest({ projectId: 'in-memory-test' });
const callableContext = { app: { appId: 'test-app-check' } };

const FACILITY = 'fac-checkout';
const UNIT = 'unit-checkout';
const RESERVATION = 'res-checkout';
const TOKEN = 'checkout-move-in-token-0123456789';
const UNIT_PATH = `facilities/${FACILITY}/units/${UNIT}`;
const RESERVATION_PATH = `publicReservations/${RESERVATION}`;
const NOT_AVAILABLE = 'Unit is not currently available';

/**
 * Stripe Connect is set up, so a checkout here reaches Stripe. The admin fee
 * keeps the amount due above the card minimum with no unit to price, so that
 * a deleted unit would reach Stripe too if the unit were not checked.
 */
const FACILITY_DATA = {
  name: 'Checkout Storage',
  stripeConnectAccountId: 'acct_checkout',
  stripeConnectOnboardingComplete: true,
  billingSettings: { adminFee: 25 },
};

/** Each way a held unit stops being available before the renter pays; null is deleted. */
const NO_LONGER_AVAILABLE: Array<[string, Record<string, unknown> | null]> = [
  ['rented since the hold', { status: 'occupied' }],
  ['no longer listed on the public website', { publicListingEnabled: false }],
  ['set to internal use', { internalUse: true }],
  ['archived', { archived: true }],
  ['deleted', null],
];

/** Loads publicMoveIn against [inMemory], with Stripe replaced by a recorder. */
function loadPublicMoveIn(inMemory: InMemoryFirestore) {
  installInMemoryFirestore(inMemory);
  const stripeCalls: string[] = [];
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
              stripeCalls.push('checkout.sessions.create');
              return { id: 'cs_test', url: 'https://checkout.example/cs_test' };
            },
          },
        },
      }) as unknown as ReturnType<typeof shared.getStripeClient>,
  });
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const moveIn = require('../publicMoveIn') as typeof import('../publicMoveIn');
  return {
    stripeCalls,
    checkout: (data: Record<string, unknown>) => testEnv.wrap(moveIn.createPublicMoveInCheckout)(data, callableContext),
  };
}

/** A facility taking online payments, and a reservation holding [UNIT] there. */
function seedFacilityAndReservation(inMemory: InMemoryFirestore) {
  inMemory.seed(`facilities/${FACILITY}`, FACILITY_DATA);
  inMemory.seed(RESERVATION_PATH, {
    facilityId: FACILITY,
    unitId: UNIT,
    unitNumber: 'K1',
    status: 'pending',
    moveInToken: TOKEN,
    moveInDate: Timestamp.fromDate(new Date(2026, 8, 25)),
    expiresAt: Timestamp.fromDate(new Date(Date.now() + 10 * 60 * 1000)),
    email: 'renter@example.com',
    name: 'Rita Renter',
    metadata: {},
  });
}

function seedUnit(inMemory: InMemoryFirestore, fields: Record<string, unknown> = {}) {
  inMemory.seed(UNIT_PATH, {
    status: 'available',
    unitNumber: 'K1',
    unitType: 'standard',
    monthlyRate: 100,
    ...fields,
  });
}

/**
 * The request the page sends, for the amount the server quotes. A correct
 * amount, so the unit check is the only thing that can stop it reaching Stripe.
 */
function checkoutRequest(inMemory: InMemoryFirestore) {
  const reservation = inMemory.read(RESERVATION_PATH) as Record<string, unknown>;
  const quote = computePublicMoveInCharges({
    reservation,
    unitData: inMemory.read(UNIT_PATH),
    facilityData: FACILITY_DATA,
    moveInDate: (reservation.moveInDate as Timestamp).toDate(),
  });
  assert.ok(quote.totalCents >= 50);
  return { reservationId: RESERVATION, token: TOKEN, amount: quote.totalAmount };
}

function refusedWith(message: string) {
  return (err: unknown): boolean => {
    const e = err as { code?: string; message?: string };
    assert.equal(e.code, 'failed-precondition');
    assert.equal(e.message, message);
    return true;
  };
}

for (const status of ['available', 'reserved']) {
  test(`checkout for a listed unit that is ${status} reaches Stripe`, async () => {
    const inMemory = new InMemoryFirestore();
    seedFacilityAndReservation(inMemory);
    seedUnit(inMemory, { status });
    const { checkout, stripeCalls } = loadPublicMoveIn(inMemory);

    const result = (await checkout(checkoutRequest(inMemory))) as { checkoutUrl?: string };

    assert.deepEqual(stripeCalls, ['checkout.sessions.create']);
    assert.equal(result.checkoutUrl, 'https://checkout.example/cs_test');
  });
}

for (const [why, unitFields] of NO_LONGER_AVAILABLE) {
  test(`checkout is refused for a unit ${why}, before Stripe is called`, async () => {
    const inMemory = new InMemoryFirestore();
    seedFacilityAndReservation(inMemory);
    if (unitFields) {
      seedUnit(inMemory, unitFields);
    }
    const { checkout, stripeCalls } = loadPublicMoveIn(inMemory);

    await assert.rejects(() => checkout(checkoutRequest(inMemory)), refusedWith(NOT_AVAILABLE));

    assert.deepEqual(stripeCalls, []);
    assert.equal(inMemory.read(RESERVATION_PATH)?.expectedCheckoutAmountCents, undefined);
  });
}

test.after(() => {
  testEnv.cleanup();
});

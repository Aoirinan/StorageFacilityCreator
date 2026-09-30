import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'fs';
import * as path from 'path';
import {
  amountsMatchCents,
  calculateProratedRent,
  computePublicMoveInCharges,
  isPublicMoveInStripePaymentRequired,
  isUnpricedPaidMoveIn,
  proratedRentDays,
} from '../moveInCharges';

test('calculateProratedRent prorates mid-month move-in', () => {
  const moveInDate = new Date(2026, 5, 15);
  const amount = calculateProratedRent(100, moveInDate);
  assert.ok(amount > 50 && amount < 60);
});

test('computePublicMoveInCharges includes configured fees and deposit', () => {
  const quote = computePublicMoveInCharges({
    reservation: { metadata: { monthlyRate: 120 } },
    unitData: { monthlyRate: 100, securityDeposit: 50 },
    facilityData: {
      billingSettings: { adminFee: 25, moveInFee: 15 },
    },
    publicSettings: {
      chargeSecurityDepositAtMoveIn: true,
      publicSecurityDepositAmount: 75,
      chargeInsuranceAtMoveIn: true,
      publicInsuranceAmount: 12,
    },
    moveInDate: new Date(2026, 5, 10),
  });

  assert.ok(quote.totalAmount > 120);
  assert.equal(quote.totalCents, Math.round(quote.totalAmount * 100));
  assert.ok(quote.lineItems.some((item) => item.type === 'adminFee'));
  assert.ok(quote.lineItems.some((item) => item.type === 'securityDeposit'));
});

test('isPublicMoveInStripePaymentRequired requires connect onboarding and positive total', () => {
  assert.equal(
    isPublicMoveInStripePaymentRequired(
      { stripeConnectAccountId: 'acct_1', stripeConnectOnboardingComplete: true },
      50,
    ),
    true,
  );
  assert.equal(
    isPublicMoveInStripePaymentRequired(
      { stripeConnectAccountId: 'acct_1', stripeConnectOnboardingComplete: false },
      50,
    ),
    false,
  );
  assert.equal(isPublicMoveInStripePaymentRequired({}, 0), false);
});

test('amountsMatchCents compares dollar input to cent quote', () => {
  assert.equal(amountsMatchCents(12345, 123.45), true);
  assert.equal(amountsMatchCents(12345, 123.44), false);
});

test('a rate injected into reservation metadata is ignored in favour of the unit', () => {
  // The public hold endpoint used to copy the caller's metadata object verbatim
  // into the reservation, and the quote preferred metadata.monthlyRate over the
  // unit. An unauthenticated caller could name their own rent, pay a quote
  // computed from it, and keep that rate as the ongoing monthly charge.
  const moveInDate = new Date(2026, 5, 10);
  const injected = computePublicMoveInCharges({
    reservation: { metadata: { monthlyRate: 0.6 } },
    unitData: { monthlyRate: 100 },
    moveInDate,
  });
  const honest = computePublicMoveInCharges({
    reservation: {},
    unitData: { monthlyRate: 100 },
    moveInDate,
  });

  assert.equal(injected.totalCents, honest.totalCents);
  // Prorated from $100/month, not from the 60-cent rate the caller asked for.
  assert.ok(injected.totalAmount > 50, `expected real rent, got ${injected.totalAmount}`);
});

// Prorating the first month by calendar day

type ProrationCase = {
  name: string;
  monthlyRate: number;
  at: string;
  daysInMonth: number;
  days: number;
  amount: number;
};

/** Cases the app's test (test/move_in_proration_parity_test.dart) runs too. */
function prorationParityCases(): ProrationCase[] {
  const file = path.join(__dirname, '..', '..', '..', 'test', 'fixtures', 'move_in_proration.json');
  return (JSON.parse(fs.readFileSync(file, 'utf8')) as { cases: ProrationCase[] }).cases;
}

test('prorated rent matches every shared parity case the app prices', () => {
  // The move-in page sends the total it priced with ProrateService, and
  // checkout refuses one a cent off the server's.
  const cases = prorationParityCases();
  assert.ok(cases.length >= 15, 'the shared fixture was not read');
  for (const c of cases) {
    const at = new Date(c.at);
    assert.equal(calculateProratedRent(c.monthlyRate, at), c.amount, c.name);
    assert.deepEqual(proratedRentDays(at), { daysInMonth: c.daysInMonth, daysBilled: c.days }, c.name);

    const quote = computePublicMoveInCharges({
      reservation: {},
      unitData: { monthlyRate: c.monthlyRate },
      moveInDate: at,
    });
    const rentLine = quote.lineItems.find((item) => item.type === 'proratedRent');
    assert.equal(rentLine?.amount ?? 0, c.amount, c.name);
    assert.equal(quote.totalCents, Math.round(c.amount * 100), c.name);
  }
});

test('the time of day a move-in is priced at does not change its rent', () => {
  // A renter with no move-in date is priced from the moment checkout runs.
  // Measured from that moment to midnight at the start of the last day, the
  // 15th at 20:00 came to 15 days, not the 16 from the 15th to the 30th.
  const atMidnight = calculateProratedRent(100, new Date('2026-09-15T00:00:00Z'));
  const atEight = calculateProratedRent(100, new Date('2026-09-15T20:00:00Z'));
  assert.equal(atEight, atMidnight);
  assert.equal(atMidnight, 53.33); // 100 / 30 * 16
});

test('moving in on the last day of a month at 20:00 costs a day, not nothing', () => {
  // This priced at 0 days. With no fees the Checkout total was $0, Stripe
  // refused it, and a renter could not pay online on the 30th or 31st.
  assert.equal(calculateProratedRent(100, new Date('2026-09-30T20:00:00Z')), 3.33);
  assert.equal(calculateProratedRent(310, new Date('2026-10-31T20:00:00Z')), 10);
  const quote = computePublicMoveInCharges({
    reservation: {},
    unitData: { monthlyRate: 100 },
    moveInDate: new Date('2026-09-30T20:00:00Z'),
  });
  assert.equal(quote.totalCents, 333);
});

test('moving in on the first bills the whole month', () => {
  assert.equal(calculateProratedRent(100, new Date('2026-09-01T00:00:00Z')), 100);
  assert.equal(calculateProratedRent(100, new Date('2026-10-01T20:00:00Z')), 100);
});

test('February is prorated over its own length, leap years included', () => {
  assert.deepEqual(proratedRentDays(new Date('2026-02-10T20:00:00Z')), { daysInMonth: 28, daysBilled: 19 });
  assert.deepEqual(proratedRentDays(new Date('2028-02-10T20:00:00Z')), { daysInMonth: 29, daysBilled: 20 });
  assert.equal(calculateProratedRent(290, new Date('2028-02-29T21:00:00Z')), 10);
});

test('the day is read in UTC, whatever clock the server runs on', () => {
  // Cloud Functions runs in UTC; the local getters this used before priced a
  // different day on any other clock. 01:00 UTC on the 16th is the 16th.
  assert.deepEqual(proratedRentDays(new Date('2026-09-16T01:00:00Z')), { daysInMonth: 30, daysBilled: 15 });
  assert.deepEqual(proratedRentDays(new Date('2026-09-15T20:00:00-05:00')), { daysInMonth: 30, daysBilled: 15 });
});

test('next month is charged after mid-month by the same UTC day', () => {
  const publicSettings = { chargeNextMonthAfterMidMonthMoveIn: true };
  const on15th = computePublicMoveInCharges({
    reservation: {},
    unitData: { monthlyRate: 100 },
    publicSettings,
    moveInDate: new Date('2026-09-15T23:30:00Z'),
  });
  const on16th = computePublicMoveInCharges({
    reservation: {},
    unitData: { monthlyRate: 100 },
    publicSettings,
    moveInDate: new Date('2026-09-16T00:30:00Z'),
  });
  assert.ok(!on15th.lineItems.some((item) => item.type === 'rent'));
  assert.ok(on16th.lineItems.some((item) => item.type === 'rent' && item.amount === 100));
});

// A unit with rent priced at nothing

test('a unit with rent quoted at $0 at a facility paid online is unpriced', () => {
  const online = { stripeConnectAccountId: 'acct_1', stripeConnectOnboardingComplete: true };
  const quote = computePublicMoveInCharges({
    reservation: {},
    unitData: { monthlyRate: 0.1 },
    facilityData: online,
    moveInDate: new Date('2026-09-30T12:00:00Z'),
  });
  assert.equal(quote.totalCents, 0);
  assert.equal(quote.monthlyRent, 0.1);
  assert.equal(isUnpricedPaidMoveIn(online, quote), true);
});

test('a facility not paid online, or a unit with no rent, may move in for nothing', () => {
  const online = { stripeConnectAccountId: 'acct_1', stripeConnectOnboardingComplete: true };
  assert.equal(isUnpricedPaidMoveIn({}, { totalCents: 0, monthlyRent: 100 }), false);
  assert.equal(
    isUnpricedPaidMoveIn({ stripeConnectAccountId: 'acct_1', stripeConnectOnboardingComplete: false }, { totalCents: 0, monthlyRent: 100 }),
    false,
  );
  assert.equal(isUnpricedPaidMoveIn(online, { totalCents: 0, monthlyRent: 0 }), false);
  assert.equal(isUnpricedPaidMoveIn(online, { totalCents: 333, monthlyRent: 100 }), false);
});

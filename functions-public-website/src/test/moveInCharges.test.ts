import test from 'node:test';
import assert from 'node:assert/strict';
import {
  amountsMatchCents,
  calculateProratedRent,
  computePublicMoveInCharges,
  isPublicMoveInStripePaymentRequired,
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

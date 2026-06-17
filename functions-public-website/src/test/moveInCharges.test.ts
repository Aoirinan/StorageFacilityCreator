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

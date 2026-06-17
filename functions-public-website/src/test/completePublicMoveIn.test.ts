/**
 * Regression tests for completePublicMoveIn payment security guards.
 *
 * Skipped (already covered elsewhere):
 * - amountsMatchCents helper — moveInCharges.test.ts
 * - isPublicMoveInStripePaymentRequired helper — moveInCharges.test.ts
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { Timestamp } from 'firebase-admin/firestore';
import firebaseFunctionsTest from 'firebase-functions-test';
import { computePublicMoveInCharges } from '../moveInCharges';
import { InMemoryFirestore, installInMemoryFirestore } from './support/inMemoryFirestore';

const testEnv = firebaseFunctionsTest({ projectId: 'in-memory-test' });

type StripeMock = {
  amountReceived: number;
  status: string;
};

const FIXTURE = {
  facilityId: 'fac-test-1',
  unitId: 'unit-test-1',
  reservationId: 'res-test-1',
  moveInToken: 'move-in-token-abc123',
  connectAccountId: 'acct_test_connect',
};

function seedPaymentRequiredFixture(inMemory: InMemoryFirestore): number {
  const moveInDate = new Date(2026, 5, 10);
  const reservation = {
    facilityId: FIXTURE.facilityId,
    unitId: FIXTURE.unitId,
    unitNumber: 'A1',
    status: 'pending',
    moveInToken: FIXTURE.moveInToken,
    moveInDate: Timestamp.fromDate(moveInDate),
    expiresAt: Timestamp.fromDate(new Date(Date.now() + 60 * 60 * 1000)),
    metadata: { monthlyRate: 120 },
  };
  const unitData = {
    status: 'available',
    monthlyRate: 100,
    unitNumber: 'A1',
    unitType: 'standard',
  };
  const facilityData = {
    name: 'Test Facility',
    stripeConnectAccountId: FIXTURE.connectAccountId,
    stripeConnectOnboardingComplete: true,
    billingSettings: { adminFee: 25, moveInFee: 15 },
  };
  const publicSettings = {
    chargeSecurityDepositAtMoveIn: true,
    publicSecurityDepositAmount: 75,
  };

  inMemory.seed(`publicReservations/${FIXTURE.reservationId}`, reservation);
  inMemory.seed(`facilities/${FIXTURE.facilityId}`, facilityData);
  inMemory.seed(`facilities/${FIXTURE.facilityId}/units/${FIXTURE.unitId}`, unitData);
  inMemory.seed(`facilities/${FIXTURE.facilityId}/settings/public`, publicSettings);

  const quote = computePublicMoveInCharges({
    reservation,
    unitData,
    facilityData,
    publicSettings,
    moveInDate,
  });
  return quote.totalCents;
}

function basePayload(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    reservationId: FIXTURE.reservationId,
    token: FIXTURE.moveInToken,
    name: 'Jane Tenant',
    email: 'jane@example.com',
    phone: '5551234567',
    signaturePngBase64: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    skipPayment: false,
    ...overrides,
  };
}

function assertFailedPrecondition(err: unknown, message: string | RegExp): boolean {
  assert.ok(err && typeof err === 'object', `expected error object, got ${String(err)}`);
  const httpsErr = err as { code?: string; message?: string };
  assert.equal(httpsErr.code, 'failed-precondition');
  if (message instanceof RegExp) {
    assert.match(httpsErr.message || '', message);
  } else {
    assert.equal(httpsErr.message, message);
  }
  return true;
}

function assertMoveInNotCompleted(inMemory: InMemoryFirestore): void {
  const tenants = inMemory.listCollection(`facilities/${FIXTURE.facilityId}/tenants`);
  assert.equal(tenants.length, 0, 'expected no tenant documents');

  const reservation = inMemory.read(`publicReservations/${FIXTURE.reservationId}`);
  assert.equal(reservation?.status, 'pending', 'reservation should remain pending');

  const unitStatus = inMemory.read(`facilities/${FIXTURE.facilityId}/units/${FIXTURE.unitId}`)?.status;
  assert.ok(
    unitStatus === 'available' || unitStatus === 'reserved',
    `unit should remain available or reserved, got ${String(unitStatus)}`,
  );
}

function loadWrappedCompletePublicMoveIn(stripeMock: StripeMock) {
  const inMemory = new InMemoryFirestore();
  seedPaymentRequiredFixture(inMemory);
  installInMemoryFirestore(inMemory);

  // Load order matters: patch Stripe client before publicMoveIn is required.
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const shared = require('@sfc/functions-shared') as typeof import('@sfc/functions-shared');
  Object.defineProperty(shared, 'getStripeClient', {
    configurable: true,
    writable: true,
    value: () =>
      ({
        paymentIntents: {
          retrieve: async () => ({
            amount_received: stripeMock.amountReceived,
            status: stripeMock.status,
          }),
        },
      }) as unknown as ReturnType<typeof shared.getStripeClient>,
  });

  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { completePublicMoveIn } = require('../publicMoveIn') as typeof import('../publicMoveIn');
  const wrapped = testEnv.wrap(completePublicMoveIn);
  const callableContext = { app: { appId: 'test-app-check' } };

  return {
    inMemory,
    invoke: (data: Record<string, unknown>) => wrapped(data, callableContext),
  };
}

test('completePublicMoveIn rejects payment intent with insufficient amount_received', async () => {
  const { inMemory, invoke } = loadWrappedCompletePublicMoveIn({
    amountReceived: 1,
    status: 'succeeded',
  });

  await assert.rejects(
    () =>
      invoke({
        ...basePayload(),
        paymentIntentId: 'pi_test_underpaid',
      }),
    (err: unknown) => assertFailedPrecondition(err, /amount mismatch/i),
  );

  assertMoveInNotCompleted(inMemory);
});

test('completePublicMoveIn rejects skipPayment when payment is required', async () => {
  const { inMemory, invoke } = loadWrappedCompletePublicMoveIn({
    amountReceived: 0,
    status: 'succeeded',
  });

  await assert.rejects(
    () =>
      invoke({
        ...basePayload(),
        skipPayment: true,
      }),
    (err: unknown) =>
      assertFailedPrecondition(err, 'Payment is required to complete this move-in.'),
  );

  assertMoveInNotCompleted(inMemory);
});

test('completePublicMoveIn rejects missing paymentIntentId when payment is required', async () => {
  const { inMemory, invoke } = loadWrappedCompletePublicMoveIn({
    amountReceived: 0,
    status: 'succeeded',
  });

  await assert.rejects(
    () =>
      invoke({
        ...basePayload(),
        skipPayment: false,
      }),
    (err: unknown) =>
      assertFailedPrecondition(err, 'Payment is required before completing move-in.'),
  );

  assertMoveInNotCompleted(inMemory);
});

test.after(() => {
  testEnv.cleanup();
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { Timestamp } from 'firebase-admin/firestore';
import firebaseFunctionsTest from 'firebase-functions-test';
import { InMemoryFirestore, installInMemoryFirestore } from './support/inMemoryFirestore';

const testEnv = firebaseFunctionsTest({ projectId: 'in-memory-test' });
const callableContext = { app: { appId: 'test-app-check' } };

test('getPublicPaymentLink returns only sanitized public fields', async () => {
  const inMemory = new InMemoryFirestore();
  installInMemoryFirestore(inMemory);
  const token = 'a'.repeat(48);
  inMemory.seed(`publicPaymentLinks/${token}`, {
    facilityId: 'facility-secret',
    tenantId: 'tenant-secret',
    amount: 42.5,
    description: 'July balance',
    status: 'pending',
    token,
    createdBy: 'staff-secret',
    paymentIntentId: 'pi_secret',
    createdAt: Timestamp.fromDate(new Date('2026-07-01T00:00:00.000Z')),
    expiresAt: Timestamp.fromDate(new Date('2099-08-01T00:00:00.000Z')),
  });

  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { getPublicPaymentLink } =
    require('../publicPaymentCheckout') as typeof import('../publicPaymentCheckout');
  const invoke = testEnv.wrap(getPublicPaymentLink);
  const result = await invoke({ token }, callableContext) as Record<string, any>;
  const paymentLink = result.paymentLink as Record<string, unknown>;

  assert.equal(result.found, true);
  assert.deepEqual(Object.keys(paymentLink).sort(), [
    'amount',
    'createdAt',
    'description',
    'expiresAt',
    'status',
    'token',
  ]);
  assert.equal(paymentLink.amount, 42.5);
  assert.equal(paymentLink.description, 'July balance');
  assert.equal(paymentLink.tenantId, undefined);
  assert.equal(paymentLink.createdBy, undefined);
  assert.equal(paymentLink.paymentIntentId, undefined);
});

test('transitionPublicReservationStatus rejects an invalid move-in token', async () => {
  const inMemory = new InMemoryFirestore();
  installInMemoryFirestore(inMemory);
  const reservationId = 'reservation-1';
  const moveInToken = 'b'.repeat(48);
  inMemory.seed(`publicReservations/${reservationId}`, {
    facilityId: 'facility-1',
    status: 'pending',
    moveInToken,
  });

  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { transitionPublicReservationStatus } =
    require('../publicMoveIn') as typeof import('../publicMoveIn');
  const invoke = testEnv.wrap(transitionPublicReservationStatus);

  await assert.rejects(
    () =>
      invoke(
        {
          reservationId,
          moveInToken: 'c'.repeat(48),
          status: 'cancelled',
        },
        callableContext,
      ),
    (error: unknown) => {
      assert.equal((error as { code?: string }).code, 'permission-denied');
      return true;
    },
  );
  assert.equal(inMemory.read(`publicReservations/${reservationId}`)?.status, 'pending');
});

test('transitionPublicReservationStatus only permits cancellation', async () => {
  const inMemory = new InMemoryFirestore();
  installInMemoryFirestore(inMemory);
  const reservationId = 'reservation-2';
  const moveInToken = 'd'.repeat(48);
  inMemory.seed(`publicReservations/${reservationId}`, {
    facilityId: 'facility-1',
    status: 'pending',
    moveInToken,
  });

  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { transitionPublicReservationStatus } =
    require('../publicMoveIn') as typeof import('../publicMoveIn');
  const invoke = testEnv.wrap(transitionPublicReservationStatus);

  await assert.rejects(
    () =>
      invoke(
        {
          reservationId,
          moveInToken,
          status: 'completed',
        },
        callableContext,
      ),
    (error: unknown) => {
      assert.equal((error as { code?: string }).code, 'invalid-argument');
      return true;
    },
  );

  const result = await invoke(
    {
      reservationId,
      moveInToken,
      status: 'cancelled',
    },
    callableContext,
  ) as Record<string, unknown>;
  assert.equal(result.status, 'cancelled');
  assert.equal(inMemory.read(`publicReservations/${reservationId}`)?.status, 'cancelled');
});

test.after(() => {
  testEnv.cleanup();
});

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  buildStripeEventProcessedFields,
  isStripeEventAlreadyProcessed,
  shouldCheckStripeEventIdempotency,
  STRIPE_WEBHOOK_EVENTS_COLLECTION,
} from '../stripeWebhookIdempotencyHelpers';
import {
  duplicatePaymentWindowStartMs,
  DUPLICATE_PAYMENT_WINDOW_MS,
  shouldRejectDuplicatePayment,
} from '../stripeFacilityProcessPaymentDuplicateCheckHelpers';

test('shouldCheckStripeEventIdempotency requires non-empty event id', () => {
  assert.equal(shouldCheckStripeEventIdempotency(''), false);
  assert.equal(shouldCheckStripeEventIdempotency('evt_123'), true);
});

test('isStripeEventAlreadyProcessed reflects document existence', () => {
  assert.equal(isStripeEventAlreadyProcessed(true), true);
  assert.equal(isStripeEventAlreadyProcessed(false), false);
});

test('buildStripeEventProcessedFields normalizes optional metadata', () => {
  assert.deepEqual(
    buildStripeEventProcessedFields('payment_intent.succeeded', 'acct_1', 'fac1', 'ten1'),
    {
      eventType: 'payment_intent.succeeded',
      account: 'acct_1',
      facilityId: 'fac1',
      tenantId: 'ten1',
    },
  );
  assert.deepEqual(buildStripeEventProcessedFields('ping'), {
    eventType: 'ping',
    account: null,
    facilityId: null,
    tenantId: null,
  });
});

test('STRIPE_WEBHOOK_EVENTS_COLLECTION remains stable', () => {
  assert.equal(STRIPE_WEBHOOK_EVENTS_COLLECTION, 'stripeWebhookEvents');
});

test('duplicatePaymentWindowStartMs uses five minute window', () => {
  const nowMs = 1_700_000_000_000;
  assert.equal(
    duplicatePaymentWindowStartMs(nowMs),
    nowMs - DUPLICATE_PAYMENT_WINDOW_MS,
  );
});

test('shouldRejectDuplicatePayment is true only when a match exists', () => {
  assert.equal(shouldRejectDuplicatePayment(true), true);
  assert.equal(shouldRejectDuplicatePayment(false), false);
});

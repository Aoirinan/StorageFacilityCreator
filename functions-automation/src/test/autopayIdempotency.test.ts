import test from 'node:test';
import assert from 'node:assert/strict';
import { autopayIdempotencyKey, hasLedgerEntryForPayment } from '../autopayIdempotency';

const base = {
  facilityId: 'fac1',
  tenantId: 'ten1',
  paymentMethodDocId: 'pm1',
  scheduledRun: new Date('2026-09-01T00:00:00.000Z'),
  amountCents: 4500,
};

test('the same scheduled run produces the same key, so a retry cannot double charge', () => {
  // This is the whole point: the worker died after charging but before writing
  // the ledger, so tonight it tries again for the same scheduled run.
  assert.equal(autopayIdempotencyKey(base), autopayIdempotencyKey({ ...base }));
});

test('the key is keyed on the scheduled run, not the day of the attempt', () => {
  // Retrying tomorrow for the same September 1 run must reuse the key.
  const attemptedLater = { ...base, scheduledRun: new Date('2026-09-01T23:59:00.000Z') };
  assert.equal(autopayIdempotencyKey(base), autopayIdempotencyKey(attemptedLater));
});

test('a different month charges normally', () => {
  const october = { ...base, scheduledRun: new Date('2026-10-01T00:00:00.000Z') };
  assert.notEqual(autopayIdempotencyKey(base), autopayIdempotencyKey(october));
});

test('a changed balance is a different charge', () => {
  // Reusing a key with different parameters is rejected by Stripe, so the
  // amount must be part of the key rather than silently billing the old total.
  assert.notEqual(autopayIdempotencyKey(base), autopayIdempotencyKey({ ...base, amountCents: 5000 }));
});

test('tenants and facilities never share a key', () => {
  assert.notEqual(autopayIdempotencyKey(base), autopayIdempotencyKey({ ...base, tenantId: 'ten2' }));
  assert.notEqual(autopayIdempotencyKey(base), autopayIdempotencyKey({ ...base, facilityId: 'fac2' }));
  assert.notEqual(
    autopayIdempotencyKey(base),
    autopayIdempotencyKey({ ...base, paymentMethodDocId: 'pm2' }),
  );
});

test('a missing scheduled run does not collapse everyone onto one key', () => {
  const a = autopayIdempotencyKey({ ...base, scheduledRun: null });
  const b = autopayIdempotencyKey({ ...base, scheduledRun: null, tenantId: 'ten2' });
  assert.notEqual(a, b);
});

// --- ledger guard -----------------------------------------------------------

test('an existing ledger entry for the payment is detected', () => {
  // Without this, a retry that receives the original PaymentIntent back would
  // write a second payment entry — a double credit for one charge.
  const entries = [{ referenceId: 'pi_123' }, { referenceId: 'pi_456' }];
  assert.equal(hasLedgerEntryForPayment(entries, 'pi_123'), true);
  assert.equal(hasLedgerEntryForPayment(entries, 'pi_789'), false);
});

test('the ledger guard tolerates missing or malformed entries', () => {
  assert.equal(hasLedgerEntryForPayment([{}, { referenceId: null }], 'pi_1'), false);
  assert.equal(hasLedgerEntryForPayment([], 'pi_1'), false);
  assert.equal(hasLedgerEntryForPayment([{ referenceId: 'pi_1' }], ''), false);
});

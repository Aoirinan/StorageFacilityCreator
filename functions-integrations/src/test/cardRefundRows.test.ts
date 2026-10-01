import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';

import { refundChargeId, refundIdempotencyKey, refundRequestId } from '../stripeFacilityProcessRefund';
import { refundRowOwner } from '../stripeWebhookChargeRefunded';

/**
 * The move-out screen now refunds a card through processRefund. Two things
 * stood in the way of that refund landing once, on the right tenant:
 * processRefund asked Stripe to expand a PaymentIntent's `charges`, which
 * the pinned API version no longer has, and the charge.refunded webhook
 * merged tenantId null over the row processRefund had written for a
 * payment whose PaymentIntent names no tenant (an online move-in's).
 *
 * Invented ids throughout: this repository is public.
 */

test("the refund goes against the PaymentIntent's latest_charge, id or expanded", () => {
  assert.equal(refundChargeId({ latest_charge: 'ch_test_1' }), 'ch_test_1');
  assert.equal(refundChargeId({ latest_charge: { id: 'ch_test_2' } }), 'ch_test_2');
  // An older API version's charges list is still read.
  assert.equal(refundChargeId({ charges: { data: [{ id: 'ch_test_3' }] } }), 'ch_test_3');
  assert.equal(refundChargeId({ latest_charge: null }), null);
  assert.equal(refundChargeId({ latest_charge: '' }), null);
  assert.equal(refundChargeId(null), null);
});

test("processRefund no longer asks Stripe to expand 'charges'", () => {
  const source = readFileSync(path.join(__dirname, '..', '..', 'src', 'stripeFacilityProcessRefund.ts'), 'utf8');
  assert.doesNotMatch(source, /expand:\s*\[\s*'charges'\s*\]/);
  assert.match(source, /const chargeId = refundChargeId\(paymentIntent\);/);
});

test("the webhook keeps the tenant processRefund wrote when the PaymentIntent names none", () => {
  // processRefund's row for an online move-in payment: the PaymentIntent
  // carries facilityId and reservationId, no tenantId.
  const written = { tenantId: 'tenant-a', referenceId: 'pi_test_1', createdBy: 'owner-uid' };
  assert.deepEqual(refundRowOwner(written, { tenantId: undefined, referenceId: null }), {
    tenantId: 'tenant-a',
    referenceId: 'pi_test_1',
    createdBy: 'owner-uid',
  });
  // A PaymentIntent that names its tenant (autopay, the portal) still wins,
  // and a payments doc found for it becomes the reference.
  assert.deepEqual(refundRowOwner(written, { tenantId: 'tenant-a', referenceId: 'payment-doc-1' }), {
    tenantId: 'tenant-a',
    referenceId: 'payment-doc-1',
    createdBy: 'owner-uid',
  });
});

test('a refund made in the Stripe dashboard (no row yet) is written as before', () => {
  assert.deepEqual(refundRowOwner(undefined, { tenantId: 'tenant-b', referenceId: null }), {
    tenantId: 'tenant-b',
    referenceId: null,
    createdBy: 'system@stripe-webhook',
  });
  assert.deepEqual(refundRowOwner(undefined, { tenantId: undefined, referenceId: null }), {
    tenantId: null,
    referenceId: null,
    createdBy: 'system@stripe-webhook',
  });
  // A row the webhook wrote on an earlier delivery keeps nothing it lacked.
  assert.deepEqual(
    refundRowOwner({ tenantId: null, referenceId: null, createdBy: 'system@stripe-webhook' }, { tenantId: '', referenceId: null }),
    { tenantId: null, referenceId: null, createdBy: 'system@stripe-webhook' },
  );
});

test("the move-out screen's request id is accepted, and keys each move-out's refund apart", () => {
  // MoveOutCardRefund.requestId: mo_<contract>_<PaymentIntent>.
  const unitA = refundRequestId('mo_contractTestA00000001_pi_test_0000000000000001');
  const unitB = refundRequestId('mo_contractTestB00000002_pi_test_0000000000000001');
  assert.equal(unitA, 'mo_contractTestA00000001_pi_test_0000000000000001');
  assert.ok(unitB);
  // A tenant moved out of two units at the same rate on the same day, both
  // refunded by card against one payment: same charge, same amount. Keyed
  // on charge and amount alone, Stripe handed the second call the first
  // refund back and nothing more was refunded.
  assert.notEqual(refundIdempotencyKey('ch_test_1', 3667, unitA), refundIdempotencyKey('ch_test_1', 3667, unitB));
  // A retry of one move-out's refund (same id) is the same refund.
  assert.equal(refundIdempotencyKey('ch_test_1', 3667, unitA), refundIdempotencyKey('ch_test_1', 3667, unitA));
  assert.equal(
    refundIdempotencyKey('ch_test_1', 3667, unitA),
    'refund_ch_test_1_3667_mo_contractTestA00000001_pi_test_0000000000000001',
  );
  // Within Stripe's 255-character limit at the longest id the screen sends.
  assert.ok(refundIdempotencyKey(`ch_${'x'.repeat(40)}`, 99999999, 'm'.repeat(64)).length <= 255);
});

test('a caller with no usable request id keeps the charge-and-amount key', () => {
  assert.equal(refundIdempotencyKey('ch_test_1', 1000, refundRequestId(undefined)), 'refund_ch_test_1_1000');
  for (const bad of ['', 'short', '../bad key', 'x'.repeat(65), 12345678, null]) {
    assert.equal(refundRequestId(bad), null, String(bad));
  }
});

test('the charge.refunded webhook creates the row, else fills in only what it lacks', () => {
  const source = readFileSync(path.join(__dirname, '..', '..', 'src', 'stripeWebhookChargeRefunded.ts'), 'utf8');
  assert.match(source, /await ledgerRef\.create\(/);
  // No merge over the whole row: that wrote tenantId null over the tenant
  // processRefund refunded, whichever wrote first.
  assert.doesNotMatch(source, /ledgerRef\.set\(/);
  assert.match(source, /if \(!hasText\(existingData\[key\]\) && owner\[key\] !== null\) update\[key\] = owner\[key\];/);
});

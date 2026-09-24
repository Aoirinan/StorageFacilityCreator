import test from 'node:test';
import assert from 'node:assert/strict';

import { MAX_SPLIT_TOTAL_CENTS, applyPayment, paymentStatusOf, splitProRata, splitTaxProRata } from '../stays/folio';

// A folio of $508.73 with $18.73 of pass-through tax (see staysQuote.test.ts).
const folio = { totalCents: 50_873, taxCents: 1_873, paidCents: 0, balanceCents: 50_873 };

test('applyPayment moves paid and balance, and returns a new folio', () => {
  const paid = applyPayment(folio, 20_000);
  assert.deepEqual([paid.paidCents, paid.balanceCents], [20_000, 30_873]);
  assert.equal(folio.paidCents, 0);
  const refunded = applyPayment(paid, -5_000);
  assert.deepEqual([refunded.paidCents, refunded.balanceCents], [15_000, 35_873]);
  assert.throws(() => applyPayment(folio, 10.5));
});

test('a payment in full carries all of the tax', () => {
  assert.deepEqual(splitTaxProRata(50_873, folio), { taxCents: 1_873, netCents: 49_000 });
});

test('instalments carry exactly the tax between them, rounded half-up on the running total', () => {
  // 200.00 of 508.73 → 18.73 × 200/508.73 = 7.3634 → 7.36; the rest carries 18.73 − 7.36.
  const first = splitTaxProRata(20_000, folio);
  assert.deepEqual(first, { taxCents: 736, netCents: 19_264 });
  const second = splitTaxProRata(30_873, { ...folio, paidCents: 20_000 });
  assert.deepEqual(second, { taxCents: 1_137, netCents: 29_736 });
  assert.equal(first.taxCents + second.taxCents, folio.taxCents);

  // Many small payments still add up to the tax to the cent.
  let paid = 0;
  let tax = 0;
  for (const amount of [1, 999, 3_333, 3_333, 3_334, 10_000, 29_873]) {
    tax += splitTaxProRata(amount, { ...folio, paidCents: paid }).taxCents;
    paid += amount;
  }
  assert.equal(paid, folio.totalCents);
  assert.equal(tax, folio.taxCents);
});

test('money past the total carries no tax, and a refund carries its share back', () => {
  assert.equal(splitTaxProRata(5_000, { ...folio, paidCents: 50_873 }).taxCents, 0);
  assert.equal(splitTaxProRata(-50_873, { ...folio, paidCents: 50_873 }).taxCents, -1_873);
  assert.deepEqual(splitTaxProRata(-20_000, { ...folio, paidCents: 20_000 }), { taxCents: -736, netCents: -19_264 });
});

test('no tax, no total, or a zero part carries nothing', () => {
  assert.equal(splitTaxProRata(1_000, { totalCents: 1_000, taxCents: 0, paidCents: 0 }).taxCents, 0);
  assert.equal(splitTaxProRata(1_000, { totalCents: 0, taxCents: 0, paidCents: 0 }).taxCents, 0);
  assert.equal(splitProRata(1_000, 0, 5_000, 0), 0);
  // A half cent rounds up: 1 of 2 cents with a 1-cent part → 0.5 → 1.
  assert.equal(splitProRata(1, 1, 2, 0), 1);
  assert.equal(splitProRata(1, 1, 2, 1), 0);
  assert.throws(() => splitProRata(1, 1, MAX_SPLIT_TOTAL_CENTS + 1, 0));
  assert.throws(() => splitProRata(1.5, 1, 100, 0));
});

test('the payment chip follows the folio, the source and the kind', () => {
  const direct = { kind: 'reservation' as const, source: 'walk_up' as const, status: 'confirmed' as const };
  const f = (paidCents: number, totalCents = 10_000) => ({ paidCents, totalCents });
  assert.equal(paymentStatusOf(f(0), direct), 'due');
  assert.equal(paymentStatusOf(f(4_000), direct), 'partial');
  assert.equal(paymentStatusOf(f(10_000), direct), 'paid');
  assert.equal(paymentStatusOf(f(12_000), direct), 'paid');
  assert.equal(paymentStatusOf(f(0, 0), direct), 'none');
  assert.equal(paymentStatusOf(f(500, 0), direct), 'paid');
  assert.equal(paymentStatusOf(f(0), direct, { refunded: true }), 'refunded');
  // A cancelled booking owes nothing more.
  assert.equal(paymentStatusOf(f(0), { ...direct, status: 'cancelled' }), 'none');
  assert.equal(paymentStatusOf(null, direct), 'none');
  // Airbnb and the other channels collect the money; blocks have none.
  assert.equal(paymentStatusOf(f(0), { ...direct, source: 'airbnb' }), 'channel_collected');
  assert.equal(paymentStatusOf(null, { ...direct, source: 'vrbo' }), 'channel_collected');
  assert.equal(paymentStatusOf(f(0), { kind: 'owner_block', source: 'owner', status: 'confirmed' }), 'none');
});

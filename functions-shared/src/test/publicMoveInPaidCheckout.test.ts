/**
 * The rules a paid online move-in checkout is recorded by, shared by the
 * Connect webhook (functions-integrations) and the move-in page's
 * confirmation and sweep (functions-public-website). Their Firestore
 * behaviour is tested in both packages against in-memory stores; these are
 * the pure rules. All data is invented.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import * as admin from 'firebase-admin';

import {
  CHECKOUT_PAID_FIELD,
  CHECKOUT_SESSION_EXPIRES_FIELD,
  PAID_HOLD_MAX_HOURS,
  UNTENANTED_DISPUTES_FIELD,
  UNTENANTED_REFUNDS_FIELD,
  holderMayBePaying,
  laterExpiry,
  moveInPaymentReturnedBeforeMoveIn,
  paidHoldCap,
  recordPaidPublicMoveInCheckout,
} from '../units/publicMoveInPaidCheckout';
import * as shared from '../index';

const HOUR = 60 * 60 * 1000;
const ts = (ms: number) => admin.firestore.Timestamp.fromMillis(ms);

test('a paid renter keeps the unit at most a day after paying', () => {
  assert.equal(PAID_HOLD_MAX_HOURS, 24);
  const paidAt = new Date('2026-09-30T10:00:00Z');
  assert.equal(paidHoldCap(paidAt).toISOString(), '2026-10-01T10:00:00.000Z');
});

test('a holder who has paid counts as paying however long ago their checkout started', () => {
  const now = Date.now();
  // Checkout began 25 hours ago; the payment is recorded. Its hold ends a
  // day after the payment, and only a live hold is asked about.
  const holder = { status: 'pending', checkoutUpdatedAt: ts(now - 25 * HOUR), [CHECKOUT_PAID_FIELD]: 'pi_paid' };
  assert.equal(holderMayBePaying(holder, new Date(now)), true);
});

test('a holder who has not paid counts only while their Checkout page may take payment', () => {
  const now = Date.now();
  const started = { status: 'pending', checkoutUpdatedAt: ts(now - 10 * 60 * 1000) };
  assert.equal(holderMayBePaying({ ...started, [CHECKOUT_SESSION_EXPIRES_FIELD]: ts(now + 60_000) }, new Date(now)), true);
  assert.equal(holderMayBePaying({ ...started, [CHECKOUT_SESSION_EXPIRES_FIELD]: ts(now - 60_000) }, new Date(now)), false);
  assert.equal(holderMayBePaying({ status: 'pending' }, new Date(now)), false);
  assert.equal(holderMayBePaying({ ...started, status: 'cancelled', [CHECKOUT_PAID_FIELD]: 'pi_paid' }, new Date(now)), false);
  assert.equal(holderMayBePaying(undefined, new Date(now)), false);
});

test('an extension never shortens a hold', () => {
  const later = new Date('2026-10-01T10:00:00Z');
  const sooner = new Date('2026-09-30T10:00:00Z');
  assert.equal(laterExpiry(ts(later.getTime()), sooner).getTime(), later.getTime());
  assert.equal(laterExpiry(ts(sooner.getTime()), later).getTime(), later.getTime());
  assert.equal(laterExpiry(undefined, sooner).getTime(), sooner.getTime());
});

test('ids that are not one path segment record nothing, before Firestore is touched', async () => {
  const untouched = new Proxy({}, {
    get: () => {
      throw new Error('Firestore must not be used');
    },
  }) as unknown as admin.firestore.Firestore;
  const base = {
    paymentIntentId: 'pi_1',
    checkoutSessionId: 'cs_1',
    reservationId: 'res_1',
    facilityId: 'fac_1',
    connectAccountId: 'acct_1',
    amountCents: 100,
    paidAt: new Date(),
    now: new Date(),
    holdMinutes: 'until-cap' as const,
    recordedBy: 'test',
  };
  for (const bad of [{ paymentIntentId: 'pi/1' }, { reservationId: '' }, { facilityId: 'a/b' }, { connectAccountId: ' ' }]) {
    assert.equal(await recordPaidPublicMoveInCheckout(untouched, { ...base, ...bad }), 'not-this-facility');
  }
});

test('the paid-checkout rules are exported for the webhook and the move-in codebase', () => {
  for (const name of [
    'recordPaidPublicMoveInCheckout',
    'holderMayBePaying',
    'paidHoldCap',
    'PUBLIC_MOVE_IN_PAID_CHECKOUTS_COLLECTION',
    'PUBLIC_MOVE_IN_PAYMENTS_COLLECTION',
    'UNTENANTED_REFUNDS_FIELD',
    'UNTENANTED_DISPUTES_FIELD',
    'moveInPaymentReturnedBeforeMoveIn',
  ]) {
    assert.ok(name in shared, name);
  }
});

test('a use record that holds only a Stripe refund or dispute made before any move-in was returned, not used', () => {
  // What the Connect webhook writes (functions-integrations moveInPaymentTenant.ts).
  const refunds = { [UNTENANTED_REFUNDS_FIELD]: { re_1: { amountCents: 1000 } } };
  const disputes = { [UNTENANTED_DISPUTES_FIELD]: { du_1: { amountCents: 2500 } } };
  assert.equal(moveInPaymentReturnedBeforeMoveIn({ paymentIntentId: 'pi_1', ...refunds }), true);
  assert.equal(moveInPaymentReturnedBeforeMoveIn({ paymentIntentId: 'pi_1', ...disputes }), true);
  assert.equal(moveInPaymentReturnedBeforeMoveIn({ ...refunds, tenantId: null }), true);

  // It moved a tenant in.
  assert.equal(moveInPaymentReturnedBeforeMoveIn({ ...refunds, tenantId: 't1' }), false);
  // The move-in's own refund (paidMoveInRefund.ts) is 'refunded', as before.
  assert.equal(moveInPaymentReturnedBeforeMoveIn({ ...refunds, refund: { status: 'pending' } }), false);
  // Nothing recorded.
  assert.equal(moveInPaymentReturnedBeforeMoveIn({ [UNTENANTED_REFUNDS_FIELD]: {} }), false);
  assert.equal(moveInPaymentReturnedBeforeMoveIn({ tenantId: 't1', contractId: 'c1' }), false);
  assert.equal(moveInPaymentReturnedBeforeMoveIn(undefined), false);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  isPublicMoveInCheckoutSession,
  paidPublicMoveInCheckoutFromSession,
} from '../stripe/publicMoveInCheckout';

/** A move-in Checkout Session as the connected account's checkout.session.completed carries it. */
function moveInSession(overrides: Record<string, unknown> = {}) {
  return {
    id: 'cs_move_in',
    metadata: {
      type: 'public_move_in',
      reservationId: 'res-1',
      moveInToken: 'token-not-copied',
      facilityId: 'fac-1',
    },
    payment_status: 'paid',
    payment_intent: 'pi_move_in',
    amount_total: 12345,
    currency: 'usd',
    livemode: true,
    ...overrides,
  } as unknown as Parameters<typeof paidPublicMoveInCheckoutFromSession>[0];
}

test('a paid move-in session becomes a record naming its reservation, account and payment', () => {
  const result = paidPublicMoveInCheckoutFromSession(moveInSession(), 'acct_facility', 'evt_1');

  assert.deepEqual(result, {
    record: {
      checkoutSessionId: 'cs_move_in',
      reservationId: 'res-1',
      facilityId: 'fac-1',
      connectedAccountId: 'acct_facility',
      paymentIntentId: 'pi_move_in',
      amountTotalCents: 12345,
      currency: 'usd',
      livemode: true,
      stripeEventId: 'evt_1',
      status: 'paid',
    },
  });
  // The renter's token stays with the session.
  assert.equal(JSON.stringify(result).includes('token-not-copied'), false);
});

test('an expanded payment intent is read by its id', () => {
  const result = paidPublicMoveInCheckoutFromSession(
    moveInSession({ payment_intent: { id: 'pi_expanded' } }),
    'acct_facility',
    'evt_1',
  );
  assert.equal('record' in result && result.record.paymentIntentId, 'pi_expanded');
});

test('only sessions created for an online move-in are move-in sessions', () => {
  assert.equal(isPublicMoveInCheckoutSession(moveInSession()), true);
  // Platform subscription checkouts carry an accountId and no type.
  assert.equal(isPublicMoveInCheckoutSession({ metadata: { accountId: 'a', facilityId: 'f' } } as never), false);
  assert.equal(isPublicMoveInCheckoutSession({ metadata: null } as never), false);
});

for (const [why, session, account] of [
  ['it is not a move-in checkout', moveInSession({ metadata: { accountId: 'a', facilityId: 'f' } }), 'acct_facility'],
  ['the event names no connected account', moveInSession(), undefined],
  ['it names no reservation', moveInSession({ metadata: { type: 'public_move_in', facilityId: 'fac-1' } }), 'acct_facility'],
  ['it names no facility', moveInSession({ metadata: { type: 'public_move_in', reservationId: 'res-1' } }), 'acct_facility'],
  ['it is not paid', moveInSession({ payment_status: 'unpaid' }), 'acct_facility'],
  ['it has no payment intent', moveInSession({ payment_intent: null }), 'acct_facility'],
] as Array<[string, ReturnType<typeof moveInSession>, string | undefined]>) {
  test(`no record when ${why}`, () => {
    const result = paidPublicMoveInCheckoutFromSession(session, account, 'evt_1');
    assert.ok('ignored' in result, JSON.stringify(result));
  });
}

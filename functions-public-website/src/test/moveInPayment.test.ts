import test from 'node:test';
import assert from 'node:assert/strict';
import { resolveMoveInPaymentStripeAccountId } from '../moveInPayment';

test('resolveMoveInPaymentStripeAccountId uses facility Connect account', () => {
  assert.equal(
    resolveMoveInPaymentStripeAccountId({ stripeConnectAccountId: 'acct_123' }),
    'acct_123',
  );
  assert.equal(resolveMoveInPaymentStripeAccountId({}), undefined);
  assert.equal(
    resolveMoveInPaymentStripeAccountId({ stripeConnectAccountId: '  ' }),
    undefined,
  );
});

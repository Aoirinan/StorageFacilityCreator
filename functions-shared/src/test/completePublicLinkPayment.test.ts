import test from 'node:test';
import assert from 'node:assert/strict';
import { Timestamp } from 'firebase-admin/firestore';
import {
  buildPublicLinkPaymentIntentMetadata,
  completePublicLinkPayment,
  isPublicLinkCheckoutSession,
  isPublicLinkPaymentIntent,
  publicLinkNotificationId,
  PublicLinkCheckoutSessionLike,
} from '../stripe/completePublicLinkPayment';
import { FakeFirestore } from '../testing/fakeFirestore';

const TOKEN = 'a'.repeat(48);
const ACCOUNT = 'acct_facility1';
const LINK_PATH = `publicPaymentLinks/${TOKEN}`;

function seed(fake: FakeFirestore, link: Record<string, unknown> = {}): void {
  fake.seed('facilities/f1', { name: 'Test Storage', stripeConnectAccountId: ACCOUNT });
  fake.seed('facilities/f1/tenants/t1', { name: 'Pat Tenant' });
  fake.seed(LINK_PATH, {
    facilityId: 'f1',
    tenantId: 't1',
    amount: 125.5,
    description: 'September rent',
    token: TOKEN,
    status: 'pending',
    paymentIntentId: null,
    paidAt: null,
    checkoutSessionIds: ['cs_1', 'cs_2'],
    checkoutSessionId: 'cs_1',
    expiresAt: Timestamp.fromDate(new Date('2099-01-01T00:00:00Z')),
    ...link,
  });
}

function session(overrides: Partial<PublicLinkCheckoutSessionLike> = {}): PublicLinkCheckoutSessionLike {
  return {
    id: 'cs_1',
    payment_status: 'paid',
    amount_total: 12550,
    currency: 'usd',
    payment_intent: 'pi_1',
    livemode: false,
    metadata: {
      facilityId: 'f1',
      tenantId: 't1',
      type: 'public_payment_link',
      paymentLinkToken: TOKEN,
    },
    ...overrides,
  };
}

function complete(fake: FakeFirestore, s: PublicLinkCheckoutSessionLike, account: string | null = ACCOUNT, source: 'webhook' | 'confirm' | 'checkout' = 'webhook') {
  return completePublicLinkPayment({ db: fake.firestore(), session: s, connectedAccountId: account, source });
}

function assertNoMoneyWrites(fake: FakeFirestore): void {
  // The payment_intent.succeeded handler is the only writer of money records.
  assert.deepEqual(fake.writesTo('facilities/f1/payments'), []);
  assert.deepEqual(fake.writesTo('facilities/f1/ledgers'), []);
}

test('PaymentIntent metadata carries what the payment handler keys on', () => {
  assert.deepEqual(buildPublicLinkPaymentIntentMetadata('f1', 't1', TOKEN), {
    facilityId: 'f1',
    tenantId: 't1',
    type: 'public_payment_link',
    paymentLinkToken: TOKEN,
    sfcKind: 'tenant_link',
  });
  assert.equal(isPublicLinkPaymentIntent({ metadata: buildPublicLinkPaymentIntentMetadata('f1', 't1', TOKEN) }), true);
  assert.equal(isPublicLinkPaymentIntent({ metadata: { facilityId: 'f1', tenantId: 't1' } }), false);
  assert.equal(isPublicLinkCheckoutSession(session()), true);
  assert.equal(isPublicLinkCheckoutSession({ metadata: { accountId: 'x' } }), false);
});

test('a paid session marks a pending link paid, once, and writes no money records', async () => {
  const fake = new FakeFirestore();
  seed(fake);

  const result = await complete(fake, session());

  assert.deepEqual(result, { outcome: 'marked_paid', linkStatus: 'paid' });
  const link = fake.read(LINK_PATH)!;
  assert.equal(link.status, 'paid');
  assert.equal(link.paymentIntentId, 'pi_1');
  assert.equal(link.checkoutSessionId, 'cs_1');
  assert.equal(link.paidVia, 'webhook');
  assert.equal(link.amountPaidCents, 12550);
  assert.ok(link.paidAt instanceof Timestamp);
  assert.deepEqual(fake.list('publicPaymentLinkExceptions'), []);
  assert.deepEqual(fake.list('facilities/f1/Notifications'), []);
  assertNoMoneyWrites(fake);
});

test('redelivery of the same paid session changes nothing', async () => {
  const fake = new FakeFirestore();
  seed(fake);
  await complete(fake, session());
  const writesAfterFirst = fake.writes.length;
  const linkAfterFirst = fake.read(LINK_PATH);

  const again = await complete(fake, session(), ACCOUNT, 'confirm');
  const third = await complete(fake, session(), ACCOUNT, 'checkout');

  assert.equal(again.outcome, 'already_paid');
  assert.equal(third.outcome, 'already_paid');
  assert.equal(fake.writes.length, writesAfterFirst);
  assert.deepEqual(fake.read(LINK_PATH), linkAfterFirst);
});

test('the success-page confirm racing the webhook marks the link paid exactly once', async () => {
  const fake = new FakeFirestore();
  seed(fake);

  const results = await Promise.all([
    complete(fake, session(), ACCOUNT, 'webhook'),
    complete(fake, session(), ACCOUNT, 'confirm'),
    complete(fake, session(), ACCOUNT, 'checkout'),
  ]);

  const outcomes = results.map((r) => r.outcome).sort();
  assert.deepEqual(outcomes, ['already_paid', 'already_paid', 'marked_paid']);
  assert.equal(fake.writesTo(LINK_PATH).length, 1);
  assert.ok(fake.transactionConflicts >= 1, 'the losers should have retried on a conflict');
  assert.deepEqual(fake.list('publicPaymentLinkExceptions'), []);
  assertNoMoneyWrites(fake);
});

test('a second paid session on a paid link raises one exception and never touches the link', async () => {
  const fake = new FakeFirestore();
  seed(fake);
  await complete(fake, session());
  const linkAfterFirst = fake.read(LINK_PATH);

  const second = session({ id: 'cs_2', payment_intent: 'pi_2' });
  const result = await complete(fake, second);
  // Webhook and success page both report the second payment.
  const redelivered = await complete(fake, second, ACCOUNT, 'confirm');

  assert.deepEqual(result, { outcome: 'exception', linkStatus: 'paid', exceptionReason: 'duplicate_payment' });
  assert.equal(redelivered.outcome, 'exception');
  assert.deepEqual(fake.read(LINK_PATH), linkAfterFirst);
  assert.deepEqual(fake.list('publicPaymentLinkExceptions'), ['cs_2']);
  const exception = fake.read('publicPaymentLinkExceptions/cs_2')!;
  assert.equal(exception.reason, 'duplicate_payment');
  assert.equal(exception.paymentIntentId, 'pi_2');
  assert.equal(exception.linkPaymentIntentId, 'pi_1');
  assert.equal(exception.facilityId, 'f1');
  assert.equal(exception.resolution, 'open');
  assert.equal(fake.writesTo('publicPaymentLinkExceptions/cs_2').length, 1);
  const notification = fake.read(`facilities/f1/Notifications/${publicLinkNotificationId('cs_2')}`)!;
  assert.equal(notification.type, 'STRIPE_ACTION_REQUIRED');
  assert.equal(notification.tenantName, 'Pat Tenant');
  assert.equal(notification.readAt, null);
  assert.match(String(notification.message), /paid twice/);
  assert.match(String(notification.message), /refund one in Stripe/);
  assert.equal(fake.list('facilities/f1/Notifications').length, 1);
  assertNoMoneyWrites(fake);
});

test('two different sessions paid at the same moment: one pays the link, the other is an exception', async () => {
  const fake = new FakeFirestore();
  seed(fake);

  const results = await Promise.all([
    complete(fake, session()),
    complete(fake, session({ id: 'cs_2', payment_intent: 'pi_2' })),
  ]);

  const outcomes = results.map((r) => r.outcome).sort();
  assert.deepEqual(outcomes, ['exception', 'marked_paid']);
  const link = fake.read(LINK_PATH)!;
  assert.equal(link.status, 'paid');
  assert.equal(fake.writesTo(LINK_PATH).length, 1);
  const exceptions = fake.list('publicPaymentLinkExceptions');
  assert.equal(exceptions.length, 1);
  // The exception is for whichever session did not pay the link.
  assert.notEqual(exceptions[0], link.checkoutSessionId);
  assertNoMoneyWrites(fake);
});

test('a session read from any account but the facility connected account is rejected', async () => {
  const fake = new FakeFirestore();
  seed(fake);

  const wrongAccount = await complete(fake, session(), 'acct_someone_else');
  const platform = await complete(fake, session(), null);

  assert.equal(wrongAccount.outcome, 'rejected');
  assert.equal(wrongAccount.rejectReason, 'account_mismatch');
  assert.equal(platform.outcome, 'rejected');
  assert.equal(fake.read(LINK_PATH)!.status, 'pending');
  assert.equal(fake.writes.length, 0);
});

test('metadata that does not match the link is rejected', async () => {
  const fake = new FakeFirestore();
  seed(fake);

  const result = await complete(fake, session({
    metadata: { facilityId: 'f1', tenantId: 'someone-else', type: 'public_payment_link', paymentLinkToken: TOKEN },
  }));
  const unknownLink = await complete(fake, session({
    metadata: { facilityId: 'f1', tenantId: 't1', type: 'public_payment_link', paymentLinkToken: 'b'.repeat(48) },
  }));

  assert.equal(result.rejectReason, 'metadata_mismatch');
  assert.equal(unknownLink.rejectReason, 'link_not_found');
  assert.equal(fake.writes.length, 0);
});

test('an unpaid session writes nothing', async () => {
  const fake = new FakeFirestore();
  seed(fake);

  const result = await complete(fake, session({ payment_status: 'unpaid' }));

  assert.deepEqual(result, { outcome: 'not_paid', linkStatus: null });
  assert.equal(fake.writes.length, 0);
});

test('a payment on a revoked link is an exception and the link stays revoked', async () => {
  const fake = new FakeFirestore();
  seed(fake, { status: 'revoked' });

  const result = await complete(fake, session());

  assert.deepEqual(result, { outcome: 'exception', linkStatus: 'revoked', exceptionReason: 'paid_after_revoke' });
  assert.equal(fake.read(LINK_PATH)!.status, 'revoked');
  assert.equal(fake.read(LINK_PATH)!.paymentIntentId, null);
  assert.equal(fake.read('publicPaymentLinkExceptions/cs_1')!.reason, 'paid_after_revoke');
  assertNoMoneyWrites(fake);
});

test('a payment for the wrong amount is an exception and does not mark the link paid', async () => {
  const fake = new FakeFirestore();
  seed(fake);

  const result = await complete(fake, session({ amount_total: 100 }));

  assert.equal(result.exceptionReason, 'amount_mismatch');
  assert.equal(fake.read(LINK_PATH)!.status, 'pending');
  assert.equal(fake.read('publicPaymentLinkExceptions/cs_1')!.linkAmountCents, 12550);
});

test('a session the link never issued still pays it, and is flagged for a ledger check', async () => {
  const fake = new FakeFirestore();
  seed(fake, { checkoutSessionIds: [], checkoutSessionId: null });

  const result = await complete(fake, session({ id: 'cs_before_fix' }));

  assert.deepEqual(result, { outcome: 'marked_paid', linkStatus: 'paid', exceptionReason: 'untracked_session' });
  const link = fake.read(LINK_PATH)!;
  assert.equal(link.status, 'paid');
  assert.deepEqual(link.checkoutSessionIds, ['cs_before_fix']);
  assert.equal(fake.read('publicPaymentLinkExceptions/cs_before_fix')!.reason, 'untracked_session');
});

test('a pending link past its expiry is still marked paid by a session it issued', async () => {
  const fake = new FakeFirestore();
  seed(fake, { expiresAt: Timestamp.fromDate(new Date('2020-01-01T00:00:00Z')) });

  const result = await complete(fake, session());

  assert.equal(result.outcome, 'marked_paid');
  assert.deepEqual(fake.list('publicPaymentLinkExceptions'), []);
});

test('a Firestore failure propagates so the webhook is retried', async () => {
  const fake = new FakeFirestore();
  seed(fake);
  fake.beforeCommit = () => {
    throw new Error('UNAVAILABLE: transient');
  };

  await assert.rejects(() => complete(fake, session()), /UNAVAILABLE/);
  assert.equal(fake.read(LINK_PATH)!.status, 'pending');
});

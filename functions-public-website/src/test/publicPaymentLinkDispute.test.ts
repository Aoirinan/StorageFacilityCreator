/**
 * A payment link staff send to collect a card dispute by hand carries the
 * dispute's id through to the PaymentIntent, so the payment handler books it
 * against the dispute (ledger metadata.disputeId) and not as rent. Untagged,
 * autopay and the delinquency job treated next month's rent as paid.
 *
 * Runs the deployed createPublicPaymentLink callable and the checkout it
 * leads to against an in-memory Firestore.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { FakeFirestore, installFakeFirestore } from '@sfc/functions-shared/testing/fakeFirestore';
import { createPublicPaymentLink } from '../publicPaymentCheckout';
import { getOrCreatePublicLinkCheckout } from '../publicPaymentCheckoutSession';
import { FakeCheckoutSessions } from './support/fakeCheckoutSessions';

const OWNER = 'owner_uid';
const ACCOUNT = 'acct_facility1';

function setup() {
  const stripe = new FakeCheckoutSessions();
  const fake = new FakeFirestore();
  fake.now = () => stripe.now;
  installFakeFirestore(fake);
  fake.seed('facilities/f1', {
    name: 'Test Storage',
    ownerUid: OWNER,
    stripeConnectAccountId: ACCOUNT,
    stripeConnectOnboardingComplete: true,
  });
  fake.seed('facilities/f1/tenants/t1', { name: 'Pat Tenant', email: 'pat@example.test' });
  fake.seed('facilities/f1/tenants/t2', { name: 'Sam Other' });
  // What stripeWebhookDisputeCreated.ts posts for a lost dispute on t1's March payment.
  fake.seed('facilities/f1/ledgers/dispute_du_1', {
    tenantId: 't1',
    facilityId: 'f1',
    type: 'dispute',
    amount: 100,
    status: 'posted',
    metadata: { disputeId: 'du_1', paymentIntentId: 'pi_march' },
  });
  return { fake, stripe };
}

const create = (createPublicPaymentLink as unknown as {
  run: (data: unknown, context: unknown) => Promise<{ success: boolean; token: string }>;
}).run;
const staff = { auth: { uid: OWNER }, app: { appId: 'test' }, rawRequest: { ip: '127.0.0.1', headers: {} } };

test('a link sent for a dispute puts the dispute id on its PaymentIntent', async () => {
  const { fake, stripe } = setup();

  const { token } = await create(
    { facilityId: 'f1', tenantId: 't1', amount: 100, description: 'Card dispute', disputeId: 'du_1' },
    staff,
  );

  assert.equal(fake.read(`publicPaymentLinks/${token}`)!.disputeId, 'du_1');
  await getOrCreatePublicLinkCheckout(token, {
    db: fake.firestore(),
    sessions: stripe.api(),
    appUrl: 'https://app.example.test',
    now: () => stripe.now,
  });
  // Before: no disputeId, so the webhook's ledger row counted the payment as rent.
  assert.equal(stripe.createCalls[0].params.payment_intent_data?.metadata?.disputeId, 'du_1');
});

test('an ordinary link carries no dispute id', async () => {
  const { fake, stripe } = setup();

  const { token } = await create({ facilityId: 'f1', tenantId: 't1', amount: 100 }, staff);

  assert.equal(fake.read(`publicPaymentLinks/${token}`)!.disputeId, undefined);
  await getOrCreatePublicLinkCheckout(token, {
    db: fake.firestore(),
    sessions: stripe.api(),
    appUrl: 'https://app.example.test',
    now: () => stripe.now,
  });
  assert.equal('disputeId' in (stripe.createCalls[0].params.payment_intent_data?.metadata ?? {}), false);
});

test('a link naming another tenant\'s, a won, or an unknown dispute, or more than it has out, is refused and not created', async () => {
  const { fake } = setup();
  fake.seed('facilities/f1/ledgers/dispute_du_won', {
    tenantId: 't1',
    type: 'dispute',
    amount: 100,
    status: 'posted',
    metadata: { disputeId: 'du_won', settledByEntryId: 'dispute_du_won_reinstated' },
  });

  const refused = [
    ['t2', 'du_1', 100],
    ['t1', 'du_won', 100],
    ['t1', 'du_nope', 100],
    ['t1', 'du_1', 100.01],
  ] as const;
  for (const [tenantId, disputeId, amount] of refused) {
    await assert.rejects(
      create({ facilityId: 'f1', tenantId, amount, disputeId }, staff),
      (error: unknown) => (error as { code?: string }).code === 'failed-precondition',
    );
  }
  assert.deepEqual(fake.list('publicPaymentLinks'), []);
});

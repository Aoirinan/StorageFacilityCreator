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
import { DISPUTE_LINK_NOT_DUE_MESSAGE, getOrCreatePublicLinkCheckout } from '../publicPaymentCheckoutSession';
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

// --- A dispute link is re-checked before every checkout ----------------------

const checkout = (fake: FakeFirestore, stripe: FakeCheckoutSessions, token: string) =>
  getOrCreatePublicLinkCheckout(token, {
    db: fake.firestore(),
    sessions: stripe.api(),
    appUrl: 'https://app.example.test',
    now: () => stripe.now,
  });

async function refusedAsNotDue(promise: Promise<unknown>): Promise<void> {
  await assert.rejects(promise, (error: unknown) => {
    assert.equal((error as { code?: string }).code, 'failed-precondition');
    assert.equal((error as Error).message, DISPUTE_LINK_NOT_DUE_MESSAGE);
    return true;
  });
}

test('a dispute link is not offered for payment once the dispute has been won, and its open session is closed', async () => {
  const { fake, stripe } = setup();
  const { token } = await create({ facilityId: 'f1', tenantId: 't1', amount: 100, disputeId: 'du_1' }, staff);
  const opened = await checkout(fake, stripe, token);
  assert.equal(opened.kind, 'checkout');
  // The facility wins: the webhook marks the dispute settled and posts the reversal.
  fake.seed('facilities/f1/ledgers/dispute_du_1', {
    ...fake.read('facilities/f1/ledgers/dispute_du_1')!,
    metadata: { disputeId: 'du_1', allocatedAmount: 100, settledByEntryId: 'dispute_du_1_reinstated' },
  });
  fake.seed('facilities/f1/ledgers/dispute_du_1_reinstated', {
    tenantId: 't1', facilityId: 'f1', type: 'dispute_reversal', amount: -100, status: 'posted', metadata: { disputeId: 'du_1' },
  });

  // Before: the open session was handed back and the tenant paid it twice.
  await refusedAsNotDue(checkout(fake, stripe, token));
  assert.deepEqual(stripe.payable(), []);
  assert.equal(stripe.created().length, 1);
});

test('a dispute link is not offered once staff recorded the dispute paid by hand', async () => {
  const { fake, stripe } = setup();
  const { token } = await create({ facilityId: 'f1', tenantId: 't1', amount: 100, disputeId: 'du_1' }, staff);
  fake.seed('facilities/f1/ledgers/cash1', {
    tenantId: 't1', facilityId: 'f1', type: 'payment', amount: -100, status: 'posted', metadata: { disputeId: 'du_1', paymentMethod: 'cash' },
  });

  await refusedAsNotDue(checkout(fake, stripe, token));
  assert.deepEqual(stripe.created(), []);
});

test('a dispute link partly paid another way since is no longer due for its full amount', async () => {
  const { fake, stripe } = setup();
  const { token } = await create({ facilityId: 'f1', tenantId: 't1', amount: 100, disputeId: 'du_1' }, staff);
  fake.seed('facilities/f1/ledgers/cash1', {
    tenantId: 't1', facilityId: 'f1', type: 'payment', amount: -40, status: 'posted', metadata: { disputeId: 'du_1', paymentMethod: 'cash' },
  });

  await refusedAsNotDue(checkout(fake, stripe, token));
});

test('a dispute link already paid is still reported paid, not refused', async () => {
  const { fake, stripe } = setup();
  const { token } = await create({ facilityId: 'f1', tenantId: 't1', amount: 100, disputeId: 'du_1' }, staff);
  const opened = await checkout(fake, stripe, token);
  assert.equal(opened.kind, 'checkout');
  stripe.pay((opened as { sessionId: string }).sessionId, 'pi_link');
  // The payment webhook booked it against the dispute before the link was marked.
  fake.seed('facilities/f1/ledgers/payment_pi_link', {
    tenantId: 't1', facilityId: 'f1', type: 'payment', amount: -100, status: 'posted', metadata: { paymentIntentId: 'pi_link', disputeId: 'du_1' },
  });

  assert.deepEqual(await checkout(fake, stripe, token), { kind: 'paid' });
});

test('an open dispute link still hands back its open session', async () => {
  const { fake, stripe } = setup();
  const { token } = await create({ facilityId: 'f1', tenantId: 't1', amount: 100, disputeId: 'du_1' }, staff);
  const first = await checkout(fake, stripe, token);
  const second = await checkout(fake, stripe, token);

  assert.deepEqual(second, { ...first, reused: true });
});

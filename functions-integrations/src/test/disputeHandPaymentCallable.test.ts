/**
 * recordDisputePaymentByHand: the server writes and caps money taken by hand
 * for a card dispute (the app used to write it itself, capped only by its
 * dialog). The logic is tested in functions-shared disputePayment.test.ts;
 * this runs the deployed callable for access and error mapping.
 *
 * Made-up ids only: this repo is public.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { recordDisputePaymentByHand } from '../disputeHandPaymentCallable';
import { LEDGERS, setup } from './support/webhookFakes';

const OWNER = 'owner_uid';
const run = (recordDisputePaymentByHand as unknown as {
  run: (data: unknown, context: unknown) => Promise<Record<string, unknown>>;
}).run;
const staff = { auth: { uid: OWNER }, app: { appId: 'test' } };

function withDispute() {
  const ctx = setup();
  ctx.fake.seed('facilities/f1', { ...ctx.fake.read('facilities/f1')!, ownerUid: OWNER });
  ctx.fake.seed(`${LEDGERS}/dispute_du_1`, {
    tenantId: 't1',
    facilityId: 'f1',
    type: 'dispute',
    amount: 100,
    status: 'posted',
    metadata: { disputeId: 'du_1' },
  });
  return ctx;
}

const request = (overrides: Record<string, unknown> = {}) => ({
  facilityId: 'f1',
  tenantId: 't1',
  disputeId: 'du_1',
  amount: 100,
  method: 'check',
  reference: '0042',
  requestId: 'req_abcdef01',
  ...overrides,
});

test('staff record a dispute payment by hand through the server', async () => {
  const { fake } = withDispute();

  const result = await run(request(), staff);

  assert.deepEqual(result, { success: true, outcome: 'recorded', paymentId: 'disputehand_req_abcdef01' });
  const row = fake.read(`${LEDGERS}/disputehand_req_abcdef01`)!;
  assert.equal(row.amount, -100);
  assert.equal((row.metadata as Record<string, unknown>).disputeId, 'du_1');
  assert.equal(row.createdBy, OWNER);
});

test('more than the dispute has out is refused by the server', async () => {
  withDispute();

  await assert.rejects(run(request({ amount: 100.01 }), staff), (error: unknown) => {
    const e = error as { code?: string; message?: string; details?: { reason?: string } };
    return e.code === 'failed-precondition' && /\$100\.00 left/.test(String(e.message)) && e.details?.reason === 'amount_over_dispute';
  });
});

test('a bad request is invalid-argument; someone without access to the facility is refused', async () => {
  const { fake } = withDispute();

  await assert.rejects(run(request({ method: 'stripe' }), staff), (error: unknown) => (error as { code?: string }).code === 'invalid-argument');
  await assert.rejects(
    run(request(), { auth: { uid: 'stranger' }, app: { appId: 'test' } }),
    (error: unknown) => (error as { code?: string }).code === 'permission-denied',
  );
  await assert.rejects(run(request(), { app: { appId: 'test' } }), (error: unknown) => (error as { code?: string }).code === 'unauthenticated');
  assert.equal(fake.read(`${LEDGERS}/disputehand_req_abcdef01`), undefined);
});

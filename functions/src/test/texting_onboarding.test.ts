import test from 'node:test';
import assert from 'node:assert/strict';
import {
  computeA2PStatus,
  ensureIdempotentResource,
  isStopKeyword,
} from '@sfc/functions-shared';

test('idempotent provisioning reuses existing sid', async () => {
  let created = 0;
  const result = await ensureIdempotentResource(
    'PNexisting123',
    async () => {
      created += 1;
      return { sid: 'PNnew' };
    },
    (r) => r.sid,
  );
  assert.equal(result.sid, 'PNexisting123');
  assert.equal(result.created, false);
  assert.equal(created, 0);
});

test('idempotent provisioning creates when missing', async () => {
  let created = 0;
  const result = await ensureIdempotentResource(
    '',
    async () => {
      created += 1;
      return { sid: 'PNnew' };
    },
    (r) => r.sid,
  );
  assert.equal(result.sid, 'PNnew');
  assert.equal(result.created, true);
  assert.equal(created, 1);
});

test('STOP keyword handling matches compliance list', () => {
  assert.equal(isStopKeyword('STOP'), true);
  assert.equal(isStopKeyword('unsubscribe'), true);
  assert.equal(isStopKeyword(' quit '), true);
  assert.equal(isStopKeyword('hello'), false);
});

test('status transitions to approved and rejected', () => {
  assert.equal(computeA2PStatus('submitted', 'pending', 'PENDING'), 'pending');
  assert.equal(computeA2PStatus('pending', 'approved', 'approved'), 'approved');
  assert.equal(computeA2PStatus('pending', 'verified', 'REJECTED'), 'rejected');
});

test('send gating model: non-approved stays blocked', () => {
  assert.notEqual(computeA2PStatus('draft', undefined, undefined), 'approved');
});

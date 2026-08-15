import test from 'node:test';
import assert from 'node:assert/strict';
import {
  autopayJobId,
  autopayRunDate,
  canClaimAutopayJob,
  chunkForBatchedWrites,
} from '../autopayJobHelpers';

// --- run date ---------------------------------------------------------------

test('autopayRunDate formats a zero-padded UTC calendar day', () => {
  assert.equal(autopayRunDate(new Date('2026-03-05T02:00:00Z')), '2026-03-05');
  assert.equal(autopayRunDate(new Date('2026-12-31T23:59:59Z')), '2026-12-31');
});

test('autopayRunDate uses UTC, not local time', () => {
  // The schedule runs at 02:00 UTC. Read in a negative-offset local zone this
  // instant is still the previous calendar day, and using local time would
  // produce a different run key — letting the same night enqueue twice.
  const atSchedule = new Date('2026-03-05T02:00:00Z');
  assert.equal(autopayRunDate(atSchedule), '2026-03-05');

  const justBeforeMidnightUtc = new Date('2026-03-05T23:59:00Z');
  assert.equal(
    autopayRunDate(justBeforeMidnightUtc),
    '2026-03-05',
    'the whole UTC day must map to one run key',
  );
});

// --- job id -----------------------------------------------------------------

test('autopayJobId is deterministic for a facility and run date', () => {
  assert.equal(autopayJobId('2026-03-05', 'fac_1'), '2026-03-05_fac_1');
  assert.equal(
    autopayJobId('2026-03-05', 'fac_1'),
    autopayJobId('2026-03-05', 'fac_1'),
    'same inputs must map to the same document so re-running cannot double-charge',
  );
});

test('autopayJobId separates facilities and separates nights', () => {
  assert.notEqual(autopayJobId('2026-03-05', 'fac_1'), autopayJobId('2026-03-05', 'fac_2'));
  assert.notEqual(autopayJobId('2026-03-05', 'fac_1'), autopayJobId('2026-03-06', 'fac_1'));
});

test('autopayJobId never produces a nested document path', () => {
  // A '/' in a document id would silently write to a subcollection path.
  const id = autopayJobId('2026-03-05', 'bad/id');
  assert.ok(!id.includes('/'), `job id must not contain a slash, got ${id}`);
});

// --- claiming ---------------------------------------------------------------

test('canClaimAutopayJob only allows pending jobs', () => {
  assert.equal(canClaimAutopayJob({ status: 'pending' }), true);
  assert.equal(
    canClaimAutopayJob({ status: 'processing' }),
    false,
    'a job already in flight must not be started again',
  );
  assert.equal(canClaimAutopayJob({ status: 'completed' }), false);
  assert.equal(canClaimAutopayJob({ status: 'failed' }), false);
});

test('canClaimAutopayJob refuses malformed jobs rather than assuming pending', () => {
  assert.equal(canClaimAutopayJob({}), false);
  assert.equal(canClaimAutopayJob(undefined), false);
  assert.equal(canClaimAutopayJob(null), false);
});

// --- batching ---------------------------------------------------------------

test('chunkForBatchedWrites respects the Firestore 500-write batch cap', () => {
  const ids = Array.from({ length: 1200 }, (_, i) => `fac_${i}`);
  const chunks = chunkForBatchedWrites(ids);

  assert.equal(chunks.length, 3);
  assert.deepEqual(chunks.map((c) => c.length), [500, 500, 200]);
  assert.equal(
    chunks.flat().length,
    ids.length,
    'every facility must be enqueued exactly once',
  );
  assert.deepEqual(chunks.flat(), ids, 'order and contents must be preserved');
});

test('chunkForBatchedWrites handles empty and exact-multiple inputs', () => {
  assert.deepEqual(chunkForBatchedWrites([]), []);
  const exact = Array.from({ length: 1000 }, (_, i) => i);
  assert.equal(chunkForBatchedWrites(exact).length, 2);
});

test('chunkForBatchedWrites rejects a non-positive chunk size', () => {
  assert.throws(() => chunkForBatchedWrites([1, 2, 3], 0), /positive/);
});

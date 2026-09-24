import test from 'node:test';
import assert from 'node:assert/strict';

import {
  LockBlockInput,
  LockStayInput,
  bucketDigest,
  checkRequested,
  lockHorizon,
  lockMonthsFor,
  rebuildBuckets,
} from '../stays/nightLocks';

const HORIZON = { clampFrom: '2026-01-01', clampTo: '2028-01-01' };

function stay(stayId: string, checkIn: string, checkOut: string, createdAtMs: number, extra: Partial<LockStayInput> = {}): LockStayInput {
  return {
    stayId,
    status: 'confirmed',
    kind: 'reservation',
    source: 'direct',
    checkIn,
    checkOut,
    createdAtMs,
    ...extra,
  };
}

function block(channelId: string, ranges: [string, string, boolean?][]): LockBlockInput {
  return {
    channelId,
    provider: 'airbnb',
    ranges: ranges.map(([checkIn, checkOut, echo]) => ({ checkIn, checkOut, echo: echo === true })),
  };
}

function rebuild(stays: LockStayInput[], blocks: LockBlockInput[] = [], months = ['2026-10']) {
  return rebuildBuckets({ months, stays, blocks, ...HORIZON });
}

test('the first writer wins, by createdAtMs and then stayId', () => {
  const r = rebuild([stay('b_later', '2026-10-03', '2026-10-05', 200), stay('a_first', '2026-10-03', '2026-10-05', 100)]);
  assert.equal(r.buckets['2026-10'].nights['2026-10-03'].s, 'a_first');
  assert.equal(r.outcomes.a_first.status, 'confirmed');
  assert.equal(r.outcomes.b_later.status, 'conflict');
  assert.deepEqual(r.outcomes.b_later.conflictStayIds, ['a_first']);
  assert.deepEqual(r.outcomes.b_later.conflictNights, ['2026-10-03', '2026-10-04']);

  // Same millisecond: the smaller stayId wins, whatever order they arrive in.
  const tie = rebuild([stay('man_b', '2026-10-03', '2026-10-04', 100), stay('man_a', '2026-10-03', '2026-10-04', 100)]);
  assert.equal(tie.buckets['2026-10'].nights['2026-10-03'].s, 'man_a');
});

test('a soft channel block yields to a hard lock and never raises a conflict', () => {
  const r = rebuild(
    [stay('s1', '2026-10-03', '2026-10-05', 100)],
    [block('ch1', [['2026-10-01', '2026-10-10']])],
  );
  const nights = r.buckets['2026-10'].nights;
  assert.equal(nights['2026-10-03'].s, 's1');
  assert.equal(nights['2026-10-03'].h, true);
  assert.equal(nights['2026-10-02'].s, 'blk:ch1');
  assert.equal(nights['2026-10-02'].h, false);
  assert.equal(nights['2026-10-02'].k, 'channel_block');
  assert.equal(r.outcomes.s1.status, 'confirmed');
  assert.deepEqual(Object.keys(r.outcomes), ['s1']);
});

test('a partial conflict keeps the nights nobody else holds', () => {
  const r = rebuild([stay('first', '2026-10-03', '2026-10-05', 100), stay('second', '2026-10-04', '2026-10-08', 200)]);
  const nights = r.buckets['2026-10'].nights;
  assert.equal(nights['2026-10-04'].s, 'first');
  for (const n of ['2026-10-05', '2026-10-06', '2026-10-07']) assert.equal(nights[n].s, 'second');
  assert.equal(r.outcomes.second.status, 'conflict');
  assert.deepEqual(r.outcomes.second.conflictNights, ['2026-10-04']);
});

test("removing the winner hands its nights to the conflict stay, which becomes confirmed", () => {
  const winner = stay('winner', '2026-10-03', '2026-10-05', 100);
  const loser = stay('loser', '2026-10-03', '2026-10-05', 200);
  assert.equal(rebuild([winner, loser]).outcomes.loser.status, 'conflict');

  const cancelled = rebuild([{ ...winner, status: 'cancelled' }, { ...loser, status: 'conflict' }]);
  assert.equal(cancelled.outcomes.loser.status, 'confirmed');
  assert.equal(cancelled.buckets['2026-10'].nights['2026-10-03'].s, 'loser');
  assert.equal(cancelled.outcomes.winner, undefined);

  const removed = rebuild([{ ...winner, status: 'removed_from_feed' }, loser]);
  assert.equal(removed.outcomes.loser.status, 'confirmed');
});

test('owner and maintenance blocks are hard claims', () => {
  const r = rebuild([
    stay('blk', '2026-10-03', '2026-10-05', 100, { kind: 'owner_block', source: 'owner' }),
    stay('res', '2026-10-04', '2026-10-06', 200),
  ]);
  assert.equal(r.buckets['2026-10'].nights['2026-10-04'].k, 'owner_block');
  assert.equal(r.outcomes.res.status, 'conflict');
});

test('echoed channel blocks are marked, and stay soft', () => {
  const r = rebuild(
    [stay('s1', '2026-10-03', '2026-10-05', 100)],
    [block('ch1', [['2026-10-03', '2026-10-05', true], ['2026-10-20', '2026-10-22', false]])],
  );
  // The hard stay owns its nights; the echo range has nothing left to mark there.
  assert.equal(r.buckets['2026-10'].nights['2026-10-03'].e, undefined);
  assert.deepEqual(r.echoRanges, [{ channelId: 'ch1', checkIn: '2026-10-03', checkOut: '2026-10-05' }]);

  const onlyEcho = rebuild([], [block('ch1', [['2026-10-03', '2026-10-05', true]])]);
  assert.equal(onlyEcho.buckets['2026-10'].nights['2026-10-03'].e, true);
  assert.equal(onlyEcho.buckets['2026-10'].nights['2026-10-03'].h, false);
  assert.equal('e' in rebuild([], [block('ch1', [['2026-10-20', '2026-10-21']])]).buckets['2026-10'].nights['2026-10-20'], false);
});

test('nights outside the horizon or the requested months are not locked', () => {
  const r = rebuildBuckets({
    months: ['2026-10', '2026-11'],
    stays: [stay('long', '2026-10-28', '2026-11-05', 100)],
    blocks: [],
    clampFrom: '2026-10-30',
    clampTo: '2026-11-03',
  });
  assert.deepEqual(Object.keys(r.buckets['2026-10'].nights), ['2026-10-30', '2026-10-31']);
  assert.deepEqual(Object.keys(r.buckets['2026-11'].nights), ['2026-11-01', '2026-11-02']);

  const oneMonth = rebuild([stay('long', '2026-10-28', '2026-11-05', 100)], [], ['2026-11']);
  assert.deepEqual(Object.keys(oneMonth.buckets), ['2026-11']);
  assert.equal(Object.keys(oneMonth.buckets['2026-11'].nights).length, 4);

  assert.deepEqual(lockHorizon('2026-10-03'), { clampFrom: '2026-08-04', clampTo: '2028-03-26' });
  assert.deepEqual(lockMonthsFor('2026-07-01', '2026-08-10', '2026-08-04', '2028-03-26'), ['2026-08']);
});

test('the digest is stable and changes only with the claims', () => {
  const a = rebuild([stay('s1', '2026-10-03', '2026-10-05', 100), stay('s2', '2026-10-10', '2026-10-12', 50)]);
  const b = rebuild([stay('s2', '2026-10-10', '2026-10-12', 50), stay('s1', '2026-10-03', '2026-10-05', 100)]);
  assert.equal(a.buckets['2026-10'].digest, b.buckets['2026-10'].digest);
  assert.equal(bucketDigest(a.buckets['2026-10'].nights), a.buckets['2026-10'].digest);
  const c = rebuild([stay('s1', '2026-10-03', '2026-10-06', 100), stay('s2', '2026-10-10', '2026-10-12', 50)]);
  assert.notEqual(a.buckets['2026-10'].digest, c.buckets['2026-10'].digest);
  // An empty month has a digest too.
  assert.match(rebuild([]).buckets['2026-10'].digest, /^[a-f0-9]{32}$/);
});

test('checkRequested reports hard nights held by others and soft nights', () => {
  const r = rebuild(
    [stay('mine', '2026-10-01', '2026-10-02', 100), stay('theirs', '2026-10-03', '2026-10-04', 100)],
    [block('ch1', [['2026-10-05', '2026-10-06']])],
  );
  const check = checkRequested(r.buckets, 'mine', ['2026-10-01', '2026-10-03', '2026-10-05', '2026-10-07']);
  assert.deepEqual(check.hardConflicts, [{ date: '2026-10-03', stayId: 'theirs' }]);
  assert.deepEqual(check.softNights, ['2026-10-05']);
});

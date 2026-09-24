import test from 'node:test';
import assert from 'node:assert/strict';
import { Timestamp } from 'firebase-admin/firestore';

import type { StayDoc } from '@sfc/functions-shared/stays/contracts';

import { staysErrorReason } from '../common/errors';
import { ApplyStayMutationsInput, applyStayMutations, driftRebuildMonthChunks } from '../common/stayWriter';
import { FakeFirestore, commitBarrier } from './support/fakeFirestore';
import { FAC, NOW, OWNER, controlsOn, makeStay, seedFacility } from './support/staysFixtures';

const STAYS = `facilities/${FAC}/stays`;
const LOCKS = `facilities/${FAC}/stayNightLocks`;
const BLOCKS = `facilities/${FAC}/stayChannelBlocks`;

const all: FakeFirestore[] = [];

function newFake(): FakeFirestore {
  const fake = new FakeFirestore();
  fake.clock = () => NOW;
  seedFacility(fake);
  all.push(fake);
  return fake;
}

function write(fake: FakeFirestore, patch: Partial<ApplyStayMutationsInput>) {
  return applyStayMutations({
    db: fake.firestore(),
    facilityId: FAC,
    controls: controlsOn(),
    mutations: [],
    nowMs: NOW,
    actor: OWNER,
    ...patch,
  });
}

function seedStay(fake: FakeFirestore, id: string, stay: StayDoc): void {
  fake.seed(`${STAYS}/${id}`, stay as unknown as Record<string, unknown>);
}

async function reasonOf(p: Promise<unknown>): Promise<string | null> {
  try {
    await p;
    return null;
  } catch (error) {
    return staysErrorReason(error) ?? `untyped: ${String(error)}`;
  }
}

function nightsOf(fake: FakeFirestore, listingId: string, month: string): Record<string, { s: string; h: boolean; e?: boolean }> {
  return (fake.read(`${LOCKS}/${listingId}_${month}`)?.nights ?? {}) as Record<string, { s: string; h: boolean; e?: boolean }>;
}

test('a new stay writes the stay and its lock buckets, across a month boundary', async () => {
  const fake = newFake();
  const result = await write(fake, {
    mutations: [{ stayId: 'man_a', next: makeStay('lst1', '2026-10-30', '2026-11-02'), mode: 'sfc', createOnly: true }],
  });
  assert.equal(result.outcomes.man_a.status, 'confirmed');
  assert.equal(fake.read(`${STAYS}/man_a`)?.status, 'confirmed');
  assert.deepEqual(Object.keys(nightsOf(fake, 'lst1', '2026-10')), ['2026-10-30', '2026-10-31']);
  assert.deepEqual(Object.keys(nightsOf(fake, 'lst1', '2026-11')), ['2026-11-01']);
  assert.deepEqual(result.changedBuckets.sort(), ['lst1_2026-10', 'lst1_2026-11']);
  const bucket = fake.read(`${LOCKS}/lst1_2026-10`)!;
  assert.equal(bucket.facilityId, FAC);
  assert.equal(bucket.month, '2026-10');
  assert.match(bucket.digest as string, /^[a-f0-9]{32}$/);
});

test('two interleaved bookings of the same night: exactly one commits, the other gets hard_conflict', async () => {
  const fake = newFake();
  fake.onBeforeCommit = commitBarrier(2);
  const book = (id: string, name: string) =>
    write(fake, {
      mutations: [
        { stayId: id, next: makeStay('lst1', '2026-10-10', '2026-10-12', { guestDisplayName: name }), mode: 'sfc', createOnly: true },
      ],
    });
  const results = await Promise.allSettled([book('man_one', 'Ann A.'), book('man_two', 'Bob B.')]);
  const won = results.filter((r) => r.status === 'fulfilled');
  const lost = results.filter((r) => r.status === 'rejected') as PromiseRejectedResult[];
  assert.equal(won.length, 1);
  assert.equal(lost.length, 1);
  assert.equal(staysErrorReason(lost[0].reason), 'hard_conflict');
  // Both read before either committed, so the loser had to retry to see the winner.
  assert.ok(fake.retries >= 1);
  const stays = fake.list(STAYS);
  assert.equal(stays.length, 1);
  const winner = stays[0].id;
  assert.equal(nightsOf(fake, 'lst1', '2026-10')['2026-10-10'].s, winner);
  const details = (lost[0].reason as { details: { nights: { date: string; stayId: string; label: string }[] } }).details;
  assert.deepEqual(
    details.nights.map((n) => [n.date, n.stayId]),
    [
      ['2026-10-10', winner],
      ['2026-10-11', winner],
    ],
  );
  assert.match(details.nights[0].label, /2026-10-10 to 2026-10-12/);
});

test('ten parallel bookings of the same nights leave exactly one stay', async () => {
  const fake = newFake();
  fake.onBeforeCommit = commitBarrier(10);
  const results = await Promise.allSettled(
    Array.from({ length: 10 }, (_, i) =>
      write(fake, {
        mutations: [{ stayId: `man_${i}`, next: makeStay('lst1', '2026-10-20', '2026-10-23'), mode: 'sfc', createOnly: true }],
        maxAttempts: 20,
      }),
    ),
  );
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  for (const r of results) {
    if (r.status === 'rejected') assert.equal(staysErrorReason(r.reason), 'hard_conflict');
  }
  assert.equal(fake.list(STAYS).length, 1);
});

test('a feed write records the conflict instead of refusing it', async () => {
  const fake = newFake();
  seedStay(fake, 'man_first', makeStay('lst1', '2026-10-10', '2026-10-13', { createdAtMs: 100 }));
  await write(fake, { rebuild: [{ listingId: 'lst1', months: ['2026-10'] }] });

  const feedStay = makeStay('lst1', '2026-10-12', '2026-10-15', {
    source: 'airbnb',
    origin: 'feed',
    createdAtMs: 200,
  });
  const result = await write(fake, { mutations: [{ stayId: 'airbnb_HMFEED0001', next: feedStay, mode: 'feed' }] });
  const stored = fake.read(`${STAYS}/airbnb_HMFEED0001`)!;
  assert.equal(stored.status, 'conflict');
  assert.deepEqual((stored.conflict as { stayIds: string[] }).stayIds, ['man_first']);
  assert.deepEqual((stored.conflict as { nights: string[] }).nights, ['2026-10-12']);
  // The earlier stay keeps its nights and its status.
  assert.equal(fake.read(`${STAYS}/man_first`)?.status, 'confirmed');
  assert.equal(nightsOf(fake, 'lst1', '2026-10')['2026-10-12'].s, 'man_first');
  assert.equal(nightsOf(fake, 'lst1', '2026-10')['2026-10-13'].s, 'airbnb_HMFEED0001');
  assert.deepEqual(result.statusChanges, [{ stayId: 'airbnb_HMFEED0001', from: null, to: 'conflict' }]);
});

test("cancelling a conflict's winner hands its nights back in the same commit", async () => {
  const fake = newFake();
  const winner = makeStay('lst1', '2026-10-10', '2026-10-13', { createdAtMs: 100 });
  seedStay(fake, 'man_winner', winner);
  await write(fake, {
    mutations: [
      { stayId: 'airbnb_HMLOSER001', next: makeStay('lst1', '2026-10-11', '2026-10-14', { createdAtMs: 200, source: 'airbnb', origin: 'feed' }), mode: 'feed' },
    ],
  });
  assert.equal(fake.read(`${STAYS}/airbnb_HMLOSER001`)?.status, 'conflict');

  const result = await write(fake, {
    mutations: [
      {
        stayId: 'man_winner',
        next: { ...winner, status: 'cancelled', version: 2, cancelReason: 'Guest called' },
        expectedVersion: 1,
        mode: 'sfc',
      },
    ],
  });
  const loser = fake.read(`${STAYS}/airbnb_HMLOSER001`)!;
  assert.equal(loser.status, 'confirmed');
  assert.equal(loser.conflict, null);
  assert.equal(loser.version, 2);
  assert.equal(loser.updatedBy, OWNER);
  for (const n of ['2026-10-11', '2026-10-12', '2026-10-13']) {
    assert.equal(nightsOf(fake, 'lst1', '2026-10')[n].s, 'airbnb_HMLOSER001');
  }
  assert.equal(nightsOf(fake, 'lst1', '2026-10')['2026-10-10'], undefined);
  assert.deepEqual(
    result.statusChanges.sort((a, b) => a.stayId.localeCompare(b.stayId)),
    [
      { stayId: 'airbnb_HMLOSER001', from: 'conflict', to: 'confirmed' },
      { stayId: 'man_winner', from: 'confirmed', to: 'cancelled' },
    ],
  );
});

test('moving a stay to another listing rebuilds both', async () => {
  const fake = newFake();
  const stay = makeStay('lst1', '2026-10-10', '2026-10-12');
  await write(fake, { mutations: [{ stayId: 'man_mv', next: stay, mode: 'sfc', createOnly: true }] });
  assert.ok(fake.has(`${LOCKS}/lst1_2026-10`));

  const result = await write(fake, {
    mutations: [{ stayId: 'man_mv', next: { ...stay, listingId: 'lst2', version: 2 }, expectedVersion: 1, mode: 'sfc' }],
  });
  // The old listing's bucket is empty now, so it is removed; the new one holds the nights.
  assert.equal(fake.has(`${LOCKS}/lst1_2026-10`), false);
  assert.equal(nightsOf(fake, 'lst2', '2026-10')['2026-10-10'].s, 'man_mv');
  assert.deepEqual(result.changedBuckets.sort(), ['lst1_2026-10', 'lst2_2026-10']);
  assert.deepEqual(Object.keys(result.plan.listingMonths).sort(), ['lst1', 'lst2']);
});

test('moving onto a booked listing is refused with the other stay named', async () => {
  const fake = newFake();
  seedStay(fake, 'man_there', makeStay('lst2', '2026-10-10', '2026-10-11', { guestDisplayName: 'Cal C.' }));
  await write(fake, { rebuild: [{ listingId: 'lst2', months: ['2026-10'] }] });
  const stay = makeStay('lst1', '2026-10-10', '2026-10-12');
  await write(fake, { mutations: [{ stayId: 'man_mv', next: stay, mode: 'sfc', createOnly: true }] });
  const p = write(fake, { mutations: [{ stayId: 'man_mv', next: { ...stay, listingId: 'lst2', version: 2 }, expectedVersion: 1, mode: 'sfc' }] });
  await assert.rejects(p, (e: unknown) => {
    const d = (e as { details: { nights: { stayId: string; label: string }[] } }).details;
    return staysErrorReason(e) === 'hard_conflict' && d.nights[0].stayId === 'man_there' && d.nights[0].label.startsWith('Cal C.');
  });
  // Nothing moved.
  assert.equal(fake.read(`${STAYS}/man_mv`)?.listingId, 'lst1');
});

test('a stale expectedVersion is refused', async () => {
  const fake = newFake();
  const stay = makeStay('lst1', '2026-10-10', '2026-10-12', { version: 3 });
  seedStay(fake, 'man_v', stay);
  const reason = await reasonOf(
    write(fake, { mutations: [{ stayId: 'man_v', next: { ...stay, checkOut: '2026-10-13', version: 4 }, expectedVersion: 2, mode: 'sfc' }] }),
  );
  assert.equal(reason, 'version_mismatch');
  assert.equal(fake.read(`${STAYS}/man_v`)?.checkOut, '2026-10-12');
  // expectedVersion 0 means "must not exist yet".
  assert.equal(
    await reasonOf(write(fake, { mutations: [{ stayId: 'man_v', next: stay, expectedVersion: 0, mode: 'sfc' }] })),
    'version_mismatch',
  );
});

test('a soft channel block needs explicit confirmation, and never conflicts', async () => {
  const fake = newFake();
  await write(fake, {
    channelBlockUpdates: [{ channelId: 'ch1', listingId: 'lst1', provider: 'airbnb', ranges: [{ checkIn: '2026-10-05', checkOut: '2026-10-08', echo: false }] }],
  });
  assert.equal(nightsOf(fake, 'lst1', '2026-10')['2026-10-06'].h, false);
  assert.equal(fake.read(`${BLOCKS}/ch1`)?.provider, 'airbnb');

  const next = makeStay('lst1', '2026-10-07', '2026-10-09');
  const p = write(fake, { mutations: [{ stayId: 'man_soft', next, mode: 'sfc', createOnly: true }] });
  await assert.rejects(p, (e: unknown) => {
    return staysErrorReason(e) === 'soft_block' && JSON.stringify((e as { details: { dates: string[] } }).details.dates) === '["2026-10-07"]';
  });
  assert.equal(fake.has(`${STAYS}/man_soft`), false);

  await write(fake, { mutations: [{ stayId: 'man_soft', next, mode: 'sfc', createOnly: true, overrideSoftBlocks: true }] });
  const nights = nightsOf(fake, 'lst1', '2026-10');
  assert.equal(nights['2026-10-07'].s, 'man_soft');
  assert.equal(nights['2026-10-07'].h, true);
  assert.equal(nights['2026-10-06'].s, 'blk:ch1');
  assert.equal(fake.read(`${STAYS}/man_soft`)?.status, 'confirmed');
});

test('replacing a feed block set with [] releases its soft nights', async () => {
  const fake = newFake();
  const ranges = [{ checkIn: '2026-10-05', checkOut: '2026-10-08', echo: false }];
  await write(fake, { channelBlockUpdates: [{ channelId: 'ch1', listingId: 'lst1', provider: 'airbnb', ranges }] });
  assert.ok(fake.has(`${LOCKS}/lst1_2026-10`));
  await write(fake, { channelBlockUpdates: [{ channelId: 'ch1', listingId: 'lst1', ranges: [] }] });
  assert.equal(fake.has(`${LOCKS}/lst1_2026-10`), false);
  assert.deepEqual(fake.read(`${BLOCKS}/ch1`)?.ranges, []);
  // The provider is kept when an update leaves it out.
  assert.equal(fake.read(`${BLOCKS}/ch1`)?.provider, 'airbnb');
});

test('an unchanged rebuild writes nothing, and a drifted bucket is healed', async () => {
  const fake = newFake();
  await write(fake, { mutations: [{ stayId: 'man_a', next: makeStay('lst1', '2026-10-10', '2026-10-12'), mode: 'sfc', createOnly: true }] });
  const writesBefore = fake.writeLog.length;
  const noop = await write(fake, { rebuild: [{ listingId: 'lst1', months: ['2026-10', '2026-11'] }] });
  assert.deepEqual(noop.changedBuckets, []);
  assert.deepEqual(noop.statusChanges, []);
  assert.equal(fake.writeLog.length, writesBefore);

  // Someone corrupts the cache: the next rebuild puts it right.
  fake.seed(`${LOCKS}/lst1_2026-10`, { facilityId: FAC, listingId: 'lst1', month: '2026-10', nights: {}, digest: 'stale' });
  const healed = await write(fake, { rebuild: [{ listingId: 'lst1', months: ['2026-10'] }] });
  assert.deepEqual(healed.changedBuckets, ['lst1_2026-10']);
  assert.equal(nightsOf(fake, 'lst1', '2026-10')['2026-10-10'].s, 'man_a');
});

test('a retried create is skipped: one stay, one money row', async () => {
  const fake = newFake();
  const income = (tx: Parameters<NonNullable<ApplyStayMutationsInput['extraWrites']>>[0], plan: { skipped: string[] }) => {
    if (plan.skipped.includes('man_req')) return;
    tx.create(fake.firestore().doc(`facilities/${FAC}/stayIncome/man_req`), { grossCents: 5000, facilityId: FAC });
  };
  const call = () =>
    write(fake, {
      mutations: [{ stayId: 'man_req', next: makeStay('lst1', '2026-10-10', '2026-10-11'), mode: 'sfc', createOnly: true }],
      extraWrites: (tx, _snaps, plan) => income(tx, plan),
    });
  const first = await call();
  const second = await call();
  assert.deepEqual(first.plan.skipped, []);
  assert.deepEqual(second.plan.skipped, ['man_req']);
  assert.equal(fake.list(`facilities/${FAC}/stayIncome`).length, 1);
  assert.equal(fake.list(STAYS).length, 1);
});

test('extraWrites can abort the whole write, and sees the extra reads', async () => {
  const fake = newFake();
  fake.seed(`facilities/${FAC}/stayFolios/man_x`, { balanceCents: 1234 });
  let seen: unknown = null;
  const p = write(fake, {
    mutations: [{ stayId: 'man_x', next: makeStay('lst1', '2026-10-10', '2026-10-11'), mode: 'sfc', createOnly: true }],
    extraReads: [fake.firestore().doc(`facilities/${FAC}/stayFolios/man_x`)],
    extraWrites: (_tx, snaps) => {
      seen = snaps[0].get('balanceCents');
      throw new Error('refuse');
    },
  });
  await assert.rejects(p, /refuse/);
  assert.equal(seen, 1234);
  assert.equal(fake.has(`${STAYS}/man_x`), false);
  assert.equal(fake.paths(LOCKS).length, 0);
});

test('re-saving an earlier stay does not trip over a later stay that lost those nights to it', async () => {
  const fake = newFake();
  const early = makeStay('lst1', '2026-10-10', '2026-10-13', { createdAtMs: 100 });
  seedStay(fake, 'man_early', early);
  await write(fake, {
    mutations: [{ stayId: 'ical_late', next: makeStay('lst1', '2026-10-11', '2026-10-12', { createdAtMs: 200, origin: 'feed', source: 'vrbo' }), mode: 'feed' }],
  });
  assert.equal(fake.read(`${STAYS}/ical_late`)?.status, 'conflict');
  const reason = await reasonOf(
    write(fake, { mutations: [{ stayId: 'man_early', next: { ...early, checkOutTime: '10:00', version: 2 }, expectedVersion: 1, mode: 'sfc' }] }),
  );
  assert.equal(reason, null);
  assert.equal(fake.read(`${STAYS}/man_early`)?.checkOutTime, '10:00');
  assert.equal(fake.read(`${STAYS}/ical_late`)?.status, 'conflict');
});

test('an acknowledged conflict keeps its acknowledgement while nothing changes', async () => {
  const fake = newFake();
  seedStay(fake, 'man_a', makeStay('lst1', '2026-10-10', '2026-10-12', { createdAtMs: 100 }));
  const ack = Timestamp.fromMillis(NOW - 1000);
  seedStay(
    fake,
    'ical_b',
    makeStay('lst1', '2026-10-11', '2026-10-12', {
      createdAtMs: 200,
      status: 'conflict',
      conflict: { stayIds: ['man_a'], nights: ['2026-10-11'], detectedAt: ack, acknowledgedAt: ack, acknowledgedBy: OWNER, note: 'ok' },
    }),
  );
  const result = await write(fake, { rebuild: [{ listingId: 'lst1', months: ['2026-10'] }] });
  assert.deepEqual(result.statusChanges, []);
  assert.equal((fake.read(`${STAYS}/ical_b`)?.conflict as { note: string }).note, 'ok');
});

test('endless contention ends in `contention`, not a hang', async () => {
  const fake = newFake();
  fake.onBeforeCommit = async () => {
    // Every attempt, something it read changes under it.
    fake.seed(`${LOCKS}/lst1_2026-10`, { nights: {}, digest: String(Math.random()) });
  };
  const reason = await reasonOf(
    write(fake, { mutations: [{ stayId: 'man_c', next: makeStay('lst1', '2026-10-10', '2026-10-11'), mode: 'sfc' }], maxAttempts: 3 }),
  );
  assert.equal(reason, 'contention');
  assert.equal(fake.has(`${STAYS}/man_c`), false);
});

test('the writer needs a confirmed zone and never assumes one', async () => {
  const fake = newFake();
  const reason = await reasonOf(
    applyStayMutations({
      db: fake.firestore(),
      facilityId: FAC,
      controls: controlsOn({ timeZone: null, timeZoneConfirmedAt: null }),
      mutations: [{ stayId: 'man_z', next: makeStay('lst1', '2026-10-10', '2026-10-11'), mode: 'sfc' }],
      nowMs: NOW,
    }),
  );
  assert.equal(reason, 'timezone_unconfirmed');
});

test('stays outside the lock horizon are written without locks', async () => {
  const fake = newFake();
  // Today is 2026-10-01 in Denver; the horizon starts 60 days back, on 2026-08-02.
  const past = makeStay('lst1', '2026-06-01', '2026-06-04', { origin: 'csv', source: 'airbnb', arrivalState: 'checked_out' });
  const result = await write(fake, { mutations: [{ stayId: 'airbnb_HMPAST0001', next: past, mode: 'feed', createOnly: true }] });
  assert.equal(fake.read(`${STAYS}/airbnb_HMPAST0001`)?.status, 'confirmed');
  assert.deepEqual(result.changedBuckets, []);
  assert.equal(result.plan.clampFrom, '2026-08-02');
});

test('writes are limited to 20 months per listing and 150 stays', async () => {
  const fake = newFake();
  const months = Array.from({ length: 21 }, (_, i) => {
    const d = new Date(Date.UTC(2026, 9 + i, 1));
    return d.toISOString().slice(0, 7);
  });
  assert.equal(await reasonOf(write(fake, { rebuild: [{ listingId: 'lst1', months }] })), 'invalid_argument');
  const many = Array.from({ length: 151 }, (_, i) => ({ stayId: `man_${i}`, next: null, mode: 'feed' as const }));
  assert.equal(await reasonOf(write(fake, { mutations: many })), 'invalid_argument');
  // The drift rebuild splits the horizon into chunks that fit.
  const chunks = driftRebuildMonthChunks('2026-10-01');
  assert.ok(chunks.every((c) => c.length <= 20));
  assert.equal(chunks.flat()[0], '2026-08');
});

test('no stay write ever touched a storage-side collection', () => {
  assert.ok(all.length > 0);
  for (const fake of all) fake.assertIsolation();
  // And the check itself catches a planted write.
  const planted = new FakeFirestore();
  planted.seed(`facilities/${FAC}/tenants/t1`, { name: 'x' });
  assert.throws(() => planted.assertIsolation(), /tenants/);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { Timestamp } from 'firebase-admin/firestore';

import type { StayDoc, StayTaskDoc } from '@sfc/functions-shared/stays/contracts';
import { inactiveTurnoverDigest } from '@sfc/functions-shared/stays/turnoverPlan';

import { TriggerDeps, handleStayWrite, turnoverRelevantChange } from '../tasks/onStayWrite';
import { handleTaskUpdate, taskNotifications } from '../tasks/onTaskWrite';
import { FakeFirestore } from './support/fakeFirestore';
import { FAC, NOW, makeStay } from './support/staysFixtures';
import { Env, P, listingInput, rvInput, seedListing, setupEnv } from './support/bookingFixtures';

// Today at the facility is 2026-10-01.
const all: FakeFirestore[] = [];

function env(controls: Record<string, unknown> = { turnoverTasksEnabled: true }, gate: Record<string, unknown> = {}): Env & { trigger: TriggerDeps } {
  const e = setupEnv(all, { controls, gate });
  seedListing(e.fake, 'lst_a', listingInput({ turnover: { ...listingInput().turnover, afterOwnerBlocks: true, checklistTemplate: [{ id: 'beds', label: 'Make beds' }, { id: 'trash', label: 'Trash out' }] } }));
  seedListing(e.fake, 'lst_rv1', rvInput(1, { turnover: { ...rvInput(1).turnover, defaultAssigneeUid: 'uid-sam', defaultAssigneeName: 'Sam' } }));
  return { ...e, trigger: { db: () => e.fake.firestore(), now: () => NOW } };
}

type E = ReturnType<typeof env>;

/** Writes a stay the way a callable would, then runs the trigger for that write. */
async function write(e: E, id: string, next: StayDoc | null) {
  const before = (e.fake.read(`${P}/stays/${id}`) as StayDoc | undefined) ?? null;
  if (next) e.fake.seed(`${P}/stays/${id}`, next as unknown as Record<string, unknown>);
  else await e.fake.firestore().doc(`${P}/stays/${id}`).delete();
  return handleStayWrite(FAC, id, before, next, e.trigger);
}

function task(e: E, stayId: string): StayTaskDoc | undefined {
  return e.fake.read(`${P}/stayTasks/turnover_${stayId}`) as StayTaskDoc | undefined;
}

function staysWrites(e: E): number {
  return e.fake.writesTo('stays').length;
}

test('a new booking gets its turnover task: timed at the facility, checklist copied, never a stay write', async () => {
  const e = env();
  const before = staysWrites(e);
  const stay = makeStay('lst_a', '2026-10-02', '2026-10-05');
  const out = await write(e, 'man_a', stay);
  assert.deepEqual(out.replanned.map((r) => [r.taskId, r.write]), [['turnover_man_a', 'create']]);
  const t = task(e, 'man_a')!;
  assert.deepEqual(
    [t.category, t.status, t.listingId, t.stayId, t.nextStayId, t.title, t.dueDate, t.sameDayTurn, t.priority, t.createdBy],
    ['turnover', 'todo', 'lst_a', 'man_a', null, 'Turnover · Airbnb A', '2026-10-05', false, 'normal', 'system:stays-trigger'],
  );
  assert.equal(t.dueStartLocal, '2026-10-05 11:00');
  assert.equal(t.dueByLocal, '2026-10-05 23:59');
  assert.equal((t.dueStartAt as Timestamp).toDate().toISOString(), '2026-10-05T17:00:00.000Z');
  assert.deepEqual(t.checklist.map((i) => [i.id, i.done, i.doneAt]), [['beds', false, null], ['trash', false, null]]);
  assert.deepEqual([t.suppliesLow, t.photoPaths, t.issueNote, t.needsAttention], [[], [], '', false]);
  assert.match(t.plannedDigest!, /^[a-f0-9]{32}$/);
  // The trigger read stays; it wrote none (the test's own seeding is not logged).
  assert.equal(staysWrites(e), before);
});

test('nothing changes when the plan does not: other fields, or the same plan again', async () => {
  const e = env();
  const stay = makeStay('lst_a', '2026-10-02', '2026-10-05');
  await write(e, 'man_a', stay);
  const taskWrites = e.fake.writesTo('stayTasks').length;
  assert.equal(turnoverRelevantChange(stay, { ...stay, staffNotes: 'x', guestDisplayName: 'Z' }), false);
  assert.deepEqual((await write(e, 'man_a', { ...stay, staffNotes: 'Late arrival' })).replanned, []);
  // A check-in is relevant, but it does not move the turnover: no write.
  const out = await write(e, 'man_a', { ...stay, arrivalState: 'checked_in' });
  assert.deepEqual(out.replanned.map((r) => r.write), ['none']);
  assert.equal(e.fake.writesTo('stayTasks').length, taskWrites);
});

test("a booking arriving on another's checkout day re-times the one before it, and a same-day turn nobody has is flagged", async () => {
  const e = env();
  await write(e, 'man_a', makeStay('lst_a', '2026-10-02', '2026-10-05'));
  const b = makeStay('lst_a', '2026-10-05', '2026-10-07', { checkInTime: '16:00' });
  const out = await write(e, 'man_b', b);
  assert.deepEqual(out.replanned.map((r) => [r.taskId, r.write]).sort(), [['turnover_man_a', 'update'], ['turnover_man_b', 'create']]);
  const a = task(e, 'man_a')!;
  assert.deepEqual([a.nextStayId, a.sameDayTurn, a.priority, a.dueByLocal], ['man_b', true, 'high', '2026-10-05 16:00']);
  // Unassigned same-day turn: one in-app notice, no guest data in it.
  assert.deepEqual(out.notified, ['stay_unassigned_turnover_man_a_2026-10-05']);
  const notice = e.fake.read(`${P}/Notifications/stay_unassigned_turnover_man_a_2026-10-05`)!;
  assert.equal(notice.type, 'STAY_TURNOVER_UNASSIGNED');
  assert.equal(notice.message, 'Same-day turnover at Airbnb A on Oct 5 has nobody assigned.');
  assert.deepEqual(notice.metadata, { taskId: 'turnover_man_a', stayId: 'man_a', listingId: 'lst_a', route: `/stays/turnover?facilityId=${FAC}&taskId=turnover_man_a` });

  // The next guest moves to the 8th: the earlier turnover relaxes again.
  await write(e, 'man_b', { ...b, checkIn: '2026-10-08', checkOut: '2026-10-10' });
  const relaxed = task(e, 'man_a')!;
  assert.deepEqual([relaxed.sameDayTurn, relaxed.priority, relaxed.dueByLocal], [false, 'normal', '2026-10-08 16:00']);
});

test('a cancelled booking cancels its to-do turnover; restored, it comes back', async () => {
  const e = env();
  const stay = makeStay('lst_a', '2026-10-02', '2026-10-05');
  await write(e, 'man_a', stay);
  await write(e, 'man_a', { ...stay, status: 'cancelled' });
  let t = task(e, 'man_a')!;
  assert.deepEqual([t.status, t.plannedDigest], ['cancelled', inactiveTurnoverDigest('man_a')]);
  await write(e, 'man_a', { ...stay, status: 'confirmed' });
  t = task(e, 'man_a')!;
  assert.deepEqual([t.status, t.needsAttention], ['todo', false]);
  // A removed-from-feed or no-show stay is the same as cancelled.
  await write(e, 'man_a', { ...stay, arrivalState: 'no_show' });
  assert.equal(task(e, 'man_a')!.status, 'cancelled');
});

test('a turnover already under way or done is flagged, not cancelled; a done one is never reopened or moved', async () => {
  const e = env();
  const stay = makeStay('lst_a', '2026-10-02', '2026-10-05');
  await write(e, 'man_a', stay);
  e.fake.seed(`${P}/stayTasks/turnover_man_a`, { ...task(e, 'man_a')!, status: 'in_progress' } as never);
  await write(e, 'man_a', { ...stay, status: 'cancelled' });
  assert.deepEqual([task(e, 'man_a')!.status, task(e, 'man_a')!.needsAttention], ['in_progress', true]);

  const done = makeStay('lst_a', '2026-10-10', '2026-10-12');
  await write(e, 'man_d', done);
  e.fake.seed(`${P}/stayTasks/turnover_man_d`, { ...task(e, 'man_d')!, status: 'done' } as never);
  const snapshot = JSON.stringify(task(e, 'man_d'));
  await write(e, 'man_d', { ...done, checkOut: '2026-10-13' });
  assert.equal(JSON.stringify(task(e, 'man_d')), snapshot);
  // Cleaned, then the booking went away: she is told, and the work stays done.
  await write(e, 'man_d', { ...done, status: 'cancelled' });
  const flagged = task(e, 'man_d')!;
  assert.deepEqual([flagged.status, flagged.needsAttention, flagged.dueDate], ['done', true, '2026-10-12']);
  await write(e, 'man_d', { ...done, status: 'confirmed' });
  assert.equal(task(e, 'man_d')!.status, 'done');
});

test("a turnover a person cancelled or skipped stays that way; a person's high priority stands", async () => {
  const e = env();
  const stay = makeStay('lst_a', '2026-10-02', '2026-10-05');
  await write(e, 'man_a', stay);
  e.fake.seed(`${P}/stayTasks/turnover_man_a`, { ...task(e, 'man_a')!, status: 'cancelled' } as never);
  await write(e, 'man_a', { ...stay, checkOut: '2026-10-06' });
  assert.equal(task(e, 'man_a')!.status, 'cancelled');
  assert.equal(task(e, 'man_a')!.dueDate, '2026-10-05');

  const other = makeStay('lst_a', '2026-10-20', '2026-10-22');
  await write(e, 'man_p', other);
  e.fake.seed(`${P}/stayTasks/turnover_man_p`, { ...task(e, 'man_p')!, priority: 'high' } as never);
  await write(e, 'man_p', { ...other, checkOut: '2026-10-23' });
  assert.deepEqual([task(e, 'man_p')!.priority, task(e, 'man_p')!.dueDate], ['high', '2026-10-23']);
});

test('the listing decides: its default cleaner, a site check for RV sites, owner blocks when asked, never maintenance', async () => {
  const e = env();
  await write(e, 'man_rv', makeStay('lst_rv1', '2026-10-02', '2026-10-04', { listingName: 'RV 1' }));
  const rv = task(e, 'man_rv')!;
  assert.deepEqual([rv.title, rv.assigneeUid, rv.assigneeName], ['Site check · RV 1', 'uid-sam', 'Sam']);
  await write(e, 'man_blk', makeStay('lst_a', '2026-10-06', '2026-10-08', { kind: 'owner_block', source: 'owner' }));
  assert.equal(task(e, 'man_blk')!.title, 'Turnover after owner stay · Airbnb A');
  await write(e, 'man_fix', makeStay('lst_a', '2026-10-10', '2026-10-12', { kind: 'maintenance_block', source: 'owner' }));
  assert.equal(task(e, 'man_fix'), undefined);
});

test('no task for a checkout already past (an imported old stay)', async () => {
  const e = env();
  await write(e, 'airbnb_HMOLD00001', makeStay('lst_a', '2026-09-20', '2026-09-25', { source: 'airbnb', origin: 'csv', arrivalState: 'checked_out' }));
  assert.equal(task(e, 'airbnb_HMOLD00001'), undefined);
});

test('nothing happens with turnovers off, Stays off, or the kill switch on', async () => {
  // Each set-up resets the gate's 60-second cache, so build them one at a time.
  for (const make of [() => env({}), () => env({ turnoverTasksEnabled: true, moduleEnabled: false }), () => env({ turnoverTasksEnabled: true }, { killSwitch: true })]) {
    const e = make();
    const out = await write(e, 'man_a', makeStay('lst_a', '2026-10-02', '2026-10-05'));
    assert.deepEqual(out.replanned, []);
    assert.equal(e.fake.writesTo('stayTasks').length, 0);
  }
});

test('a deleted stay releases its to-do turnover', async () => {
  const e = env();
  await write(e, 'man_a', makeStay('lst_a', '2026-10-02', '2026-10-05'));
  await write(e, 'man_a', null);
  assert.equal(task(e, 'man_a')!.status, 'cancelled');
});

// ---------------------------------------------------------------------------
// staysOnTaskWrite
// ---------------------------------------------------------------------------

const baseTask: Partial<StayTaskDoc> = {
  title: 'Turnover · Airbnb A',
  dueDate: '2026-10-05',
  stayId: 'man_a',
  listingId: 'lst_a',
  status: 'in_progress',
  issueNote: '',
  suppliesLow: [],
};

test('done and issue notices: once each, pointing at the task, never carrying the note', async () => {
  const e = env();
  const done = await handleTaskUpdate(FAC, 'turnover_man_a', baseTask, { ...baseTask, status: 'done', suppliesLow: ['towels', 'toilet paper', 'call 406-555-0123'] }, e.trigger);
  assert.deepEqual(done, ['stay_turnover_done_turnover_man_a']);
  const n = e.fake.read(`${P}/Notifications/stay_turnover_done_turnover_man_a`)!;
  assert.equal(n.type, 'STAY_TURNOVER_DONE');
  assert.equal(n.message, 'Turnover · Airbnb A (Oct 5) is done. Running low on: towels, toilet paper.');
  assert.equal((n.metadata as { route: string }).route, `/stays/turnover?facilityId=${FAC}&taskId=turnover_man_a`);
  // Done again later (reopened and redone): no second notice.
  assert.deepEqual(await handleTaskUpdate(FAC, 'turnover_man_a', baseTask, { ...baseTask, status: 'done' }, e.trigger), []);

  const note = 'Broken window, guest said call 406-555-0123';
  const issue = await handleTaskUpdate(FAC, 'turnover_man_a', baseTask, { ...baseTask, issueNote: note }, e.trigger);
  assert.equal(issue.length, 1);
  assert.match(issue[0], /^stay_turnover_issue_turnover_man_a_[a-f0-9]{12}$/);
  const i = e.fake.read(`${P}/Notifications/${issue[0]}`)!;
  assert.equal(i.message, 'Issue reported on Turnover · Airbnb A (Oct 5). Open the task to see it.');
  assert.equal(JSON.stringify(i).includes('555'), false);
  // The same note again is no news; a changed one is.
  assert.deepEqual(taskNotifications(FAC, 't', { ...baseTask, issueNote: note }, { ...baseTask, issueNote: note }), []);
  assert.equal(taskNotifications(FAC, 't', { ...baseTask, issueNote: note }, { ...baseTask, issueNote: `${note}. Also the sink.` }).length, 1);
  assert.deepEqual(taskNotifications(FAC, 't', { ...baseTask, issueNote: note }, { ...baseTask, issueNote: '' }), []);
});

test('task notices wait for Stays to be on and the kill switch off', async () => {
  for (const make of [() => env({ moduleEnabled: false }), () => env({}, { killSwitch: true })]) {
    const e = make();
    assert.deepEqual(await handleTaskUpdate(FAC, 't1', baseTask, { ...baseTask, status: 'done' }, e.trigger), []);
    assert.equal(e.fake.list(`${P}/Notifications`).length, 0);
  }
});

test('the triggers wrote no stays and never touched a storage-side collection', () => {
  assert.ok(all.length > 0);
  for (const fake of all) {
    fake.assertIsolation();
    // Every stays write in these tests is the test seeding (seed() is not logged) or deleting one.
    assert.equal(fake.writeLog.filter((w) => w.path.includes('/stays/') && w.op !== 'delete').length, 0);
  }
});

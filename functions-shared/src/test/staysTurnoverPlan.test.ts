import test from 'node:test';
import assert from 'node:assert/strict';

import {
  TurnoverListing,
  TurnoverStay,
  inactiveTurnoverDigest,
  isInactiveTurnoverDigest,
  planTurnover,
  wantsTurnover,
} from '../stays/turnoverPlan';

const controls = { timeZone: 'America/Denver', defaultCheckInTime: '15:00', defaultCheckOutTime: '11:00' };

function listing(patch: Partial<TurnoverListing['turnover']> = {}): TurnoverListing {
  return {
    name: 'Airbnb A',
    times: { checkIn: null, checkOut: null },
    turnover: {
      mode: 'full',
      afterOwnerBlocks: false,
      checklistTemplate: [
        { id: 'beds', label: 'Make beds' },
        { id: 'trash', label: 'Trash out' },
      ],
      defaultAssigneeUid: 'uid-cleaner',
      defaultAssigneeName: 'Sam',
      ...patch,
    },
  };
}

function stay(stayId: string, checkIn: string, checkOut: string, patch: Partial<TurnoverStay> = {}): TurnoverStay {
  return {
    stayId,
    listingId: 'lst1',
    kind: 'reservation',
    status: 'confirmed',
    arrivalState: 'upcoming',
    checkIn,
    checkOut,
    checkInTime: '15:00',
    checkOutTime: '11:00',
    ...patch,
  };
}

const iso = (ms: number) => new Date(ms).toISOString();

test('a same-day turn: checkout 11:00 to the next check-in at 15:00, high priority', () => {
  const plan = planTurnover(stay('a', '2026-10-02', '2026-10-05'), stay('b', '2026-10-05', '2026-10-08'), listing(), controls)!;
  assert.ok(plan);
  const t = plan.task;
  assert.equal(t.taskId, 'turnover_a');
  assert.equal(t.category, 'turnover');
  assert.equal(t.nextStayId, 'b');
  assert.equal(t.sameDayTurn, true);
  assert.equal(t.priority, 'high');
  assert.equal(t.dueDate, '2026-10-05');
  // Denver is UTC−6 in October.
  assert.equal(iso(t.dueStartAtMs), '2026-10-05T17:00:00.000Z');
  assert.equal(t.dueStartLocal, '2026-10-05 11:00');
  assert.equal(iso(t.dueByAtMs), '2026-10-05T21:00:00.000Z');
  assert.equal(t.dueByLocal, '2026-10-05 15:00');
  assert.equal(t.title, 'Turnover · Airbnb A');
  assert.deepEqual(t.checklist, [
    { id: 'beds', label: 'Make beds' },
    { id: 'trash', label: 'Trash out' },
  ]);
  assert.deepEqual([t.assigneeUid, t.assigneeName], ['uid-cleaner', 'Sam']);
  assert.match(plan.digest, /^[a-f0-9]{32}$/);
});

test('the next arrival days later sets the due-by time; nothing after means 23:59 on checkout day', () => {
  const later = planTurnover(stay('a', '2026-10-02', '2026-10-05'), stay('b', '2026-10-08', '2026-10-10', { checkInTime: '16:00' }), listing(), controls)!;
  assert.equal(later.task.sameDayTurn, false);
  assert.equal(later.task.priority, 'normal');
  assert.equal(later.task.dueByLocal, '2026-10-08 16:00');
  const none = planTurnover(stay('a', '2026-10-02', '2026-10-05'), null, listing(), controls)!;
  assert.equal(none.task.nextStayId, null);
  assert.equal(none.task.dueByLocal, '2026-10-05 23:59');
  assert.equal(iso(none.task.dueByAtMs), '2026-10-06T05:59:00.000Z');
  assert.notEqual(none.digest, later.digest);
});

test('a "next" stay that starts before this checkout, is cancelled or is another listing is ignored', () => {
  const base = stay('a', '2026-10-02', '2026-10-05');
  for (const next of [
    stay('b', '2026-10-04', '2026-10-06'),
    stay('b', '2026-10-05', '2026-10-06', { status: 'cancelled' }),
    stay('b', '2026-10-05', '2026-10-06', { listingId: 'lst2' }),
    stay('b', '2026-10-05', '2026-10-06', { kind: 'maintenance_block' }),
    stay('a', '2026-10-05', '2026-10-06'),
  ]) {
    assert.equal(planTurnover(base, next, listing(), controls)!.task.nextStayId, null, JSON.stringify(next));
  }
  // An owner block is an arrival too: the place must be clean for her.
  assert.equal(planTurnover(base, stay('b', '2026-10-05', '2026-10-06', { kind: 'owner_block' }), listing(), controls)!.task.sameDayTurn, true);
});

test('owner blocks get a turnover only when the listing asks; maintenance blocks never', () => {
  const block = stay('blk', '2026-10-02', '2026-10-05', { kind: 'owner_block' });
  assert.equal(planTurnover(block, null, listing(), controls), null);
  const after = planTurnover(block, null, listing({ afterOwnerBlocks: true }), controls)!;
  assert.equal(after.task.title, 'Turnover after owner stay · Airbnb A');
  assert.equal(planTurnover(stay('m', '2026-10-02', '2026-10-05', { kind: 'maintenance_block' }), null, listing({ afterOwnerBlocks: true }), controls), null);
});

test("mode 'none', and stays that no longer hold their nights, have no turnover", () => {
  assert.equal(planTurnover(stay('a', '2026-10-02', '2026-10-05'), null, listing({ mode: 'none' }), controls), null);
  for (const patch of [{ status: 'cancelled' }, { status: 'removed_from_feed' }, { arrivalState: 'no_show' }] as Partial<TurnoverStay>[]) {
    assert.equal(planTurnover(stay('a', '2026-10-02', '2026-10-05', patch), null, listing(), controls), null);
    assert.equal(wantsTurnover(stay('a', '2026-10-02', '2026-10-05', patch), listing()), false);
  }
  // A conflict still holds nights, so it still gets cleaned after.
  assert.ok(planTurnover(stay('a', '2026-10-02', '2026-10-05', { status: 'conflict' }), null, listing(), controls));
});

test("an RV site's quick check is titled as one", () => {
  const plan = planTurnover(stay('a', '2026-10-02', '2026-10-05'), null, { ...listing({ mode: 'quick_check' }), name: 'RV 3' }, controls)!;
  assert.equal(plan.task.mode, 'quick_check');
  assert.equal(plan.task.title, 'Site check · RV 3');
});

test('times come from the stay, then the listing, then the controls', () => {
  const s = stay('a', '2026-10-02', '2026-10-05', { checkOutTime: 'bad' as string });
  const fromListing = planTurnover(s, null, { ...listing(), times: { checkIn: null, checkOut: '10:00' } }, controls)!;
  assert.equal(fromListing.task.dueStartLocal, '2026-10-05 10:00');
  const fromControls = planTurnover(s, null, listing(), controls)!;
  assert.equal(fromControls.task.dueStartLocal, '2026-10-05 11:00');
});

test('checkout on the fall-back day is timed in standard time', () => {
  // 2026-11-01: Denver goes from MDT (−6) to MST (−7) at 02:00.
  const plan = planTurnover(stay('a', '2026-10-30', '2026-11-01'), null, listing(), controls)!;
  assert.equal(iso(plan.task.dueStartAtMs), '2026-11-01T18:00:00.000Z');
  assert.equal(plan.task.dueStartLocal, '2026-11-01 11:00');
});

test('the digest is stable, moves with the plan, and ignores the checklist and assignee', () => {
  const a = planTurnover(stay('a', '2026-10-02', '2026-10-05'), null, listing(), controls)!;
  const again = planTurnover(stay('a', '2026-10-02', '2026-10-05'), null, listing(), controls)!;
  assert.equal(a.digest, again.digest);
  const otherList = planTurnover(stay('a', '2026-10-02', '2026-10-05'), null, listing({ checklistTemplate: [], defaultAssigneeUid: null }), controls)!;
  assert.equal(otherList.digest, a.digest);
  const moved = planTurnover(stay('a', '2026-10-02', '2026-10-06'), null, listing(), controls)!;
  assert.notEqual(moved.digest, a.digest);
  assert.equal(isInactiveTurnoverDigest(inactiveTurnoverDigest('a')), true);
  assert.equal(isInactiveTurnoverDigest(a.digest), false);
});

test('no zone, no plan: a turnover is never timed in a guessed zone', () => {
  assert.throws(() => planTurnover(stay('a', '2026-10-02', '2026-10-05'), null, listing(), { ...controls, timeZone: null }));
  assert.throws(() => planTurnover(stay('a', '2026-10-02', '2026-10-05'), null, listing(), { ...controls, timeZone: 'Mountain' }));
});

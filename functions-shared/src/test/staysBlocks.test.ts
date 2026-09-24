import test from 'node:test';
import assert from 'node:assert/strict';

import { ECHO_PREP_NIGHTS, MAX_BLOCK_RANGES, markEchoes, normalizeBlockRanges, sameBlockRanges } from '../stays/blocks';
import { addDays } from '../stays/dates';

const CLAMP = { clampFrom: '2026-08-02', clampTo: '2028-03-24' };

test('block ranges are clamped to the horizon, sorted, and merged when they overlap or touch', () => {
  const { ranges, dropped } = normalizeBlockRanges(
    [
      { checkIn: '2026-10-20', checkOut: '2026-10-22' },
      { checkIn: '2026-10-15', checkOut: '2026-10-20' }, // touches the next: one range
      { checkIn: '2026-10-16', checkOut: '2026-10-18' }, // inside: absorbed
      { checkIn: '2026-07-01', checkOut: '2026-08-05' }, // starts before the horizon
      { checkIn: '2028-03-01', checkOut: '2029-01-01' }, // ends after it
      { checkIn: '2026-06-01', checkOut: '2026-06-10' }, // wholly before: dropped
      { checkIn: '2026-11-01', checkOut: '2026-11-03' },
    ],
    CLAMP,
  );
  assert.equal(dropped, 0);
  assert.deepEqual(ranges, [
    { checkIn: '2026-08-02', checkOut: '2026-08-05', echo: false },
    { checkIn: '2026-10-15', checkOut: '2026-10-22', echo: false },
    { checkIn: '2026-11-01', checkOut: '2026-11-03', echo: false },
    { checkIn: '2028-03-01', checkOut: '2028-03-24', echo: false },
  ]);
});

test('the same blocks in any order give the same ranges (the set, not the UIDs, is what counts)', () => {
  const events = [
    { checkIn: '2026-10-01', checkOut: '2026-10-03' },
    { checkIn: '2026-10-10', checkOut: '2026-10-12' },
    { checkIn: '2026-10-02', checkOut: '2026-10-05' },
  ];
  const a = normalizeBlockRanges(events, CLAMP).ranges;
  const b = normalizeBlockRanges([...events].reverse(), CLAMP).ranges;
  assert.ok(sameBlockRanges(a, b));
  assert.equal(sameBlockRanges(a, [...a.slice(0, 1)]), false);
  assert.equal(sameBlockRanges(a, a.map((r, i) => ({ ...r, echo: i === 0 }))), false);
});

test('at most 500 ranges are kept', () => {
  // 507 single nights back to back merge into one range.
  const touching = Array.from({ length: MAX_BLOCK_RANGES + 7 }, (_, i) => ({
    checkIn: addDays('2026-08-10', i),
    checkOut: addDays('2026-08-10', i + 1),
  }));
  assert.equal(normalizeBlockRanges(touching, { clampFrom: '2026-08-02', clampTo: '2030-01-01' }).ranges.length, 1);
  // 600 single nights with a free night between each: the first 500 are kept.
  const tooMany = normalizeBlockRanges(
    Array.from({ length: 600 }, (_, i) => ({ checkIn: addDays('2026-08-03', i * 2), checkOut: addDays('2026-08-03', i * 2 + 1) })),
    { clampFrom: '2026-08-02', clampTo: '2030-01-01' },
  );
  assert.equal(tooMany.ranges.length, MAX_BLOCK_RANGES);
  assert.equal(tooMany.dropped, 100);
});

test('an echo is a block our own exported stays fully cover, allowing up to 3 prep nights at each end', () => {
  const stays = [
    { checkIn: '2026-10-10', checkOut: '2026-10-13' },
    { checkIn: '2026-10-13', checkOut: '2026-10-15' },
  ];
  const r = (checkIn: string, checkOut: string) => ({ checkIn, checkOut, echo: false });
  const marked = markEchoes(
    [
      r('2026-10-10', '2026-10-15'), // exactly our two stays back to back
      r('2026-10-07', '2026-10-18'), // plus 3 prep nights each side
      r('2026-10-06', '2026-10-15'), // 4 uncovered nights before: not ours
      r('2026-10-20', '2026-10-22'), // nothing of ours
      r('2026-10-11', '2026-10-12'), // inside a stay
    ],
    stays,
  );
  assert.deepEqual(
    marked.map((m) => m.echo),
    [true, true, false, false, true],
  );
  assert.equal(ECHO_PREP_NIGHTS, 3);
  // A gap between two of our stays inside the block means it is not only ours.
  const gap = markEchoes([r('2026-10-01', '2026-10-09')], [
    { checkIn: '2026-10-01', checkOut: '2026-10-03' },
    { checkIn: '2026-10-06', checkOut: '2026-10-09' },
  ]);
  assert.equal(gap[0].echo, false);
  // Nothing exported: nothing is an echo.
  assert.deepEqual(markEchoes([r('2026-10-10', '2026-10-15')], []).map((m) => m.echo), [false]);
});

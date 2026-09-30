import test from 'node:test';
import assert from 'node:assert/strict';

import { moveOutFutureDateRefusal, moveOutInstant } from '../moveOutDate';

/**
 * The move-out screen used to send local midnight with no offset
 * (toIso8601String() on a local DateTime), which Node read as UTC, so the
 * day the owner picked showed as the evening before in US time zones. The
 * screen now sends the calendar day; the server dates both at noon UTC.
 */

const iso = (d: Date | null) => d?.toISOString() ?? null;

test('a calendar day is dated at noon UTC', () => {
  assert.equal(iso(moveOutInstant('2026-09-23')), '2026-09-23T12:00:00.000Z');
  assert.equal(iso(moveOutInstant(' 2026-01-01 ')), '2026-01-01T12:00:00.000Z');
  assert.equal(iso(moveOutInstant('2028-02-29')), '2028-02-29T12:00:00.000Z');
});

test("the deployed client's zoneless local time is read as its calendar day", () => {
  // Dart's toIso8601String() of DateTime(2026, 9, 23): no Z, no offset.
  assert.equal(iso(moveOutInstant('2026-09-23T00:00:00.000')), '2026-09-23T12:00:00.000Z');
  // Its default is DateTime.now(), so the time of day is whatever it was.
  assert.equal(iso(moveOutInstant('2026-09-23T15:42:10.123456')), '2026-09-23T12:00:00.000Z');
  assert.equal(iso(moveOutInstant('2026-09-23T23:59')), '2026-09-23T12:00:00.000Z');
});

test('an instant with a zone is kept as given', () => {
  assert.equal(iso(moveOutInstant('2026-09-23T12:00:00Z')), '2026-09-23T12:00:00.000Z');
  assert.equal(iso(moveOutInstant('2026-09-23T03:30:00.000-05:00')), '2026-09-23T08:30:00.000Z');
});

test('what is not a date is null', () => {
  assert.equal(moveOutInstant('2026-02-30'), null);
  assert.equal(moveOutInstant('2026-13-01'), null);
  assert.equal(moveOutInstant('2026-09-00'), null);
  assert.equal(moveOutInstant('2026-02-30T00:00:00.000'), null);
  assert.equal(moveOutInstant('yesterday'), null);
  assert.equal(moveOutInstant(''), null);
  assert.equal(moveOutInstant(1758628800000), null);
  assert.equal(moveOutInstant(null), null);
  assert.equal(moveOutInstant(undefined), null);
});

test('a move-out dated after today (UTC) is refused; today and earlier are not', () => {
  // The screen's date picker ends at today; a direct call or an old page
  // could send a later day, prorating days that have not happened.
  const now = new Date('2026-09-30T15:00:00Z');
  const day = (text: string) => moveOutInstant(text)!;
  assert.equal(moveOutFutureDateRefusal(day('2026-09-30'), now), null);
  assert.equal(moveOutFutureDateRefusal(day('2026-09-29'), now), null);
  assert.equal(moveOutFutureDateRefusal(day('2025-12-31'), now), null);
  assert.match(moveOutFutureDateRefusal(day('2026-10-01'), now) ?? '', /^The move-out date is after today, so nothing was moved out\./);
  assert.match(moveOutFutureDateRefusal(day('2027-01-01'), now) ?? '', /after today/);
  // Just after midnight UTC, which is still yesterday evening in the US:
  // today in UTC is allowed, the next day is not.
  const early = new Date('2026-10-01T00:30:00Z');
  assert.equal(moveOutFutureDateRefusal(day('2026-10-01'), early), null);
  assert.notEqual(moveOutFutureDateRefusal(day('2026-10-02'), early), null);
  // An instant with a zone is judged by its UTC day.
  assert.equal(moveOutFutureDateRefusal(day('2026-09-30T23:30:00Z'), now), null);
  assert.notEqual(moveOutFutureDateRefusal(day('2026-09-30T23:30:00-05:00'), now), null);
});

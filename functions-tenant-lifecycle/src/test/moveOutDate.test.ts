import test from 'node:test';
import assert from 'node:assert/strict';

import { moveOutInstant } from '../moveOutDate';

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

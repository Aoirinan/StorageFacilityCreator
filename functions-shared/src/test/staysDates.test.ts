import test from 'node:test';
import assert from 'node:assert/strict';

import {
  addDays,
  diffDays,
  enumerateNights,
  facilityLocalHour,
  facilityLocalMinute,
  facilityToday,
  isValidHourMinute,
  isValidIanaZone,
  isValidYmd,
  localDateTimeToUtc,
  monthEnd,
  monthOf,
  monthStart,
  monthsSpanned,
  slotKey,
  utcToLocalString,
  weekdayOfYmd,
} from '../stays/dates';

const DENVER = 'America/Denver';

test('dates are validated as real calendar days', () => {
  assert.equal(isValidYmd('2026-02-28'), true);
  assert.equal(isValidYmd('2026-02-29'), false);
  assert.equal(isValidYmd('2028-02-29'), true);
  assert.equal(isValidYmd('2026-13-01'), false);
  assert.equal(isValidYmd('2026-1-01'), false);
  assert.equal(isValidYmd(20261001), false);
  assert.equal(isValidHourMinute('15:00'), true);
  assert.equal(isValidHourMinute('24:00'), false);
  assert.equal(isValidHourMinute('9:00'), false);
});

test('calendar math crosses months, years and leap days', () => {
  assert.equal(addDays('2026-12-31', 1), '2027-01-01');
  assert.equal(addDays('2028-02-28', 1), '2028-02-29');
  assert.equal(addDays('2026-03-01', -1), '2026-02-28');
  assert.equal(diffDays('2026-10-03', '2026-10-06'), 3);
  assert.equal(diffDays('2026-10-06', '2026-10-03'), -3);
  // DST days are still one calendar day apart: no zone is involved.
  assert.equal(diffDays('2026-10-31', '2026-11-02'), 2);
});

test('enumerateNights leaves out the exclusive checkout', () => {
  assert.deepEqual(enumerateNights('2026-10-30', '2026-11-02'), ['2026-10-30', '2026-10-31', '2026-11-01']);
  assert.deepEqual(enumerateNights('2026-10-03', '2026-10-03'), []);
  assert.deepEqual(enumerateNights('2026-10-04', '2026-10-03'), []);
});

test('monthsSpanned covers the nights, not the checkout day', () => {
  assert.deepEqual(monthsSpanned('2026-10-30', '2026-11-01'), ['2026-10']);
  assert.deepEqual(monthsSpanned('2026-10-30', '2026-11-02'), ['2026-10', '2026-11']);
  assert.deepEqual(monthsSpanned('2026-12-20', '2027-02-02'), ['2026-12', '2027-01', '2027-02']);
  assert.deepEqual(monthsSpanned('2026-10-03', '2026-10-03'), []);
  assert.equal(monthOf('2026-10-03'), '2026-10');
  assert.equal(monthStart('2026-10'), '2026-10-01');
  assert.equal(monthEnd('2026-12'), '2027-01-01');
});

test('weekdays come from the date alone', () => {
  assert.equal(weekdayOfYmd('2026-10-02'), 5); // Friday
  assert.equal(weekdayOfYmd('2026-10-03'), 6); // Saturday
  assert.equal(weekdayOfYmd('2026-10-04'), 0); // Sunday
});

test('isValidIanaZone refuses bad zones rather than guessing one', () => {
  assert.equal(isValidIanaZone(DENVER), true);
  assert.equal(isValidIanaZone('UTC'), true);
  assert.equal(isValidIanaZone('America/Nowhere'), false);
  assert.equal(isValidIanaZone('MST'), false);
  assert.equal(isValidIanaZone('+05:00'), false);
  assert.equal(isValidIanaZone(''), false);
  assert.equal(isValidIanaZone(null), false);
  assert.throws(() => facilityToday('America/Nowhere', Date.now()));
});

test('facilityToday follows the facility, not UTC, across UTC midnight', () => {
  // 03:30 UTC on Oct 3 is still Oct 2 in Denver (MDT, UTC−6).
  const at = Date.parse('2026-10-03T03:30:00Z');
  assert.equal(facilityToday(DENVER, at), '2026-10-02');
  assert.equal(facilityToday('UTC', at), '2026-10-03');
  assert.equal(facilityLocalHour(DENVER, at), 21);
  assert.equal(facilityLocalMinute(DENVER, at), 30);
  // And at 06:00 UTC it has become Oct 3 there.
  assert.equal(facilityToday(DENVER, Date.parse('2026-10-03T06:00:00Z')), '2026-10-03');
});

test('fall back, 2026-11-01: 01:59 MDT is followed by 01:00 MST', () => {
  const lastMdt = Date.parse('2026-11-01T07:59:00Z'); // 01:59 MDT
  const firstMst = Date.parse('2026-11-01T08:00:00Z'); // 01:00 MST
  assert.equal(facilityLocalHour(DENVER, lastMdt), 1);
  assert.equal(facilityLocalMinute(DENVER, lastMdt), 59);
  assert.equal(facilityLocalHour(DENVER, firstMst), 1);
  assert.equal(facilityLocalMinute(DENVER, firstMst), 0);
  assert.equal(facilityToday(DENVER, firstMst), '2026-11-01');
  assert.equal(utcToLocalString(lastMdt, DENVER), '2026-11-01 01:59');
  assert.equal(utcToLocalString(firstMst, DENVER), '2026-11-01 01:00');
  // 01:30 happens twice; the earlier (MDT) instant is chosen.
  assert.equal(localDateTimeToUtc('2026-11-01', '01:30', DENVER).toISOString(), '2026-11-01T07:30:00.000Z');
  // Checkout at 11:00 that day is MST.
  assert.equal(localDateTimeToUtc('2026-11-01', '11:00', DENVER).toISOString(), '2026-11-01T18:00:00.000Z');
});

test('spring forward, 2027-03-14: 02:00 MST jumps to 03:00 MDT', () => {
  const lastMst = Date.parse('2027-03-14T08:59:00Z'); // 01:59 MST
  const firstMdt = Date.parse('2027-03-14T09:00:00Z'); // 03:00 MDT
  assert.equal(facilityLocalHour(DENVER, lastMst), 1);
  assert.equal(facilityLocalHour(DENVER, firstMdt), 3);
  assert.equal(facilityToday(DENVER, firstMdt), '2027-03-14');
  // 02:30 does not exist; it moves forward by the gap.
  assert.equal(localDateTimeToUtc('2027-03-14', '02:30', DENVER).toISOString(), '2027-03-14T09:30:00.000Z');
  assert.equal(localDateTimeToUtc('2027-03-14', '15:00', DENVER).toISOString(), '2027-03-14T21:00:00.000Z');
  assert.equal(localDateTimeToUtc('2027-03-13', '15:00', DENVER).toISOString(), '2027-03-13T22:00:00.000Z');
});

test('local times round-trip through UTC', () => {
  for (const [ymd, hm] of [
    ['2026-10-03', '15:00'],
    ['2026-12-31', '23:59'],
    ['2027-01-01', '00:00'],
  ]) {
    assert.equal(utcToLocalString(localDateTimeToUtc(ymd, hm, DENVER), DENVER), `${ymd} ${hm}`);
  }
});

test('slotKey floors to the half hour in UTC', () => {
  assert.equal(slotKey(Date.parse('2026-10-03T14:44:59Z')), '2026-10-03T14:30');
  assert.equal(slotKey(Date.parse('2026-10-03T14:29:59Z')), '2026-10-03T14:00');
  assert.equal(slotKey(new Date('2026-10-03T23:59:00Z')), '2026-10-03T23:30');
});

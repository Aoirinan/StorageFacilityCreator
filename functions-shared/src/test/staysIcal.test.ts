import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import {
  AIRBNB_HOSTS,
  ICS_LIMITS,
  IcsParseError,
  classifyEvent,
  extractAirbnbRefs,
  keptSummary,
  parseIcs,
  unescapeText,
} from '../stays/ical';
import { BUILTIN_ICAL_HOSTS } from '../net/safeFetch';

const TZ = 'America/Denver';
const FIXTURES = join(__dirname, '..', '..', 'src', 'test', 'fixtures', 'ical');

/** A fixture with the line ends a real feed might use (git may check it out either way). */
function fixture(name: string, eol: 'lf' | 'crlf' = 'lf'): string {
  const text = readFileSync(join(FIXTURES, name), 'utf8').replace(/\r\n/g, '\n');
  return eol === 'crlf' ? text.replace(/\n/g, '\r\n') : text;
}

function calendar(...events: string[][]): string {
  return ['BEGIN:VCALENDAR', 'VERSION:2.0', ...events.flatMap((e) => ['BEGIN:VEVENT', ...e, 'END:VEVENT']), 'END:VCALENDAR'].join('\r\n');
}

for (const eol of ['lf', 'crlf'] as const) {
  test(`Airbnb export (${eol}): reservations with codes, phone last 4, and "Not available" blocks`, () => {
    const parsed = parseIcs(fixture('airbnb_reserved_and_blocked.ics', eol), TZ);
    assert.equal(parsed.eventCount, 5);
    assert.deepEqual(
      parsed.events.map((e) => [e.checkIn, e.checkOut, classifyEvent('airbnb', e.summary, e.description)]),
      [
        ['2026-10-03', '2026-10-06', 'reservation'],
        ['2026-10-06', '2026-10-10', 'reservation'],
        ['2026-10-15', '2026-10-20', 'block'],
        ['2026-10-20', '2026-10-22', 'block'],
        ['2027-06-01', '2028-01-01', 'block'],
      ],
    );
    // The reservation link was folded across two lines; unfolding rejoins it.
    const refs = extractAirbnbRefs(parsed.events[0].description);
    assert.deepEqual(refs, {
      confirmationCode: 'HMTEST0001',
      reservationUrl: 'https://www.airbnb.com/hosting/reservations/details/HMTEST0001',
      phoneLast4: '0199',
    });
    assert.equal(extractAirbnbRefs(parsed.events[1].description).confirmationCode, 'HMTEST0002');
    assert.equal(keptSummary('airbnb', parsed.events[0].summary), 'Reserved');
    assert.equal(keptSummary('airbnb', parsed.events[2].summary), 'Airbnb (Not available)');
    assert.equal(parsed.events[0].uid, '1418fb94e984-0a1b2c3d4e5f60718293a4b5c6d7e8f9@airbnb.com');
  });
}

test('VRBO: a guest name in the summary is never kept; Blocked and Unavailable are blocks', () => {
  const parsed = parseIcs(fixture('vrbo_basic.ics'), TZ);
  assert.deepEqual(
    parsed.events.map((e) => classifyEvent('vrbo', e.summary, e.description)),
    ['reservation', 'block', 'block'],
  );
  assert.equal(keptSummary('vrbo', parsed.events[0].summary), null);
  assert.equal(keptSummary('airbnb', 'Reserved - Testguest Example'), null);
});

test('Booking.com: CLOSED - Not available is a block unless a reservation reference is present', () => {
  const parsed = parseIcs(fixture('booking_closed.ics'), TZ);
  assert.deepEqual(
    parsed.events.map((e) => [e.checkIn, e.checkOut, classifyEvent('booking', e.summary, e.description)]),
    [
      ['2026-10-05', '2026-10-07', 'block'],
      ['2026-11-08', '2026-11-11', 'reservation'],
    ],
  );
});

test('Google: Z times become Denver dates, the end day is exclusive, cancelled and repeating events are left out', () => {
  const parsed = parseIcs(fixture('google_busy.ics', 'crlf'), TZ);
  // The VTIMEZONE's own RRULEs belong to the zone, not to an event.
  assert.equal(parsed.eventCount, 5);
  assert.equal(parsed.cancelled, 1);
  assert.equal(parsed.skippedRecurring, 1);
  assert.deepEqual(parsed.warnings, ['recurring_events_skipped']);
  assert.deepEqual(
    parsed.events.map((e) => [e.checkIn, e.checkOut, classifyEvent('google', e.summary, e.description)]),
    [
      ['2026-10-20', '2026-10-23', 'reservation'],
      // 16:00 MDT on the 25th to 12:00 on the 27th: the nights of the 25th and 26th.
      ['2026-10-25', '2026-10-27', 'block'],
      // 00:00 MDT to 00:00 MDT: two nights, the end day is free.
      ['2026-10-29', '2026-10-31', 'reservation'],
    ],
  );
  assert.equal(keptSummary('google', parsed.events[0].summary), null);
});

test('BOM, folding, TZID (quoted and unknown), a missing DTEND, DURATION, VALARM text and bad events', () => {
  const text = fixture('folded_bom_tzid.ics');
  assert.ok(text.startsWith('﻿'));
  const parsed = parseIcs(text, TZ);
  assert.equal(parsed.eventCount, 7);
  const byUid = new Map(parsed.events.map((e) => [e.uid, e]));
  // 15:00 New York = 13:00 Denver on the 3rd; 02:00 New York on the 6th = local midnight, exclusive.
  assert.deepEqual([byUid.get('folded-1@stays.test')?.checkIn, byUid.get('folded-1@stays.test')?.checkOut], ['2026-10-03', '2026-10-06']);
  assert.equal(byUid.get('folded-1@stays.test')?.summary, 'A long summary that is folded across two lines');
  assert.equal(byUid.get('folded-1@stays.test')?.description, 'Line one\nLine two, with comma; and semicolon \\ backslash');
  assert.deepEqual([byUid.get('no-end@stays.test')?.checkIn, byUid.get('no-end@stays.test')?.checkOut], ['2026-10-12', '2026-10-13']);
  // 23:00 Los Angeles = 00:00 Denver the next day; 09:00 LA on the 16th is 10:00 Denver.
  assert.deepEqual([byUid.get('quoted-tz@stays.test')?.checkIn, byUid.get('quoted-tz@stays.test')?.checkOut], ['2026-10-15', '2026-10-16']);
  // An unknown zone name is read as facility time, with a warning.
  assert.deepEqual([byUid.get('windows-tz@stays.test')?.checkIn, byUid.get('windows-tz@stays.test')?.checkOut], ['2026-10-18', '2026-10-19']);
  assert.deepEqual([byUid.get('duration@stays.test')?.checkIn, byUid.get('duration@stays.test')?.checkOut], ['2026-11-20', '2026-11-23']);
  assert.equal(byUid.has('inverted@stays.test'), false);
  assert.equal(byUid.has('recurring-override@stays.test'), false);
  assert.equal(parsed.skippedInvalid, 1);
  assert.equal(parsed.skippedRecurring, 1);
  assert.deepEqual(parsed.warnings, ['events_skipped', 'recurring_events_skipped', 'unknown_time_zone']);
});

test('DATE-TIME across the Denver fall-back (2026-11-01 01:59 MDT → 01:00 MST)', () => {
  const parsed = parseIcs(
    calendar(
      // 07:30Z is 01:30 MDT (first pass) on Nov 1; 07:00Z on Nov 2 is 00:00 MST: one night.
      ['UID:a', 'DTSTART:20261101T073000Z', 'DTEND:20261102T070000Z'],
      // 16:00 MDT on Oct 31 to 01:30 MST (second pass) on Nov 1: the night of Oct 31.
      ['UID:b', 'DTSTART:20261031T220000Z', 'DTEND:20261101T083000Z'],
      // 01:30 MDT to 01:30 MST: an hour apart, the same local day, no night.
      ['UID:c', 'DTSTART:20261101T073000Z', 'DTEND:20261101T083000Z'],
    ),
    TZ,
  );
  assert.deepEqual(
    parsed.events.map((e) => [e.uid, e.checkIn, e.checkOut]),
    [
      ['a', '2026-11-01', '2026-11-02'],
      ['b', '2026-10-31', '2026-11-01'],
    ],
  );
  assert.equal(parsed.withinOneDay, 1);
});

test('a stay with check-in and check-out times frees its checkout night; an event inside one day holds none', () => {
  const parsed = parseIcs(
    calendar(
      // Fri 15:00 to Sun 11:00 (MDT): Friday and Saturday nights.
      ['UID:stay', 'DTSTART:20261009T210000Z', 'DTEND:20261011T170000Z', 'SUMMARY:Smith family'],
      // A cleaning on Sunday 10:00-14:00 must not block Sunday night.
      ['UID:clean', 'DTSTART:20261011T160000Z', 'DTEND:20261011T200000Z', 'SUMMARY:Cleaning'],
      // A timed start with no end is a moment.
      ['UID:moment', 'DTSTART;TZID=America/Denver:20261012T090000'],
    ),
    TZ,
  );
  assert.deepEqual(parsed.events.map((e) => [e.uid, e.checkIn, e.checkOut]), [['stay', '2026-10-09', '2026-10-11']]);
  assert.equal(parsed.withinOneDay, 2);
  assert.deepEqual(parsed.warnings, []);
});

test('parsing is all-or-nothing: not a calendar, cut off, or malformed throws invalid_feed', () => {
  const html = fixture('malformed_html.txt');
  assert.throws(() => parseIcs(html, TZ), (e: unknown) => e instanceof IcsParseError && e.code === 'invalid_feed');
  const cut = fixture('airbnb_reserved_and_blocked.ics').split('\n').slice(0, 20).join('\n');
  assert.throws(() => parseIcs(cut, TZ), (e: unknown) => e instanceof IcsParseError && e.code === 'invalid_feed');
  const mismatched = 'BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:x\nDTSTART;VALUE=DATE:20261001\nEND:VCALENDAR\n';
  assert.throws(() => parseIcs(mismatched, TZ), (e: unknown) => e instanceof IcsParseError && e.code === 'invalid_feed');
  assert.throws(() => parseIcs('', TZ), (e: unknown) => e instanceof IcsParseError);
});

test('caps: more than 3000 events or too many lines is too_large; an over-long line is cut with a warning', () => {
  const many = calendar(...Array.from({ length: ICS_LIMITS.maxEvents + 1 }, (_, i) => [`UID:${i}`, 'DTSTART;VALUE=DATE:20261001']));
  assert.throws(() => parseIcs(many, TZ), (e: unknown) => e instanceof IcsParseError && e.code === 'too_large');
  const atCap = calendar(...Array.from({ length: ICS_LIMITS.maxEvents }, (_, i) => [`UID:${i}`, 'DTSTART;VALUE=DATE:20261001']));
  assert.equal(parseIcs(atCap, TZ).events.length, ICS_LIMITS.maxEvents);

  const lines = ['BEGIN:VCALENDAR', ...Array.from({ length: ICS_LIMITS.maxLines + 1 }, () => 'X-FILLER:1'), 'END:VCALENDAR'].join('\n');
  assert.throws(() => parseIcs(lines, TZ), (e: unknown) => e instanceof IcsParseError && e.code === 'too_large');

  const long = calendar(['UID:long', 'DTSTART;VALUE=DATE:20261001', `DESCRIPTION:${'x'.repeat(20_000)}`]);
  const parsed = parseIcs(long, TZ);
  assert.equal(parsed.events.length, 1);
  assert.ok((parsed.events[0].description ?? '').length < ICS_LIMITS.maxLineChars);
  assert.deepEqual(parsed.warnings, ['long_lines_cut']);
});

test('parseIcs refuses to guess a zone', () => {
  assert.throws(() => parseIcs(fixture('vrbo_basic.ics'), 'Mountain'), /time zone/);
});

test('classifyEvent follows each channel rule', () => {
  assert.equal(classifyEvent('airbnb', 'Reserved', null), 'reservation');
  assert.equal(classifyEvent('airbnb', 'Airbnb (Not available)', null), 'block');
  assert.equal(classifyEvent('airbnb', 'Something new', 'https://www.airbnb.com/hosting/reservations/details/HMABC12345'), 'reservation');
  assert.equal(classifyEvent('airbnb', 'Something new', null), 'block');
  for (const provider of ['vrbo', 'google', 'hipcamp', 'other']) {
    assert.equal(classifyEvent(provider, 'Blocked', null), 'block');
    assert.equal(classifyEvent(provider, 'NOT AVAILABLE', null), 'block');
    assert.equal(classifyEvent(provider, 'Unavailable', null), 'block');
    assert.equal(classifyEvent(provider, 'Closed for winter', null), 'block');
    assert.equal(classifyEvent(provider, 'Smith family', null), 'reservation');
  }
  assert.equal(classifyEvent('booking', 'CLOSED - Not available', null), 'block');
  assert.equal(classifyEvent('booking', 'CLOSED - Not available', 'Booking number #4000123456'), 'reservation');
});

test('extractAirbnbRefs trusts only https reservation links on Airbnb hosts', () => {
  const at = (url: string) => extractAirbnbRefs(`Reservation URL: ${url}`).confirmationCode;
  assert.equal(at('https://www.airbnb.ca/hosting/reservations/details/HMCANADA01'), 'HMCANADA01');
  assert.equal(at('https://www.airbnb.com/hosting/reservations/details/HMABC12345/'), 'HMABC12345');
  assert.equal(at('http://www.airbnb.com/hosting/reservations/details/HMABC12345'), null);
  assert.equal(at('https://www.airbnb.com.evil.com/hosting/reservations/details/HMABC12345'), null);
  assert.equal(at('https://evil.com/?u=https://www.airbnb.com/hosting/reservations/details/HMABC12345'), null);
  assert.equal(at('https://www.airbnb.com/hosting/reservations/details/hmabc12345'), null);
  assert.equal(at('https://www.airbnb.com/hosting/reservations/HMABC12345'), null);
  assert.equal(at('https://user:pw@www.airbnb.com/hosting/reservations/details/HMABC12345'), null);
  assert.equal(extractAirbnbRefs(null).confirmationCode, null);
  assert.equal(extractAirbnbRefs('Phone Number (Last 4 Digits): 12345').phoneLast4, null);
  for (const host of AIRBNB_HOSTS) assert.ok(BUILTIN_ICAL_HOSTS.includes(host), host);
});

test('unescapeText handles the RFC 5545 escapes only', () => {
  assert.equal(unescapeText('a\\nb\\Nc\\,d\\;e\\\\f\\x'), 'a\nb\nc,d;e\\f\\x');
});

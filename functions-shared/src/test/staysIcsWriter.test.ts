import test from 'node:test';
import assert from 'node:assert/strict';

import type { ExportableStay } from '../stays/icsWriter';
import { ICS_BUSY_SUMMARY, buildIcs, escapeText, exportUid, foldLine, inExportScope, staysForExport } from '../stays/icsWriter';
import { parseIcs } from '../stays/ical';

const NOW = Date.parse('2026-10-01T18:00:00Z');

test('the calendar uses CRLF everywhere and says only "Not available"', () => {
  const ics = buildIcs({
    calName: 'SFC Airbnb 1',
    events: [
      { stayId: 'man_0123456789abcdef0123456789abcdef', checkIn: '2026-10-03', checkOut: '2026-10-06', version: 2 },
      { stayId: 'airbnb_HMSECRET01', checkIn: '2026-10-08', checkOut: '2026-10-09', version: 1 },
    ],
    now: NOW,
  });
  assert.ok(ics.endsWith('\r\n'));
  assert.equal(/[^\r]\n/.test(ics), false, 'no bare LF');
  assert.equal(/\r(?!\n)/.test(ics), false, 'no bare CR');
  const lines = ics.split('\r\n').filter(Boolean);
  assert.deepEqual(lines.slice(0, 6), [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Storage Facility Creator//Stays//EN',
    'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH',
    'X-WR-CALNAME:SFC Airbnb 1',
  ]);
  const first = lines.slice(lines.indexOf('BEGIN:VEVENT'), lines.indexOf('END:VEVENT') + 1);
  assert.deepEqual(first, [
    'BEGIN:VEVENT',
    `UID:${exportUid('man_0123456789abcdef0123456789abcdef')}`,
    'DTSTAMP:20261001T180000Z',
    'DTSTART;VALUE=DATE:20261003',
    'DTEND;VALUE=DATE:20261006',
    'SEQUENCE:2',
    `SUMMARY:${ICS_BUSY_SUMMARY}`,
    'TRANSP:OPAQUE',
    'END:VEVENT',
  ]);
  // No stay id, code or description ever leaves.
  assert.equal(ics.includes('HMSECRET01'), false);
  assert.equal(ics.includes('man_'), false);
  assert.equal(ics.includes('DESCRIPTION'), false);
  // Our own parser reads it back to the same nights.
  const back = parseIcs(ics, 'America/Denver');
  assert.deepEqual(
    back.events.map((e) => [e.checkIn, e.checkOut, e.summary]),
    [
      ['2026-10-03', '2026-10-06', 'Not available'],
      ['2026-10-08', '2026-10-09', 'Not available'],
    ],
  );
});

test('UIDs are stable per stay, differ between stays, and hide the stay id', () => {
  const a = exportUid('airbnb_HMABC12345');
  assert.equal(a, exportUid('airbnb_HMABC12345'));
  assert.notEqual(a, exportUid('airbnb_HMABC12346'));
  assert.match(a, /^[a-f0-9]{32}@stays\.storagefacilitycreator\.com$/);
});

test('long lines fold at 75 octets without splitting a character, and unfold to the original', () => {
  const name = `Cabañas del río ${'é'.repeat(60)} end`;
  const line = `X-WR-CALNAME:${escapeText(name)}`;
  const folded = foldLine(line);
  const physical = folded.split('\r\n');
  assert.ok(physical.length > 1);
  for (const p of physical) assert.ok(Buffer.byteLength(p, 'utf8') <= 75, `${Buffer.byteLength(p, 'utf8')} octets`);
  for (const p of physical.slice(1)) assert.ok(p.startsWith(' '));
  assert.equal(physical.map((p, i) => (i === 0 ? p : p.slice(1))).join(''), line);
  const ics = buildIcs({ calName: name, events: [], now: NOW });
  assert.equal(ics.includes('�'), false);
  assert.equal(foldLine('SHORT:1'), 'SHORT:1');
});

test('text is escaped', () => {
  assert.equal(escapeText('a,b;c\\d\ne'), 'a\\,b\\;c\\\\d\\ne');
});

function stay(stayId: string, patch: Partial<ExportableStay>): ExportableStay {
  return { stayId, status: 'confirmed', kind: 'reservation', source: 'direct', checkIn: '2026-10-10', checkOut: '2026-10-12', version: 1, ...patch };
}

test('scope: blocks only, then SFC bookings, then other channels; never the target channel itself', () => {
  const all = [
    stay('owner', { kind: 'owner_block', source: 'owner' }),
    stay('maint', { kind: 'maintenance_block', source: 'owner' }),
    stay('direct', { source: 'direct' }),
    stay('phone', { source: 'phone' }),
    stay('walkup', { source: 'walk_up' }),
    stay('airbnb', { source: 'airbnb' }),
    stay('vrbo', { source: 'vrbo' }),
    stay('booking', { source: 'booking' }),
  ];
  const ids = (scope: 'blocks_only' | 'sfc' | 'all', target: 'airbnb' | 'vrbo' | 'google') =>
    staysForExport(all, { scope, targetProvider: target, todayYmd: '2026-10-01', lastCheckInYmd: '2028-03-24' }).map((s) => s.stayId);
  assert.deepEqual(ids('blocks_only', 'airbnb'), ['owner', 'maint']);
  assert.deepEqual(ids('sfc', 'airbnb'), ['owner', 'maint', 'direct', 'phone', 'walkup']);
  assert.deepEqual(ids('all', 'airbnb'), ['owner', 'maint', 'direct', 'phone', 'walkup', 'vrbo', 'booking']);
  assert.deepEqual(ids('all', 'vrbo'), ['owner', 'maint', 'direct', 'phone', 'walkup', 'airbnb', 'booking']);
  assert.deepEqual(ids('all', 'google'), ['owner', 'maint', 'direct', 'phone', 'walkup', 'airbnb', 'vrbo', 'booking']);
  assert.equal(inExportScope({ kind: 'reservation', source: 'airbnb' }, 'all', 'airbnb'), false);
});

test('only active stays from today to today+540 are sent', () => {
  const list = [
    stay('ok', {}),
    stay('conflict', { status: 'conflict' }),
    stay('cancelled', { status: 'cancelled' }),
    stay('removed', { status: 'removed_from_feed' }),
    stay('past', { checkIn: '2026-09-20', checkOut: '2026-09-30' }),
    stay('departing', { checkIn: '2026-09-28', checkOut: '2026-10-01' }),
    stay('far', { checkIn: '2028-03-25', checkOut: '2028-03-27' }),
    stay('edge', { checkIn: '2028-03-24', checkOut: '2028-03-26' }),
  ];
  const out = staysForExport(list, { scope: 'sfc', targetProvider: 'airbnb', todayYmd: '2026-10-01', lastCheckInYmd: '2028-03-24' }).map(
    (s) => s.stayId,
  );
  assert.deepEqual(out, ['ok', 'conflict', 'departing', 'edge']);
});

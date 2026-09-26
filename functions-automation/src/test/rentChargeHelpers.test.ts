import test from 'node:test';
import assert from 'node:assert/strict';
import {
  buildRentChargeDescription,
  hasRentChargeForMonth,
  isRentChargeForMonth,
  rentChargeDateFor,
  rentChargeDuplicateWindow,
  rentChargeMonthAt,
  rentChargeMonthFromInput,
  shouldChargeTenant,
} from '../rentChargeHelpers';

/** Mimics a Firestore Timestamp well enough for the duplicate check. */
const ts = (date: Date) => ({ toDate: () => date });

// --- who gets charged -------------------------------------------------------

test('shouldChargeTenant requires an assigned unit and a positive rate', () => {
  assert.equal(shouldChargeTenant({ unitNumber: '101', monthlyRate: 120 }), true);
});

test('shouldChargeTenant skips tenants with no real unit', () => {
  assert.equal(shouldChargeTenant({ unitNumber: '', monthlyRate: 120 }), false);
  assert.equal(shouldChargeTenant({ unitNumber: '   ', monthlyRate: 120 }), false);
  assert.equal(shouldChargeTenant({ monthlyRate: 120 }), false);
});

test('shouldChargeTenant skips non-billable rates rather than inventing revenue', () => {
  assert.equal(shouldChargeTenant({ unitNumber: '101', monthlyRate: 0 }), false);
  assert.equal(shouldChargeTenant({ unitNumber: '101', monthlyRate: -50 }), false);
  assert.equal(shouldChargeTenant({ unitNumber: '101' }), false);
  assert.equal(shouldChargeTenant({ unitNumber: '101', monthlyRate: '120' }), false);
  assert.equal(shouldChargeTenant({ unitNumber: '101', monthlyRate: NaN }), false);
});

test('shouldChargeTenant handles missing tenant data', () => {
  assert.equal(shouldChargeTenant(undefined), false);
  assert.equal(shouldChargeTenant(null), false);
});

// --- duplicate protection ---------------------------------------------------

const recurring = (date: Date, month: number, year: number) => ({
  entryDate: ts(date),
  metadata: { recurringCharge: true, chargeType: 'monthlyRent', month, year },
});

test('hasRentChargeForMonth detects this month\'s recurring charge', () => {
  const entries = [recurring(new Date(2026, 2, 1), 3, 2026)];
  assert.equal(hasRentChargeForMonth(entries, 3, 2026), true);
});

test('hasRentChargeForMonth ignores other months and years', () => {
  const entries = [
    recurring(new Date(2026, 1, 1), 2, 2026),
    recurring(new Date(2025, 2, 1), 3, 2025),
  ];
  assert.equal(hasRentChargeForMonth(entries, 3, 2026), false);
});

test('hasRentChargeForMonth does not mistake a manual charge for the recurring one', () => {
  // A one-off adjustment dated in the same month must not suppress rent, or the
  // tenant silently goes un-billed for the month.
  const entries = [
    {
      entryDate: ts(new Date(2026, 2, 10)),
      metadata: { chargeType: 'lateFee' },
    },
    {
      entryDate: ts(new Date(2026, 2, 12)),
      metadata: {},
    },
  ];
  assert.equal(hasRentChargeForMonth(entries, 3, 2026), false);
});

test('hasRentChargeForMonth tolerates entries with no date', () => {
  assert.equal(hasRentChargeForMonth([{ metadata: {} }, {}], 3, 2026), false);
  assert.equal(hasRentChargeForMonth([], 3, 2026), false);
});

test('hasRentChargeForMonth still finds a charge posted at 00:00 UTC on the 1st', () => {
  // Every charge the scheduled job raised before the noon-UTC fix sits at
  // midnight UTC. Missing one of those would bill the month a second time.
  const entries = [recurring(new Date('2026-10-01T00:00:00Z'), 10, 2026)];
  assert.equal(hasRentChargeForMonth(entries, 10, 2026), true);
});

test('hasRentChargeForMonth finds a charge the app posted at a local midnight east of UTC', () => {
  // The app dates its charges at the operator's local midnight; in Europe that
  // is the previous day in UTC. Metadata says October, so it is October's.
  const entries = [recurring(new Date('2026-09-30T22:00:00Z'), 10, 2026)];
  assert.equal(hasRentChargeForMonth(entries, 10, 2026), true);
});

test('hasRentChargeForMonth finds a charge at the new noon-UTC date', () => {
  const entries = [recurring(rentChargeDateFor(2026, 10), 10, 2026)];
  assert.equal(hasRentChargeForMonth(entries, 10, 2026), true);
});

test('hasRentChargeForMonth ignores a charge dated well outside the month', () => {
  // Metadata alone is not enough: an entry dated months away is not this
  // month's recurring charge, whatever it claims.
  const entries = [recurring(new Date('2026-12-15T12:00:00Z'), 10, 2026)];
  assert.equal(hasRentChargeForMonth(entries, 10, 2026), false);
});

test('isRentChargeForMonth handles missing entries', () => {
  assert.equal(isRentChargeForMonth(undefined, 10, 2026), false);
  assert.equal(isRentChargeForMonth(null, 10, 2026), false);
});

// --- charge date ------------------------------------------------------------

/** Calendar date of an instant as seen in a time zone, e.g. "2026-10-01". */
const dayIn = (date: Date, timeZone: string) =>
  new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(date);

test('rentChargeDateFor is the 1st of the month at 12:00 UTC', () => {
  assert.equal(rentChargeDateFor(2026, 10).toISOString(), '2026-10-01T12:00:00.000Z');
  assert.equal(rentChargeDateFor(2026, 1).toISOString(), '2026-01-01T12:00:00.000Z');
  assert.equal(rentChargeDateFor(2026, 12).toISOString(), '2026-12-01T12:00:00.000Z');
});

test('rentChargeDateFor is the 1st in every US time zone and in Europe', () => {
  const zones = [
    'Pacific/Honolulu',
    'America/Anchorage',
    'America/Los_Angeles',
    'America/Denver',
    'America/Chicago',
    'America/New_York',
    'Europe/London',
    'Europe/Berlin',
  ];
  // Every month of the year, so both sides of daylight saving are covered.
  for (let month = 1; month <= 12; month += 1) {
    const expected = `2026-${String(month).padStart(2, '0')}-01`;
    const charge = rentChargeDateFor(2026, month);
    for (const zone of zones) {
      assert.equal(dayIn(charge, zone), expected, `${zone}, month ${month}`);
    }
  }
});

test('the old 00:00 UTC date was the previous day in US time zones', () => {
  // The bug this fixes: October rent showed as dated September 30.
  const old = new Date('2026-10-01T00:00:00Z');
  assert.equal(dayIn(old, 'America/Chicago'), '2026-09-30');
  assert.equal(dayIn(old, 'America/Denver'), '2026-09-30');
});

// --- which month a run bills ------------------------------------------------

test('a run seconds after midnight UTC on the 1st bills the new month', () => {
  // The scheduler fires at 00:00 UTC on the 1st.
  assert.deepEqual(rentChargeMonthAt(new Date('2026-10-01T00:00:05Z')), { year: 2026, month: 10 });
  assert.deepEqual(rentChargeMonthAt(new Date('2027-01-01T00:00:05Z')), { year: 2027, month: 1 });
});

test('the scheduler run date names the billing month', () => {
  // The job carries the scheduler's UTC run date, e.g. "2026-10-01".
  assert.deepEqual(rentChargeMonthFromInput('2026-10-01'), { year: 2026, month: 10 });
});

test('rentChargeMonthFromInput takes the month the operator picked', () => {
  // The app sends a local DateTime.toIso8601String() with no offset; the
  // leading year and month are the operator's month, whatever the server zone.
  assert.deepEqual(rentChargeMonthFromInput('2026-10-15T00:00:00.000'), { year: 2026, month: 10 });
  assert.deepEqual(rentChargeMonthFromInput('2026-10-01T00:00:00.000'), { year: 2026, month: 10 });
  assert.deepEqual(rentChargeMonthFromInput('2026-12-31T23:59:59.999'), { year: 2026, month: 12 });
});

test('rentChargeMonthFromInput rejects values it cannot read', () => {
  assert.equal(rentChargeMonthFromInput('2026-13-01'), null);
  assert.equal(rentChargeMonthFromInput('2026-00-01'), null);
  assert.equal(rentChargeMonthFromInput('not a date'), null);
  assert.equal(rentChargeMonthFromInput(undefined), null);
  assert.equal(rentChargeMonthFromInput({}), null);
});

test('rentChargeMonthFromInput reads an epoch time in UTC', () => {
  const epoch = Date.parse('2026-10-01T00:00:05Z');
  assert.deepEqual(rentChargeMonthFromInput(epoch), { year: 2026, month: 10 });
});

// --- duplicate window -------------------------------------------------------

test('the duplicate window covers the whole month plus a day either side', () => {
  const { start, end } = rentChargeDuplicateWindow(2026, 10);
  assert.equal(start.toISOString(), '2026-09-30T00:00:00.000Z');
  assert.equal(end.toISOString(), '2026-11-02T00:00:00.000Z');

  const inside = (date: Date) => date >= start && date < end;
  assert.equal(inside(new Date('2026-10-01T00:00:00Z')), true, 'old midnight-UTC charge');
  assert.equal(inside(rentChargeDateFor(2026, 10)), true, 'new noon-UTC charge');
  assert.equal(inside(new Date('2026-10-31T23:59:59Z')), true, 'end of month');
  assert.equal(inside(rentChargeDateFor(2026, 9)), false, 'previous month');
});

test('the duplicate window rolls over the year end', () => {
  const { start, end } = rentChargeDuplicateWindow(2026, 12);
  assert.equal(start.toISOString(), '2026-11-30T00:00:00.000Z');
  assert.equal(end.toISOString(), '2027-01-02T00:00:00.000Z');
});

test('a run on 2026-10-01 finds the October charge already posted at 00:00 UTC', () => {
  // End to end through the helpers the job uses: pick the month from the run
  // time, then check the ledger. A retry on the 1st must skip, not re-bill.
  const { year, month } = rentChargeMonthAt(new Date('2026-10-01T00:00:05Z'));
  const posted = [recurring(new Date('2026-10-01T00:00:00Z'), 10, 2026)];
  assert.equal(hasRentChargeForMonth(posted, month, year), true);
  // September's charge does not count for October.
  const september = [recurring(new Date('2026-09-01T00:00:00Z'), 9, 2026)];
  assert.equal(hasRentChargeForMonth(september, month, year), false);
});

// --- description ------------------------------------------------------------

test('buildRentChargeDescription names the month and year', () => {
  assert.equal(buildRentChargeDescription(2026, 3), 'Monthly Rent - March 2026');
  assert.equal(buildRentChargeDescription(2026, 12), 'Monthly Rent - December 2026');
  assert.equal(buildRentChargeDescription(2027, 1), 'Monthly Rent - January 2027');
});

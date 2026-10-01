import test from 'node:test';
import assert from 'node:assert/strict';
import {
  MoveInRentCover,
  RENT_CHARGE_LEDGER_TYPES,
  buildReducedRentChargeDescription,
  buildRentChargeDescription,
  hasRentChargeForMonth,
  isRentChargeForMonth,
  moveInRentCoversForMonth,
  planMonthlyRentCharge,
  rentChargeDateFor,
  rentChargeDuplicateWindow,
  rentChargeLedgerWindow,
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

// --- rent already charged at move-in -----------------------------------------

/** The online move-in's rows: type 'proratedRent' or 'rent', dated UTC midnight. */
const online = (type: 'proratedRent' | 'rent', iso: string, amount: number, extra: Record<string, any> = {}) => ({
  id: `${type}-${iso}`,
  type,
  status: 'posted',
  referenceId: 'c1',
  amount,
  entryDate: ts(new Date(iso)),
  metadata: { lineItemId: null, isProrated: type === 'proratedRent' },
  ...extra,
});

/**
 * The app wizard's rows: type 'rentCharge' with metadata.lineItemType, the
 * date picked in metadata.moveInDate, and an entryDate that keeps the
 * wizard's time of day.
 */
const app = (
  lineItemType: 'proratedRent' | 'rent',
  moveInDate: string,
  entryIso: string,
  amount: number,
  extra: Record<string, any> = {},
) => ({
  id: `app-${lineItemType}-${moveInDate}`,
  type: 'rentCharge',
  status: 'posted',
  referenceId: 'c1',
  amount,
  entryDate: ts(new Date(entryIso)),
  metadata: { lineItemType, isProrated: lineItemType === 'proratedRent', moveInDate: `${moveInDate}T00:00:00.000` },
  ...extra,
});

const covered = (rows: ReadonlyArray<Record<string, any>>, month: number, year: number) =>
  moveInRentCoversForMonth(rows, month, year);

test('Pinewood: an online move-in dated 1 Oct, charged all of October at move-in, covers October', () => {
  // Unit TEST-1, $1 a month, moved in online in September for a tenancy
  // starting 1 Oct. The job posted "Monthly Rent - October 2026" on top.
  const rows = [
    online('proratedRent', '2026-10-01T00:00:00Z', 1),
    { type: 'payment', status: 'posted', referenceId: 'pi_1', amount: -1, entryDate: ts(new Date('2026-09-23T18:12:00Z')) },
  ];
  assert.equal(hasRentChargeForMonth(rows, 10, 2026), false, 'the old check saw no October charge');
  const covers = covered(rows, 10, 2026);
  assert.deepEqual(covers, [{ contractId: 'c1', monthlyShare: 1, entryIds: ['proratedRent-2026-10-01T00:00:00Z'] }]);
  assert.deepEqual(planMonthlyRentCharge({ monthlyRate: 1, covers, heldUnitCount: 1 }), { action: 'skip', covers });
});

test("the app's prorated rent for a move-in dated the 1st covers that month", () => {
  // Central time: a midnight move-in on 1 Oct is 05:00 UTC.
  const rows = [app('proratedRent', '2026-10-01', '2026-10-01T05:00:00Z', 1)];
  assert.deepEqual(covered(rows, 10, 2026).map((c) => c.monthlyShare), [1]);
  // It does not reach into November.
  assert.deepEqual(covered(rows, 11, 2026), []);
});

test("the app's full month at move-in covers the move-in month", () => {
  const onTheFirst = [app('rent', '2026-10-01', '2026-10-01T05:00:00Z', 120)];
  assert.deepEqual(covered(onTheFirst, 10, 2026).map((c) => c.monthlyShare), [120]);
  // A full month charged for a mid-September move-in is September's, as at
  // move-out: October is still the job's to charge.
  const midSeptember = [app('rent', '2026-09-15', '2026-09-15T14:30:00Z', 120)];
  assert.deepEqual(covered(midSeptember, 10, 2026), []);
});

test('the online "Next Month Rent" covers the month after the move-in', () => {
  const rows = [
    online('proratedRent', '2026-09-20T00:00:00Z', 44),
    online('rent', '2026-09-20T00:00:00Z', 120, { description: 'Next Month Rent' }),
  ];
  const october = covered(rows, 10, 2026);
  assert.deepEqual(october, [{ contractId: 'c1', monthlyShare: 120, entryIds: ['rent-2026-09-20T00:00:00Z'] }]);
  assert.equal(planMonthlyRentCharge({ monthlyRate: 120, covers: october, heldUnitCount: 1 }).action, 'skip');
  // November is not covered: the job charges it.
  assert.deepEqual(covered(rows, 11, 2026), []);
});

test('a December "Next Month Rent" covers January of the next year', () => {
  const rows = [online('rent', '2026-12-20T00:00:00Z', 90)];
  assert.equal(covered(rows, 1, 2027).length, 1);
  assert.deepEqual(covered(rows, 12, 2026), []);
});

test("a mid-month move-in's prorated rent covers only its own month; the job charges the next", () => {
  const onlineRows = [online('proratedRent', '2026-09-15T00:00:00Z', 64)];
  const appRows = [app('proratedRent', '2026-09-15', '2026-09-15T14:30:00Z', 64)];
  assert.deepEqual(covered(onlineRows, 10, 2026), []);
  assert.deepEqual(covered(appRows, 10, 2026), []);
  const plan = planMonthlyRentCharge({ monthlyRate: 120, covers: covered(appRows, 10, 2026), heldUnitCount: 1 });
  assert.deepEqual(plan, { action: 'charge', amount: 120, lessCoveredAtMoveIn: 0, covers: [] });
});

test("an evening move-in on 30 Sep in the app is September's, though its entryDate is 1 Oct in UTC", () => {
  // 30 Sep at 21:00 Central is 02:00 UTC on 1 Oct. Read as an instant, its one
  // prorated day would cover all of October and October would go unbilled.
  const rows = [app('proratedRent', '2026-09-30', '2026-10-01T02:00:00Z', 4)];
  assert.deepEqual(covered(rows, 10, 2026), []);
});

test('a move-in dated later in the month and posted before the 1st covers that month from the move-in', () => {
  // Recorded in September for a tenancy starting 15 Oct. The days before it
  // are not the tenancy's, as at move-out, and 15-31 Oct are charged: a full
  // October from the job charged both again.
  const rows = [app('proratedRent', '2026-10-15', '2026-10-15T14:00:00Z', 54.84)];
  const covers = covered(rows, 10, 2026);
  // Scaled up to the month: 54.84 for 17 of 31 days is $100.00 a month.
  assert.deepEqual(covers.map((c) => c.monthlyShare), [100]);
  assert.equal(planMonthlyRentCharge({ monthlyRate: 100, covers, heldUnitCount: 1 }).action, 'skip');
});

test('a tenancy that starts after the month is not a cover for it', () => {
  // Dated 1 Nov: inside the ledger window's extra day, but November's rent.
  const rows = [online('proratedRent', '2026-11-01T00:00:00Z', 100)];
  assert.deepEqual(covered(rows, 10, 2026), []);
});

test('only posted move-in rent counts', () => {
  const voided = [{ ...online('proratedRent', '2026-10-01T00:00:00Z', 1), status: 'voided' }];
  const pending = [{ ...app('rent', '2026-10-01', '2026-10-01T05:00:00Z', 1), status: 'pending' }];
  assert.deepEqual(covered(voided, 10, 2026), []);
  assert.deepEqual(covered(pending, 10, 2026), []);
});

test('the monthly charge and other ledger rows are not move-in rent', () => {
  const rows = [
    { ...recurring(new Date('2026-10-01T12:00:00Z'), 10, 2026), type: 'rentCharge', status: 'posted', amount: 120 },
    {
      type: 'rentCharge',
      status: 'posted',
      referenceId: 'c1',
      amount: 120,
      entryDate: ts(new Date('2026-10-01T12:00:00Z')),
      metadata: {},
    },
    {
      type: 'insuranceCharge',
      status: 'posted',
      referenceId: 'c1',
      amount: 12,
      entryDate: ts(new Date('2026-10-01T05:00:00Z')),
      metadata: { lineItemType: 'insurance', moveInDate: '2026-10-01T00:00:00.000' },
    },
  ];
  assert.deepEqual(covered(rows, 10, 2026), []);
});

test('a free-month discount at move-in does not make the month uncharged', () => {
  // +120 rent, -120 coupon: the month was charged at move-in and discounted.
  // Charging it again on the 1st would take back the coupon.
  const rows = [
    app('rent', '2026-10-01', '2026-10-01T05:00:00Z', 120),
    {
      type: 'credit',
      status: 'posted',
      referenceId: 'c1',
      amount: -120,
      entryDate: ts(new Date('2026-10-01T05:00:00Z')),
      metadata: { lineItemType: 'discount' },
    },
  ];
  assert.deepEqual(covered(rows, 10, 2026).map((c) => c.monthlyShare), [120]);
});

test('each contract is its own unit', () => {
  const rows = [
    online('proratedRent', '2026-10-01T00:00:00Z', 50, { referenceId: 'c1' }),
    app('rent', '2026-10-01', '2026-10-01T05:00:00Z', 75, { referenceId: 'c2' }),
  ];
  assert.deepEqual(
    covered(rows, 10, 2026).map((c) => [c.contractId, c.monthlyShare]),
    [
      ['c1', 50],
      ['c2', 75],
    ],
  );
});

test("a covering row with no amount leaves the unit's share unknown", () => {
  const rows = [{ ...online('proratedRent', '2026-10-01T00:00:00Z', 0), amount: undefined }];
  assert.deepEqual(covered(rows, 10, 2026).map((c) => c.monthlyShare), [null]);
});

test('February: a move-in on the 1st covers the 28 days', () => {
  const rows = [online('proratedRent', '2027-02-01T00:00:00Z', 80)];
  assert.deepEqual(covered(rows, 2, 2027).map((c) => c.monthlyShare), [80]);
});

// --- what the job charges -----------------------------------------------------

const cover = (contractId: string, monthlyShare: number | null): MoveInRentCover => ({
  contractId,
  monthlyShare,
  entryIds: [],
});

test('no move-in rent for the month: the full rate', () => {
  assert.deepEqual(planMonthlyRentCharge({ monthlyRate: 150, covers: [], heldUnitCount: 2 }), {
    action: 'charge',
    amount: 150,
    lessCoveredAtMoveIn: 0,
    covers: [],
  });
});

test('one unit, charged at move-in: nothing, whatever the amounts', () => {
  for (const share of [150, 120, null]) {
    const plan = planMonthlyRentCharge({ monthlyRate: 150, covers: [cover('c1', share)], heldUnitCount: 1 });
    assert.equal(plan.action, 'skip', `share ${share}`);
  }
  // A tenant whose unit is not linked to them rents one unit.
  assert.equal(planMonthlyRentCharge({ monthlyRate: 150, covers: [cover('c1', 150)], heldUnitCount: 0 }).action, 'skip');
});

test("a unit added to one already rented: the rate less the new unit's rent", () => {
  // Unit A at $50 for months; unit B at $100 moved in dated 1 Oct, with
  // October charged at move-in. The rate is $150 for both; B's October is
  // paid, A's is not.
  const plan = planMonthlyRentCharge({ monthlyRate: 150, covers: [cover('cB', 100)], heldUnitCount: 2 });
  assert.equal(plan.action, 'charge');
  assert.equal(plan.action === 'charge' && plan.amount, 50);
  assert.equal(plan.action === 'charge' && plan.lessCoveredAtMoveIn, 100);
});

test('every unit charged at move-in: nothing', () => {
  const plan = planMonthlyRentCharge({
    monthlyRate: 150,
    covers: [cover('cA', 50), cover('cB', 100)],
    heldUnitCount: 2,
  });
  assert.equal(plan.action, 'skip');
});

test('a covering unit already moved out does not reduce the charge', () => {
  // B moved in dated 1 Oct and moved out before it; the rate is A's alone.
  const plan = planMonthlyRentCharge({
    monthlyRate: 50,
    covers: [cover('cB', 100)],
    heldUnitCount: 1,
    movedOutContractIds: new Set(['cB']),
  });
  assert.deepEqual(plan, { action: 'charge', amount: 50, lessCoveredAtMoveIn: 0, covers: [] });
});

test('several units and a split that does not add up: nothing posted, flagged', () => {
  // The rate does not cover the other unit: it was never raised when B was
  // added, or B's rent went down. Charging a guess, or the whole rate on top
  // of B's move-in rent, would bill the tenant wrongly either way.
  const short = planMonthlyRentCharge({ monthlyRate: 100, covers: [cover('cB', 100)], heldUnitCount: 2 });
  assert.equal(short.action, 'review');
  const unknown = planMonthlyRentCharge({ monthlyRate: 150, covers: [cover('cB', null)], heldUnitCount: 2 });
  assert.equal(unknown.action, 'review');
});

test('the reduced charge rounds to the cent', () => {
  const plan = planMonthlyRentCharge({ monthlyRate: 150.1, covers: [cover('cB', 100.03)], heldUnitCount: 2 });
  assert.equal(plan.action === 'charge' && plan.amount, 50.07);
});

test('a reduced charge says why it is under the rate', () => {
  assert.equal(
    buildReducedRentChargeDescription(2026, 10, 100),
    'Monthly Rent - October 2026 (less $100.00 charged at move-in)',
  );
});

// --- what the job reads -------------------------------------------------------

test("the job reads its own charges and both move-ins' rent", () => {
  assert.deepEqual([...RENT_CHARGE_LEDGER_TYPES].sort(), ['proratedRent', 'rent', 'rentCharge']);
});

test('the ledger window reaches back to "Next Month Rent" dated in the month before', () => {
  const { start, end } = rentChargeLedgerWindow(2026, 10);
  assert.equal(start.toISOString(), '2026-08-31T00:00:00.000Z');
  assert.equal(end.toISOString(), '2026-11-02T00:00:00.000Z');
  const inside = (iso: string) => {
    const at = new Date(iso);
    return at >= start && at < end;
  };
  assert.equal(inside('2026-09-01T00:00:00Z'), true, 'Next Month Rent for a move-in on 1 Sep');
  assert.equal(inside('2026-09-30T22:00:00Z'), true, 'app move-in at a local midnight east of UTC');
  assert.equal(inside('2026-11-01T02:00:00Z'), true, 'app move-in on the evening of 31 Oct in the US');
  // Every row the duplicate check needs is inside it.
  const dup = rentChargeDuplicateWindow(2026, 10);
  assert.ok(start <= dup.start && dup.end <= end);
});

test('the ledger window rolls back over the year start', () => {
  const { start, end } = rentChargeLedgerWindow(2027, 1);
  assert.equal(start.toISOString(), '2026-11-30T00:00:00.000Z');
  assert.equal(end.toISOString(), '2027-02-02T00:00:00.000Z');
});

test('a run on 2026-10-01 skips a tenant whose move-in charged October, and charges one whose did not', () => {
  // End to end through the helpers the job uses, on the rows its query reads.
  const { year, month } = rentChargeMonthFromInput('2026-10-01') as { year: number; month: number };
  const decide = (rows: ReadonlyArray<Record<string, any>>, monthlyRate: number) =>
    hasRentChargeForMonth(rows, month, year)
      ? 'already charged'
      : planMonthlyRentCharge({ monthlyRate, covers: moveInRentCoversForMonth(rows, month, year), heldUnitCount: 1 })
          .action;

  assert.equal(decide([online('proratedRent', '2026-10-01T00:00:00Z', 1)], 1), 'skip');
  assert.equal(decide([online('rent', '2026-09-25T00:00:00Z', 120)], 120), 'skip');
  assert.equal(decide([online('proratedRent', '2026-09-25T00:00:00Z', 24)], 120), 'charge');
  // A retry after the job posted October still finds that charge first.
  assert.equal(
    decide(
      [online('proratedRent', '2026-09-25T00:00:00Z', 24), recurring(rentChargeDateFor(2026, 10), 10, 2026)],
      120,
    ),
    'already charged',
  );
});

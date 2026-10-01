import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { isoDay, moveOutLines, moveOutPreviewRefusal, moveOutRentLine, postedBalance, wallDay } from '../moveOutRent';

type Row = { type?: string; status?: string; referenceId?: string; entryDate?: string; metadata?: Record<string, unknown> };

type Fixture = {
  cases: Array<{
    name: string;
    monthlyRate: number;
    moveOutDate: string;
    unitMoveInDate: string | null;
    rows: Row[];
    chargeDays: number;
    chargeAmount: number;
    creditDays: number;
    creditAmount: number;
    moveInDate: string | null;
  }>;
  wallDates: Array<[string, string | null]>;
};

const fixture = JSON.parse(
  readFileSync(join(__dirname, '..', '..', 'src', 'test', 'fixtures', 'moveOutRent.json'), 'utf8'),
) as Fixture;

/** A row as read from Firestore: entryDate a Timestamp-like with toDate(). */
const asRead = (row: Row) => ({
  ...row,
  entryDate: row.entryDate ? { toDate: () => new Date(row.entryDate as string) } : undefined,
});

test('moveOutRentLine matches the shared table (the app runs it too)', () => {
  assert.ok(fixture.cases.length > 10);
  for (const c of fixture.cases) {
    const moveOutDay = wallDay(c.moveOutDate);
    assert.notEqual(moveOutDay, null, c.name);
    const line = moveOutRentLine({
      monthlyRate: c.monthlyRate,
      moveOutDay: moveOutDay as number,
      contractId: 'c1',
      rows: c.rows.map(asRead),
      unitMoveInDate: c.unitMoveInDate ? new Date(c.unitMoveInDate) : null,
    });
    assert.deepEqual(
      line,
      {
        chargeDays: c.chargeDays,
        chargeAmount: c.chargeAmount,
        creditDays: c.creditDays,
        creditAmount: c.creditAmount,
        moveInDate: c.moveInDate,
      },
      c.name,
    );
  }
});

test('wallDay reads the date the owner picked, as the app sends it', () => {
  for (const [input, expected] of fixture.wallDates) {
    const day = wallDay(input);
    assert.equal(day === null ? null : isoDay(day), expected, input);
  }
});

test('the three cases a test move-out raised', () => {
  const find = (fragment: string) => {
    const c = fixture.cases.find((x) => x.name.includes(fragment));
    assert.ok(c, fragment);
    return c;
  };
  // Before a future move-in date: nothing charged, the prepaid month back.
  const early = find('before a tenancy starting 1 Oct, October prorated and paid online');
  assert.equal(early.chargeAmount, 0);
  assert.equal(early.creditAmount, 1);
  // Mid-month move-in then out the same month: not charged from the 1st.
  const sameMonth = find('mid-month move-in on 10 Sep, moved out on 20 Sep');
  assert.equal(sameMonth.chargeAmount, 0);
  // After the month's rent posted: not charged again.
  const posted = find("after June's rent posted");
  assert.equal(posted.chargeAmount, 0);
  assert.equal(posted.creditAmount, 100);
});

test('the move-out posts rent, the unused-days credit and the fees as their own lines', () => {
  const rent = { chargeDays: 4, chargeAmount: 13.33, creditDays: 31, creditAmount: 1, moveInDate: null };
  const posted = moveOutLines({ rent, moveOutFees: 25 });
  assert.deepEqual(posted.rows, [
    { type: 'moveOutFee', amount: 13.33, description: 'Prorated rent (4 days)', line: 'proratedRent', days: 4 },
    { type: 'credit', amount: -1, description: 'Prorated rent credit (31 unused days)', line: 'proratedRentCredit', days: 31 },
    { type: 'moveOutFee', amount: 25, description: 'Move-out fees', line: 'fees', days: null },
  ]);
  assert.equal(posted.net, 37.33);

  // Out before a tenancy starting 1 Oct: nothing charged, October's $1 back.
  const beforeTenancy = moveOutLines({
    rent: { chargeDays: 0, chargeAmount: 0, creditDays: 31, creditAmount: 1, moveInDate: '2026-10-01' },
    moveOutFees: 0,
  });
  assert.deepEqual(beforeTenancy.rows.map((r) => [r.type, r.amount]), [['credit', -1]]);
  assert.equal(beforeTenancy.net, -1);

  // Not prorating, no fees: nothing posted. Fees that are not money are none.
  assert.deepEqual(moveOutLines({ rent: null, moveOutFees: 0 }), { rows: [], net: 0 });
  assert.deepEqual(moveOutLines({ rent: null, moveOutFees: 'x' }), { rows: [], net: 0 });
  assert.deepEqual(moveOutLines({ rent: null, moveOutFees: -5 }), { rows: [], net: 0 });
});

test('the balance is the sum of posted amounts, as the app reads it', () => {
  assert.equal(
    postedBalance([
      { status: 'posted', amount: 1 },
      { status: 'posted', amount: -1 },
      { status: 'posted', amount: 0.1 },
      { status: 'posted', amount: 0.2 },
      { status: 'void', amount: 50 },
      { status: 'posted', amount: '9' },
    ]),
    0.3,
  );
});

test('what the owner was not shown is refused', () => {
  const base = { net: -1, shownNet: -1, balance: 0, refund: 1, processRefund: true };
  assert.equal(moveOutPreviewRefusal(base), null);
  // Rent posted since the screen calculated.
  assert.equal(
    moveOutPreviewRefusal({ ...base, shownNet: 0.8 }),
    'The move-out charges have changed since they were calculated: they now come to a $1.00 credit, not $0.80. ' +
      'Nothing was moved out. Calculate charges again and check them.',
  );
  // A payment taken since: the tenant is owed less than the refund offered.
  assert.equal(
    moveOutPreviewRefusal({ ...base, balance: 0.5 }),
    'The $1.00 refund is more than the $0.50 this tenant is owed after the move-out. ' +
      'Nothing was moved out. Calculate charges again and check them.',
  );
  // Not refunding: the credit stays theirs, whatever it comes to.
  assert.equal(moveOutPreviewRefusal({ ...base, balance: 0.5, processRefund: false }), null);
  // Float residue is not a difference.
  assert.equal(moveOutPreviewRefusal({ ...base, net: 0.1 + 0.2, shownNet: 0.3, refund: 0 }), null);
});

test("a cash refund for a coupon's free month is refused: the refund check uses the capped credit", () => {
  const c = fixture.cases.find((x) => x.name.startsWith('a free-month coupon'));
  assert.ok(c);
  const line = moveOutRentLine({
    monthlyRate: c.monthlyRate,
    moveOutDay: wallDay(c.moveOutDate) as number,
    contractId: 'c1',
    rows: c.rows.map(asRead),
  });
  const lines = moveOutLines({ rent: line, moveOutFees: 0 });
  assert.deepEqual(lines, { rows: [], net: 0 });
  const balance = postedBalance(c.rows);
  assert.equal(balance, 0);
  // The old rule's screen: a $200 credit, refunded in cash.
  assert.match(
    moveOutPreviewRefusal({ net: lines.net, shownNet: -200, balance, refund: 200, processRefund: true }) ?? '',
    /now come to \$0\.00, not a \$200\.00 credit/,
  );
  // Whatever the screen showed, no refund beyond what the tenant is owed.
  assert.match(
    moveOutPreviewRefusal({ net: lines.net, shownNet: 0, balance, refund: 200, processRefund: true }) ?? '',
    /The \$200\.00 refund is more than the \$0\.00 this tenant is owed/,
  );
});

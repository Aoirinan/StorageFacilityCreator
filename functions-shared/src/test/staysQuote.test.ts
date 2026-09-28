import test from 'node:test';
import assert from 'node:assert/strict';

import type { StayListingInput } from '../stays/contracts';
import { MAX_FOLIO_TOTAL_CENTS, isWeekendNight, quoteStay, taxOn } from '../stays/quote';
import { StayValidationError } from '../stays/validation';

// Every figure below is worked out by hand from these rates, not by the code under test.
// 2026-10-01 is a Thursday: Oct 5 is a Monday, Oct 9 a Friday, Oct 10 a Saturday.
function listing(patch: Partial<StayListingInput> = {}): Pick<StayListingInput, 'ratesCents' | 'seasonalRates' | 'taxLines'> {
  return {
    ratesCents: {
      nightly: 10_000,
      weekendNightly: 12_500,
      weeklyNightly: 9_000,
      cleaningFee: 7_500,
      petFee: 2_500,
      extraGuestFee: 1_500,
      extraGuestAfter: 2,
    },
    seasonalRates: [
      { id: 'summer', name: 'Summer', startMmdd: '06-01', endMmdd: '08-31', nightlyCents: 15_000, weekendNightlyCents: 17_500 },
      // Wraps the year end; no weekend rate of its own.
      { id: 'holidays', name: 'Holidays', startMmdd: '12-20', endMmdd: '01-05', nightlyCents: 20_000, weekendNightlyCents: null },
    ],
    taxLines: [
      { code: 'county', label: 'County lodging', rateBps: 333, appliesTo: ['cleaning'], remittedBy: 'owner' },
      { code: 'pet_tax', label: 'Pet tax', rateBps: 250, appliesTo: ['pet'], remittedBy: 'owner' },
      { code: 'lodging', label: 'State lodging', rateBps: 400, appliesTo: ['lodging', 'extra_guest'], remittedBy: 'owner' },
    ],
    ...patch,
  };
}

const TAX_OFF = { lodgingTaxEnabled: false };
const TAX_ON = { lodgingTaxEnabled: true };
const couple = { adults: 2, children: 0, pets: 0 };

function lodging(q: ReturnType<typeof quoteStay>) {
  return q.lines.filter((l) => l.code === 'lodging').map((l) => [l.label, l.qty, l.unitCents, l.amountCents]);
}

test('weekday nights at the nightly rate, plus the cleaning fee once', () => {
  const q = quoteStay(listing(), TAX_OFF, { checkIn: '2026-10-05', checkOut: '2026-10-08', ...couple });
  assert.equal(q.nights, 3);
  assert.deepEqual(lodging(q), [['Nightly rate', 3, 10_000, 30_000]]);
  assert.deepEqual(
    q.lines.map((l) => [l.code, l.amountCents]),
    [
      ['lodging', 30_000],
      ['cleaning', 7_500],
    ],
  );
  assert.equal(q.subtotalCents, 37_500);
  assert.equal(q.taxCents, 0);
  assert.deepEqual(q.taxLines, []);
  assert.equal(q.totalCents, 37_500);
  assert.equal(q.currency, 'usd');
});

test('Friday and Saturday nights take the weekend rate', () => {
  assert.equal(isWeekendNight('2026-10-09'), true);
  assert.equal(isWeekendNight('2026-10-10'), true);
  assert.equal(isWeekendNight('2026-10-11'), false);
  const q = quoteStay(listing(), TAX_OFF, { checkIn: '2026-10-08', checkOut: '2026-10-11', ...couple });
  assert.deepEqual(lodging(q), [
    ['Nightly rate', 1, 10_000, 10_000],
    ['Weekend nights (Fri/Sat)', 2, 12_500, 25_000],
  ]);
  assert.equal(q.totalCents, 35_000 + 7_500);
});

test('7+ nights take the weekly rate, except weekend nights, which the weekend rate beats', () => {
  const q = quoteStay(listing(), TAX_OFF, { checkIn: '2026-10-05', checkOut: '2026-10-13', ...couple });
  assert.equal(q.nights, 8);
  assert.deepEqual(lodging(q), [
    ['Weekly rate (7+ nights)', 6, 9_000, 54_000],
    ['Weekend nights (Fri/Sat)', 2, 12_500, 25_000],
  ]);
  // 6 nights is not a week.
  const six = quoteStay(listing(), TAX_OFF, { checkIn: '2026-10-11', checkOut: '2026-10-17', ...couple });
  assert.deepEqual(lodging(six), [
    ['Nightly rate', 5, 10_000, 50_000],
    ['Weekend nights (Fri/Sat)', 1, 12_500, 12_500],
  ]);
});

test('a season beats the weekend rate, and its own weekend rate applies on Fri/Sat', () => {
  // Fri Aug 28 – Wed Sep 2: two summer weekend nights, two summer nights, one ordinary night.
  const q = quoteStay(listing(), TAX_OFF, { checkIn: '2026-08-28', checkOut: '2026-09-02', ...couple });
  assert.deepEqual(lodging(q), [
    ['Summer, weekend nights', 2, 17_500, 35_000],
    ['Summer', 2, 15_000, 30_000],
    ['Nightly rate', 1, 10_000, 10_000],
  ]);
});

test('a season that wraps the year end covers both sides, and beats the weekly rate', () => {
  // Wed Dec 30 – Thu Jan 7: 7 holiday nights (its Fri/Sat too: no holiday weekend rate), then one weekly night.
  const q = quoteStay(listing(), TAX_OFF, { checkIn: '2026-12-30', checkOut: '2027-01-07', ...couple });
  assert.deepEqual(lodging(q), [
    ['Holidays', 7, 20_000, 140_000],
    ['Weekly rate (7+ nights)', 1, 9_000, 9_000],
  ]);
});

test('extra guests per guest per night after the threshold, pets once per stay', () => {
  const q = quoteStay(listing(), TAX_OFF, { checkIn: '2026-10-05', checkOut: '2026-10-08', adults: 3, children: 1, pets: 2 });
  assert.deepEqual(
    q.lines.map((l) => [l.code, l.qty, l.unitCents, l.amountCents]),
    [
      ['lodging', 3, 10_000, 30_000],
      ['extra_guest', 6, 1_500, 9_000],
      ['cleaning', 1, 7_500, 7_500],
      ['pet', 1, 2_500, 2_500],
    ],
  );
  assert.equal(q.lines[1].label, 'Extra guests (2 × 3 nights)');
  assert.equal(q.subtotalCents, 49_000);
  // At or under the threshold, and with no pets, neither line appears.
  const two = quoteStay(listing(), TAX_OFF, { checkIn: '2026-10-05', checkOut: '2026-10-08', adults: 1, children: 1, pets: 0 });
  assert.deepEqual(two.lines.map((l) => l.code), ['lodging', 'cleaning']);
});

test('tax lines: each one half-up to the cent over its own charges, only when lodging tax is on', () => {
  const q = quoteStay(listing(), TAX_ON, { checkIn: '2026-10-05', checkOut: '2026-10-08', adults: 3, children: 1, pets: 1 });
  // county 3.33% of cleaning 75.00 = 2.4975 → 2.50; pet 2.5% of 25.00 = 0.625 → 0.63;
  // state 4% of lodging + extra guests (300.00 + 90.00) = 15.60.
  assert.deepEqual(
    q.taxLines.map((t) => [t.code, t.rateBps, t.amountCents, t.remittedBy]),
    [
      ['county', 333, 250, 'owner'],
      ['pet_tax', 250, 63, 'owner'],
      ['lodging', 400, 1_560, 'owner'],
    ],
  );
  assert.equal(q.taxCents, 1_873);
  assert.equal(q.subtotalCents, 49_000);
  assert.equal(q.totalCents, 50_873);
  assert.equal(taxOn(2_500, 250), 63);
  assert.equal(taxOn(2_499, 250), 62);
  assert.equal(taxOn(7_500, 333), 250);
});

test('a manager adjustment is its own line and is never taxed', () => {
  const q = quoteStay(listing(), TAX_ON, {
    checkIn: '2026-10-05',
    checkOut: '2026-10-08',
    adults: 3,
    children: 1,
    pets: 1,
    adjustmentCents: -5_000,
  });
  const adj = q.lines.find((l) => l.code === 'adjustment')!;
  assert.deepEqual([adj.label, adj.qty, adj.unitCents, adj.amountCents], ['Adjustment', 1, -5_000, -5_000]);
  assert.equal(q.subtotalCents, 44_000);
  assert.equal(q.taxCents, 1_873);
  assert.equal(q.totalCents, 45_873);
  assert.throws(
    () => quoteStay(listing(), TAX_OFF, { checkIn: '2026-10-05', checkOut: '2026-10-06', ...couple, adjustmentCents: -20_000 }),
    (e: unknown) => e instanceof StayValidationError && e.field === 'adjustmentCents',
  );
});

test('a stored listing with a bad tax line or season is refused, not priced', () => {
  const bad = [
    listing({ taxLines: [{ code: 'x', label: 'X', rateBps: 3_001, appliesTo: ['lodging'], remittedBy: 'owner' }] }),
    listing({ taxLines: [{ code: 'x', label: 'X', rateBps: 4.5, appliesTo: ['lodging'], remittedBy: 'owner' }] }),
    listing({ taxLines: [{ code: 'x', label: 'X', rateBps: 100, appliesTo: ['adjustment' as never], remittedBy: 'owner' }] }),
    listing({
      taxLines: [
        { code: 'x', label: 'X', rateBps: 100, appliesTo: ['lodging'], remittedBy: 'owner' },
        { code: 'x', label: 'Y', rateBps: 100, appliesTo: ['cleaning'], remittedBy: 'owner' },
      ],
    }),
    listing({ seasonalRates: [{ id: 's', name: 'S', startMmdd: '02-30', endMmdd: '03-10', nightlyCents: 1, weekendNightlyCents: null }] }),
    listing({ ratesCents: { ...listing().ratesCents, nightly: '100' as unknown as number } }),
  ];
  for (const l of bad) {
    assert.throws(() => quoteStay(l, TAX_ON, { checkIn: '2026-10-05', checkOut: '2026-10-06', ...couple }), StayValidationError);
  }
});

test('dates and party sizes are checked', () => {
  const at = (checkIn: string, checkOut: string, extra: Record<string, unknown> = {}) => () =>
    quoteStay(listing(), TAX_OFF, { checkIn, checkOut, ...couple, ...extra } as never);
  assert.throws(at('2026-10-06', '2026-10-06'), StayValidationError);
  assert.throws(at('2026-10-07', '2026-10-06'), StayValidationError);
  assert.throws(at('2026-02-30', '2026-03-02'), StayValidationError);
  assert.throws(at('2026-10-05', '2026-10-06', { adults: 1.5 }), StayValidationError);
  assert.throws(at('2026-10-05', '2026-10-06', { pets: -1 }), StayValidationError);
  assert.throws(at('2026-10-05', '2026-10-06', { adjustmentCents: 10.5 }), StayValidationError);
});

test('a stay that would total more than the cap is refused', () => {
  const pricey = listing({ ratesCents: { ...listing().ratesCents, nightly: 10_000_000, weekendNightly: null, weeklyNightly: null } });
  assert.throws(() => quoteStay(pricey, TAX_OFF, { checkIn: '2026-10-05', checkOut: '2026-10-12', ...couple }), StayValidationError);
  assert.ok(MAX_FOLIO_TOTAL_CENTS >= 50_000_000);
});

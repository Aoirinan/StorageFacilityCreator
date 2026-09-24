import test from 'node:test';
import assert from 'node:assert/strict';

import {
  StayValidationError,
  isAirbnbWebUrl,
  mmddInSeason,
  validateChecklist,
  validateListingInput,
  validateSeasonalRates,
  validateTaxLines,
  validateTime,
} from '../stays/validation';

/** A listing as the app's StayListing.toInputMap() sends it. */
function input(patch: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    name: 'Airbnb A',
    shortCode: 'A1',
    kind: 'vacation_rental',
    group: 'Airbnbs',
    sortOrder: 1,
    active: true,
    archived: false,
    address: '12 Main St, Glendive MT',
    capacity: { maxGuests: 6, bedrooms: 2, beds: 3, bathrooms: 1.5, petsAllowed: false },
    rv: null,
    times: { checkIn: '15:00', checkOut: null },
    stayRules: { minNights: 2, maxNights: 28 },
    ratesCents: { nightly: 12_900, weekendNightly: 14_900, weeklyNightly: null, cleaningFee: 7_500, petFee: 0, extraGuestFee: 0, extraGuestAfter: 0 },
    seasonalRates: [],
    taxLines: [],
    turnover: { mode: 'full', afterOwnerBlocks: false, checklistTemplate: [{ id: 'beds', label: 'Make beds' }], defaultAssigneeUid: null, defaultAssigneeName: null },
    accessCodeMode: 'phone_last4',
    airbnb: { listingNameAliases: ['Cozy Caprock Cottage'], listingUrl: 'https://www.airbnb.com/rooms/12345', calendarUrl: null },
    notes: '',
    ...patch,
  };
}

function fieldOf(fn: () => unknown): string | null {
  try {
    fn();
    return null;
  } catch (error) {
    assert.ok(error instanceof StayValidationError, `expected a StayValidationError, got ${String(error)}`);
    return error.field;
  }
}

test('a complete listing passes; text is trimmed, a blank optional is null, unknown keys are dropped', () => {
  const out = validateListingInput(input({ name: '  Airbnb A ', address: '   ', secretToken: 'x', rv: undefined }));
  assert.equal(out.name, 'Airbnb A');
  assert.equal(out.address, null);
  assert.equal(out.rv, null);
  assert.equal((out as unknown as Record<string, unknown>).secretToken, undefined);
  assert.deepEqual(out.times, { checkIn: '15:00', checkOut: null });
  assert.equal(out.capacity.bathrooms, 1.5);
  assert.deepEqual(out.turnover.checklistTemplate, [{ id: 'beds', label: 'Make beds' }]);
});

test('bad values are rejected with the field named, never coerced', () => {
  const cases: [Record<string, unknown>, string][] = [
    [{ name: '' }, 'name'],
    [{ name: 'x'.repeat(81) }, 'name'],
    [{ name: 'Two\nlines' }, 'name'],
    [{ shortCode: 'TOOLONGCODE' }, 'shortCode'],
    [{ kind: 'castle' }, 'kind'],
    [{ sortOrder: 1.5 }, 'sortOrder'],
    [{ active: 'true' }, 'active'],
    [{ capacity: { maxGuests: '6', bedrooms: 2, beds: 3, bathrooms: 1, petsAllowed: false } }, 'capacity.maxGuests'],
    [{ capacity: { maxGuests: 6, bedrooms: 2, beds: 3, bathrooms: 1.3, petsAllowed: false } }, 'capacity.bathrooms'],
    [{ times: { checkIn: '3pm', checkOut: null } }, 'times.checkIn'],
    [{ stayRules: { minNights: 3, maxNights: 2 } }, 'stayRules.minNights'],
    [{ stayRules: { minNights: 1, maxNights: 181 } }, 'stayRules.maxNights'],
    [{ ratesCents: { ...(input().ratesCents as object), nightly: 129.5 } }, 'ratesCents.nightly'],
    [{ ratesCents: { ...(input().ratesCents as object), nightly: -1 } }, 'ratesCents.nightly'],
    [{ ratesCents: { ...(input().ratesCents as object), extraGuestFee: 1_000, extraGuestAfter: 0 } }, 'ratesCents.extraGuestAfter'],
    [{ turnover: { mode: 'deep', afterOwnerBlocks: false, checklistTemplate: [] } }, 'turnover.mode'],
    [{ accessCodeMode: 'smart_lock' }, 'accessCodeMode'],
    [{ notes: 'x'.repeat(2001) }, 'notes'],
  ];
  for (const [patch, field] of cases) {
    assert.equal(fieldOf(() => validateListingInput(input(patch))), field, JSON.stringify(patch));
  }
  assert.equal(fieldOf(() => validateListingInput(null)), 'listing');
});

test('RV specs: hookup, a subset of 15/20/30/50 amps, a length', () => {
  const rv = (patch: Record<string, unknown>) =>
    input({ kind: 'rv_site', rv: { hookup: 'full', amps: [50, 30], maxLengthFt: 45, pullThrough: true, surface: 'gravel', ...patch } });
  assert.deepEqual(validateListingInput(rv({})).rv, { hookup: 'full', amps: [30, 50], maxLengthFt: 45, pullThrough: true, surface: 'gravel' });
  assert.equal(fieldOf(() => validateListingInput(rv({ hookup: 'sewer' }))), 'rv.hookup');
  assert.equal(fieldOf(() => validateListingInput(rv({ amps: [25] }))), 'rv.amps[0]');
  assert.equal(fieldOf(() => validateListingInput(rv({ amps: ['30'] }))), 'rv.amps[0]');
  assert.equal(fieldOf(() => validateListingInput(rv({ amps: [30, 30] }))), 'rv.amps');
  assert.equal(fieldOf(() => validateListingInput(rv({ maxLengthFt: 0 }))), 'rv.maxLengthFt');
});

test('Airbnb links: https on an Airbnb host only, and never the private calendar export', () => {
  assert.equal(isAirbnbWebUrl('https://www.airbnb.com/rooms/1'), true);
  assert.equal(isAirbnbWebUrl('https://www.airbnb.co.uk/rooms/1'), true);
  for (const url of [
    'http://www.airbnb.com/rooms/1',
    'https://airbnb.com.evil.com/rooms/1',
    'https://evil.com/www.airbnb.com',
    'https://user:pw@www.airbnb.com/rooms/1',
    'https://www.airbnb.com:8443/rooms/1',
    'javascript:alert(1)',
  ]) {
    assert.equal(isAirbnbWebUrl(url), false, url);
  }
  const withUrl = (calendarUrl: string) => input({ airbnb: { listingNameAliases: [], listingUrl: null, calendarUrl } });
  assert.equal(fieldOf(() => validateListingInput(withUrl('https://airbnb.com.evil.com/x'))), 'airbnb.calendarUrl');
  const secret = 'https://www.airbnb.com/calendar/ical/12345.ics?s=0123456789abcdef';
  assert.equal(fieldOf(() => validateListingInput(withUrl(secret))), 'airbnb.calendarUrl');
  assert.equal(validateListingInput(withUrl('https://www.airbnb.com/multicalendar/12345')).airbnb.calendarUrl, 'https://www.airbnb.com/multicalendar/12345');
  const aliases = input({ airbnb: { listingNameAliases: ['Cottage', 'cottage'], listingUrl: null, calendarUrl: null } });
  assert.equal(fieldOf(() => validateListingInput(aliases)), 'airbnb.listingNameAliases');
});

test('seasons: valid MM-DD days, unique ids, no overlaps (a wrap-around one included)', () => {
  const s = (id: string, startMmdd: string, endMmdd: string) => ({ id, name: id, startMmdd, endMmdd, nightlyCents: 100, weekendNightlyCents: null });
  assert.equal(validateSeasonalRates([s('summer', '06-01', '08-31'), s('holidays', '12-20', '01-05')]).length, 2);
  assert.equal(validateSeasonalRates([s('leap', '02-29', '02-29')])[0].startMmdd, '02-29');
  assert.equal(fieldOf(() => validateSeasonalRates([s('bad', '02-30', '03-01')])), 'seasonalRates[0].startMmdd');
  assert.equal(fieldOf(() => validateSeasonalRates([s('bad', '6-1', '08-31')])), 'seasonalRates[0].startMmdd');
  assert.equal(fieldOf(() => validateSeasonalRates([s('a', '06-01', '06-30'), s('a', '07-01', '07-31')])), 'seasonalRates[1].id');
  assert.equal(fieldOf(() => validateSeasonalRates([s('a', '06-01', '07-15'), s('b', '07-15', '08-31')])), 'seasonalRates');
  assert.equal(fieldOf(() => validateSeasonalRates([s('winter', '12-01', '02-28'), s('ny', '01-01', '01-02')])), 'seasonalRates');
  assert.equal(fieldOf(() => validateSeasonalRates(Array.from({ length: 11 }, (_, i) => s(`s${i}`, '01-01', '01-01')))), 'seasonalRates');
  assert.equal(mmddInSeason('01-03', '12-20', '01-05'), true);
  assert.equal(mmddInSeason('12-19', '12-20', '01-05'), false);
  assert.equal(mmddInSeason('08-31', '06-01', '08-31'), true);
});

test('tax lines: owner-remitted, 0–3000 bps, known charges, unique codes', () => {
  const t = (patch: Record<string, unknown>) => [{ code: 'mt', label: 'Montana lodging', rateBps: 400, appliesTo: ['lodging'], ...patch }];
  assert.deepEqual(validateTaxLines(t({})), [{ code: 'mt', label: 'Montana lodging', rateBps: 400, appliesTo: ['lodging'], remittedBy: 'owner' }]);
  assert.equal(fieldOf(() => validateTaxLines(t({ rateBps: 3_001 }))), 'taxLines[0].rateBps');
  assert.equal(fieldOf(() => validateTaxLines(t({ rateBps: '400' }))), 'taxLines[0].rateBps');
  assert.equal(fieldOf(() => validateTaxLines(t({ appliesTo: [] }))), 'taxLines[0].appliesTo');
  assert.equal(fieldOf(() => validateTaxLines(t({ appliesTo: ['lodging', 'lodging'] }))), 'taxLines[0].appliesTo');
  assert.equal(fieldOf(() => validateTaxLines(t({ appliesTo: ['adjustment'] }))), 'taxLines[0].appliesTo[0]');
  assert.equal(fieldOf(() => validateTaxLines(t({ remittedBy: 'airbnb' }))), 'taxLines[0].remittedBy');
  assert.equal(fieldOf(() => validateTaxLines(t({ code: 'has space' }))), 'taxLines[0].code');
});

test('checklists: at most 50 items with unique ids and one-line labels', () => {
  assert.equal(validateChecklist([{ id: 'a', label: ' Towels ' }])[0].label, 'Towels');
  assert.equal(fieldOf(() => validateChecklist([{ id: 'a', label: 'x' }, { id: 'a', label: 'y' }])), 'checklistTemplate[1].id');
  assert.equal(fieldOf(() => validateChecklist([{ id: 'a', label: '' }])), 'checklistTemplate[0].label');
  assert.equal(fieldOf(() => validateChecklist(Array.from({ length: 51 }, (_, i) => ({ id: `i${i}`, label: 'x' })))), 'checklistTemplate');
});

test('times are 24-hour HH:mm', () => {
  assert.equal(validateTime('00:00'), '00:00');
  assert.equal(validateTime('23:59'), '23:59');
  for (const bad of ['24:00', '9:00', '15:60', 1500, null]) {
    assert.throws(() => validateTime(bad), StayValidationError);
  }
});

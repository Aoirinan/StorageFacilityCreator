import test from 'node:test';
import assert from 'node:assert/strict';

import { handleSetControls } from '../bookings/controls';
import { handleSearchGuests } from '../bookings/guests';
import { handleBulkCreateRvSites, handleSaveListing } from '../bookings/listings';
import { handleRecordPayment, handleVoidIncome } from '../bookings/payments';
import { handleCancelStay, handleCreateStay, handleModifyStay, handleQuote, handleReviewStay } from '../bookings/stays';
import { FakeFirestore } from './support/fakeFirestore';
import { EMPLOYEE, FAC, OWNER } from './support/staysFixtures';
import { Handler, P, as, listingInput, rateLimitsOf, reasonOf, rid, rvInput, seedListing, setupEnv } from './support/bookingFixtures';

// Spec §6.5 sets the limits for quote (120/min per user), create (60/min per
// facility, 20/min per user), guest search (60/min) and set-controls
// (20/min); the others are this package's choice, pinned here so a change is
// deliberate. A per-user key is shown as `{key}_u`.
const all: FakeFirestore[] = [];

const dates = { listingId: 'lst_a', checkIn: '2026-10-05', checkOut: '2026-10-08' };

const CASES: [string, Handler<unknown>, string, () => Record<string, unknown>, [string, number, number][]][] = [
  ['staysSetControls', handleSetControls, OWNER, () => ({ changes: {} }), [['stays_controls', 20, 60]]],
  ['staysSaveListing', handleSaveListing, OWNER, () => ({ requestId: rid(), listing: listingInput({ name: 'New', shortCode: 'NW' }) }), [['stays_listing', 60, 60]]],
  ['staysBulkCreateRvSites', handleBulkCreateRvSites, OWNER, () => ({ requestId: rid(), prefix: 'RV ', from: 1, to: 1, group: 'RV park' }), [['stays_bulk_rv', 10, 60]]],
  ['staysQuote', handleQuote, EMPLOYEE, () => ({ ...dates }), [['stays_quote_u', 120, 60]]],
  ['staysCreateStay', handleCreateStay, OWNER, () => ({ requestId: rid(), ...dates }), [['stays_create', 60, 60], ['stays_create_u', 20, 60]]],
  ['staysModifyStay', handleModifyStay, OWNER, () => ({ stayId: 'man_x' }), [['stays_modify', 60, 60], ['stays_modify_u', 30, 60]]],
  ['staysCancelStay', handleCancelStay, OWNER, () => ({ stayId: 'man_x' }), [['stays_cancel', 30, 60]]],
  ['staysReviewStay', handleReviewStay, OWNER, () => ({ stayId: 'man_x' }), [['stays_review', 60, 60]]],
  ['staysRecordPayment', handleRecordPayment, OWNER, () => ({ requestId: rid(), stayId: 'man_x' }), [['stays_payment', 60, 60], ['stays_payment_u', 20, 60]]],
  ['staysVoidIncome', handleVoidIncome, OWNER, () => ({ entryId: 'man_x' }), [['stays_void', 30, 60]]],
  ['staysSearchGuests', handleSearchGuests, OWNER, () => ({ query: 'jane' }), [['stays_guest_search_u', 60, 60]]],
];

test('every booking-engine callable asks for its rate limits', async () => {
  for (const [name, handler, uid, data, expected] of CASES) {
    const env = setupEnv(all);
    seedListing(env.fake, 'lst_a', listingInput());
    assert.deepEqual(await rateLimitsOf(env, handler, uid, data()), expected, name);
  }
});

test('a person gets 20 booking attempts a minute, and the 21st is refused', async () => {
  const env = setupEnv(all);
  seedListing(env.fake, 'lst_a', listingInput());
  // Counted even when the booking itself is refused (no kind here), so retrying a bad form is limited too.
  for (let i = 0; i < 20; i++) assert.equal(await reasonOf(as(env, handleCreateStay, OWNER, { requestId: rid(), ...dates })), 'invalid_argument');
  assert.equal(await reasonOf(as(env, handleCreateStay, OWNER, { requestId: rid(), ...dates })), 'rate_limited');
});

test('guest search is limited to 60 a minute per person', async () => {
  const env = setupEnv(all, { controls: { employeesCanBook: true } });
  for (let i = 0; i < 60; i++) await as(env, handleSearchGuests, EMPLOYEE, { query: `guest ${i}` });
  assert.equal(await reasonOf(as(env, handleSearchGuests, EMPLOYEE, { query: 'jane' })), 'rate_limited');
  assert.equal(await reasonOf(as(env, handleSearchGuests, OWNER, { query: 'jane' })), null);
});

test("an employee's whole-number phone searches are also capped at 20 an hour", async () => {
  const env = setupEnv(all, { controls: { employeesCanBook: true } });
  const phone = (i: number) => ({ query: `406555${String(i).padStart(4, '0')}` });
  assert.deepEqual(await rateLimitsOf(env, handleSearchGuests, EMPLOYEE, phone(0)), [
    ['stays_guest_search_u', 60, 60],
    ['stays_guest_contact_u', 20, 3600],
  ]);
  // A name, a plate or a partial number looks up no phone, so it is not counted.
  assert.deepEqual(await rateLimitsOf(env, handleSearchGuests, EMPLOYEE, { query: '406555' }), [['stays_guest_search_u', 60, 60]]);
  assert.deepEqual(await rateLimitsOf(env, handleSearchGuests, OWNER, phone(0)), [['stays_guest_search_u', 60, 60]]);

  const desk = setupEnv(all, { controls: { employeesCanBook: true } });
  for (let i = 0; i < 20; i++) assert.equal(await reasonOf(as(desk, handleSearchGuests, EMPLOYEE, phone(i))), null);
  assert.equal(await reasonOf(as(desk, handleSearchGuests, EMPLOYEE, phone(20))), 'rate_limited');
  assert.equal(await reasonOf(as(desk, handleSearchGuests, EMPLOYEE, { query: 'jane' })), null);
  assert.equal(await reasonOf(as(desk, handleSearchGuests, OWNER, phone(21))), null);
});

function profileDoc(name: string, patch: Record<string, unknown> = {}): Record<string, unknown> {
  return { facilityId: FAC, name, nameLower: name.toLowerCase(), phoneE164: null, email: null, vehicle: null, notes: '', doNotRent: false, doNotRentReason: null, consent: null, stayCount: 1, lastStayAt: null, ...patch };
}

/** An employee's walk-up for a new guest: a name on the do-not-rent list, so a phone that is not on file is refused cleanly as do_not_rent. */
function typedWalkUp(create: Record<string, unknown>): Record<string, unknown> {
  return {
    requestId: rid(),
    listingId: 'lst_rv1',
    checkIn: '2026-10-01',
    checkOut: '2026-10-02',
    kind: 'reservation',
    source: 'walk_up',
    guest: { displayName: '', adults: 1, children: 0, pets: 0, rvLengthFt: null },
    guestProfile: { create: { name: 'Rex Ruin', ...create } },
  };
}

test("an employee's phone and email lookups share one hourly budget across guest search and booking", async () => {
  const desk = setupEnv(all, { controls: { employeesCanBook: true } });
  seedListing(desk.fake, 'lst_rv1', rvInput(1, { accessCodeMode: 'phone_last4' }));
  desk.fake.seed(`${P}/stayGuestProfiles/gp_jane`, profileDoc('Jane Doe', { phoneE164: '+14065550123', email: 'jane@example.com' }));
  desk.fake.seed(`${P}/stayGuestProfiles/gp_rex`, profileDoc('Rex Ruin', { doNotRent: true, doNotRentReason: 'Damage' }));
  const guess = (exchange: number) => typedWalkUp({ phone: `406${String(exchange).padStart(3, '0')}0123` });

  // A booking that types a phone or email looks it up, on the same budget as search.
  assert.deepEqual(await rateLimitsOf(desk, handleCreateStay, EMPLOYEE, guess(100)), [
    ['stays_create', 60, 60],
    ['stays_create_u', 20, 60],
    ['stays_guest_contact_u', 20, 3600],
  ]);
  assert.deepEqual((await rateLimitsOf(desk, handleCreateStay, EMPLOYEE, typedWalkUp({ email: 'x@example.com' }))).slice(-1), [['stays_guest_contact_u', 20, 3600]]);
  // Picked from the search, or typed with no phone or email, nothing is looked up; nor for an owner.
  const uncounted: [string, Record<string, unknown>][] = [
    [EMPLOYEE, { ...typedWalkUp({}), guestProfile: { profileId: 'gp_jane' } }],
    [EMPLOYEE, typedWalkUp({})],
    [OWNER, guess(101)],
  ];
  for (const [uid, data] of uncounted) {
    assert.deepEqual(await rateLimitsOf(desk, handleCreateStay, uid, data), [['stays_create', 60, 60], ['stays_create_u', 20, 60]]);
  }

  // A fresh hour's budget: 10 whole-number searches and 10 guessed numbers on bookings (each refused as do_not_rent, nothing written).
  const next = setupEnv(all, { controls: { employeesCanBook: true } });
  seedListing(next.fake, 'lst_rv1', rvInput(1, { accessCodeMode: 'phone_last4' }));
  next.fake.seed(`${P}/stayGuestProfiles/gp_jane`, profileDoc('Jane Doe', { phoneE164: '+14065550123', email: 'jane@example.com' }));
  next.fake.seed(`${P}/stayGuestProfiles/gp_rex`, profileDoc('Rex Ruin', { doNotRent: true, doNotRentReason: 'Damage' }));
  for (let i = 0; i < 10; i++) assert.equal(await reasonOf(as(next, handleSearchGuests, EMPLOYEE, { query: `406${String(i).padStart(3, '0')}0123` })), null);
  for (let i = 10; i < 20; i++) assert.equal(await reasonOf(as(next, handleCreateStay, EMPLOYEE, guess(i))), 'do_not_rent');
  // The 21st lookup, by either path, is refused before anything is looked up: her real number (406-555-0123)
  // answers exactly as a wrong one does, and an email is no way round it.
  assert.equal(await reasonOf(as(next, handleCreateStay, EMPLOYEE, guess(555))), 'rate_limited');
  assert.equal(await reasonOf(as(next, handleCreateStay, EMPLOYEE, typedWalkUp({ email: 'jane@example.com' }))), 'rate_limited');
  assert.equal(await reasonOf(as(next, handleSearchGuests, EMPLOYEE, { query: '4065550123' })), 'rate_limited');
  assert.equal(next.fake.list(`${P}/stays`).length, 0);
  // Picking her from the search still books her.
  const picked = await as(next, handleCreateStay, EMPLOYEE, { ...typedWalkUp({}), guestProfile: { profileId: 'gp_jane' } });
  assert.equal(picked.created, true);
});

test('rate-limit checks never touched a storage-side collection', () => {
  assert.ok(all.length > 0);
  for (const fake of all) fake.assertIsolation();
});

import test from 'node:test';
import assert from 'node:assert/strict';

import { handleSetControls } from '../bookings/controls';
import { handleSearchGuests } from '../bookings/guests';
import { handleBulkCreateRvSites, handleSaveListing } from '../bookings/listings';
import { handleRecordPayment, handleVoidIncome } from '../bookings/payments';
import { handleCancelStay, handleCreateStay, handleModifyStay, handleQuote, handleReviewStay } from '../bookings/stays';
import { FakeFirestore } from './support/fakeFirestore';
import { EMPLOYEE, OWNER } from './support/staysFixtures';
import { Handler, as, listingInput, rateLimitsOf, reasonOf, rid, seedListing, setupEnv } from './support/bookingFixtures';

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
    ['stays_guest_phone_u', 20, 3600],
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

test('rate-limit checks never touched a storage-side collection', () => {
  assert.ok(all.length > 0);
  for (const fake of all) fake.assertIsolation();
});

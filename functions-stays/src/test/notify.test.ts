import test from 'node:test';
import assert from 'node:assert/strict';
import { Timestamp } from 'firebase-admin/firestore';

import type { StayNotificationType } from '@sfc/functions-shared/stays/contracts';

import { personalDataIn, writeStayNotifications } from '../common/notify';
import { FakeFirestore } from './support/fakeFirestore';
import { FAC, NOW, seedFacility } from './support/staysFixtures';

const NOTES = `facilities/${FAC}/Notifications`;
const all: FakeFirestore[] = [];

function newFake(): FakeFirestore {
  const fake = new FakeFirestore();
  seedFacility(fake);
  all.push(fake);
  return fake;
}

function note(id: string, message: string, type: StayNotificationType = 'STAY_BOOKING_IMPORTED') {
  return { id, type, message, metadata: { stayId: 'airbnb_HMABC12345', route: '/stays/stay?facilityId=x&stayId=y' } };
}

test('what staff may see passes: listing, dates, times and the display name', () => {
  for (const message of [
    'New Airbnb booking: Jane D. · Airbnb 1 · Oct 3–6',
    'Jane D. · 2026-10-03 to 2026-10-06, check-in 15:00',
    'Turnover done at RV 12 by Sam',
    'Double booking at Airbnb 2: 2026-10-10 to 2026-10-12',
    'The VRBO feed for Cabin 3 has failed 3 times',
    'Daily brief: 4 arrivals, 2 departures, 3 turnovers',
  ]) {
    assert.equal(personalDataIn(message), null, message);
  }
});

test('money, contact details and access codes are caught', () => {
  assert.equal(personalDataIn('Jane D. paid $450.00'), 'money');
  assert.equal(personalDataIn('Balance 120 USD'), 'money');
  assert.equal(personalDataIn('Guest jane@example.com booked'), 'email');
  assert.equal(personalDataIn('Call Jane at (555) 123-4567'), 'phone');
  assert.equal(personalDataIn('Guest phone 5551234567'), 'phone');
  assert.equal(personalDataIn('Door code 4821 for Airbnb 1'), 'access_code');
  assert.equal(personalDataIn('Lockbox: 0917'), 'access_code');
  assert.equal(personalDataIn('WiFi password is 88887777'), 'access_code');
});

test('notifications are created once each, and a personal-looking one is refused, not stored', async () => {
  const fake = newFake();
  const at = Timestamp.fromMillis(NOW);
  const first = await writeStayNotifications(
    fake.firestore(),
    FAC,
    [note('stay_ok_1', 'New Airbnb booking: Jane D. · Airbnb 1 · Oct 3–6'), note('stay_bad_1', 'Door code 4821, call (555) 123-4567')],
    at,
  );
  assert.deepEqual(first.created, ['stay_ok_1']);
  assert.deepEqual(first.failed, ['stay_bad_1']);
  assert.equal(fake.has(`${NOTES}/stay_bad_1`), false);
  const stored = fake.read(`${NOTES}/stay_ok_1`)!;
  assert.equal(stored.type, 'STAY_BOOKING_IMPORTED');
  assert.equal(stored.readAt, null);

  const again = await writeStayNotifications(fake.firestore(), FAC, [note('stay_ok_1', 'New Airbnb booking: Jane D. · Airbnb 1 · Oct 3–6')], at);
  assert.deepEqual(again.existed, ['stay_ok_1']);
  assert.deepEqual(again.created, []);

  const unknown = await writeStayNotifications(fake.firestore(), FAC, [note('stay_x', 'Hi', 'NOT_A_TYPE' as StayNotificationType)], at);
  assert.deepEqual(unknown.failed, ['stay_x']);
});

test('notifications never touched a storage-side collection', () => {
  assert.ok(all.length > 0);
  for (const fake of all) fake.assertIsolation();
});

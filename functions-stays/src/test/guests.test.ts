import test from 'node:test';
import assert from 'node:assert/strict';
import { Timestamp } from 'firebase-admin/firestore';

import { StayValidationError } from '@sfc/functions-shared/stays/validation';

import {
  displayNameFrom,
  handleSearchGuests,
  nameMatchKey,
  normalizeEmail,
  normalizePhone,
  normalizeVehicle,
  phoneLast4,
  resolveGuestProfile,
} from '../bookings/guests';
import { FakeFirestore } from './support/fakeFirestore';
import { EMPLOYEE, FAC, MANAGER, NOW, OWNER, VIEWER } from './support/staysFixtures';
import { Env, P, as, reasonOf, rid, setupEnv } from './support/bookingFixtures';

const all: FakeFirestore[] = [];

function seedProfile(e: Env, id: string, name: string, patch: Record<string, unknown> = {}) {
  e.fake.seed(`${P}/stayGuestProfiles/${id}`, {
    facilityId: FAC,
    name,
    nameLower: name.toLowerCase(),
    phoneE164: null,
    email: null,
    vehicle: null,
    notes: '',
    doNotRent: false,
    doNotRentReason: null,
    consent: null,
    stayCount: 1,
    lastStayAt: Timestamp.fromMillis(NOW - 86_400_000 * 30),
    ...patch,
  });
}

function env(controls: Record<string, unknown> = {}): Env {
  const e = setupEnv(all, { controls });
  seedProfile(e, 'gp_jane', 'Jane Doe', {
    phoneE164: '+14065550123',
    email: 'jane@example.com',
    vehicle: { plate: 'MT1ABC', state: 'MT', make: 'Winnebago', rvType: 'Class A', rvLengthFt: 35 },
  });
  seedProfile(e, 'gp_janet', 'Janet Smith', { phoneE164: '+14065559999', stayCount: 4 });
  seedProfile(e, 'gp_rex', 'Rex Ruin', { doNotRent: true, doNotRentReason: 'Left the site trashed' });
  return e;
}

test('owners and managers find returning guests by name, with their contact details', async () => {
  const e = env();
  const found = await as(e, handleSearchGuests, MANAGER, { query: 'jan' });
  assert.deepEqual(found.map((g) => g.name), ['Jane Doe', 'Janet Smith']);
  assert.deepEqual(found[0], {
    profileId: 'gp_jane',
    name: 'Jane Doe',
    rvLengthFt: 35,
    lastStayAt: new Date(NOW - 86_400_000 * 30).toISOString(),
    stayCount: 1,
    doNotRent: false,
    phoneE164: '+14065550123',
    email: 'jane@example.com',
  });
});

test('staff booking walk-ups see the do-not-rent flag but never contact details or the reason', async () => {
  const e = env({ employeesCanBook: true });
  const [jane] = await as(e, handleSearchGuests, EMPLOYEE, { query: 'Jane D' });
  assert.equal(jane.profileId, 'gp_jane');
  assert.equal('phoneE164' in jane, false);
  assert.equal('email' in jane, false);
  const [rex] = await as(e, handleSearchGuests, EMPLOYEE, { query: 'rex' });
  assert.equal(rex.doNotRent, true);
  assert.equal(JSON.stringify(rex).includes('trashed'), false);

  assert.equal(await reasonOf(as(env(), handleSearchGuests, EMPLOYEE, { query: 'jane' })), 'employee_setting_off');
  assert.equal(await reasonOf(as(e, handleSearchGuests, VIEWER, { query: 'jane' })), 'role_not_allowed');
});

test('a phone number or a plate finds the guest too; very short queries find nothing', async () => {
  const e = env();
  assert.deepEqual((await as(e, handleSearchGuests, OWNER, { query: '(406) 555-01' })).map((g) => g.profileId), ['gp_jane']);
  assert.deepEqual((await as(e, handleSearchGuests, OWNER, { query: '406555' })).map((g) => g.profileId).sort(), ['gp_jane', 'gp_janet']);
  assert.deepEqual((await as(e, handleSearchGuests, OWNER, { query: 'mt 1-abc' })).map((g) => g.profileId), ['gp_jane']);
  assert.deepEqual(await as(e, handleSearchGuests, OWNER, { query: 'j' }), []);
  assert.equal(await reasonOf(as(e, handleSearchGuests, OWNER, { query: 42 })), 'invalid_argument');
});

test('an employee finds a guest only by the whole phone number, so it cannot be guessed a digit at a time', async () => {
  const e = env({ employeesCanBook: true });
  const found = async (uid: string, query: string) => (await as(e, handleSearchGuests, uid, { query })).map((g) => g.profileId).sort();
  // Every partial number finds nothing, however many digits it has.
  for (const partial of ['406555', '(406) 555-01', '406555012', '+1406555012']) {
    assert.deepEqual(await found(EMPLOYEE, partial), [], partial);
  }
  assert.deepEqual(await found(EMPLOYEE, '406-555-0123'), ['gp_jane']);
  assert.deepEqual(await found(EMPLOYEE, '+1 406 555 0123'), ['gp_jane']);
  const [jane] = await as(e, handleSearchGuests, EMPLOYEE, { query: '4065550123' });
  assert.equal('phoneE164' in jane, false);
  // Owners and managers, who see numbers anyway, still match on the first digits.
  assert.deepEqual(await found(MANAGER, '406555'), ['gp_jane', 'gp_janet']);
});

test('phones become E.164, emails lower case; anything else is refused, not guessed', () => {
  assert.equal(normalizePhone('(406) 555-0123'), '+14065550123');
  assert.equal(normalizePhone('1 406 555 0123'), '+14065550123');
  assert.equal(normalizePhone('+44 20 7946 0958'), '+442079460958');
  assert.equal(normalizePhone('  '), null);
  assert.throws(() => normalizePhone('555-0123'), StayValidationError);
  assert.throws(() => normalizePhone('call me'), StayValidationError);
  assert.equal(normalizeEmail(' Jane@Example.COM '), 'jane@example.com');
  assert.throws(() => normalizeEmail('jane@'), StayValidationError);
  assert.deepEqual(normalizeVehicle({ plate: 'mt 1-abc', rvLengthFt: 35 }), { plate: 'MT1ABC', state: null, make: null, rvType: null, rvLengthFt: 35 });
  assert.equal(normalizeVehicle({ plate: '' }), null);
  assert.throws(() => normalizeVehicle({ rvLengthFt: 81 }), StayValidationError);
  assert.equal(displayNameFrom('  Jane  Q. doe '), 'Jane D.');
  assert.equal(displayNameFrom('Cher'), 'Cher');
  assert.equal(phoneLast4('+14065550123'), '0123');
  assert.equal(phoneLast4(null), null);
});

test('the do-not-rent name check ignores spacing, case, accents, punctuation and word order, and nothing else', () => {
  const key = nameMatchKey('Rex Ruin');
  for (const same of ['rex  ruin', ' REX RUIN ', 'Rex-Ruin', 'Ruin, Rex', 'Rëx Ruin', 'Rex\tRuin.']) assert.equal(nameMatchKey(same), key, same);
  assert.equal(nameMatchKey("O'Brien Pat"), nameMatchKey('Pat OBrien'));
  for (const other of ['Rex Ruiz', 'Rex', 'R. Ruin', 'Rex J Ruin']) assert.notEqual(nameMatchKey(other), key, other);
  assert.equal(nameMatchKey(' .- '), '');
});

test('a new guest whose email is already on file is the same guest; their phone is lent only to a booker who may read it', async () => {
  const e = env();
  const resolved = await resolveGuestProfile(e.fake.firestore(), FAC, rid(), { create: { name: 'J. Doe', email: 'JANE@example.com' } });
  assert.equal(resolved?.profileId, 'gp_jane');
  assert.equal(resolved?.existing?.name, 'Jane Doe');
  // Found by the email typed: the booking's phone is only what was typed (none), never the profile's.
  assert.deepEqual([resolved?.matchedBy, resolved?.phoneE164], ['email', null]);
  // An owner or manager, who could pick her profile and read it anyway, gets her phone (and so her door code).
  const lent = await resolveGuestProfile(e.fake.firestore(), FAC, rid(), { create: { name: 'J. Doe', email: 'jane@example.com' } }, { lendMatchedPhone: true });
  assert.deepEqual([lent?.matchedBy, lent?.phoneE164], ['email', '+14065550123']);
  // A phone typed now is this booking's, even for them.
  const typed = await resolveGuestProfile(e.fake.firestore(), FAC, rid(), { create: { name: 'J', email: 'jane@example.com', phone: '406 555 4242' } }, { lendMatchedPhone: true });
  assert.deepEqual([typed?.profileId, typed?.phoneE164], ['gp_jane', '+14065554242']);
  const byPhone = await resolveGuestProfile(e.fake.firestore(), FAC, rid(), { create: { name: 'J', phone: '406 555 0123' } });
  assert.deepEqual([byPhone?.profileId, byPhone?.matchedBy, byPhone?.phoneE164], ['gp_jane', 'phone', '+14065550123']);
  const picked = await resolveGuestProfile(e.fake.firestore(), FAC, rid(), { profileId: 'gp_jane' });
  assert.deepEqual([picked?.matchedBy, picked?.phoneE164], ['profile_id', '+14065550123']);
  const fresh = await resolveGuestProfile(e.fake.firestore(), FAC, 'a'.repeat(32), { create: { name: 'New Person', phone: '406-555-7777' } });
  assert.deepEqual([fresh?.profileId, fresh?.existing, fresh?.phoneE164, fresh?.matchedBy], [`gp_${'a'.repeat(32)}`, null, '+14065557777', null]);
  assert.equal(await resolveGuestProfile(e.fake.firestore(), FAC, rid(), undefined), null);
});

test('guest search never touched a storage-side collection', () => {
  assert.ok(all.length > 0);
  for (const fake of all) fake.assertIsolation();
});

import test from 'node:test';
import assert from 'node:assert/strict';

import { handleBulkCreateRvSites, handleSaveListing, siteShortCode } from '../bookings/listings';
import { SITE_CHECK_CHECKLIST } from '../bookings/seedDefaults';
import { staysErrorReason } from '../common/errors';
import { FakeFirestore } from './support/fakeFirestore';
import { EMPLOYEE, MANAGER, OWNER, makeStay } from './support/staysFixtures';
import { P, as, errorOf, listingInput, reasonOf, rid, rvInput, seedListing, setupEnv } from './support/bookingFixtures';

const all: FakeFirestore[] = [];

test('a new listing is stored validated, under lst_{requestId}, and a retry does not make a second', async () => {
  const env = setupEnv(all);
  const requestId = rid();
  const first = await as(env, handleSaveListing, OWNER, { requestId, listing: { ...listingInput({ name: '  Airbnb A ' }), extra: 'dropped' } });
  assert.deepEqual([first.listingId, first.version, first.created], [`lst_${requestId}`, 1, true]);
  const stored = env.fake.read(`${P}/stayListings/lst_${requestId}`)!;
  assert.equal(stored.name, 'Airbnb A');
  assert.equal(stored.extra, undefined);
  assert.equal(stored.facilityId, 'fac-caprock');
  assert.equal(stored.createdBy, OWNER);

  const writes = env.fake.writesTo('stayListings').length;
  const retry = await as(env, handleSaveListing, OWNER, { requestId, listing: listingInput() });
  assert.deepEqual([retry.listingId, retry.version, retry.created], [`lst_${requestId}`, 1, false]);
  assert.equal(env.fake.writesTo('stayListings').length, writes);
  assert.equal(env.handle.audits.filter((a) => a.entry.eventType === 'stays.listing.saved').length, 2);
});

test('the setup wizard can add listings before Stays is turned on, but only owners and managers', async () => {
  const env = setupEnv(all, { controls: { moduleEnabled: false } });
  assert.equal(await reasonOf(as(env, handleSaveListing, MANAGER, { requestId: rid(), listing: listingInput() })), null);
  assert.equal(await reasonOf(as(env, handleSaveListing, EMPLOYEE, { requestId: rid(), listing: listingInput({ name: 'X', shortCode: 'X' }) })), 'role_not_allowed');
  const unlisted = setupEnv(all, { gate: { allowlistFacilityIds: [] } });
  assert.equal(await reasonOf(as(unlisted, handleSaveListing, OWNER, { requestId: rid(), listing: listingInput() })), 'module_not_available');
});

test('bad listing values are refused with the field named', async () => {
  const env = setupEnv(all);
  const bad = listingInput({ taxLines: [{ code: 'mt', label: 'MT', rateBps: 5_000, appliesTo: ['lodging'], remittedBy: 'owner' }] });
  const error = await errorOf(as(env, handleSaveListing, OWNER, { requestId: rid(), listing: bad }));
  assert.equal(staysErrorReason(error), 'invalid_argument');
  assert.equal((error.details as { field: string }).field, 'taxLines[0].rateBps');
  const ical = listingInput({ airbnb: { listingNameAliases: [], listingUrl: null, calendarUrl: 'https://www.airbnb.com/calendar/ical/1.ics?s=abc' } });
  assert.equal(await reasonOf(as(env, handleSaveListing, OWNER, { requestId: rid(), listing: ical })), 'invalid_argument');
  assert.equal(env.fake.list(`${P}/stayListings`).length, 0);
});

test('an edit needs the version it was opened at, and bumps it', async () => {
  const env = setupEnv(all);
  seedListing(env.fake, 'lst_a', listingInput(), 3);
  assert.equal(await reasonOf(as(env, handleSaveListing, OWNER, { requestId: rid(), listingId: 'lst_a', listing: listingInput() })), 'invalid_argument');
  assert.equal(
    await reasonOf(as(env, handleSaveListing, OWNER, { requestId: rid(), listingId: 'lst_a', expectedVersion: 2, listing: listingInput() })),
    'version_mismatch',
  );
  assert.equal(await reasonOf(as(env, handleSaveListing, OWNER, { requestId: rid(), listingId: 'lst_nope', expectedVersion: 1, listing: listingInput() })), 'not_found');
  const saved = await as(env, handleSaveListing, MANAGER, {
    requestId: rid(),
    listingId: 'lst_a',
    expectedVersion: 3,
    listing: listingInput({ ratesCents: { ...listingInput().ratesCents, nightly: 13_900 } }),
  });
  assert.equal(saved.version, 4);
  const stored = env.fake.read(`${P}/stayListings/lst_a`)!;
  assert.equal((stored.ratesCents as { nightly: number }).nightly, 13_900);
  assert.equal(stored.createdBy, OWNER);
  assert.equal(stored.updatedBy, MANAGER);
});

test('two unarchived listings cannot share a name or short code; archived ones do not count', async () => {
  const env = setupEnv(all);
  seedListing(env.fake, 'lst_a', listingInput());
  seedListing(env.fake, 'lst_old', listingInput({ name: 'Old Cabin', shortCode: 'OC', archived: true, active: false }));
  const nameClash = await errorOf(as(env, handleSaveListing, OWNER, { requestId: rid(), listing: listingInput({ name: 'airbnb a', shortCode: 'B1' }) }));
  assert.equal((nameClash.details as { field: string }).field, 'name');
  const codeClash = await errorOf(as(env, handleSaveListing, OWNER, { requestId: rid(), listing: listingInput({ name: 'Airbnb B', shortCode: 'a1' }) }));
  assert.equal((codeClash.details as { field: string }).field, 'shortCode');
  assert.equal(await reasonOf(as(env, handleSaveListing, OWNER, { requestId: rid(), listing: listingInput({ name: 'Old Cabin', shortCode: 'OC' }) })), null);
  // Saving a listing under its own name is fine.
  assert.equal(await reasonOf(as(env, handleSaveListing, OWNER, { requestId: rid(), listingId: 'lst_a', expectedVersion: 1, listing: listingInput() })), null);
});

test('a facility has at most 60 active listings; archiving frees a place', async () => {
  const env = setupEnv(all);
  for (let i = 0; i < 60; i++) seedListing(env.fake, `lst_${i}`, rvInput(i));
  assert.equal(await reasonOf(as(env, handleSaveListing, OWNER, { requestId: rid(), listing: listingInput() })), 'limit_reached');
  // An inactive new listing does not count.
  assert.equal(await reasonOf(as(env, handleSaveListing, OWNER, { requestId: rid(), listing: listingInput({ active: false }) })), null);
  await as(env, handleSaveListing, OWNER, { requestId: rid(), listingId: 'lst_0', expectedVersion: 1, listing: rvInput(0, { archived: true, active: false }) });
  assert.equal(await reasonOf(as(env, handleSaveListing, OWNER, { requestId: rid(), listing: listingInput({ name: 'Airbnb Z', shortCode: 'Z' }) })), null);
});

test("a rename carries to the listing's current and future stays, with a version bump", async () => {
  const env = setupEnv(all);
  seedListing(env.fake, 'lst_a', listingInput());
  env.fake.seed(`${P}/stays/man_now`, makeStay('lst_a', '2026-10-02', '2026-10-05', { listingName: 'Airbnb A', version: 2 }) as never);
  env.fake.seed(`${P}/stays/man_old`, makeStay('lst_a', '2026-05-01', '2026-05-03', { listingName: 'Airbnb A', version: 1 }) as never);
  const saved = await as(env, handleSaveListing, OWNER, {
    requestId: rid(),
    listingId: 'lst_a',
    expectedVersion: 1,
    listing: listingInput({ name: 'Sunset Cottage', group: 'Cottages' }),
  });
  assert.equal(saved.staysUpdated, 1);
  const now = env.fake.read(`${P}/stays/man_now`)!;
  assert.deepEqual([now.listingName, now.listingGroup, now.version], ['Sunset Cottage', 'Cottages', 3]);
  // Long past stays keep the name they had.
  assert.equal(env.fake.read(`${P}/stays/man_old`)!.listingName, 'Airbnb A');
});

test('bulk RV sites: RV 1–5 with their own hookups, a site check each, created together', async () => {
  const env = setupEnv(all, { controls: { moduleEnabled: false } });
  const requestId = rid();
  const result = await as(env, handleBulkCreateRvSites, OWNER, {
    requestId,
    prefix: 'RV ',
    from: 1,
    to: 5,
    group: 'RV park',
    defaults: { ratesCents: { nightly: 4_500, weekendNightly: null, weeklyNightly: 27_000, cleaningFee: 0, petFee: 0, extraGuestFee: 0, extraGuestAfter: 0 } },
    perSite: [1, 2, 3, 4, 5].map((n) => ({ n, hookup: n <= 2 ? 'full' : 'water_electric', amps: n === 1 ? [50, 30] : [30], maxLengthFt: n === 5 ? null : 40, pullThrough: n === 1 })),
  });
  assert.deepEqual(result.listingIds, [1, 2, 3, 4, 5].map((n) => `lst_${requestId}_${n}`));
  assert.equal(result.created, 5);
  const one = env.fake.read(`${P}/stayListings/lst_${requestId}_1`)!;
  assert.deepEqual([one.name, one.shortCode, one.kind, one.group, one.active, one.sortOrder], ['RV 1', 'RV1', 'rv_site', 'RV park', true, 1]);
  assert.deepEqual(one.rv, { hookup: 'full', amps: [30, 50], maxLengthFt: 40, pullThrough: true, surface: null });
  assert.equal((one.ratesCents as { weeklyNightly: number }).weeklyNightly, 27_000);
  assert.deepEqual((one.turnover as { mode: string; checklistTemplate: unknown }).mode, 'quick_check');
  assert.deepEqual((one.turnover as { checklistTemplate: unknown }).checklistTemplate, SITE_CHECK_CHECKLIST);
  assert.equal((env.fake.read(`${P}/stayListings/lst_${requestId}_5`)!.rv as { maxLengthFt: unknown }).maxLengthFt, null);

  // A retry of the same request: the same ids, nothing new.
  const writes = env.fake.writesTo('stayListings').length;
  const retry = await as(env, handleBulkCreateRvSites, OWNER, { requestId, prefix: 'RV ', from: 1, to: 5, group: 'RV park', defaults: {}, perSite: result.listingIds.map((_, i) => ({ n: i + 1, hookup: 'full', amps: [30], maxLengthFt: null, pullThrough: false })) });
  assert.equal(retry.created, 0);
  assert.equal(env.fake.writesTo('stayListings').length, writes);

  // Sites 1–5 again under a new request clash by name.
  const again = await errorOf(as(env, handleBulkCreateRvSites, OWNER, { requestId: rid(), prefix: 'RV ', from: 4, to: 6, group: 'RV park', defaults: { rv: { hookup: 'dry', amps: [], maxLengthFt: null, pullThrough: false } } }));
  assert.equal(staysErrorReason(again), 'invalid_argument');
  assert.match((again.details as { field: string }).field, /^site 4: name$/);
  assert.equal(env.fake.list(`${P}/stayListings`).length, 5);
});

test('bulk RV sites are checked: every site needs a hookup, numbers in range, the cap holds', async () => {
  const env = setupEnv(all);
  const base = { prefix: 'Site ', group: 'RV park', defaults: {} };
  assert.equal(await reasonOf(as(env, handleBulkCreateRvSites, OWNER, { requestId: rid(), ...base, from: 1, to: 2, perSite: [{ n: 1, hookup: 'full', amps: [30], maxLengthFt: null, pullThrough: false }] })), 'invalid_argument');
  assert.equal(await reasonOf(as(env, handleBulkCreateRvSites, OWNER, { requestId: rid(), ...base, from: 1, to: 1, perSite: [{ n: 2, hookup: 'full', amps: [30], maxLengthFt: null, pullThrough: false }] })), 'invalid_argument');
  assert.equal(await reasonOf(as(env, handleBulkCreateRvSites, OWNER, { requestId: rid(), ...base, from: 3, to: 1, perSite: [] })), 'invalid_argument');
  assert.equal(await reasonOf(as(env, handleBulkCreateRvSites, OWNER, { requestId: rid(), ...base, from: 1, to: 1, defaults: { name: 'All the same' }, perSite: [] })), 'invalid_argument');
  assert.equal(await reasonOf(as(env, handleBulkCreateRvSites, OWNER, { requestId: rid(), ...base, from: 1, to: 1, perSite: [{ n: 1, hookup: 'sewer', amps: [30], maxLengthFt: null, pullThrough: false }] })), 'invalid_argument');
  assert.equal(await reasonOf(as(env, handleBulkCreateRvSites, EMPLOYEE, { requestId: rid(), ...base, from: 1, to: 1, perSite: [] })), 'role_not_allowed');

  for (let i = 0; i < 58; i++) seedListing(env.fake, `lst_${i}`, listingInput({ name: `Cabin ${i}`, shortCode: `C${i}` }));
  const rv = { rv: { hookup: 'electric', amps: [30], maxLengthFt: null, pullThrough: false } };
  assert.equal(await reasonOf(as(env, handleBulkCreateRvSites, OWNER, { requestId: rid(), ...base, from: 1, to: 3, defaults: rv })), 'limit_reached');
  assert.equal(env.fake.list(`${P}/stayListings`).length, 58);
  assert.equal(await reasonOf(as(env, handleBulkCreateRvSites, OWNER, { requestId: rid(), ...base, from: 1, to: 2, defaults: rv })), null);
  assert.equal(siteShortCode('Site ', 12), 'Site12');
  assert.equal(siteShortCode('Pull-through ', 104), 'Pullt104');
});

test('listings never touched a storage-side collection', () => {
  assert.ok(all.length > 0);
  for (const fake of all) fake.assertIsolation();
});

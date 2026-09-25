import test from 'node:test';
import assert from 'node:assert/strict';
import * as functions from 'firebase-functions/v1';
import {
  movedToSlugOf,
  planPublicSlugPointers,
  publicMapPointer,
  readPublicFacilityMap,
} from '../hosting/publicFacilityMapSlug';
import { resolveFacilitySlugFromInput } from '../hosting/hostingCustomDomains';
import { InMemoryFirestore, installInMemoryFirestore } from './support/inMemoryFirestore';

/**
 * Old public map slugs after a slug change: the old doc becomes a pointer, and
 * readers follow it one hop, only to a published map of the same facility.
 */

const FACILITY = 'eXnWPuwuqzBVFcZWv1ZL';

function units(n: number) {
  return Array.from({ length: n }, (_, i) => ({ unitId: `u${i}`, isRentable: true }));
}

function seeded() {
  const inMemory = new InMemoryFirestore();
  inMemory.seed('publicFacilityMaps/keepsakeonlinerentals', {
    facilityId: FACILITY,
    facilitySlug: 'keepsakeonlinerentals',
    units: units(3),
    publicSettings: { enabled: true },
  });
  inMemory.seed('publicFacilityMaps/storage', publicMapPointer(FACILITY, 'keepsakeonlinerentals', 'then'));
  return inMemory;
}

test('movedToSlugOf: only a non-empty string is a pointer', () => {
  assert.equal(movedToSlugOf({ movedToSlug: 'new-slug' }), 'new-slug');
  assert.equal(movedToSlugOf({ movedToSlug: '  new-slug ' }), 'new-slug');
  assert.equal(movedToSlugOf({ movedToSlug: '' }), null);
  assert.equal(movedToSlugOf({ movedToSlug: 42 }), null);
  assert.equal(movedToSlugOf({ units: [] }), null);
  assert.equal(movedToSlugOf(undefined), null);
});

test('a published map is served where it is', async () => {
  const map = await readPublicFacilityMap(seeded().firestore(), 'keepsakeonlinerentals');
  assert.equal(map?.slug, 'keepsakeonlinerentals');
  assert.equal((map?.data.units as unknown[]).length, 3);
});

test('an old slug serves the current map, and says where it lives now', async () => {
  const map = await readPublicFacilityMap(seeded().firestore(), 'storage');
  assert.equal(map?.slug, 'keepsakeonlinerentals');
  assert.equal(map?.data.facilityId, FACILITY);
  assert.equal((map?.data.units as unknown[]).length, 3);
});

test('a missing slug, or an empty one, serves nothing', async () => {
  const db = seeded().firestore();
  assert.equal(await readPublicFacilityMap(db, 'nope'), null);
  assert.equal(await readPublicFacilityMap(db, ''), null);
});

test("a pointer to another facility's map is not followed", async () => {
  const inMemory = seeded();
  inMemory.seed('publicFacilityMaps/rival', { facilityId: 'rival-facility', units: units(1) });
  inMemory.seed('publicFacilityMaps/storage', publicMapPointer(FACILITY, 'rival', 'then'));
  assert.equal(await readPublicFacilityMap(inMemory.firestore(), 'storage'), null);
});

test('a pointer is followed one hop only: not to another pointer, nor to itself', async () => {
  const inMemory = seeded();
  inMemory.seed('publicFacilityMaps/older', publicMapPointer(FACILITY, 'storage', 'then'));
  inMemory.seed('publicFacilityMaps/loop', publicMapPointer(FACILITY, 'loop', 'then'));
  const db = inMemory.firestore();
  assert.equal(await readPublicFacilityMap(db, 'older'), null);
  assert.equal(await readPublicFacilityMap(db, 'loop'), null);
});

test('a pointer to a slug with no doc, or a pointer with no facility, serves nothing', async () => {
  const inMemory = seeded();
  inMemory.seed('publicFacilityMaps/dangling', publicMapPointer(FACILITY, 'gone', 'then'));
  inMemory.seed('publicFacilityMaps/anon', { movedToSlug: 'keepsakeonlinerentals' });
  const db = inMemory.firestore();
  assert.equal(await readPublicFacilityMap(db, 'dangling'), null);
  assert.equal(await readPublicFacilityMap(db, 'anon'), null);
});

test('migration plan: every other doc of the facility becomes a pointer (the Keepsake case)', () => {
  const docs = [
    { id: 'eXnWPuwuqzBVFcZWv1ZL', data: { facilityId: FACILITY, units: units(200) } },
    { id: 'keepsakeonlinerentals', data: { facilityId: FACILITY, units: units(200), inventorySyncedAt: 'now' } },
    { id: 'r6iubms3mdn7m90ss7oo', data: { facilityId: FACILITY, units: units(200) } },
    { id: 'storage', data: { facilityId: FACILITY, units: units(200) } },
    { id: 'storageunitrentals', data: { facilityId: FACILITY, units: units(200) } },
    // Already pointing at the current slug: nothing to do.
    { id: 'done', data: publicMapPointer(FACILITY, 'keepsakeonlinerentals', 'then') },
    // Pointing at an older slug: repointed, so it is one hop from the map.
    { id: 'chained', data: publicMapPointer(FACILITY, 'storage', 'then') },
    // Another facility's doc is never touched.
    { id: 'theirs', data: { facilityId: 'other', units: units(5) } },
  ];
  const plan = planPublicSlugPointers(FACILITY, 'keepsakeonlinerentals', docs);
  assert.ok('changes' in plan);
  assert.deepEqual(plan.changes, [
    { slug: 'chained', was: 'pointer', unitCount: 0, movedToSlug: 'storage' },
    { slug: 'eXnWPuwuqzBVFcZWv1ZL', was: 'map', unitCount: 200, movedToSlug: null },
    { slug: 'r6iubms3mdn7m90ss7oo', was: 'map', unitCount: 200, movedToSlug: null },
    { slug: 'storage', was: 'map', unitCount: 200, movedToSlug: null },
    { slug: 'storageunitrentals', was: 'map', unitCount: 200, movedToSlug: null },
  ]);
});

test('migration plan: nothing changes without a current map of the facility to point at', () => {
  const stale = { id: 'storage', data: { facilityId: FACILITY, units: units(2) } };
  for (const [currentSlug, docs, reason] of [
    [null, [stale], /no mapEngine\/meta.publicSlug/],
    ['  ', [stale], /no mapEngine\/meta.publicSlug/],
    ['keepsake', [stale], /no publicFacilityMaps\/keepsake of this facility/],
    ['keepsake', [stale, { id: 'keepsake', data: { facilityId: 'other' } }], /no publicFacilityMaps\/keepsake/],
    ['keepsake', [stale, { id: 'keepsake', data: publicMapPointer(FACILITY, 'storage', 'then') }], /itself a pointer/],
    [FACILITY, [stale, { id: FACILITY, data: { facilityId: FACILITY, units: units(1) } }], /not lower case/],
  ] as const) {
    const plan = planPublicSlugPointers(FACILITY, currentSlug, [...docs]);
    assert.ok('skipped' in plan, `expected a skip for ${currentSlug}`);
    assert.match(plan.skipped, reason);
  }
});

test('custom domains: an old slug resolves to its facility and the current slug', async () => {
  const inMemory = seeded();
  installInMemoryFirestore(inMemory);
  assert.deepEqual(await resolveFacilitySlugFromInput({ slug: 'Storage' }), {
    facilityId: FACILITY,
    slug: 'keepsakeonlinerentals',
  });
  assert.deepEqual(await resolveFacilitySlugFromInput({ slug: 'keepsakeonlinerentals' }), {
    facilityId: FACILITY,
    slug: 'keepsakeonlinerentals',
  });
});

test("custom domains: a pointer to another facility's slug is not found", async () => {
  const inMemory = seeded();
  inMemory.seed('publicFacilityMaps/rival', { facilityId: 'rival-facility' });
  inMemory.seed('publicFacilityMaps/storage', publicMapPointer(FACILITY, 'rival', 'then'));
  installInMemoryFirestore(inMemory);
  await assert.rejects(resolveFacilitySlugFromInput({ slug: 'storage' }), (err: unknown) => {
    assert.equal((err as functions.https.HttpsError).code, 'not-found');
    return true;
  });
});

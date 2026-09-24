import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'fs';
import * as path from 'path';
import {
  fitUnitsToDocument,
  readEveryDoc,
  syncPublicFacilityMapInventoryForFacility,
  syncPublicFacilityMapInventoryOnUnitWrite,
} from '../publicFacilityMapInventorySync';
import { InMemoryFirestore, installInMemoryFirestore } from './support/inMemoryFirestore';

/**
 * Cover for the two caps this replaced.
 *
 * The sync read tenants with `.limit(500)` and units with `.limit(400)`, neither with an
 * `orderBy`, so Firestore fell back to document-id order and both took an arbitrary slice. On
 * units that hid real units from the public map. On tenants it was worse: `tenantClaimed` is what
 * marks a unit as taken, so a tenant beyond the cap left their unit advertised as available.
 */

/** Enough of a CollectionReference for the pager: ordered by id, with a cursor. */
function fakeCollection(ids: string[]) {
  let pages = 0;
  const make = (after?: string, limit = Infinity) => ({
    orderBy: () => make(after, limit),
    limit: (n: number) => make(after, n),
    startAfter: (cursor: { id: string }) => make(cursor.id, limit),
    get: async () => {
      pages++;
      const sorted = [...ids].sort();
      const from = after ? sorted.filter((id) => id > after) : sorted;
      const docs = from.slice(0, limit === Infinity ? undefined : limit).map((id) => ({ id }));
      return { docs, size: docs.length };
    },
  });
  return { ref: make() as never, pageCount: () => pages };
}

test('the pager returns every document, across several pages', async () => {
  // 2,500 forces three pages at the production page size of 1,000.
  const ids = Array.from({ length: 2500 }, (_, i) => `unit-${String(i).padStart(5, '0')}`);
  const { ref, pageCount } = fakeCollection(ids);

  const docs = await readEveryDoc(ref);

  assert.equal(docs.length, 2500, 'every document, not the first page');
  assert.equal(new Set(docs.map((d) => d.id)).size, 2500, 'no document returned twice');
  assert.ok(pageCount() >= 3, `expected several pages, made ${pageCount()}`);
});

test('the pager terminates on an exact multiple of the page size', async () => {
  // The off-by-one that loops forever: a final page that is full, followed by an empty one.
  const ids = Array.from({ length: 2000 }, (_, i) => `u${String(i).padStart(4, '0')}`);
  const { ref } = fakeCollection(ids);
  const docs = await readEveryDoc(ref);
  assert.equal(docs.length, 2000);
});

test('the pager copes with an empty collection', async () => {
  const { ref } = fakeCollection([]);
  assert.deepEqual(await readEveryDoc(ref), []);
});

function unit(n: number) {
  return {
    unitId: `unit-${n}`,
    unitNumber: String(n),
    displayName: `Unit ${n}`,
    status: 'available',
    unitType: 'Climate Controlled 10x10',
    description: 'A reasonably wordy description, of the sort a real listing carries.',
    monthlyRate: 129,
    isRentable: true,
  };
}

test('a list that fits is published whole', () => {
  const units = Array.from({ length: 50 }, (_, i) => unit(i));
  const { published, omitted } = fitUnitsToDocument(units);
  assert.equal(published.length, 50);
  assert.equal(omitted, 0);
});

test('a list that does not fit is trimmed from the end and the loss is reported', () => {
  const units = Array.from({ length: 5000 }, (_, i) => unit(i));
  const { published, omitted } = fitUnitsToDocument(units, 50_000);

  assert.ok(published.length > 0, 'something is published');
  assert.ok(published.length < units.length, 'and it is genuinely smaller');
  assert.equal(omitted, units.length - published.length, 'the count adds up');
  assert.ok(
    Buffer.byteLength(JSON.stringify(published), 'utf8') <= 50_000,
    'what is published actually fits',
  );
  // Trimming from the end of an already-sorted list is what makes this predictable, rather than
  // the arbitrary document-id slice the old cap took.
  assert.deepEqual(
    published.map((u) => u.unitId),
    units.slice(0, published.length).map((u) => u.unitId),
    'the kept units are the first ones, in order',
  );
});

test('trimming terminates even when a single unit is over the ceiling', () => {
  const units = Array.from({ length: 8 }, (_, i) => unit(i));
  const { published, omitted } = fitUnitsToDocument(units, 10);
  assert.equal(published.length, 1, 'stops at one rather than looping to nothing');
  assert.equal(omitted, 7);
});

const MAP_FACILITY = 'fac-map';
const MAP_SLUG = 'fac-map-slug';

/** A published map for MAP_FACILITY with available, unlinked units A1..A4. */
function seedPublishedMap(inMemory: InMemoryFirestore) {
  inMemory.seed(`facilities/${MAP_FACILITY}/mapEngine/meta`, { publicSlug: MAP_SLUG });
  inMemory.seed(`publicFacilityMaps/${MAP_SLUG}`, { facilityId: MAP_FACILITY, units: [] });
  for (const n of ['A1', 'A2', 'A3', 'A4']) {
    inMemory.seed(`facilities/${MAP_FACILITY}/units/${n}`, {
      unitNumber: n,
      status: 'available',
      unitType: 'standard',
      monthlyRate: 100,
    });
  }
}

async function publishedUnits(inMemory: InMemoryFirestore): Promise<Record<string, Record<string, any>>> {
  installInMemoryFirestore(inMemory);
  await syncPublicFacilityMapInventoryForFacility(MAP_FACILITY);
  const units = inMemory.read(`publicFacilityMaps/${MAP_SLUG}`)?.units as Array<Record<string, any>>;
  return Object.fromEntries(units.map((u) => [String(u.unitNumber), u]));
}

test('only a tenant with isActive exactly true claims its unit, as in the app', async () => {
  const inMemory = new InMemoryFirestore();
  seedPublishedMap(inMemory);
  inMemory.seed(`facilities/${MAP_FACILITY}/tenants/active`, { name: 'Al', isActive: true, unitNumber: 'A1' });
  inMemory.seed(`facilities/${MAP_FACILITY}/tenants/archived`, { name: 'Bo', isActive: false, unitNumber: 'A2' });
  // A partial doc with no isActive, e.g. recreated by a server merge-write.
  inMemory.seed(`facilities/${MAP_FACILITY}/tenants/partial`, { unitNumber: 'A3' });

  const units = await publishedUnits(inMemory);

  assert.equal(units.A1.status, 'rented');
  assert.equal(units.A1.isRentable, false);
  assert.equal(units.A2.isRentable, true);
  // Before: skipped only isActive === false, so the partial doc claimed A3
  // here while the app (TenantModel reads a missing isActive as inactive)
  // published A3 as rentable: the two writers of this list disagreed.
  assert.equal(units.A3.isRentable, true);
  assert.equal(units.A4.isRentable, true);
});

test('archived units are left off the public map by the same test the app uses', async () => {
  const inMemory = new InMemoryFirestore();
  seedPublishedMap(inMemory);
  inMemory.seed(`facilities/${MAP_FACILITY}/units/A2`, {
    unitNumber: 'A2', status: 'available', unitType: 'standard', archived: true,
  });
  // A stray string: the app's unit read drops it, so this sync must too.
  inMemory.seed(`facilities/${MAP_FACILITY}/units/A3`, {
    unitNumber: 'A3', status: 'available', unitType: 'standard', archived: 'true',
  });
  inMemory.seed(`facilities/${MAP_FACILITY}/units/A4`, {
    unitNumber: 'A4', status: 'available', unitType: 'standard', archived: false,
  });

  const units = await publishedUnits(inMemory);

  assert.deepEqual(Object.keys(units).sort(), ['A1', 'A4']);
});

type FixtureDoc = { id: string; data: Record<string, unknown> };
type PublicMapCase = {
  name: string;
  units: FixtureDoc[];
  tenants: FixtureDoc[];
  /** Per unit, the published fields compared: isRentable and status always, some others. */
  expected: Record<string, Record<string, unknown>>;
};

/** Cases the app's test (test/public_map_units_parity_test.dart) runs too. */
function publicMapParityCases(): PublicMapCase[] {
  const file = path.join(__dirname, '..', '..', '..', 'test', 'fixtures', 'public_map_units.json');
  return (JSON.parse(fs.readFileSync(file, 'utf8')) as { cases: PublicMapCase[] }).cases;
}

test('the sync publishes every shared parity case as the app does', async () => {
  const cases = publicMapParityCases();
  assert.ok(cases.length >= 10, 'the shared fixture was not read');
  for (const c of cases) {
    const inMemory = new InMemoryFirestore();
    inMemory.seed(`facilities/${MAP_FACILITY}/mapEngine/meta`, { publicSlug: MAP_SLUG });
    inMemory.seed(`publicFacilityMaps/${MAP_SLUG}`, { facilityId: MAP_FACILITY, units: [] });
    for (const u of c.units) inMemory.seed(`facilities/${MAP_FACILITY}/units/${u.id}`, u.data);
    for (const t of c.tenants) inMemory.seed(`facilities/${MAP_FACILITY}/tenants/${t.id}`, t.data);
    installInMemoryFirestore(inMemory);

    await syncPublicFacilityMapInventoryForFacility(MAP_FACILITY);

    const units = inMemory.read(`publicFacilityMaps/${MAP_SLUG}`)?.units as Array<Record<string, any>>;
    // The fields each unit's entry names; a unit the fixture does not expect shows up as an extra key.
    const fieldsOf = (unitId: string) => Object.keys(c.expected[unitId] ?? { isRentable: 0, status: 0 });
    assert.deepEqual(
      Object.fromEntries(
        units.map((u) => [u.unitId, Object.fromEntries(fieldsOf(u.unitId).map((f) => [f, u[f]]))]),
      ),
      c.expected,
      c.name,
    );
  }
});

test('an internal-use unit left listed is not offered, as the online hold refuses it', async () => {
  const inMemory = new InMemoryFirestore();
  seedPublishedMap(inMemory);
  inMemory.seed(`facilities/${MAP_FACILITY}/units/A2`, {
    unitNumber: 'A2', status: 'available', unitType: 'standard', internalUse: true, publicListingEnabled: true,
  });

  const units = await publishedUnits(inMemory);

  // Before: only publicListingEnabled counted, so this office was published as rentable and
  // createPublicReservationHold (isUnitOfferedOnline) then turned the renter away.
  assert.equal(units.A2.isRentable, false);
  assert.equal(units.A2.status, 'unavailable');
  assert.equal(units.A2.publicListingEnabled, true, 'its own switch is still published as set');
  assert.equal(units.A1.isRentable, true);
});

/** A unit doc write as the v1 onWrite trigger receives it: only `exists` and `data()` are read. */
function unitChange(before: Record<string, unknown>, after: Record<string, unknown>) {
  return {
    before: { exists: true, data: () => before },
    after: { exists: true, data: () => after },
  } as unknown as Parameters<typeof syncPublicFacilityMapInventoryOnUnitWrite.run>[0];
}

test('turning internal use on or off resyncs the public map', async () => {
  const office = { unitNumber: 'A2', status: 'available', unitType: 'standard' };
  const trigger = (before: Record<string, unknown>, after: Record<string, unknown>) =>
    syncPublicFacilityMapInventoryOnUnitWrite.run(unitChange(before, after), {
      params: { facilityId: MAP_FACILITY, unitId: 'A2' },
    });

  for (const [from, to] of [[false, true], [true, false], [undefined, true]]) {
    const inMemory = new InMemoryFirestore();
    seedPublishedMap(inMemory);
    inMemory.seed(`facilities/${MAP_FACILITY}/units/A2`, { ...office, internalUse: to });
    installInMemoryFirestore(inMemory);

    await trigger({ ...office, internalUse: from }, { ...office, internalUse: to });

    // Before: internalUse was not an inventory key, so this change was ignored and the list kept
    // offering (or kept hiding) the unit until some other field changed.
    const map = inMemory.read(`publicFacilityMaps/${MAP_SLUG}`);
    assert.ok(map?.inventorySyncedAt, `internalUse ${from} -> ${to} resynced`);
    const a2 = (map?.units as Array<Record<string, any>>).find((u) => u.unitId === 'A2');
    assert.equal(a2?.isRentable, to !== true, `internalUse ${from} -> ${to}`);
  }

  // The control: a change to a field the public list does not carry leaves it alone.
  const inMemory = new InMemoryFirestore();
  seedPublishedMap(inMemory);
  installInMemoryFirestore(inMemory);
  await trigger({ ...office, notes: 'a' }, { ...office, notes: 'b' });
  assert.equal(inMemory.read(`publicFacilityMaps/${MAP_SLUG}`)?.inventorySyncedAt, undefined);
});

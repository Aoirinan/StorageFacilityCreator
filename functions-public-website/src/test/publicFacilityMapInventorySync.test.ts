import test from 'node:test';
import assert from 'node:assert/strict';
import {
  fitUnitsToDocument,
  readEveryDoc,
} from '../publicFacilityMapInventorySync';

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

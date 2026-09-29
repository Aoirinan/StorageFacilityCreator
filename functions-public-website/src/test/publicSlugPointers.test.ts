import test from 'node:test';
import assert from 'node:assert/strict';
import { getPublicWebsiteConfig, renderPublicWebsite } from '../publicWebsite';
import { syncPublicFacilityMapInventoryForFacility } from '../publicFacilityMapInventorySync';
import { InMemoryFirestore, installInMemoryFirestore } from './support/inMemoryFirestore';

/**
 * Old public map slugs. A slug change used to leave the old doc with its full
 * unit list and nothing synced it again, so /w/<old> and the rental links in it
 * served a frozen list. The old doc is now a pointer to the current slug, and
 * the site serves the current map for it, under the current slug.
 */

const FACILITY = 'eXnWPuwuqzBVFcZWv1ZL';
const LIVE = 'keepsakeonlinerentals';

function seed(): InMemoryFirestore {
  const inMemory = new InMemoryFirestore();
  // billingExempt: served without the add-on (hasActiveWebsiteSubscription).
  inMemory.seed(`facilities/${FACILITY}`, { name: 'Keepsake', billingExempt: true });
  inMemory.seed(`facilities/${FACILITY}/mapEngine/meta`, { publicSlug: LIVE });
  // Online rentals on, so the page renders its rent links (the rent links and
  // rentUrl are only offered while the hold would take a rental, 0216e7e).
  inMemory.seed(`facilities/${FACILITY}/settings/public`, { enabled: true, publicRentalsEnabled: true });
  inMemory.seed(`publicFacilityMaps/${LIVE}`, {
    facilityId: FACILITY,
    facilitySlug: LIVE,
    facilityName: 'Keepsake Storage',
    publicSettings: { enabled: true },
    units: [
      { unitId: 'u1', unitNumber: 'A1', categorySlug: 'standard', monthlyRate: 60, isRentable: true },
      { unitId: 'u2', unitNumber: 'A2', categorySlug: 'standard', monthlyRate: 70, isRentable: false },
    ],
  });
  inMemory.seed('publicFacilityMaps/storage', { facilityId: FACILITY, movedToSlug: LIVE, movedAt: 'then' });
  inMemory.seed('facilities/rival', { name: 'Rival', billingExempt: true });
  inMemory.seed('publicFacilityMaps/rival', {
    facilityId: 'rival',
    facilityName: 'Rival Storage',
    publicSettings: { enabled: true },
    units: [{ unitId: 'r1', isRentable: true, monthlyRate: 1 }],
  });
  installInMemoryFirestore(inMemory);
  return inMemory;
}

function fakeResponse() {
  const out: { status: number; body: unknown; headers: Record<string, string> } = {
    status: 200,
    body: undefined,
    headers: {},
  };
  const res = {
    headersSent: false,
    set(key: string, value: string) {
      out.headers[key] = value;
      return res;
    },
    status(code: number) {
      out.status = code;
      return res;
    },
    type() {
      return res;
    },
    json(body: unknown) {
      out.body = body;
      res.headersSent = true;
      return res;
    },
    send(body: unknown) {
      out.body = body;
      res.headersSent = true;
      return res;
    },
  };
  return { res, out };
}

async function call(
  handler: unknown,
  req: { path?: string; query?: Record<string, string> },
): Promise<{ status: number; body: unknown }> {
  const { res, out } = fakeResponse();
  const request = {
    method: 'GET',
    path: req.path || '/',
    originalUrl: req.path || '/',
    query: req.query || {},
    headers: { host: 'app.storagefacilitycreator.com' },
  };
  await (handler as (q: unknown, s: unknown) => Promise<void>)(request, res);
  return out;
}

test('website config: an old slug answers with the current map, under the current slug', async () => {
  seed();
  const { status, body } = await call(getPublicWebsiteConfig, { query: { slug: 'storage' } });
  assert.equal(status, 200);
  const config = body as Record<string, unknown>;
  assert.equal(config.facilityId, FACILITY);
  assert.equal(config.facilitySlug, LIVE);
  assert.equal(config.availableCount, 1);
  assert.equal(config.rentUrl, `https://app.storagefacilitycreator.com/w/${LIVE}#units`);
});

test("website config: a pointer to another facility's slug is not found", async () => {
  const inMemory = seed();
  inMemory.seed('publicFacilityMaps/storage', { facilityId: FACILITY, movedToSlug: 'rival', movedAt: 'then' });
  const { status } = await call(getPublicWebsiteConfig, { query: { slug: 'storage' } });
  assert.equal(status, 404);
});

test('rendered site: /w/<old slug> renders the current map, every link on the current slug', async () => {
  seed();
  const { status, body } = await call(renderPublicWebsite, { path: '/w/storage' });
  assert.equal(status, 200);
  const html = String(body);
  assert.match(html, /Keepsake Storage/);
  assert.ok(html.includes(`/w/${LIVE}`), 'links to the current slug');
  assert.ok(html.includes(`/#/f/${LIVE}/standard`), 'rent links on the current slug');
  assert.ok(!html.includes('/w/storage'), 'no link keeps the old slug');
  assert.ok(!html.includes('/f/storage/'), 'no rent link keeps the old slug');
});

test('rendered site: a pointer is followed one hop, to its own facility only', async () => {
  const inMemory = seed();
  inMemory.seed('publicFacilityMaps/older', { facilityId: FACILITY, movedToSlug: 'storage', movedAt: 'then' });
  inMemory.seed('publicFacilityMaps/hijack', { facilityId: FACILITY, movedToSlug: 'rival', movedAt: 'then' });
  for (const slug of ['older', 'hijack']) {
    const { status, body } = await call(renderPublicWebsite, { path: `/w/${slug}` });
    assert.equal(status, 404, slug);
    assert.ok(!String(body).includes('Rival Storage'), slug);
  }
});

test('the current slug renders as before', async () => {
  seed();
  const { status, body } = await call(renderPublicWebsite, { path: `/w/${LIVE}` });
  assert.equal(status, 200);
  assert.match(String(body), /Keepsake Storage/);
});

test('inventory sync leaves a pointer at the current slug without units', async () => {
  const inMemory = seed();
  inMemory.seed(`facilities/${FACILITY}/mapEngine/meta`, { publicSlug: 'storage' });
  inMemory.seed(`facilities/${FACILITY}/units/u1`, { unitNumber: 'A1', status: 'available' });
  await syncPublicFacilityMapInventoryForFacility(FACILITY);
  const pointer = inMemory.read('publicFacilityMaps/storage');
  assert.deepEqual(Object.keys(pointer || {}).sort(), ['facilityId', 'movedAt', 'movedToSlug']);
});

test("inventory sync never writes this facility's units into another facility's slug", async () => {
  const inMemory = seed();
  inMemory.seed(`facilities/${FACILITY}/mapEngine/meta`, { publicSlug: 'rival' });
  inMemory.seed(`facilities/${FACILITY}/units/u1`, { unitNumber: 'A1', status: 'available' });
  await syncPublicFacilityMapInventoryForFacility(FACILITY);
  const rival = inMemory.read('publicFacilityMaps/rival');
  assert.deepEqual(rival?.units, [{ unitId: 'r1', isRentable: true, monthlyRate: 1 }]);
  assert.equal(rival?.inventorySyncedAt, undefined);
});

test("inventory sync still refreshes the facility's own current map", async () => {
  const inMemory = seed();
  inMemory.seed(`facilities/${FACILITY}/units/u9`, { unitNumber: 'B9', status: 'available' });
  await syncPublicFacilityMapInventoryForFacility(FACILITY);
  const live = inMemory.read(`publicFacilityMaps/${LIVE}`);
  assert.deepEqual((live?.units as Array<{ unitId: string }>).map((u) => u.unitId), ['u9']);
  assert.notEqual(live?.inventorySyncedAt, undefined);
});

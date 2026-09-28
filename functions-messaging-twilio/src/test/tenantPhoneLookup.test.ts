import assert from 'node:assert/strict';
import test from 'node:test';
import {
  findTenantsByPhoneNumber,
  nationalDigits,
  phoneLookupVariants,
  rankTenantMatches,
  samePhone,
  TenantPhoneMatch,
  TenantPhoneStore,
} from '../tenantPhoneLookup';

/** An in-memory Firestore stand-in that behaves like the real `in` query. */
function store(tenants: TenantPhoneMatch[]): TenantPhoneStore & { scans: string[] } {
  const scans: string[] = [];
  return {
    scans,
    async queryByPhones(phones, isActive) {
      assert.ok(phones.length <= 30, 'Firestore `in` allows at most 30 values');
      return tenants.filter((t) => t.isActive === isActive && phones.includes(t.phone));
    },
    async listFacilityTenants(facilityId) {
      scans.push(facilityId);
      return tenants.filter((t) => t.facilityId === facilityId);
    },
  };
}

const INBOUND = '+19035550100';

test('an inbound number matches the dashed form production stores', async () => {
  const s = store([{ facilityId: 'fA', id: 't1', phone: '903-555-0100', isActive: true }]);
  const matches = await findTenantsByPhoneNumber(INBOUND, null, s);
  assert.deepEqual(matches.map((m) => m.id), ['t1']);
});

test('common written forms all match', async () => {
  for (const phone of ['903-555-0100', '(903) 555-0100', '(903)555-0100', '903.555.0100', '903 555 0100', '9035550100', '+19035550100', '19035550100', '1-903-555-0100', '+1 (903) 555-0100']) {
    const s = store([{ facilityId: 'fA', id: 't1', phone, isActive: true }]);
    const matches = await findTenantsByPhoneNumber(INBOUND, null, s);
    assert.equal(matches.length, 1, phone);
  }
});

test('the variant list stays inside the Firestore `in` limit and covers the dashed form', () => {
  const v = phoneLookupVariants(INBOUND);
  assert.ok(v.length <= 30);
  assert.ok(v.includes('903-555-0100'));
  assert.ok(v.includes('(903) 555-0100'));
  assert.deepEqual(phoneLookupVariants('not a phone'), []);
});

test('every tenant with the number is found, across facilities and including former tenants', async () => {
  const s = store([
    { facilityId: 'fA', id: 't1', phone: '903-555-0100', isActive: true },
    { facilityId: 'fB', id: 't2', phone: '(903) 555-0100', isActive: true },
    { facilityId: 'fB', id: 't3', phone: '903-555-0100', isActive: false },
    { facilityId: 'fC', id: 't4', phone: '903-555-0199', isActive: true },
  ]);
  const matches = await findTenantsByPhoneNumber(INBOUND, null, s);
  assert.deepEqual(matches.map((m) => m.id).sort(), ['t1', 't2', 't3']);
  // Active tenants rank ahead of former ones.
  assert.equal(matches[matches.length - 1].id, 't3');
});

test('the facility that owns the inbound line ranks first', async () => {
  const s = store([
    { facilityId: 'fA', id: 't1', phone: '903-555-0100', isActive: true },
    { facilityId: 'fB', id: 't2', phone: '903-555-0100', isActive: true },
  ]);
  const matches = await findTenantsByPhoneNumber(INBOUND, 'fB', s);
  assert.equal(matches[0].facilityId, 'fB');
});

test('an odd written form on the facility line is still found by a digits scan', async () => {
  const s = store([{ facilityId: 'fA', id: 't1', phone: '903 555-0100 (cell)', isActive: true }]);
  assert.deepEqual(await findTenantsByPhoneNumber(INBOUND, null, s), []);
  const matches = await findTenantsByPhoneNumber(INBOUND, 'fA', s);
  assert.deepEqual(matches.map((m) => m.id), ['t1']);
  assert.deepEqual(s.scans, ['fA']);
});

test('no scan when the variant query already found the tenant', async () => {
  const s = store([{ facilityId: 'fA', id: 't1', phone: '903-555-0100', isActive: true }]);
  await findTenantsByPhoneNumber(INBOUND, 'fA', s);
  assert.deepEqual(s.scans, []);
});

test('unknown numbers match nobody, so only they reach the lead line', async () => {
  const s = store([{ facilityId: 'fA', id: 't1', phone: '903-555-0100', isActive: true }]);
  assert.deepEqual(await findTenantsByPhoneNumber('+18175550123', null, s), []);
});

test('digits comparison helpers', () => {
  assert.equal(nationalDigits('903-555-0100'), '9035550100');
  assert.equal(nationalDigits('+1 (903) 555-0100'), '9035550100');
  assert.equal(nationalDigits(''), null);
  assert.equal(samePhone('903-555-0100', '+19035550100'), true);
  assert.equal(samePhone('903-555-0100', '903-555-0101'), false);
  assert.equal(samePhone(null, null), false);
});

test('ranking removes duplicates', () => {
  const m = { facilityId: 'fA', id: 't1', phone: '903-555-0100', isActive: true };
  assert.equal(rankTenantMatches([m, { ...m }]).length, 1);
});

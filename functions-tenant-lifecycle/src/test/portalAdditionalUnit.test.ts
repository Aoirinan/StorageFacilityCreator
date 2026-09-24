/**
 * "Rent another unit" in the tenant portal offers only units the owner offers
 * online.
 *
 * The portal listed every unit with status 'available', and its hold checked
 * only status, so a portal tenant could rent a unit the owner had left off
 * the public website, kept as an office or residence, or archived. The portal
 * rents through the same online move-in and checkout as the public page.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import { InMemoryFirestore, installInMemoryFirestore } from './support/inMemoryFirestore';

const FACILITY = 'fac-portal';
const TENANT = 'tenant-portal';
const EMAIL = 'tess@example.com';
const ACCESS_CODE = 'ABCD2345';
const context = { rawRequest: { ip: '203.0.113.7' } } as unknown as functions.https.CallableContext;

/** Each way an owner keeps a unit off online rental, as the app writes it. */
const NOT_OFFERED: Array<[string, Record<string, unknown>]> = [
  ['not listed on the public website', { publicListingEnabled: false }],
  ['kept for internal use', { internalUse: true }],
  ['archived', { archived: true }],
];

const unitPath = (unitId: string) => `facilities/${FACILITY}/units/${unitId}`;
const holdPath = (unitId: string) => `facilities/${FACILITY}/mapEngine/activeHolds/items/${unitId}`;

/**
 * Loads the portal callables against [inMemory]. Portal sign-in is replaced
 * by one that accepts the seeded tenant: it is tested in functions-shared,
 * and its collection-group query is beyond this in-memory store.
 */
function loadPortal(inMemory: InMemoryFirestore) {
  installInMemoryFirestore(inMemory);
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const shared = require('@sfc/functions-shared') as typeof import('@sfc/functions-shared');
  Object.defineProperty(shared, 'authenticatePortalTenantForFacility', {
    configurable: true,
    writable: true,
    value: async (_email: string, _code: string, facilityId: string) => {
      const facilityRef = admin.firestore().collection('facilities').doc(facilityId);
      const tenantDoc = await facilityRef.collection('tenants').doc(TENANT).get();
      return { tenantDoc, tenantId: TENANT, tenantData: tenantDoc.data(), facilityId, facilityRef };
    },
  });
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const portal = require('../moveOutPortalHold') as typeof import('../moveOutPortalHold');
  const credentials = { email: EMAIL, accessCode: ACCESS_CODE, facilityId: FACILITY };
  return {
    list: async () =>
      (await portal.tenantPortalListAvailableUnits.run(credentials, context)) as {
        units: Array<{ id: string }>;
      },
    hold: (unitId: string) =>
      portal.createTenantPortalAdditionalUnitHold.run({ ...credentials, unitId }, context) as Promise<{
        success?: boolean;
        reservationId?: string;
      }>,
  };
}

function seedPortalTenant(inMemory: InMemoryFirestore) {
  inMemory.seed(`facilities/${FACILITY}`, { name: 'Portal Storage' });
  inMemory.seed(`facilities/${FACILITY}/tenants/${TENANT}`, {
    name: 'Tess Tenant',
    email: EMAIL,
    emailLower: EMAIL,
    phone: '5559876543',
    portalEnabled: true,
    portalAccessCode: ACCESS_CODE,
    portalAccountId: TENANT,
    isActive: true,
  });
}

function seedUnit(inMemory: InMemoryFirestore, unitId: string, fields: Record<string, unknown> = {}) {
  inMemory.seed(unitPath(unitId), {
    status: 'available',
    unitNumber: unitId.toUpperCase(),
    unitType: 'standard',
    monthlyRate: 80,
    ...fields,
  });
}

function assertNothingHeld(inMemory: InMemoryFirestore, unitId: string) {
  assert.equal(inMemory.listCollection('publicReservations').length, 0);
  assert.equal(inMemory.read(holdPath(unitId)), undefined);
}

test('the portal lists an available unit the owner offers online', async () => {
  const inMemory = new InMemoryFirestore();
  seedPortalTenant(inMemory);
  seedUnit(inMemory, 'a1');
  seedUnit(inMemory, 'a2', { publicListingEnabled: true, internalUse: false, archived: false });
  seedUnit(inMemory, 'o1', { status: 'occupied' });
  const { list } = loadPortal(inMemory);

  const { units } = await list();

  assert.deepEqual(units.map((u) => u.id).sort(), ['a1', 'a2']);
});

for (const [why, fields] of NOT_OFFERED) {
  test(`the portal does not list a unit ${why}`, async () => {
    const inMemory = new InMemoryFirestore();
    seedPortalTenant(inMemory);
    seedUnit(inMemory, 'listed');
    seedUnit(inMemory, 'kept', fields);
    const { list } = loadPortal(inMemory);

    const { units } = await list();

    assert.deepEqual(units.map((u) => u.id), ['listed']);
  });
}

test('a portal tenant can hold a unit the owner offers online', async () => {
  const inMemory = new InMemoryFirestore();
  seedPortalTenant(inMemory);
  seedUnit(inMemory, 'listed');
  const { hold } = loadPortal(inMemory);

  const result = await hold('listed');

  assert.equal(result.success, true);
  const reservation = inMemory.read(`publicReservations/${result.reservationId}`);
  assert.equal((reservation?.metadata as Record<string, unknown>)?.source, 'tenant_portal_additional_unit');
  assert.ok(inMemory.read(holdPath('listed')));
});

for (const [why, fields] of NOT_OFFERED) {
  test(`a portal tenant cannot hold a unit ${why} by sending its id, and nothing is written`, async () => {
    const inMemory = new InMemoryFirestore();
    seedPortalTenant(inMemory);
    seedUnit(inMemory, 'kept', fields);
    const { hold } = loadPortal(inMemory);

    await assert.rejects(
      () => hold('kept'),
      (err: unknown) => {
        const e = err as { code?: string; message?: string };
        assert.equal(e.code, 'failed-precondition');
        assert.equal(e.message, 'Unit is not currently available');
        return true;
      },
    );

    assertNothingHeld(inMemory, 'kept');
  });
}

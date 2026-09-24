/**
 * The online move-in applies the app's active-tenant cap.
 *
 * The app refused an operator's tenant past the cap (counting archived
 * tenants too), while the online move-in created tenants with no check.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'fs';
import * as path from 'path';
import { Timestamp } from 'firebase-admin/firestore';
import firebaseFunctionsTest from 'firebase-functions-test';
import { computePublicMoveInCharges } from '../moveInCharges';
import { InMemoryFirestore, installInMemoryFirestore } from './support/inMemoryFirestore';
import { MAX_ACTIVE_TENANTS_PER_FACILITY, countActiveTenants } from '../tenantCapacity';

const testEnv = firebaseFunctionsTest({ projectId: 'in-memory-test' });
const callableContext = { app: { appId: 'test-app-check' } };

const FACILITY = 'fac-cap';
const UNIT = 'unit-cap';
const RESERVATION = 'res-cap';
const TOKEN = 'cap-move-in-token-0123456789';
const CAPACITY_MESSAGE = 'This facility is not taking online move-ins right now. Please contact the facility.';

function seedTenants(inMemory: InMemoryFirestore, counts: { active: number; archived?: number; noFlag?: number }) {
  for (let i = 0; i < counts.active; i++) {
    inMemory.seed(`facilities/${FACILITY}/tenants/a${i}`, { name: `A${i}`, isActive: true });
  }
  for (let i = 0; i < (counts.archived ?? 0); i++) {
    inMemory.seed(`facilities/${FACILITY}/tenants/x${i}`, { name: `X${i}`, isActive: false });
  }
  // Partial docs without the field are not active tenants anywhere.
  for (let i = 0; i < (counts.noFlag ?? 0); i++) {
    inMemory.seed(`facilities/${FACILITY}/tenants/n${i}`, { autopay: { status: 'OFF' } });
  }
}

function tenantCount(inMemory: InMemoryFirestore): number {
  return inMemory.listCollection(`facilities/${FACILITY}/tenants`).length;
}

function assertCapacityRefusal(err: unknown): boolean {
  const e = err as { code?: string; message?: string };
  assert.equal(e.code, 'failed-precondition');
  assert.equal(e.message, CAPACITY_MESSAGE);
  return true;
}

/** Loads publicMoveIn against [inMemory], with Stripe replaced by a recorder. */
function loadPublicMoveIn(inMemory: InMemoryFirestore, stripe: { amountReceived?: number } = {}) {
  installInMemoryFirestore(inMemory);
  const stripeCalls: string[] = [];
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const shared = require('@sfc/functions-shared') as typeof import('@sfc/functions-shared');
  Object.defineProperty(shared, 'getStripeClient', {
    configurable: true,
    writable: true,
    value: () =>
      ({
        paymentIntents: {
          retrieve: async () => {
            stripeCalls.push('paymentIntents.retrieve');
            return { amount_received: stripe.amountReceived ?? 0, status: 'succeeded' };
          },
        },
        checkout: {
          sessions: {
            create: async () => {
              stripeCalls.push('checkout.sessions.create');
              return { id: 'cs_test', url: 'https://checkout.example/cs_test' };
            },
          },
        },
      }) as unknown as ReturnType<typeof shared.getStripeClient>,
  });
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const moveIn = require('../publicMoveIn') as typeof import('../publicMoveIn');
  return {
    stripeCalls,
    hold: (data: Record<string, unknown>) => testEnv.wrap(moveIn.createPublicReservationHold)(data, callableContext),
    checkout: (data: Record<string, unknown>) => testEnv.wrap(moveIn.createPublicMoveInCheckout)(data, callableContext),
    complete: (data: Record<string, unknown>) => testEnv.wrap(moveIn.completePublicMoveIn)(data, callableContext),
  };
}

function seedUnit(inMemory: InMemoryFirestore) {
  inMemory.seed(`facilities/${FACILITY}/units/${UNIT}`, {
    status: 'available',
    unitNumber: 'C1',
    unitType: 'standard',
    monthlyRate: 100,
  });
}

function seedReservation(inMemory: InMemoryFirestore) {
  inMemory.seed(`publicReservations/${RESERVATION}`, {
    facilityId: FACILITY,
    unitId: UNIT,
    unitNumber: 'C1',
    status: 'pending',
    moveInToken: TOKEN,
    moveInDate: Timestamp.fromDate(new Date(2026, 8, 25)),
    expiresAt: Timestamp.fromDate(new Date(Date.now() + 60 * 60 * 1000)),
    email: 'renter@example.com',
    name: 'Rita Renter',
    metadata: {},
  });
}

const holdRequest = {
  facilityId: FACILITY,
  unitId: UNIT,
  email: 'renter@example.com',
  name: 'Rita Renter',
};

const completeRequest = {
  reservationId: RESERVATION,
  token: TOKEN,
  name: 'Rita Renter',
  email: 'renter@example.com',
  phone: '5551234567',
  signaturePngBase64:
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
};

test('the cap matches the app', () => {
  const dart = fs.readFileSync(
    path.join(__dirname, '..', '..', '..', 'lib', 'services', 'facility_limits_service.dart'),
    'utf8',
  );
  const match = dart.match(/maxTenantsPerFacility\s*=\s*(\d+)/);
  assert.ok(match, 'maxTenantsPerFacility not found in facility_limits_service.dart');
  assert.equal(MAX_ACTIVE_TENANTS_PER_FACILITY, Number(match[1]));
});

test('only tenants with isActive exactly true are counted', async () => {
  const inMemory = new InMemoryFirestore();
  seedTenants(inMemory, { active: 3, archived: 4, noFlag: 2 });
  assert.equal(await countActiveTenants(inMemory.firestore(), FACILITY), 3);
});

test('a hold is refused at a facility at its active tenant cap, before the unit is held', async () => {
  const inMemory = new InMemoryFirestore();
  inMemory.seed(`facilities/${FACILITY}`, { name: 'Cap Storage' });
  seedUnit(inMemory);
  seedTenants(inMemory, { active: MAX_ACTIVE_TENANTS_PER_FACILITY });
  const { hold } = loadPublicMoveIn(inMemory);

  await assert.rejects(() => hold(holdRequest), assertCapacityRefusal);

  assert.equal(inMemory.listCollection('publicReservations').length, 0);
  assert.equal(inMemory.read(`facilities/${FACILITY}/mapEngine/activeHolds/items/${UNIT}`), undefined);
});

test('archived tenants do not count toward the cap for a hold', async () => {
  const inMemory = new InMemoryFirestore();
  inMemory.seed(`facilities/${FACILITY}`, { name: 'Cap Storage' });
  seedUnit(inMemory);
  // 300 tenants over the facility's life, 249 of them still active.
  seedTenants(inMemory, { active: MAX_ACTIVE_TENANTS_PER_FACILITY - 1, archived: 46, noFlag: 5 });
  const { hold } = loadPublicMoveIn(inMemory);

  const result = (await hold(holdRequest)) as { success?: boolean };

  assert.equal(result.success, true);
  assert.equal(inMemory.listCollection('publicReservations').length, 1);
});

test('a failed active-tenant count lets the hold through', async () => {
  const inMemory = new InMemoryFirestore();
  inMemory.seed(`facilities/${FACILITY}`, { name: 'Cap Storage' });
  seedUnit(inMemory);
  // At the cap, so only the fail-open path can let this renter through.
  seedTenants(inMemory, { active: MAX_ACTIVE_TENANTS_PER_FACILITY });
  inMemory.countError = Object.assign(new Error('deadline-exceeded'), { code: 4 });
  const { hold } = loadPublicMoveIn(inMemory);

  const result = (await hold(holdRequest)) as { success?: boolean };

  // A transient read error must not turn every online renter away; the cap
  // controls cost and abuse, and the next count decides the next renter.
  assert.equal(result.success, true);
  assert.equal(inMemory.listCollection('publicReservations').length, 1);
});

test('checkout is refused at the cap before Stripe is called', async () => {
  const inMemory = new InMemoryFirestore();
  inMemory.seed(`facilities/${FACILITY}`, {
    name: 'Cap Storage',
    stripeConnectAccountId: 'acct_cap',
    stripeConnectOnboardingComplete: true,
  });
  seedUnit(inMemory);
  seedReservation(inMemory);
  seedTenants(inMemory, { active: MAX_ACTIVE_TENANTS_PER_FACILITY, archived: 3 });
  const { checkout, stripeCalls } = loadPublicMoveIn(inMemory);

  await assert.rejects(
    () => checkout({ reservationId: RESERVATION, token: TOKEN, amount: 100 }),
    assertCapacityRefusal,
  );
  assert.deepEqual(stripeCalls, []);
});

test('a move-in with nothing to pay is refused at the cap, and no tenant is created', async () => {
  const inMemory = new InMemoryFirestore();
  // No Stripe Connect: no payment is taken online.
  inMemory.seed(`facilities/${FACILITY}`, { name: 'Cap Storage' });
  seedUnit(inMemory);
  seedReservation(inMemory);
  seedTenants(inMemory, { active: MAX_ACTIVE_TENANTS_PER_FACILITY });
  const { complete } = loadPublicMoveIn(inMemory);

  await assert.rejects(() => complete({ ...completeRequest, skipPayment: true }), assertCapacityRefusal);

  assert.equal(tenantCount(inMemory), MAX_ACTIVE_TENANTS_PER_FACILITY);
  assert.equal(inMemory.read(`publicReservations/${RESERVATION}`)?.status, 'pending');
});

test('a renter who has paid is never turned away for capacity', async () => {
  const inMemory = new InMemoryFirestore();
  const facilityData = {
    name: 'Cap Storage',
    stripeConnectAccountId: 'acct_cap',
    stripeConnectOnboardingComplete: true,
  };
  inMemory.seed(`facilities/${FACILITY}`, facilityData);
  seedUnit(inMemory);
  seedReservation(inMemory);
  // At the cap when the renter completes: capacity was checked at checkout,
  // and the payment has been taken.
  seedTenants(inMemory, { active: MAX_ACTIVE_TENANTS_PER_FACILITY });
  const reservation = inMemory.read(`publicReservations/${RESERVATION}`) as Record<string, any>;
  const quote = computePublicMoveInCharges({
    reservation,
    unitData: inMemory.read(`facilities/${FACILITY}/units/${UNIT}`) as Record<string, any>,
    facilityData,
    publicSettings: {},
    moveInDate: (reservation.moveInDate as Timestamp).toDate(),
  });
  assert.ok(quote.totalCents > 0);
  const { complete, stripeCalls } = loadPublicMoveIn(inMemory, { amountReceived: quote.totalCents });

  const result = (await complete({ ...completeRequest, paymentIntentId: 'pi_cap' })) as {
    success?: boolean;
    tenantId?: string;
  };

  assert.deepEqual(stripeCalls, ['paymentIntents.retrieve']);
  assert.equal(result.success, true);
  assert.equal(tenantCount(inMemory), MAX_ACTIVE_TENANTS_PER_FACILITY + 1);
});

test('a move-in with nothing to pay below the cap completes', async () => {
  const inMemory = new InMemoryFirestore();
  inMemory.seed(`facilities/${FACILITY}`, { name: 'Cap Storage' });
  seedUnit(inMemory);
  seedReservation(inMemory);
  seedTenants(inMemory, { active: MAX_ACTIVE_TENANTS_PER_FACILITY - 1, archived: 20 });
  const { complete } = loadPublicMoveIn(inMemory);

  const result = (await complete({ ...completeRequest, skipPayment: true })) as { success?: boolean };

  assert.equal(result.success, true);
  assert.equal(tenantCount(inMemory), MAX_ACTIVE_TENANTS_PER_FACILITY - 1 + 20 + 1);
});

test.after(() => {
  testEnv.cleanup();
});

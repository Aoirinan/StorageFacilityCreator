import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import { Timestamp } from 'firebase/firestore';

const __dirname = dirname(fileURLToPath(import.meta.url));
const rulesPath = join(__dirname, '..', '..', 'firestore.rules');
const rules = readFileSync(rulesPath, 'utf8');

const PROJECT_ID = 'sfc-rules-test';
const OWNER_UID = 'owner-user';
const STAFF_UID = 'staff-user';
const OUTSIDER_UID = 'outsider-user';
const FACILITY_ID = 'fac-test-1';
const TENANT_ID = 'tenant-test-1';

function firestoreEmulatorConfig() {
  const raw = process.env.FIRESTORE_EMULATOR_HOST || 'localhost:8080';
  const [host, portString] = raw.split(':');
  return { host, port: Number(portString) };
}

/** @type {import('@firebase/rules-unit-testing').RulesTestEnvironment | null} */
let testEnv = null;

test.before(async () => {
  const { host, port } = firestoreEmulatorConfig();
  testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: { rules, host, port },
  });
});

test.after(async () => {
  await testEnv?.cleanup();
});

test.beforeEach(async () => {
  await testEnv.clearFirestore();
});

async function seedFacility() {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await db.collection('facilities').doc(FACILITY_ID).set({
      ownerUid: OWNER_UID,
      roles: {
        [OWNER_UID]: 'owner',
        [STAFF_UID]: 'employee',
      },
    });
    await db.collection('facilities').doc(FACILITY_ID).collection('tenants').doc(TENANT_ID).set({
      facilityId: FACILITY_ID,
      name: 'Test Tenant',
      isActive: true,
    });
  });
}

test('rateLimits collection denies all client access', async () => {
  const authed = testEnv.authenticatedContext(OWNER_UID);
  await assertFails(authed.firestore().collection('rateLimits').doc('global').get());
  await assertFails(
    authed.firestore().collection('rateLimits').doc('global').set({ count: 1 }),
  );
});

test('user-scoped rateLimits denies client read and write', async () => {
  const authed = testEnv.authenticatedContext(OWNER_UID);
  const ref = authed.firestore().collection('users').doc(OWNER_UID).collection('rateLimits').doc('otp');
  await assertFails(ref.get());
  await assertFails(ref.set({ count: 1 }));
});

test('facility rateLimits denies client access', async () => {
  await seedFacility();
  const authed = testEnv.authenticatedContext(OWNER_UID);
  const ref = authed
    .firestore()
    .collection('facilities')
    .doc(FACILITY_ID)
    .collection('rateLimits')
    .doc('window-1');
  await assertFails(ref.get());
  await assertFails(ref.set({ count: 1 }));
});

test('facility staff can create valid manual tenant payment rows only', async () => {
  await seedFacility();
  const staff = testEnv.authenticatedContext(STAFF_UID);
  const payments = staff
    .firestore()
    .collection('facilities')
    .doc(FACILITY_ID)
    .collection('tenants')
    .doc(TENANT_ID)
    .collection('payments');

  const now = Timestamp.now();
  await assertSucceeds(
    payments.doc('manual-1').set({
      facilityId: FACILITY_ID,
      tenantId: TENANT_ID,
      type: 'manual',
      amountCents: 5000,
      currency: 'usd',
      chargeType: 'manual_cash',
      status: 'succeeded',
      description: 'Cash payment',
      createdAt: now,
      updatedAt: now,
      failureCode: null,
      failureMessage: null,
    }),
  );

  await assertFails(
    payments.doc('stripe-1').set({
      facilityId: FACILITY_ID,
      tenantId: TENANT_ID,
      type: 'stripe',
      amountCents: 5000,
      currency: 'usd',
      chargeType: 'manual_cash',
      status: 'succeeded',
      description: 'Should be blocked',
      createdAt: now,
      updatedAt: now,
      failureCode: null,
      failureMessage: null,
    }),
  );
});

test('outsider cannot create manual tenant payments', async () => {
  await seedFacility();
  const outsider = testEnv.authenticatedContext(OUTSIDER_UID);
  const now = Timestamp.now();
  await assertFails(
    outsider
      .firestore()
      .collection('facilities')
      .doc(FACILITY_ID)
      .collection('tenants')
      .doc(TENANT_ID)
      .collection('payments')
      .doc('manual-outsider')
      .set({
        facilityId: FACILITY_ID,
        tenantId: TENANT_ID,
        type: 'manual',
        amountCents: 1000,
        currency: 'usd',
        chargeType: 'manual_check',
        status: 'succeeded',
        description: 'Blocked',
        createdAt: now,
        updatedAt: now,
        failureCode: null,
        failureMessage: null,
      }),
  );
});

test('unmatched collections like stripeWebhookEvents deny client access', async () => {
  const authed = testEnv.authenticatedContext(OWNER_UID);
  await assertFails(
    authed.firestore().collection('stripeWebhookEvents').doc('evt_123').get(),
  );
});

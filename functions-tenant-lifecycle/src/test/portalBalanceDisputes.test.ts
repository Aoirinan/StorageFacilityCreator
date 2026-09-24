/**
 * The tenant portal's balance, and so its Pay now amount, leaves out a
 * payment the Stripe webhook has marked disputed.
 *
 * The portal counted every payment record not paid or completed as owed. The
 * dispute webhook marks the charged payment `disputed`, so its amount was
 * added straight back to the balance and to Pay now, and a tenant who paid it
 * paid twice once the facility won. Runs the deployed tenantPortalFetch.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import { FakeFirestore, installFakeFirestore } from '@sfc/functions-shared/testing/fakeFirestore';

const FACILITY = 'f1';
const TENANT = 't1';
const PAYMENTS = `facilities/${FACILITY}/payments`;
const context = { rawRequest: { ip: '203.0.113.7' } } as unknown as functions.https.CallableContext;

type PortalStats = { outstandingBalance: number; nextAmountDue: number | null };
type PortalResult = { stats: PortalStats; units: Array<{ outstandingBalance: number; isDelinquent: boolean }> };

function loadPortal(fake: FakeFirestore) {
  installFakeFirestore(fake);
  // Portal sign-in is tested in functions-shared; here it accepts the seeded tenant.
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const shared = require('@sfc/functions-shared') as typeof import('@sfc/functions-shared');
  Object.defineProperty(shared, 'authenticatePortalTenant', {
    configurable: true,
    writable: true,
    value: async () => {
      const facilityRef = admin.firestore().collection('facilities').doc(FACILITY);
      const tenantDoc = await facilityRef.collection('tenants').doc(TENANT).get();
      return { tenantDoc, tenantId: TENANT, tenantData: tenantDoc.data(), facilityId: FACILITY, facilityRef };
    },
  });
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const portal = require('../contractsPortal') as typeof import('../contractsPortal');
  return async () =>
    (await portal.tenantPortalFetch.run({ email: 'pat@example.test', accessCode: 'ABCD2345' }, context)) as PortalResult;
}

function setup(payments: Array<[string, Record<string, unknown>]>) {
  const fake = new FakeFirestore();
  fake.seed(`facilities/${FACILITY}`, { name: 'Test Storage' });
  fake.seed(`facilities/${FACILITY}/tenants/${TENANT}`, {
    name: 'Pat Tenant',
    email: 'pat@example.test',
    unitNumber: 'A1',
    monthlyRate: 100,
    portalEnabled: true,
    isActive: true,
  });
  const due = admin.firestore.Timestamp.fromDate(new Date('2026-10-01T00:00:00Z'));
  for (const [id, payment] of payments) {
    fake.seed(`${PAYMENTS}/${id}`, { tenantId: TENANT, facilityId: FACILITY, dueDate: due, ...payment });
  }
  return { fake, fetch: loadPortal(fake) };
}

test('a disputed payment is not part of the balance the portal asks the tenant to pay', async () => {
  const { fetch } = setup([
    ['stripe_pi_march', { amount: 100, status: 'disputed', disputeStatus: 'needs_response' }],
    ['october', { amount: 100, status: 'pending' }],
  ]);

  const result = await fetch();

  // It was $200: Pay now charged the disputed $100 again.
  assert.equal(result.stats.outstandingBalance, 100);
  assert.equal(result.units[0].outstandingBalance, 100);
  assert.equal(result.stats.nextAmountDue, 100);
});

test('a tenant whose only open record is a disputed payment is not shown owing or delinquent', async () => {
  const { fetch } = setup([['stripe_pi_march', { amount: 100, status: 'disputed', disputeStatus: 'lost' }]]);

  const result = await fetch();

  assert.equal(result.stats.outstandingBalance, 0);
  assert.equal(result.units[0].isDelinquent, false);
});

test('only records still owed count: no status, pending and failed', async () => {
  const { fetch } = setup([
    ['no_status', { amount: 10 }],
    ['pending', { amount: 20, status: 'pending' }],
    ['failed', { amount: 40, status: 'failed' }],
    ['paid', { amount: 1000, status: 'paid' }],
    ['completed', { amount: 1000, status: 'completed' }],
    ['refunded', { amount: 1000, status: 'refunded' }],
    ['part_refunded', { amount: 1000, status: 'partially_refunded' }],
    ['cancelled', { amount: 1000, status: 'cancelled' }],
    ['unknown', { amount: 1000, status: 'something_new' }],
  ]);

  const result = await fetch();

  assert.equal(result.stats.outstandingBalance, 70);
});

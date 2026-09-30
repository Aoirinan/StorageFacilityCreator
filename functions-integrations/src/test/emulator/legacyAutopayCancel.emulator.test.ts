import test from 'node:test';
import assert from 'node:assert/strict';
import type * as functions from 'firebase-functions/v1';
import type Stripe from 'stripe';
import { hasAutopaySubscription, type LegacySubscriptionStripe } from '@sfc/functions-shared';

import { setTenantAutopayArming } from '../../autopayArming';
import { disableFacilityTenantAutopay } from '../../stripeFacilityConnectOffboarding';
import { toggleAutopay } from '../../stripe/tenant_billing';
import { clearEmulator, emulatorDb, skipWithoutEmulator } from './firestoreEmulator';

/**
 * The facility delete refuses while a tenant's billing/default still holds a
 * legacy platform-account subscription id (hasAutopaySubscription), and tells
 * the owner to press Disable autopay on the tenant's page. That button
 * (setTenantAutopay, through setTenantAutopayArming) only switched the flag
 * off: the subscription went on charging, its id stayed, and the delete
 * stayed refused with no control that could clear it. These run the real
 * arming code against the emulator with a fake Stripe.
 */

const FACILITY = 'fac-1';
const TENANT = 't1';

type Call = { op: 'cancel' | 'retrieve'; id: string };

function fakeStripe(behaviour: {
  cancel?: (id: string) => unknown;
  status?: string;
}): { stripe: () => LegacySubscriptionStripe; calls: Call[] } {
  const calls: Call[] = [];
  return {
    calls,
    stripe: () => ({
      subscriptions: {
        cancel: async (id: string) => {
          calls.push({ op: 'cancel', id });
          if (behaviour.cancel) return behaviour.cancel(id);
          return { id, status: 'canceled' };
        },
        retrieve: async (id: string) => {
          calls.push({ op: 'retrieve', id });
          return { id, status: behaviour.status ?? 'active' };
        },
      },
    }),
  };
}

const tenantRef = () => emulatorDb().collection('facilities').doc(FACILITY).collection('tenants').doc(TENANT);
const billing = async () => (await tenantRef().collection('billing').doc('default').get()).data() ?? {};
const card = async () => (await tenantRef().collection('paymentMethods').doc('pm1').get()).data() ?? {};

async function seed(): Promise<void> {
  const db = emulatorDb();
  await db.collection('facilities').doc(FACILITY).set({ name: 'Acme', ownerUid: 'owner-1' });
  await tenantRef().set({ name: 'Ada Park', isActive: true, monthlyRate: 100 });
  await tenantRef().collection('billing').doc('default').set({ autopayEnabled: true, stripeSubscriptionId: 'sub_legacy' });
  await tenantRef()
    .collection('paymentMethods')
    .doc('pm1')
    .set({ isActive: true, isDefault: true, autopayEnabled: true, facilityId: FACILITY, tenantId: TENANT });
}

test.beforeEach(async () => {
  if (!skipWithoutEmulator) await clearEmulator();
});

test('Disable autopay cancels the legacy subscription and clears it, so the facility delete goes ahead', { skip: skipWithoutEmulator }, async () => {
  await seed();
  assert.equal(hasAutopaySubscription(await billing()), true);
  const fake = fakeStripe({});
  await setTenantAutopayArming(FACILITY, TENANT, false, fake.stripe);

  assert.deepEqual(fake.calls, [{ op: 'cancel', id: 'sub_legacy' }]);
  const after = await billing();
  assert.equal(after.autopayEnabled, false);
  assert.equal(after.stripeSubscriptionId, undefined);
  assert.equal((await card()).autopayEnabled, false);
  // The predicate the facility delete refuses on.
  assert.equal(hasAutopaySubscription(after), false);

  // Again: nothing left to cancel, nothing asked of Stripe.
  const again = fakeStripe({});
  await setTenantAutopayArming(FACILITY, TENANT, false, again.stripe);
  assert.deepEqual(again.calls, []);
});

test('a subscription Stripe says is already gone or ended is cleared too', { skip: skipWithoutEmulator }, async () => {
  await seed();
  const gone = fakeStripe({
    cancel: () => {
      throw Object.assign(new Error('No such subscription: sub_legacy'), { code: 'resource_missing' });
    },
  });
  await setTenantAutopayArming(FACILITY, TENANT, false, gone.stripe);
  assert.equal((await billing()).stripeSubscriptionId, undefined);

  await seed();
  const ended = fakeStripe({
    cancel: () => {
      throw new Error('temporary');
    },
    status: 'canceled',
  });
  await setTenantAutopayArming(FACILITY, TENANT, false, ended.stripe);
  assert.deepEqual(ended.calls.map((c) => c.op), ['cancel', 'retrieve']);
  assert.equal((await billing()).stripeSubscriptionId, undefined);
});

test('a cancel that fails keeps the id and says so; the card is disarmed either way', { skip: skipWithoutEmulator }, async () => {
  await seed();
  const failing = fakeStripe({
    cancel: () => {
      throw new Error('Stripe is down');
    },
  });
  await assert.rejects(setTenantAutopayArming(FACILITY, TENANT, false, failing.stripe), (err: unknown) => {
    const e = err as functions.https.HttpsError;
    assert.equal(e.code, 'unavailable');
    assert.match(e.message, /older autopay subscription in Stripe couldn't be cancelled, so it may still charge them/);
    return true;
  });
  const after = await billing();
  assert.equal(after.stripeSubscriptionId, 'sub_legacy');
  assert.equal(after.autopayEnabled, false);
  assert.equal((await card()).autopayEnabled, false);
  // Still refused: it may still be billing.
  assert.equal(hasAutopaySubscription(after), true);

  // Turning autopay on while it may still bill would charge them twice.
  await assert.rejects(setTenantAutopayArming(FACILITY, TENANT, true, failing.stripe), /Autopay was not turned on/);
  assert.equal((await card()).autopayEnabled, false);
});

test('detaching a facility from Stripe cancels its tenants\' legacy subscriptions before clearing their ids', { skip: skipWithoutEmulator }, async () => {
  // The legacy subscription is on the platform account, so the facility's
  // disconnect doesn't stop it; the id was nulled anyway, hiding it.
  await seed();
  const oldBilling = emulatorDb()
    .collection('facilities')
    .doc(FACILITY)
    .collection('oldTenants')
    .doc('o1')
    .collection('billing')
    .doc('default');
  await emulatorDb().collection('facilities').doc(FACILITY).collection('oldTenants').doc('o1').set({ name: 'Old' });
  // Legacy only, autopay flag off: it was skipped altogether.
  await oldBilling.set({ autopayEnabled: false, stripeSubscriptionId: 'sub_old' });

  const failing = fakeStripe({
    cancel: (id) => {
      if (id === 'sub_old') throw new Error('Stripe is down');
      return { id, status: 'canceled' };
    },
  });
  assert.equal(await disableFacilityTenantAutopay(FACILITY, failing.stripe), 2);
  assert.deepEqual(failing.calls.filter((c) => c.op === 'cancel').map((c) => c.id).sort(), ['sub_legacy', 'sub_old']);
  assert.equal((await billing()).stripeSubscriptionId, null);
  assert.equal((await billing()).autopayEnabled, false);
  assert.equal((await card()).autopayEnabled, false);
  // Not cancelled: kept, so the facility delete still refuses on it.
  assert.equal((await oldBilling.get()).get('stripeSubscriptionId'), 'sub_old');

  const working = fakeStripe({});
  await disableFacilityTenantAutopay(FACILITY, working.stripe);
  assert.deepEqual(working.calls, [{ op: 'cancel', id: 'sub_old' }]);
  assert.equal((await oldBilling.get()).get('stripeSubscriptionId'), null);
});

test("the billing panel's switch keeps the id when the cancel fails, and clears it when it works", { skip: skipWithoutEmulator }, async () => {
  const context = { auth: { uid: 'owner-1', token: {} } } as unknown as functions.https.CallableContext;
  await seed();
  const failing = fakeStripe({
    cancel: () => {
      throw new Error('Stripe is down');
    },
  });
  await assert.rejects(
    toggleAutopay({ facilityId: FACILITY, tenantId: TENANT, enable: false }, context, failing.stripe() as unknown as Stripe),
    /may still charge them/,
  );
  assert.equal((await billing()).stripeSubscriptionId, 'sub_legacy');
  assert.equal((await billing()).autopayEnabled, false);

  const working = fakeStripe({});
  await toggleAutopay({ facilityId: FACILITY, tenantId: TENANT, enable: false }, context, working.stripe() as unknown as Stripe);
  assert.equal((await billing()).stripeSubscriptionId, undefined);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import type Stripe from 'stripe';

import { handleSubscriptionDeleted, handleSubscriptionUpdate } from '../../stripeWebhookSubscriptionHandlers';
import { clearEmulator, emulatorDb, skipWithoutEmulator } from './firestoreEmulator';

/**
 * A facility delete (owner or super admin) cancels the facility's Stripe
 * subscriptions and then deletes the facility, so Stripe's events for those
 * subscriptions arrive after it is gone. The handlers threw (NOT_FOUND, or
 * "Facility not found"), and Stripe retried each event for days; the tenant
 * autopay update recreated a billing doc under a deleted tenant. These run
 * the real handlers against the emulator.
 */

function subscription(metadata: Record<string, string>): Stripe.Subscription {
  return {
    id: 'sub_1',
    metadata,
    status: 'canceled',
    cancel_at_period_end: false,
  } as unknown as Stripe.Subscription;
}

async function exists(path: string): Promise<boolean> {
  return (await emulatorDb().doc(path).get()).exists;
}

test.beforeEach(async () => {
  if (!skipWithoutEmulator) await clearEmulator();
});

test('deleted: a website add-on for a deleted facility is acknowledged and writes nothing', { skip: skipWithoutEmulator }, async () => {
  emulatorDb();
  await handleSubscriptionDeleted(subscription({ facilityId: 'gone', subscriptionType: 'website_addon' }));
  assert.equal(await exists('facilities/gone'), false);
  assert.equal(await exists('facilities/gone/settings/public'), false);
});

test('deleted: a platform plan for a deleted facility is acknowledged and writes nothing', { skip: skipWithoutEmulator }, async () => {
  emulatorDb();
  await handleSubscriptionDeleted(subscription({ facilityId: 'gone' }));
  assert.equal(await exists('facilities/gone'), false);
});

test('deleted: tenant autopay whose tenant is gone, and an account that is gone, are acknowledged', { skip: skipWithoutEmulator }, async () => {
  emulatorDb();
  await handleSubscriptionDeleted(subscription({ facilityId: 'gone', tenantId: 't1' }));
  assert.equal(await exists('facilities/gone/tenants/t1/billing/default'), false);
  await handleSubscriptionDeleted(subscription({ accountId: 'acct-gone' }));
  assert.equal(await exists('facilityCreatorAccounts/acct-gone'), false);
});

test('deleted: a facility that still exists is marked cancelled, as before', { skip: skipWithoutEmulator }, async () => {
  const db = emulatorDb();
  await db.doc('facilities/f1').set({ name: 'Acme', stripeWebsiteSubscriptionId: 'sub_1', stripePlatformSubscriptionId: 'sub_2' });
  await handleSubscriptionDeleted(subscription({ facilityId: 'f1', subscriptionType: 'website_addon' }));
  let facility = (await db.doc('facilities/f1').get()).data()!;
  assert.equal(facility.websiteSubscriptionStatus, 'cancelled');
  assert.equal(facility.stripeWebsiteSubscriptionId, undefined);
  assert.equal((await db.doc('facilities/f1/settings/public').get()).get('enabled'), false);

  await handleSubscriptionDeleted(subscription({ facilityId: 'f1' }));
  facility = (await db.doc('facilities/f1').get()).data()!;
  assert.equal(facility.platformSubscriptionStatus, 'cancelled');
  assert.equal(facility.stripePlatformSubscriptionId, undefined);

  await db.doc('facilities/f1/tenants/t1/billing/default').set({ autopayEnabled: true, stripeSubscriptionId: 'sub_1' });
  await handleSubscriptionDeleted(subscription({ facilityId: 'f1', tenantId: 't1' }));
  assert.equal((await db.doc('facilities/f1/tenants/t1/billing/default').get()).get('autopayEnabled'), false);
});

test('updated: a website add-on for a deleted facility is acknowledged and writes nothing', { skip: skipWithoutEmulator }, async () => {
  emulatorDb();
  await handleSubscriptionUpdate(subscription({ facilityId: 'gone', subscriptionType: 'website_addon' }));
  assert.equal(await exists('facilities/gone'), false);
  assert.equal(await exists('facilities/gone/settings/public'), false);
});

test('updated: tenant autopay under a deleted tenant is not recreated; a live tenant still gets it', { skip: skipWithoutEmulator }, async () => {
  const db = emulatorDb();
  await handleSubscriptionUpdate(subscription({ facilityId: 'f1', tenantId: 'gone' }));
  assert.equal(await exists('facilities/f1/tenants/gone/billing/default'), false);

  await db.doc('facilities/f1/tenants/t1').set({ name: 'Ada Park' });
  await handleSubscriptionUpdate({
    ...subscription({ facilityId: 'f1', tenantId: 't1' }),
    status: 'active',
  } as Stripe.Subscription);
  const billing = (await db.doc('facilities/f1/tenants/t1/billing/default').get()).data()!;
  assert.equal(billing.autopayEnabled, true);
  assert.equal(billing.stripeSubscriptionId, 'sub_1');
});

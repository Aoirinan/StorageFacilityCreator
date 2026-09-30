import test from 'node:test';
import assert from 'node:assert/strict';
import * as functions from 'firebase-functions/v1';
import type Stripe from 'stripe';

import { executeCreateSubscriptionCheckout } from '../../stripePlatformAccountSubscriptionCheckoutLogic';
import { executeCreateFacilitySubscriptionCheckout } from '../../stripePlatformFacilitySubscriptionCheckoutLogic';
import { startTrial } from '../../stripePlatformStartTrial';
import { createWebsiteSubscriptionCheckout } from '../../stripePlatformWebsiteSubscription';
import { SUSPENDED_ACCOUNT_REASON } from '../../stripePlatformSuspendedAccount';
import { clearEmulator, emulatorDb, skipWithoutEmulator } from './firestoreEmulator';

/**
 * A suspended owner is sent to /subscription, where the app offered Stripe
 * checkout, and the checkout callables took the money ($75) while the account
 * stayed locked: paying does not lift a suspension. These run the real
 * callables against the emulator. Each refusal comes before any Stripe call,
 * so no Stripe key is needed or used.
 */

const OWNER = 'owner-1';
const context = {
  auth: { uid: OWNER, token: { email: 'owner@example.com' } },
  app: { appId: 'test-app' },
} as unknown as functions.https.CallableContext;

async function seed(suspended: boolean): Promise<void> {
  const db = emulatorDb();
  await db.doc('facilityCreatorAccounts/acct-1').set({
    ownerUid: OWNER,
    ownerEmail: 'owner@example.com',
    // What suspending writes (SuperAdminDataService.setAccountSuspended).
    subscriptionStatus: 'cancelled',
    suspended,
    facilityIds: ['fac-1'],
  });
  await db.doc('facilities/fac-1').set({
    ownerUid: OWNER,
    name: 'Maple Storage',
    facilityCreatorAccountId: 'acct-1',
  });
}

/**
 * The checkout flows build their Stripe client before reading the account
 * (resolvePlatformCheckoutDeps), so the account and facility checkouts get
 * one that throws on any use: each refusal must come before a Stripe call.
 */
const stripeMustNotBeUsed = new Proxy(
  {},
  {
    get(_target, prop) {
      throw new Error(`Stripe was used before the refusal (${String(prop)})`);
    },
  },
) as unknown as Stripe;

function checkoutDeps() {
  return { db: emulatorDb(), stripe: stripeMustNotBeUsed };
}

function isSuspensionRefusal(error: unknown): boolean {
  assert.ok(error instanceof functions.https.HttpsError, String(error));
  assert.equal(error.code, 'failed-precondition');
  assert.deepEqual(error.details, { reason: SUSPENDED_ACCOUNT_REASON });
  assert.match(error.message, /suspended/);
  return true;
}

test.beforeEach(async () => {
  if (!skipWithoutEmulator) await clearEmulator();
});

test('account checkout refuses a suspended account', { skip: skipWithoutEmulator }, async () => {
  await seed(true);
  await assert.rejects(
    executeCreateSubscriptionCheckout(
      { accountId: 'acct-1', customerEmail: 'owner@example.com' },
      context,
      checkoutDeps(),
    ),
    isSuspensionRefusal,
  );
  // Nothing was started for it at Stripe.
  const account = (await emulatorDb().doc('facilityCreatorAccounts/acct-1').get()).data()!;
  assert.equal(account.stripeCustomerId, undefined);
});

test('facility checkout refuses a suspended account', { skip: skipWithoutEmulator }, async () => {
  await seed(true);
  await assert.rejects(
    executeCreateFacilitySubscriptionCheckout(
      { accountId: 'acct-1', facilityId: 'fac-1', customerEmail: 'owner@example.com' },
      context,
      checkoutDeps(),
    ),
    isSuspensionRefusal,
  );
});

test('a trial is refused too: suspending clears the trial end, so it looked unused', { skip: skipWithoutEmulator }, async () => {
  await seed(true);
  await assert.rejects(Promise.resolve(startTrial.run({ accountId: 'acct-1' }, context)), isSuspensionRefusal);
  const account = (await emulatorDb().doc('facilityCreatorAccounts/acct-1').get()).data()!;
  assert.equal(account.subscriptionStatus, 'cancelled');
  assert.equal(account.subscriptionTrialEnd, undefined);
});

test('the website add-on says suspended, not "buy the $75 plan"', { skip: skipWithoutEmulator }, async () => {
  await seed(true);
  await assert.rejects(
    Promise.resolve(
      createWebsiteSubscriptionCheckout.run(
        { accountId: 'acct-1', facilityId: 'fac-1', customerEmail: 'owner@example.com' },
        context,
      ),
    ),
    isSuspensionRefusal,
  );
});

test('someone else is still refused as before, suspended or not', { skip: skipWithoutEmulator }, async () => {
  await seed(true);
  const stranger = {
    auth: { uid: 'stranger', token: {} },
    app: { appId: 'test-app' },
  } as unknown as functions.https.CallableContext;
  await assert.rejects(
    executeCreateSubscriptionCheckout({ accountId: 'acct-1', customerEmail: 'x@example.com' }, stranger, checkoutDeps()),
    (error: unknown) => error instanceof functions.https.HttpsError && error.code === 'permission-denied',
  );
});

test('a trial for an account that is not suspended is granted as before', { skip: skipWithoutEmulator }, async () => {
  await seed(false);
  await startTrial.run({ accountId: 'acct-1' }, context);
  const account = (await emulatorDb().doc('facilityCreatorAccounts/acct-1').get()).data()!;
  assert.equal(account.subscriptionStatus, 'trialing');
});

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  buildFacilityDisconnectUpdate,
  buildTenantPiiRedaction,
  deauthorizeConnectedAccount,
  isNotConnectedStripeError,
  isOffboardingDue,
  isOrphanedConnectedAccount,
  OFFBOARDING_GRACE_DAYS,
  offboardingDueAt,
  REDACTED_TENANT_NAME,
  selectFacilitiesForOffboarding,
  TENANT_PII_FIELDS_TO_CLEAR,
  TENANT_PII_LIST_FIELDS_TO_EMPTY,
} from '../stripe/connectOffboarding';

const DAY_MS = 24 * 60 * 60 * 1000;

test('isNotConnectedStripeError recognises Stripe wording for an unattached account', () => {
  assert.equal(
    isNotConnectedStripeError({ message: 'This application is not connected to stripe account acct_1' }),
    true,
  );
  assert.equal(isNotConnectedStripeError({ message: 'Invalid API Key provided' }), false);
  assert.equal(isNotConnectedStripeError(null), false);
  assert.equal(isNotConnectedStripeError('string error'), false);
});

test('deauthorizeConnectedAccount calls Stripe with the platform client id', async () => {
  const calls: unknown[] = [];
  const stripe = {
    oauth: {
      deauthorize: async (params: unknown) => {
        calls.push(params);
        return { stripe_user_id: 'acct_1' };
      },
    },
  } as never;
  const result = await deauthorizeConnectedAccount(stripe, 'ca_platform', 'acct_1');
  assert.equal(result, 'deauthorized');
  assert.deepEqual(calls, [{ client_id: 'ca_platform', stripe_user_id: 'acct_1' }]);
});

test('deauthorizeConnectedAccount treats an already-disconnected account as success', async () => {
  const stripe = {
    oauth: {
      deauthorize: async () => {
        throw Object.assign(new Error('This application is not connected to stripe account acct_1'), {
          type: 'invalid_request_error',
        });
      },
    },
  } as never;
  assert.equal(await deauthorizeConnectedAccount(stripe, 'ca_platform', 'acct_1'), 'already_disconnected');
});

test('deauthorizeConnectedAccount surfaces other Stripe errors and refuses without a client id', async () => {
  const stripe = {
    oauth: {
      deauthorize: async () => {
        throw new Error('Rate limited');
      },
    },
  } as never;
  await assert.rejects(() => deauthorizeConnectedAccount(stripe, 'ca_platform', 'acct_1'), /Rate limited/);
  await assert.rejects(() => deauthorizeConnectedAccount(stripe, '', 'acct_1'), /STRIPE_CONNECT_CLIENT_ID/);
  await assert.rejects(() => deauthorizeConnectedAccount(stripe, 'ca_platform', ''), /accountId/);
});

test('buildFacilityDisconnectUpdate clears the account and records why', () => {
  const now = new Date('2026-09-14T00:00:00Z');
  const update = buildFacilityDisconnectUpdate({ accountId: 'acct_1', reason: 'facility_deleted', now });
  assert.equal(update.stripeConnectAccountId, null);
  assert.equal(update.stripeConnectPreviousAccountId, 'acct_1');
  assert.equal(update.stripeConnectDisconnectReason, 'facility_deleted');
  assert.equal(update.stripeConnectOnboardingComplete, false);
  assert.equal(update.stripeConnectDisconnectedAt, now);
  assert.deepEqual(update.stripeStatus, {
    state: 'DISCONNECTED',
    chargesEnabled: false,
    payoutsEnabled: false,
    detailsSubmitted: false,
    currentlyDue: [],
    pastDue: [],
    updatedAt: now,
  });
});

test('buildTenantPiiRedaction blanks every identifying field and keeps the document usable', () => {
  const now = new Date('2026-09-14T00:00:00Z');
  const update = buildTenantPiiRedaction({ reason: 'subscription_cancelled', now });
  assert.equal(update.name, REDACTED_TENANT_NAME);
  assert.equal(update.portalEnabled, false);
  assert.equal(update.piiRedactedAt, now);
  assert.equal(update.piiRedactedReason, 'subscription_cancelled');
  for (const field of TENANT_PII_FIELDS_TO_CLEAR) {
    assert.equal(update[field], null, `${field} should be cleared`);
  }
  for (const field of TENANT_PII_LIST_FIELDS_TO_EMPTY) {
    assert.deepEqual(update[field], [], `${field} should be emptied`);
  }
  // Financial and structural fields are deliberately not part of the redaction.
  for (const kept of ['unitNumber', 'monthlyRate', 'paidThrough', 'isActive', 'createdAt', 'facilityId']) {
    assert.equal(kept in update, false, `${kept} must not be touched`);
  }
});

test('offboarding grace period is thirty days from cancellation', () => {
  const cancelled = new Date('2026-08-01T12:00:00Z');
  assert.equal(OFFBOARDING_GRACE_DAYS, 30);
  assert.equal(offboardingDueAt(cancelled).getTime(), cancelled.getTime() + 30 * DAY_MS);
  assert.equal(isOffboardingDue(cancelled, new Date(cancelled.getTime() + 29 * DAY_MS)), false);
  assert.equal(isOffboardingDue(cancelled, new Date(cancelled.getTime() + 30 * DAY_MS)), true);
});

test('selectFacilitiesForOffboarding sorts candidates into due, waiting and clock-start', () => {
  const now = new Date('2026-09-14T00:00:00Z');
  const selection = selectFacilitiesForOffboarding(
    [
      { id: 'due', platformSubscriptionStatus: 'cancelled', platformSubscriptionCancelledAt: new Date(now.getTime() - 31 * DAY_MS) },
      { id: 'waiting', platformSubscriptionStatus: 'cancelled', platformSubscriptionCancelledAt: new Date(now.getTime() - 3 * DAY_MS) },
      { id: 'legacy', platformSubscriptionStatus: 'cancelled' },
      { id: 'resubscribed', platformSubscriptionStatus: 'active', platformSubscriptionCancelledAt: new Date(now.getTime() - 90 * DAY_MS) },
      { id: 'done', platformSubscriptionStatus: 'cancelled', platformSubscriptionCancelledAt: new Date(now.getTime() - 90 * DAY_MS), offboardedAt: new Date(now.getTime() - 60 * DAY_MS) },
    ],
    now,
  );
  assert.deepEqual(selection, { due: ['due'], needsClockStart: ['legacy'], waiting: ['waiting'] });
});

test('isOrphanedConnectedAccount only flags platform-created accounts whose facility is gone', () => {
  assert.equal(isOrphanedConnectedAccount({ id: 'acct_1', metadata: { facilityId: 'f1' } }, false), true);
  assert.equal(isOrphanedConnectedAccount({ id: 'acct_1', metadata: { facilityId: 'f1' } }, true), false);
  assert.equal(isOrphanedConnectedAccount({ id: 'acct_2', metadata: {} }, false), false);
  assert.equal(isOrphanedConnectedAccount({ id: 'acct_3', metadata: null }, false), false);
});

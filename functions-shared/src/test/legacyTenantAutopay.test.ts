import test from 'node:test';
import assert from 'node:assert/strict';

import {
  cancelLegacyAutopaySubscription,
  legacySubscriptionId,
  type LegacySubscriptionStripe,
} from '../stripe/legacyTenantAutopay';

const where = { facilityId: 'fac-1', tenantId: 't1' };

function fakeStripe(behaviour: { cancel?: () => unknown; status?: string; lookup?: () => unknown } = {}) {
  const calls: string[] = [];
  let made = 0;
  const client: LegacySubscriptionStripe = {
    subscriptions: {
      cancel: async (id: string) => {
        calls.push(`cancel ${id}`);
        return behaviour.cancel ? behaviour.cancel() : { id, status: 'canceled' };
      },
      retrieve: async (id: string) => {
        calls.push(`retrieve ${id}`);
        if (behaviour.lookup) behaviour.lookup();
        return { status: behaviour.status ?? 'active' };
      },
    },
  };
  return {
    calls,
    made: () => made,
    stripe: () => {
      made++;
      return client;
    },
  };
}

test('the id is read trimmed; anything else is none', () => {
  assert.equal(legacySubscriptionId({ stripeSubscriptionId: ' sub_1 ' }), 'sub_1');
  assert.equal(legacySubscriptionId({ stripeSubscriptionId: null }), '');
  assert.equal(legacySubscriptionId({ stripeSubscriptionId: 7 }), '');
  assert.equal(legacySubscriptionId(undefined), '');
});

test('no id: nothing is asked of Stripe, and no client is made', async () => {
  const fake = fakeStripe();
  assert.equal(await cancelLegacyAutopaySubscription(fake.stripe, where, { autopayEnabled: true }), 'none');
  assert.equal(fake.made(), 0);
  assert.deepEqual(fake.calls, []);
});

test('cancelled now, or already gone or ended in Stripe, is cancelled', async () => {
  const now = fakeStripe();
  assert.equal(await cancelLegacyAutopaySubscription(now.stripe, where, { stripeSubscriptionId: 'sub_1' }), 'cancelled');
  assert.deepEqual(now.calls, ['cancel sub_1']);

  const gone = fakeStripe({
    cancel: () => {
      throw Object.assign(new Error('No such subscription: sub_1'), { code: 'resource_missing' });
    },
  });
  assert.equal(await cancelLegacyAutopaySubscription(gone.stripe, where, { stripeSubscriptionId: 'sub_1' }), 'cancelled');

  const ended = fakeStripe({
    cancel: () => {
      throw new Error('temporary');
    },
    status: 'canceled',
  });
  assert.equal(await cancelLegacyAutopaySubscription(ended.stripe, where, { stripeSubscriptionId: 'sub_1' }), 'cancelled');
  assert.deepEqual(ended.calls, ['cancel sub_1', 'retrieve sub_1']);
});

test('a cancel that fails with the subscription still live, or unknown, is failed', async () => {
  const live = fakeStripe({
    cancel: () => {
      throw new Error('Stripe is down');
    },
  });
  assert.equal(await cancelLegacyAutopaySubscription(live.stripe, where, { stripeSubscriptionId: 'sub_1' }), 'failed');

  const unknown = fakeStripe({
    cancel: () => {
      throw new Error('Stripe is down');
    },
    lookup: () => {
      throw new Error('still down');
    },
  });
  assert.equal(await cancelLegacyAutopaySubscription(unknown.stripe, where, { stripeSubscriptionId: 'sub_1' }), 'failed');
});

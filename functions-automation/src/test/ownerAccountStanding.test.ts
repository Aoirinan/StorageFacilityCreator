import test from 'node:test';
import assert from 'node:assert/strict';
import type { AccountDocLike, OwnerAccountStanding, OwnerStandingSyncDeps } from '@sfc/functions-shared';
import { handleAccountWriteForStanding, syncAllOwnerAccountStanding } from '../ownerAccountStanding';

function doc(id: string, data: Record<string, unknown>): AccountDocLike {
  return { id, data: () => data };
}

/** Accounts and facilities by ownerUid, and every facility write made. */
function fakeDeps(
  accounts: Record<string, AccountDocLike[]>,
  facilities: Record<string, AccountDocLike[]>,
  failFor: string[] = [],
) {
  const writes: Array<[string, OwnerAccountStanding | null]> = [];
  const deps: OwnerStandingSyncDeps = {
    listOwnerAccounts: async (uid) => {
      if (failFor.includes(uid)) throw new Error('unavailable');
      return accounts[uid] ?? [];
    },
    listOwnerFacilities: async (uid) => facilities[uid] ?? [],
    writeFacilityStanding: async (id, standing) => {
      writes.push([id, standing]);
    },
  };
  return { deps, writes };
}

const suspendedAccount = {
  ownerUid: 'owner-1',
  subscriptionStatus: 'cancelled',
  suspended: true,
  createdAt: { toMillis: () => 1 },
};

test('a suspension reaches every facility the owner owns', async () => {
  const { deps, writes } = fakeDeps(
    { 'owner-1': [doc('acct_1', suspendedAccount)] },
    { 'owner-1': [doc('fac_a', {}), doc('fac_b', {})] },
  );
  const result = await handleAccountWriteForStanding(
    { ...suspendedAccount, subscriptionStatus: 'active', suspended: false },
    suspendedAccount,
    deps,
  );
  assert.deepEqual(result, { owners: 1, updated: 2 });
  assert.deepEqual(
    writes.map(([id, s]) => [id, s?.suspended, s?.subscriptionStatus]),
    [
      ['fac_a', true, 'cancelled'],
      ['fac_b', true, 'cancelled'],
    ],
  );
});

test('a write that cannot change the standing reads and writes nothing', async () => {
  let reads = 0;
  const { deps, writes } = fakeDeps({}, {});
  deps.listOwnerAccounts = async () => {
    reads += 1;
    return [];
  };
  const result = await handleAccountWriteForStanding(
    suspendedAccount,
    { ...suspendedAccount, onboardingEmails: { underReviewSentAt: 'x' } },
    deps,
  );
  assert.deepEqual(result, { owners: 0, updated: 0 });
  assert.equal(reads, 0);
  assert.deepEqual(writes, []);
});

test('a deleted account removes the mirror when the owner has none left', async () => {
  const { deps, writes } = fakeDeps(
    {},
    { 'owner-1': [doc('fac_a', { ownerAccountStanding: { accountId: 'acct_1' } })] },
  );
  await handleAccountWriteForStanding(suspendedAccount, undefined, deps);
  assert.deepEqual(writes, [['fac_a', null]]);
});

test('a write to a duplicate account never displaces the preferred one', async () => {
  const original = doc('acct_original', {
    ownerUid: 'owner-1',
    subscriptionStatus: 'active',
    createdAt: { toMillis: () => 1 },
  });
  const duplicate = {
    ownerUid: 'owner-1',
    subscriptionStatus: 'pendingApproval',
    createdAt: { toMillis: () => 2 },
  };
  const { deps, writes } = fakeDeps(
    { 'owner-1': [doc('acct_dup', duplicate), original] },
    { 'owner-1': [doc('fac_a', {})] },
  );
  await handleAccountWriteForStanding(undefined, duplicate, deps);
  assert.deepEqual(
    writes.map(([id, s]) => [id, s?.accountId, s?.subscriptionStatus]),
    [['fac_a', 'acct_original', 'active']],
  );
});

test('the nightly sweep syncs each owner once and carries on past a failure', async () => {
  const { deps, writes } = fakeDeps(
    {
      'owner-1': [doc('acct_1', { ownerUid: 'owner-1', subscriptionStatus: 'active' })],
      'owner-3': [doc('acct_3', { ownerUid: 'owner-3', subscriptionStatus: 'trialing' })],
    },
    { 'owner-1': [doc('fac_1', {})], 'owner-3': [doc('fac_3', {})] },
    ['owner-2'],
  );
  const summary = await syncAllOwnerAccountStanding(
    async () => ['owner-1', 'owner-2', 'owner-1', 'owner-3'],
    deps,
  );
  assert.deepEqual(summary, { owners: 3, updated: 2, failed: 1 });
  assert.deepEqual(writes.map(([id]) => id), ['fac_1', 'fac_3']);
});

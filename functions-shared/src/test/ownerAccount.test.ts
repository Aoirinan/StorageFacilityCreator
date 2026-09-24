import test from 'node:test';
import assert from 'node:assert/strict';
import {
  OWNER_ACCOUNT_READ_LIMIT,
  OWNER_ACCOUNT_STANDING_FIELD,
  accountWriteAffectsStanding,
  buildOwnerAccountStanding,
  findOwnerAccountDoc,
  preferredOwnerAccountDoc,
  sameOwnerAccountStanding,
  syncOwnerAccountStanding,
  type AccountDocLike,
  type OwnerAccountStanding,
} from '../platform/ownerAccount';

/** A Firestore Timestamp stand-in: only toMillis is read. */
function ts(iso: string) {
  const ms = Date.parse(iso);
  return { toMillis: () => ms, iso };
}

function doc(id: string, data: Record<string, unknown>): AccountDocLike {
  return { id, data: () => data };
}

const original = doc('acct_original', {
  ownerUid: 'owner-1',
  subscriptionStatus: 'active',
  createdAt: ts('2026-03-01T00:00:00Z'),
});
// What a failed read in the app's getOrCreateAccountForCurrentUser used to create.
const pendingDuplicate = doc('acct_duplicate', {
  ownerUid: 'owner-1',
  subscriptionStatus: 'pendingApproval',
  createdAt: ts('2026-09-20T00:00:00Z'),
});

test('an approved account wins over a newer pendingApproval duplicate, whatever the read order', () => {
  // limit(1) took whichever doc Firestore returned first.
  assert.equal(preferredOwnerAccountDoc([pendingDuplicate, original])?.id, 'acct_original');
  assert.equal(preferredOwnerAccountDoc([original, pendingDuplicate])?.id, 'acct_original');
});

test('a pendingApproval doc loses even when it is the older one', () => {
  // Not only a question of age: an approved, billed or suspended account is
  // the one that decides, whichever was written first.
  const olderPending = doc('acct_pending', {
    subscriptionStatus: 'pendingApproval',
    createdAt: ts('2025-01-01T00:00:00Z'),
  });
  const newerCancelled = doc('acct_cancelled', {
    subscriptionStatus: 'cancelled',
    createdAt: ts('2026-01-01T00:00:00Z'),
  });
  assert.equal(preferredOwnerAccountDoc([olderPending, newerCancelled])?.id, 'acct_cancelled');
  assert.equal(preferredOwnerAccountDoc([newerCancelled, olderPending])?.id, 'acct_cancelled');
});

test('then the oldest, then the id; a doc without createdAt counts as the newest', () => {
  const older = doc('acct_b', { subscriptionStatus: 'cancelled', createdAt: ts('2025-01-01T00:00:00Z') });
  const newer = doc('acct_a', { subscriptionStatus: 'active', createdAt: ts('2026-01-01T00:00:00Z') });
  const twin = doc('acct_c', { subscriptionStatus: 'cancelled', createdAt: ts('2025-01-01T00:00:00Z') });
  const undated = doc('acct_0', { subscriptionStatus: 'active' });
  assert.equal(preferredOwnerAccountDoc([newer, older])?.id, 'acct_b');
  assert.equal(preferredOwnerAccountDoc([twin, older])?.id, 'acct_b');
  assert.equal(preferredOwnerAccountDoc([undated, newer])?.id, 'acct_a');
  assert.equal(preferredOwnerAccountDoc([]), null);
});

test('findOwnerAccountDoc reads every doc for the owner (bounded) and picks the preferred one', async () => {
  const asked: unknown[] = [];
  const db = {
    collection(name: string) {
      asked.push(['collection', name]);
      const query = {
        where(field: string, op: string, value: unknown) {
          asked.push(['where', field, op, value]);
          return query;
        },
        limit(n: number) {
          asked.push(['limit', n]);
          return query;
        },
        async get() {
          return { docs: [pendingDuplicate, original] };
        },
      };
      return query;
    },
  };
  const found = await findOwnerAccountDoc(db as never, 'owner-1');
  assert.equal(found?.id, 'acct_original');
  assert.deepEqual(asked, [
    ['collection', 'facilityCreatorAccounts'],
    ['where', 'ownerUid', '==', 'owner-1'],
    ['limit', OWNER_ACCOUNT_READ_LIMIT],
  ]);
  assert.ok(OWNER_ACCOUNT_READ_LIMIT > 1, 'limit(1) is what picked an arbitrary doc');
});

test('the standing copies what the app needs and nothing else', () => {
  const trialEnd = ts('2026-10-01T00:00:00Z');
  const standing = buildOwnerAccountStanding(
    doc('acct_1', {
      subscriptionStatus: 'trialing',
      subscriptionTrialEnd: trialEnd,
      subscriptionCurrentPeriodEnd: 'not a date',
      suspended: true,
      billingExempt: false,
      stripeCustomerId: 'cus_secret',
      ownerEmail: 'owner@example.com',
    }),
  );
  assert.deepEqual(standing, {
    accountId: 'acct_1',
    subscriptionStatus: 'trialing',
    subscriptionTrialEnd: trialEnd,
    subscriptionCurrentPeriodEnd: null,
    suspended: true,
    billingExempt: false,
  });
});

test('sameOwnerAccountStanding compares dates by instant', () => {
  const standing = buildOwnerAccountStanding(
    doc('acct_1', { subscriptionStatus: 'active', subscriptionCurrentPeriodEnd: ts('2026-10-01T00:00:00Z') }),
  );
  assert.equal(
    sameOwnerAccountStanding({ ...standing, subscriptionCurrentPeriodEnd: ts('2026-10-01T00:00:00Z') }, standing),
    true,
  );
  assert.equal(
    sameOwnerAccountStanding({ ...standing, subscriptionCurrentPeriodEnd: ts('2026-11-01T00:00:00Z') }, standing),
    false,
  );
  assert.equal(sameOwnerAccountStanding({ ...standing, suspended: true }, standing), false);
  assert.equal(sameOwnerAccountStanding(undefined, standing), false);
  assert.equal(sameOwnerAccountStanding(undefined, null), true);
  assert.equal(sameOwnerAccountStanding(standing, null), false);
});

test('only writes that can change a mirror are acted on', () => {
  const base = { ownerUid: 'o', subscriptionStatus: 'active', facilityIds: ['f1'], createdAt: ts('2026-01-01T00:00:00Z') };
  assert.equal(accountWriteAffectsStanding(base, { ...base, updatedAt: ts('2026-09-23T00:00:00Z') }), false);
  assert.equal(accountWriteAffectsStanding(base, { ...base, referralCode: 'ABCD1234' }), false);
  assert.equal(accountWriteAffectsStanding(base, { ...base, createdAt: ts('2026-01-01T00:00:00Z') }), false);
  assert.equal(accountWriteAffectsStanding(base, { ...base, suspended: true }), true);
  assert.equal(accountWriteAffectsStanding(base, { ...base, subscriptionStatus: 'cancelled' }), true);
  assert.equal(accountWriteAffectsStanding(base, { ...base, facilityIds: ['f1', 'f2'] }), true);
  assert.equal(
    accountWriteAffectsStanding(base, { ...base, subscriptionTrialEnd: ts('2026-10-01T00:00:00Z') }),
    true,
  );
  assert.equal(accountWriteAffectsStanding(undefined, base), true, 'created');
  assert.equal(accountWriteAffectsStanding(base, undefined), true, 'deleted');
});

function syncHarness(accounts: AccountDocLike[], facilities: AccountDocLike[]) {
  const writes: Array<[string, OwnerAccountStanding | null]> = [];
  const deps = {
    listOwnerAccounts: async () => accounts,
    listOwnerFacilities: async () => facilities,
    writeFacilityStanding: async (id: string, standing: OwnerAccountStanding | null) => {
      writes.push([id, standing]);
    },
  };
  return { deps, writes };
}

test("sync writes the preferred account's standing to every facility the owner owns that differs", async () => {
  const current = buildOwnerAccountStanding(original);
  const { deps, writes } = syncHarness(
    [pendingDuplicate, original],
    [
      doc('fac_new', {}),
      doc('fac_same', { [OWNER_ACCOUNT_STANDING_FIELD]: { ...current } }),
      doc('fac_stale', { [OWNER_ACCOUNT_STANDING_FIELD]: { ...current, suspended: true } }),
    ],
  );
  const result = await syncOwnerAccountStanding('owner-1', deps);
  assert.deepEqual(result, { facilities: 3, updated: 2 });
  assert.deepEqual(
    writes.map(([id, s]) => [id, s?.accountId]),
    [
      ['fac_new', 'acct_original'],
      ['fac_stale', 'acct_original'],
    ],
  );
});

test('sync removes the mirror when the owner has no account left', async () => {
  const stale = buildOwnerAccountStanding(original);
  const { deps, writes } = syncHarness(
    [],
    [doc('fac_1', { [OWNER_ACCOUNT_STANDING_FIELD]: stale }), doc('fac_2', {})],
  );
  const result = await syncOwnerAccountStanding('owner-1', deps);
  assert.deepEqual(result, { facilities: 2, updated: 1 });
  assert.deepEqual(writes, [['fac_1', null]]);
});

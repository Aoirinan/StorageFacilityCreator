import test from 'node:test';
import assert from 'node:assert/strict';
import * as admin from 'firebase-admin';
import { statsCoalesceTestUtils, StatsCoalesceHooks } from '../facility_stats';

const {
  shouldClaimStatsRecompute,
  recomputeFacilityStatsCoalesced,
  claimStatsRecompute,
  releaseStatsClaim,
  STATS_COALESCE_WINDOW_MS,
  STATS_MAX_DRAIN_PASSES,
  STATS_FAILED_PASS_BACKOFF_MS,
} = statsCoalesceTestUtils;

/**
 * Regression cover for the 2026-08-31 load run, where ~30,000 tenant writes each
 * recomputed their whole facility and cost ~5.0M Firestore reads in one hour.
 */

function hooks(over: Partial<StatsCoalesceHooks> = {}) {
  const calls = { claim: 0, recompute: 0, consumeDirty: 0, release: 0 };
  const base: StatsCoalesceHooks = {
    claim: async () => {
      calls.claim++;
      return 'claimed';
    },
    recompute: async () => {
      calls.recompute++;
    },
    consumeDirty: async () => {
      calls.consumeDirty++;
      return false;
    },
    release: async () => {
      calls.release++;
    },
    ...over,
  };
  return { calls, hooks: base };
}

test('a lone edit outside the window claims and recomputes immediately', () => {
  const now = 1_000_000;
  assert.equal(shouldClaimStatsRecompute(now - STATS_COALESCE_WINDOW_MS, now), true);
  assert.equal(shouldClaimStatsRecompute(0, now), true);
});

test('a write inside a live window does not claim', () => {
  const now = 1_000_000;
  assert.equal(shouldClaimStatsRecompute(now, now), false);
  assert.equal(shouldClaimStatsRecompute(now - (STATS_COALESCE_WINDOW_MS - 1), now), false);
});

test('a writer that loses the claim does no reads at all', async () => {
  const { calls, hooks: h } = hooks({ claim: async () => 'coalesced' });
  await recomputeFacilityStatsCoalesced('fac-1', 'tenant change', h);
  assert.equal(calls.recompute, 0, 'coalesced writer must not recompute');
  assert.equal(calls.consumeDirty, 0);
});

test('the claim holder recomputes once when nothing arrived mid-pass', async () => {
  const { calls, hooks: h } = hooks();
  await recomputeFacilityStatsCoalesced('fac-1', 'tenant change', h);
  assert.equal(calls.recompute, 1);
});

test('the claim holder drains writes that landed during its recompute', async () => {
  let dirty = 2;
  const { calls, hooks: h } = hooks({
    consumeDirty: async () => dirty-- > 0,
  });
  await recomputeFacilityStatsCoalesced('fac-1', 'tenant change', h);
  assert.equal(calls.recompute, 3, 'initial pass plus two drains');
});

test('a sustained burst is capped so the invocation cannot run to its timeout', async () => {
  const { calls, hooks: h } = hooks({ consumeDirty: async () => true });
  await recomputeFacilityStatsCoalesced('fac-1', 'tenant change', h);
  assert.equal(calls.recompute, STATS_MAX_DRAIN_PASSES);
});

test('a 30k-write burst collapses to one recompute per claim, not one per write', async () => {
  let claimed = false;
  let recomputes = 0;
  const h: StatsCoalesceHooks = {
    // First writer wins the window; the rest arrive inside it and only mark dirty.
    claim: async () => {
      if (claimed) return 'coalesced';
      claimed = true;
      return 'claimed';
    },
    recompute: async () => {
      recomputes++;
    },
    consumeDirty: async () => false,
    release: async () => {},
  };
  await Promise.all(
    Array.from({ length: 30_000 }, () =>
      recomputeFacilityStatsCoalesced('fac-1', 'tenant change', h),
    ),
  );
  assert.equal(recomputes, 1, '30,000 writes must not cost 30,000 facility scans');
});

test('a failing recompute never propagates into the triggering write', async () => {
  const { hooks: h } = hooks({
    recompute: async () => {
      throw new Error('firestore unavailable');
    },
  });
  await assert.doesNotReject(() => recomputeFacilityStatsCoalesced('fac-1', 'tenant change', h));
});

test('writes that landed during a failed pass get one retry', async () => {
  let recomputes = 0;
  const { calls, hooks: h } = hooks({
    recompute: async () => {
      recomputes++;
      if (recomputes === 1) throw new Error('deadline-exceeded');
    },
    // Dirty once: a write arrived during the failed pass.
    consumeDirty: async () => recomputes === 1,
  });
  await recomputeFacilityStatsCoalesced('fac-1', 'tenant change', h);
  // Before: the failed pass exited through the catch and those writes
  // waited for the next write or the nightly job.
  assert.equal(recomputes, 2);
  assert.equal(calls.release, 0, 'the retry succeeded, so the claim runs its course');
});

test('a pass that keeps failing releases the claim so the next write recomputes at once', async () => {
  const { calls, hooks: h } = hooks({
    recompute: async () => {
      calls.recompute++;
      throw new Error('firestore unavailable');
    },
    consumeDirty: async () => true,
  });
  await recomputeFacilityStatsCoalesced('fac-1', 'tenant change', h);
  assert.equal(calls.recompute, 2, 'one retry, not a loop');
  // Before: the claim stayed live for the rest of its window, so writes in
  // it only marked the facility dirty and nothing recomputed them.
  assert.equal(calls.release, 1);
});

test('a failed pass with no writes waiting is not retried, and releases the claim', async () => {
  const { calls, hooks: h } = hooks({
    recompute: async () => {
      calls.recompute++;
      throw new Error('firestore unavailable');
    },
  });
  await recomputeFacilityStatsCoalesced('fac-1', 'tenant change', h);
  assert.equal(calls.recompute, 1);
  assert.equal(calls.release, 1);
});

test('a failure on the last drain pass still gets its retry', async () => {
  let recomputes = 0;
  const { calls, hooks: h } = hooks({
    recompute: async () => {
      recomputes++;
      if (recomputes === STATS_MAX_DRAIN_PASSES) throw new Error('deadline-exceeded');
    },
    // A sustained burst: always dirty until the retry has run.
    consumeDirty: async () => recomputes <= STATS_MAX_DRAIN_PASSES,
  });
  await recomputeFacilityStatsCoalesced('fac-1', 'tenant change', h);
  assert.equal(recomputes, STATS_MAX_DRAIN_PASSES + 1);
  assert.equal(calls.release, 0);
});

test('a writer that lost the claim never releases it', async () => {
  const { calls, hooks: h } = hooks({
    claim: async () => {
      throw new Error('contention');
    },
  });
  await recomputeFacilityStatsCoalesced('fac-1', 'tenant change', h);
  assert.equal(calls.release, 0);
});

test('a deleted facility is neither recomputed nor released', async () => {
  const { calls, hooks: h } = hooks({ claim: async () => 'facility-missing' });
  await recomputeFacilityStatsCoalesced('fac-gone', 'unit change', h);
  assert.equal(calls.recompute, 0);
  assert.equal(calls.release, 0);
});

/** A Firestore stand-in for the claim: one facility doc and its claim doc. */
function claimDb(opts: { facilityExists: boolean; claimedAtMs?: number }) {
  const writes: Array<Record<string, unknown>> = [];
  let transactions = 0;
  const claimRef = { path: 'facilities/fac-1/stats/recompute' };
  const db = {
    collection: (name: string) => {
      assert.equal(name, 'facilities');
      return {
        doc: () => ({
          get: async () => ({ exists: opts.facilityExists }),
          collection: (sub: string) => {
            assert.equal(sub, 'stats');
            return { doc: (id: string) => (assert.equal(id, 'recompute'), claimRef) };
          },
        }),
      };
    },
    runTransaction: async (fn: (tx: unknown) => Promise<unknown>) => {
      transactions++;
      return fn({
        get: async (ref: unknown) => {
          assert.equal(ref, claimRef);
          return {
            data: () =>
              opts.claimedAtMs === undefined
                ? undefined
                : { claimedAt: admin.firestore.Timestamp.fromMillis(opts.claimedAtMs) },
          };
        },
        set: (ref: unknown, data: Record<string, unknown>) => {
          assert.equal(ref, claimRef);
          writes.push(data);
        },
      });
    },
  };
  return {
    db: db as unknown as admin.firestore.Firestore,
    writes,
    transactions: () => transactions,
  };
}

test('a write for a deleted facility claims nothing and writes no stats doc', async () => {
  const fake = claimDb({ facilityExists: false });
  assert.equal(await claimStatsRecompute('fac-1', fake.db), 'facility-missing');
  // Before: the claim transaction ran and set stats/recompute, recreating it
  // under the deleted facility on every subcollection write of a purge.
  assert.equal(fake.transactions(), 0);
  assert.deepEqual(fake.writes, []);
});

test('an idle facility is claimed; one inside a live window is marked dirty', async () => {
  const idle = claimDb({ facilityExists: true });
  assert.equal(await claimStatsRecompute('fac-1', idle.db), 'claimed');
  assert.equal(idle.writes.length, 1);
  assert.equal(idle.writes[0].dirty, false);

  const busy = claimDb({ facilityExists: true, claimedAtMs: Date.now() });
  assert.equal(await claimStatsRecompute('fac-1', busy.db), 'coalesced');
  assert.deepEqual(busy.writes, [{ dirty: true }]);
});

test('a failed pass releases its claim to a short backoff, not to zero', async () => {
  const updates: Array<Record<string, unknown>> = [];
  const ref = {
    update: async (data: Record<string, unknown>) => {
      updates.push(data);
    },
  } as unknown as admin.firestore.DocumentReference;
  const now = 1_000_000_000;

  await releaseStatsClaim('fac-1', ref, now);

  assert.equal(updates.length, 1);
  const releasedAt = (updates[0].claimedAt as admin.firestore.Timestamp).toMillis();
  // Before: released to 0, so under a failure that keeps happening every
  // write in a burst claimed at once and passes ran back to back.
  assert.equal(shouldClaimStatsRecompute(releasedAt, now + 1_000), false);
  assert.equal(shouldClaimStatsRecompute(releasedAt, now + STATS_FAILED_PASS_BACKOFF_MS - 1), false);
  assert.equal(shouldClaimStatsRecompute(releasedAt, now + STATS_FAILED_PASS_BACKOFF_MS), true);
  // Still well short of a full window.
  assert.ok(STATS_FAILED_PASS_BACKOFF_MS < STATS_COALESCE_WINDOW_MS);
});

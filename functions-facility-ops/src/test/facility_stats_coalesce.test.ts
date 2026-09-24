import test from 'node:test';
import assert from 'node:assert/strict';
import * as admin from 'firebase-admin';
import {
  statsCoalesceTestUtils,
  StatsClaimOutcome,
  StatsCoalesceHooks,
  StatsDrainClaim,
} from '../facility_stats';

const {
  shouldClaimStatsRecompute,
  recomputeFacilityStatsCoalesced,
  claimStatsRecompute,
  consumeStatsDirtyFlag,
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

/**
 * One facility's claim doc, held in memory, behind the calls the production
 * claim and drain make (facility get, stats/recompute, transactions).
 */
function claimStore(initial?: Record<string, unknown>) {
  let claimDoc: Record<string, unknown> | undefined = initial ? { ...initial } : undefined;
  const claimRef = {
    path: 'facilities/fac-1/stats/recompute',
    // releaseStatsClaim writes through the ref, outside a transaction.
    update: async (data: Record<string, unknown>) => {
      if (!claimDoc) throw Object.assign(new Error('NOT_FOUND'), { code: 5 });
      claimDoc = { ...claimDoc, ...data };
    },
  };
  const db = {
    collection: (name: string) => {
      assert.equal(name, 'facilities');
      return {
        doc: () => ({
          get: async () => ({ exists: true }),
          collection: (sub: string) => {
            assert.equal(sub, 'stats');
            return { doc: (id: string) => (assert.equal(id, 'recompute'), claimRef) };
          },
        }),
      };
    },
    runTransaction: async (fn: (tx: unknown) => Promise<unknown>) =>
      fn({
        get: async (ref: unknown) => {
          assert.equal(ref, claimRef);
          const current = claimDoc;
          return { exists: current !== undefined, data: () => (current ? { ...current } : undefined) };
        },
        set: (ref: unknown, data: Record<string, unknown>, options?: { merge?: boolean }) => {
          assert.equal(ref, claimRef);
          claimDoc = options?.merge ? { ...(claimDoc ?? {}), ...data } : { ...data };
        },
        update: (ref: unknown, data: Record<string, unknown>) => {
          assert.equal(ref, claimRef);
          if (!claimDoc) throw Object.assign(new Error('NOT_FOUND'), { code: 5 });
          claimDoc = { ...claimDoc, ...data };
        },
      }),
  };
  return {
    db: db as unknown as admin.firestore.Firestore,
    ref: claimRef as unknown as admin.firestore.DocumentReference,
    doc: () => claimDoc,
  };
}

/** The production claim, drain and release against [store], with [over] for the rest. */
function storeHooks(
  store: ReturnType<typeof claimStore>,
  over: Partial<StatsCoalesceHooks> = {},
): StatsCoalesceHooks {
  return {
    claim: (facilityId) => claimStatsRecompute(facilityId, store.db),
    consumeDirty: (facilityId, claim) => consumeStatsDirtyFlag(facilityId, claim, store.db),
    recompute: async () => {},
    release: (facilityId) => releaseStatsClaim(facilityId, store.ref),
    ...over,
  };
}

function claimedAtMs(store: ReturnType<typeof claimStore>): number {
  return (store.doc()?.claimedAt as admin.firestore.Timestamp).toMillis();
}

test('a drain that finds nothing waiting ends the claim, so the next write recomputes', async () => {
  const now = Date.now();
  const store = claimStore({ claimedAt: admin.firestore.Timestamp.fromMillis(now), dirty: false });

  assert.equal(await consumeStatsDirtyFlag('fac-1', 'end-when-idle', store.db), false);

  // Before: the claim stayed live for the rest of its window, so this write
  // only marked the facility dirty, and the holder had already stopped
  // draining. The mirror kept the old counts until another write.
  assert.equal(await claimStatsRecompute('fac-1', store.db), 'claimed');
});

test('a drain that finds writes waiting consumes them and keeps the claim', async () => {
  const now = Date.now();
  const store = claimStore({ claimedAt: admin.firestore.Timestamp.fromMillis(now), dirty: true });

  assert.equal(await consumeStatsDirtyFlag('fac-1', 'end-when-idle', store.db), true);
  assert.equal(store.doc()?.dirty, false);
  assert.equal((store.doc()?.claimedAt as admin.firestore.Timestamp).toMillis(), now);
  // Still coalescing: the holder runs another pass for these writes.
  assert.equal(await claimStatsRecompute('fac-1', store.db), 'coalesced');
});

test('a drain does not recreate a claim doc deleted with its facility', async () => {
  for (const claim of ['end-when-idle', 'keep', 'end'] as StatsDrainClaim[]) {
    const store = claimStore();
    assert.equal(await consumeStatsDirtyFlag('fac-1', claim, store.db), false, claim);
    assert.equal(store.doc(), undefined, claim);
  }
});

test('a write after the holder finished is recomputed, not stranded in the window', async () => {
  const store = claimStore();
  let recomputes = 0;
  const h = storeHooks(store, {
    recompute: async () => {
      recomputes++;
    },
  });

  // Create a tenant, then assign it a unit a few seconds later, well inside
  // the window the first write claimed.
  await recomputeFacilityStatsCoalesced('fac-1', 'tenant change', h);
  await recomputeFacilityStatsCoalesced('fac-1', 'unit change', h);

  // Before: 1. The second write found a live claim, set dirty and returned;
  // nothing drained it.
  assert.equal(recomputes, 2);
  assert.notEqual(store.doc()?.dirty, true);
});

test('an ended claim reads as ended to a writer whose clock runs behind', async () => {
  const now = Date.now();
  const store = claimStore({ claimedAt: admin.firestore.Timestamp.fromMillis(now), dirty: false });

  await consumeStatsDirtyFlag('fac-1', 'end-when-idle', store.db);

  // Before: ended at the consumer's now minus the window, so a writer whose
  // clock ran a minute behind still saw a live claim, only marked the
  // facility dirty, and nobody drained it.
  assert.equal(shouldClaimStatsRecompute(claimedAtMs(store), now - 60_000), true);
  assert.equal(claimedAtMs(store), 0);
});

test('a drain after a failed pass consumes the flag but keeps the claim', async () => {
  const now = Date.now();
  const store = claimStore({ claimedAt: admin.firestore.Timestamp.fromMillis(now), dirty: true });

  assert.equal(await consumeStatsDirtyFlag('fac-1', 'keep', store.db), true);
  assert.equal(store.doc()?.dirty, false);
  assert.equal(claimedAtMs(store), now);

  assert.equal(await consumeStatsDirtyFlag('fac-1', 'keep', store.db), false);
  assert.equal(claimedAtMs(store), now, 'nothing waiting still keeps it');
});

test('a failed pass with nothing waiting holds its claim until it releases to the backoff', async () => {
  const store = claimStore();
  let writerDuringFailure: StatsClaimOutcome | undefined;
  const h = storeHooks(store, {
    recompute: async () => {
      throw new Error('deadline-exceeded');
    },
    release: async (facilityId) => {
      // Another write lands between the failed pass's drain and the release.
      writerDuringFailure = await claimStatsRecompute(facilityId, store.db);
      await releaseStatsClaim(facilityId, store.ref);
    },
  });

  await recomputeFacilityStatsCoalesced('fac-1', 'tenant change', h);

  // Before: the drain ended the claim, so this writer claimed and started a
  // pass on a facility that was failing, and the release then cut its new
  // claim short.
  assert.equal(writerDuringFailure, 'coalesced');
  // Released to the backoff, not ended: the next write waits it out.
  assert.equal(shouldClaimStatsRecompute(claimedAtMs(store), Date.now()), false);
  assert.equal(store.doc()?.dirty, true, 'the write stays marked for the next holder');
});

test('a burst that outlasts the drain passes ends the claim, so the next write recomputes', async () => {
  const store = claimStore();
  let recomputes = 0;
  const h = storeHooks(store, {
    recompute: async (facilityId) => {
      recomputes++;
      // A write lands during every pass.
      assert.equal(await claimStatsRecompute(facilityId, store.db), 'coalesced');
    },
  });

  await recomputeFacilityStatsCoalesced('fac-1', 'tenant change', h);

  assert.equal(recomputes, STATS_MAX_DRAIN_PASSES);
  // Before: the last drain consumed the flag and the claim stayed live, so
  // this write was only marked dirty and nothing recomputed it.
  assert.equal(await claimStatsRecompute('fac-1', store.db), 'claimed');
});

test('the drain keeps the claim after a failure and ends it on the last pass', async () => {
  const seen: StatsDrainClaim[] = [];
  let recomputes = 0;
  const { hooks: h } = hooks({
    recompute: async () => {
      recomputes++;
      if (recomputes === 1) throw new Error('deadline-exceeded');
    },
    consumeDirty: async (_facilityId, claim) => {
      seen.push(claim);
      return true;
    },
  });

  await recomputeFacilityStatsCoalesced('fac-1', 'tenant change', h);

  // One failed pass (retried), then every drain pass the retry allows.
  assert.deepEqual(seen, [
    'keep',
    ...Array.from({ length: STATS_MAX_DRAIN_PASSES - 1 }, () => 'end-when-idle'),
    'end',
  ]);
});

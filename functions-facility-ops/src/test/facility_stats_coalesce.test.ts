import test from 'node:test';
import assert from 'node:assert/strict';
import { statsCoalesceTestUtils, StatsCoalesceHooks } from '../facility_stats';

const {
  shouldClaimStatsRecompute,
  recomputeFacilityStatsCoalesced,
  STATS_COALESCE_WINDOW_MS,
  STATS_MAX_DRAIN_PASSES,
} = statsCoalesceTestUtils;

/**
 * Regression cover for the 2026-08-31 load run, where ~30,000 tenant writes each
 * recomputed their whole facility and cost ~5.0M Firestore reads in one hour.
 */

function hooks(over: Partial<StatsCoalesceHooks> = {}) {
  const calls = { claim: 0, recompute: 0, consumeDirty: 0 };
  const base: StatsCoalesceHooks = {
    claim: async () => {
      calls.claim++;
      return true;
    },
    recompute: async () => {
      calls.recompute++;
    },
    consumeDirty: async () => {
      calls.consumeDirty++;
      return false;
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
  const { calls, hooks: h } = hooks({ claim: async () => false });
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
      if (claimed) return false;
      claimed = true;
      return true;
    },
    recompute: async () => {
      recomputes++;
    },
    consumeDirty: async () => false,
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

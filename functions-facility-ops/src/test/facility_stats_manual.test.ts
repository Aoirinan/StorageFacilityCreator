import test from 'node:test';
import assert from 'node:assert/strict';
import * as functions from 'firebase-functions/v1';
import { manualStatsTestUtils, ManualStatsDeps } from '../facility_stats';

const { handleUpdateFacilityStatsManual } = manualStatsTestUtils;

/**
 * updateFacilityStatsManual used to check only that the caller was signed in:
 * any user could read another operator's revenue and past-due counts and
 * trigger unit writes (orphan heals) on their facility.
 */

function deps(hasAccess: boolean) {
  const calls = { access: 0, recompute: 0 };
  const d: ManualStatsDeps = {
    assertFacilityAccess: async () => {
      calls.access++;
      if (!hasAccess) {
        throw new functions.https.HttpsError(
          'permission-denied',
          'You do not have access to this facility',
        );
      }
      return {};
    },
    recompute: async () => {
      calls.recompute++;
      return { totalUnits: 3, occupiedUnits: 2 };
    },
  };
  return { calls, deps: d };
}

function codeOf(e: unknown): string | undefined {
  return (e as { code?: string }).code;
}

test('rejects a caller with no access to the facility before computing anything', async () => {
  const { calls, deps: d } = deps(false);
  await assert.rejects(
    handleUpdateFacilityStatsManual(
      { facilityId: 'someone-elses' },
      { auth: { uid: 'u1', token: {} } },
      d,
    ),
    (e) => codeOf(e) === 'permission-denied',
  );
  assert.equal(calls.access, 1);
  assert.equal(calls.recompute, 0, 'no reads, heals or stats for an outsider');
});

test('recomputes for a caller with facility access', async () => {
  const { calls, deps: d } = deps(true);
  const result = await handleUpdateFacilityStatsManual(
    { facilityId: 'mine' },
    { auth: { uid: 'owner', token: {} } },
    d,
  );
  // Only success: the stats hold revenue and past-due counts, and the
  // callable is open to staff roles. Before: the full stats came back.
  assert.deepEqual(result, { success: true });
  assert.equal(calls.access, 1);
  assert.equal(calls.recompute, 1);
});

test('a super admin (server-set claim) needs no facility role', async () => {
  const { calls, deps: d } = deps(false);
  await handleUpdateFacilityStatsManual(
    { facilityId: 'any' },
    { auth: { uid: 'admin', token: { superadmin: true } } },
    d,
  );
  assert.equal(calls.access, 0);
  assert.equal(calls.recompute, 1);
});

test('a truthy non-boolean superadmin claim is not a super admin', async () => {
  const { calls, deps: d } = deps(false);
  await assert.rejects(
    handleUpdateFacilityStatsManual(
      { facilityId: 'any' },
      { auth: { uid: 'u1', token: { superadmin: 'true' } } },
      d,
    ),
    (e) => codeOf(e) === 'permission-denied',
  );
  assert.equal(calls.recompute, 0);
});

test('an unauthenticated call or a missing facilityId is rejected', async () => {
  const { calls, deps: d } = deps(true);
  await assert.rejects(
    handleUpdateFacilityStatsManual({ facilityId: 'x' }, {}, d),
    (e) => codeOf(e) === 'unauthenticated',
  );
  await assert.rejects(
    handleUpdateFacilityStatsManual({}, { auth: { uid: 'u1', token: {} } }, d),
    (e) => codeOf(e) === 'invalid-argument',
  );
  assert.equal(calls.recompute, 0);
});

test('a failed recompute is reported as an error, never as success', async () => {
  const d: ManualStatsDeps = {
    assertFacilityAccess: async () => ({}),
    recompute: async () => {
      throw new Error('deadline-exceeded');
    },
  };
  await assert.rejects(
    handleUpdateFacilityStatsManual(
      { facilityId: 'mine' },
      { auth: { uid: 'owner', token: {} } },
      d,
    ),
    (e) => codeOf(e) === 'internal',
  );
});

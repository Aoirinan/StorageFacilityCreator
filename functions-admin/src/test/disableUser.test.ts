import test from 'node:test';
import assert from 'node:assert/strict';
import { disableUserHandler, DisableUserDeps } from '../disableUser';

const ADMIN = 'admin@test.invalid';
process.env.SUPER_ADMIN_EMAILS = ADMIN;

function fakeDeps(targetEmail = 'owner@test.invalid') {
  const calls: string[] = [];
  const userDocs: Record<string, Record<string, unknown>> = {};
  const deps: DisableUserDeps = {
    auth: {
      getUser: async (uid) => {
        calls.push(`getUser:${uid}`);
        return { email: targetEmail };
      },
      updateUser: async (uid, properties) => {
        calls.push(`updateUser:${uid}:disabled=${properties.disabled}`);
        return {};
      },
      revokeRefreshTokens: async (uid) => {
        calls.push(`revokeRefreshTokens:${uid}`);
      },
    },
    mergeUserDoc: async (uid, fields) => {
      calls.push(`mergeUserDoc:${uid}`);
      userDocs[uid] = { ...(userDocs[uid] ?? {}), ...fields };
    },
    serverTimestamp: () => 'SERVER_TIMESTAMP',
  };
  return { deps, calls, userDocs };
}

const asAdmin = { auth: { token: { email: ADMIN } } };

test('disabling a user also revokes their refresh tokens', async () => {
  // Disabling alone left sessions already signed in running until the client
  // re-checked with Auth, and let them resume if the user was re-enabled.
  const { deps, calls, userDocs } = fakeDeps();
  const result = await disableUserHandler({ uid: ' owner-1 ' }, asAdmin, deps);

  assert.deepEqual(result, { success: true });
  assert.deepEqual(calls, [
    'getUser:owner-1',
    'updateUser:owner-1:disabled=true',
    'mergeUserDoc:owner-1',
    'revokeRefreshTokens:owner-1',
  ]);
  assert.deepEqual(userDocs['owner-1'], {
    authDisabled: true,
    authDisabledAt: 'SERVER_TIMESTAMP',
  });
});

test('a failed revoke still records the disable, and fails so it is retried', async () => {
  // The login is disabled in Auth by then. Recording it only after the revoke
  // left the console showing a disabled user as enabled when the revoke failed.
  const { deps, calls, userDocs } = fakeDeps();
  deps.auth.revokeRefreshTokens = async () => {
    throw new Error('auth unavailable');
  };
  await assert.rejects(disableUserHandler({ uid: 'owner-1' }, asAdmin, deps), /auth unavailable/);
  assert.deepEqual(calls, ['getUser:owner-1', 'updateUser:owner-1:disabled=true', 'mergeUserDoc:owner-1']);
  assert.deepEqual(userDocs['owner-1'], { authDisabled: true, authDisabledAt: 'SERVER_TIMESTAMP' });

  // The retry goes through: every step is safe to repeat.
  deps.auth.revokeRefreshTokens = async (uid) => {
    calls.push(`revokeRefreshTokens:${uid}`);
  };
  assert.deepEqual(await disableUserHandler({ uid: 'owner-1' }, asAdmin, deps), { success: true });
  assert.equal(calls[calls.length - 1], 'revokeRefreshTokens:owner-1');
});

test('a failed Auth disable records nothing', async () => {
  const { deps, calls, userDocs } = fakeDeps();
  deps.auth.updateUser = async () => {
    throw new Error('auth unavailable');
  };
  await assert.rejects(disableUserHandler({ uid: 'owner-1' }, asAdmin, deps), /auth unavailable/);
  assert.deepEqual(calls, ['getUser:owner-1']);
  assert.equal(userDocs['owner-1'], undefined);
});

test('only a super admin may disable, and never another super admin', async () => {
  const { deps, calls } = fakeDeps();
  await assert.rejects(disableUserHandler({ uid: 'owner-1' }, undefined, deps), {
    code: 'unauthenticated',
  });
  await assert.rejects(
    disableUserHandler({ uid: 'owner-1' }, { auth: { token: { email: 'owner@test.invalid' } } }, deps),
    { code: 'permission-denied' },
  );
  await assert.rejects(disableUserHandler({ uid: '  ' }, asAdmin, deps), {
    code: 'invalid-argument',
  });
  assert.deepEqual(calls, []);

  const other = fakeDeps(ADMIN);
  await assert.rejects(disableUserHandler({ uid: 'admin-2' }, asAdmin, other.deps), {
    code: 'permission-denied',
  });
  assert.deepEqual(other.calls, ['getUser:admin-2']);
});

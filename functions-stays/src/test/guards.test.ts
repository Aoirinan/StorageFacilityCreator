import test from 'node:test';
import assert from 'node:assert/strict';
import * as functions from 'firebase-functions/v1';
import { Timestamp } from 'firebase-admin/firestore';

import type { StayRole } from '@sfc/functions-shared/stays/contracts';

import {
  StaysGuardOptions,
  assertEmployeeSetting,
  auditStays,
  requireRequestId,
  runStaysGuards,
  staysCallable,
} from '../common/guards';
import { resetStaysGateCacheForTests } from '../common/serverConfig';
import { staysErrorReason } from '../common/errors';
import { FakeFirestore } from './support/fakeFirestore';
import {
  EMPLOYEE,
  FAC,
  MANAGER,
  NOW,
  OUTSIDER,
  OWNER,
  VIEWER,
  callableContext,
  fakeDeps,
  seedControls,
  seedFacility,
  seedGate,
} from './support/staysFixtures';

const OM: StayRole[] = ['owner', 'manager'];
const STAFF: StayRole[] = ['owner', 'manager', 'employee'];
const ANY: StayRole[] = ['owner', 'manager', 'employee', 'viewer'];

/** Every store a test used, for the isolation check at the end. */
const all: FakeFirestore[] = [];

function setup(opts: { gate?: Record<string, unknown> | null; controls?: Record<string, unknown> | null; facility?: Record<string, unknown> } = {}) {
  resetStaysGateCacheForTests();
  const fake = new FakeFirestore();
  all.push(fake);
  seedFacility(fake, opts.facility);
  if (opts.gate !== null) seedGate(fake, opts.gate ?? {});
  if (opts.controls !== null) seedControls(fake, opts.controls ?? {});
  const handle = fakeDeps(fake);
  return { fake, handle };
}

function guard(
  handle: ReturnType<typeof fakeDeps>,
  uid: string | null,
  options: Partial<StaysGuardOptions> = {},
  data: Record<string, unknown> = { facilityId: FAC },
  appCheck = true,
) {
  return runStaysGuards(
    data,
    callableContext(uid, { appCheck }),
    { callable: 'staysQuote', roles: OM, ...options },
    handle.deps,
  );
}

async function reasonOf(p: Promise<unknown>): Promise<string | null> {
  try {
    await p;
    return null;
  } catch (error) {
    return staysErrorReason(error) ?? `untyped: ${String(error)}`;
  }
}

test('no sign-in is refused first', async () => {
  const { handle } = setup();
  assert.equal(await reasonOf(guard(handle, null)), 'unauthenticated');
});

test('no App Check token is refused', async () => {
  const { handle } = setup();
  assert.equal(await reasonOf(guard(handle, OWNER, {}, { facilityId: FAC }, false)), 'app_check_required');
});

test('ids are checked before anything is read', async () => {
  const { fake, handle } = setup({ gate: { killSwitch: true } });
  fake.failReads = () => true;
  assert.equal(await reasonOf(guard(handle, OWNER, {}, { facilityId: 'a/b' })), 'invalid_argument');
  assert.equal(await reasonOf(guard(handle, OWNER, {}, { facilityId: '' })), 'invalid_argument');
  assert.equal(
    await reasonOf(guard(handle, OWNER, { validate: (d) => void requireRequestId(d) }, { facilityId: FAC, requestId: 'nope' })),
    'invalid_argument',
  );
});

test('the kill switch pauses Stays for everyone, the owner included', async () => {
  const { handle } = setup({ gate: { killSwitch: true, enabledGlobal: true } });
  assert.equal(await reasonOf(guard(handle, OWNER)), 'stays_paused');
});

test('a facility that is not allowlisted is not available', async () => {
  const { handle } = setup({ gate: { allowlistFacilityIds: ['someone-else'] } });
  assert.equal(await reasonOf(guard(handle, OWNER)), 'module_not_available');

  const global = setup({ gate: { allowlistFacilityIds: [], enabledGlobal: true } });
  assert.equal(await reasonOf(guard(global.handle, OWNER)), null);
});

test('the gate fails closed: no config doc, or a failed read, allows nothing', async () => {
  const missing = setup({ gate: null });
  assert.equal(await reasonOf(guard(missing.handle, OWNER)), 'module_not_available');

  const broken = setup();
  broken.fake.failReads = (path) => path.startsWith('staysServerConfig');
  assert.equal(await reasonOf(guard(broken.handle, OWNER)), 'module_not_available');
  // A failed read is not cached: once the doc reads again, the facility is allowed.
  broken.fake.failReads = null;
  assert.equal(await reasonOf(guard(broken.handle, OWNER)), null);
});

test('the gate is cached for 60 seconds', async () => {
  const { fake, handle } = setup();
  assert.equal(await reasonOf(guard(handle, OWNER)), null);
  seedGate(fake, { killSwitch: true });
  handle.setNow(NOW + 59_000);
  assert.equal(await reasonOf(guard(handle, OWNER)), null);
  handle.setNow(NOW + 61_000);
  assert.equal(await reasonOf(guard(handle, OWNER)), 'stays_paused');
});

test('module disabled is refused unless the callable works without it', async () => {
  const { handle } = setup({ controls: { moduleEnabled: false } });
  assert.equal(await reasonOf(guard(handle, OWNER)), 'module_disabled');
  assert.equal(await reasonOf(guard(handle, OWNER, { callable: 'staysSetControls', requireModuleEnabled: false })), null);

  const noDoc = setup({ controls: null });
  assert.equal(await reasonOf(guard(noDoc.handle, OWNER)), 'module_disabled');
  // A doc with moduleEnabled as a string is not "on".
  const loose = setup({ controls: { moduleEnabled: 'true' } });
  assert.equal(await reasonOf(guard(loose.handle, OWNER)), 'module_disabled');
});

test('the role matrix: owner/manager-only callables', async () => {
  const { handle } = setup();
  assert.equal(await reasonOf(guard(handle, OWNER, { roles: OM })), null);
  assert.equal(await reasonOf(guard(handle, MANAGER, { roles: OM })), null);
  assert.equal(await reasonOf(guard(handle, EMPLOYEE, { roles: OM })), 'role_not_allowed');
  assert.equal(await reasonOf(guard(handle, VIEWER, { roles: OM })), 'role_not_allowed');
  assert.equal(await reasonOf(guard(handle, OUTSIDER, { roles: OM })), 'role_not_allowed');
});

test('the role matrix: staff callables and the any-role availability check', async () => {
  const { handle } = setup();
  assert.equal(await reasonOf(guard(handle, EMPLOYEE, { roles: STAFF })), null);
  assert.equal(await reasonOf(guard(handle, VIEWER, { roles: STAFF })), 'role_not_allowed');
  assert.equal(await reasonOf(guard(handle, OUTSIDER, { roles: STAFF })), 'role_not_allowed');
  assert.equal(
    await reasonOf(guard(handle, VIEWER, { callable: 'staysGetAvailability', roles: ANY, requireModuleEnabled: false })),
    null,
  );
  assert.equal(
    await reasonOf(guard(handle, OUTSIDER, { callable: 'staysGetAvailability', roles: ANY, requireModuleEnabled: false })),
    'role_not_allowed',
  );
});

test('roles come from ownerUid, the managers map, the roles map and active user_roles rows', async () => {
  const { fake, handle } = setup({
    facility: {
      managers: { 'uid-legacy': true, 'uid-object': { active: true }, 'uid-off': { active: false } },
      roles: { 'uid-coowner': 'owner', 'uid-admin': 'admin', [EMPLOYEE]: 'employee', [VIEWER]: 'viewer' },
    },
  });
  fake.seed('user_roles/r1', { userId: 'uid-invited', facilityId: FAC, roleType: 'manager', isActive: true });
  fake.seed('user_roles/r2', { userId: 'uid-inactive', facilityId: FAC, roleType: 'manager', isActive: false });
  fake.seed('user_roles/r3', { userId: 'uid-other-fac', facilityId: 'another', roleType: 'manager', isActive: true });
  fake.seed('user_roles/r4', {
    userId: 'uid-expired',
    facilityId: FAC,
    roleType: 'manager',
    isActive: true,
    expiresAt: Timestamp.fromMillis(NOW - 1),
  });
  fake.seed('user_roles/r5', { userId: VIEWER, facilityId: FAC, roleType: 'employee', isActive: true });

  const roleOf = async (uid: string) => {
    try {
      return (await guard(handle, uid, { roles: ANY })).role;
    } catch (error) {
      return staysErrorReason(error);
    }
  };
  assert.equal(await roleOf(OWNER), 'owner');
  assert.equal(await roleOf('uid-legacy'), 'manager');
  assert.equal(await roleOf('uid-object'), 'manager');
  assert.equal(await roleOf('uid-off'), 'role_not_allowed');
  // Only ownerUid makes an owner; a roles entry of 'owner' is a manager.
  assert.equal(await roleOf('uid-coowner'), 'manager');
  assert.equal(await roleOf('uid-admin'), 'manager');
  assert.equal(await roleOf('uid-invited'), 'manager');
  assert.equal(await roleOf('uid-inactive'), 'role_not_allowed');
  assert.equal(await roleOf('uid-other-fac'), 'role_not_allowed');
  assert.equal(await roleOf('uid-expired'), 'role_not_allowed');
  // The highest of the facility doc and user_roles wins.
  assert.equal(await roleOf(VIEWER), 'employee');
});

test('a facility that does not exist is refused without saying so', async () => {
  const { handle } = setup({ gate: { enabledGlobal: true } });
  assert.equal(await reasonOf(guard(handle, OWNER, {}, { facilityId: 'no-such-facility' })), 'role_not_allowed');
});

test('rate limits apply facility-wide and per user', async () => {
  const { handle } = setup();
  const options = { roles: STAFF, rateLimit: { key: 'stays_create', windowSeconds: 60, perFacility: 2, perUser: 1 } };
  assert.equal(await reasonOf(guard(handle, OWNER, options)), null);
  assert.deepEqual(handle.rateLimitKeys, ['stays_create', `stays_create_u_${OWNER}`]);
  // The same user again: over their own limit.
  assert.equal(await reasonOf(guard(handle, OWNER, options)), 'rate_limited');
  // A different user: their own slot, but the facility-wide count is now used up.
  assert.equal(await reasonOf(guard(handle, MANAGER, options)), 'rate_limited');
  // A new window starts over.
  handle.setNow(NOW + 120_000);
  assert.equal(await reasonOf(guard(handle, MANAGER, options)), null);
});

test('employee booking and cash depend on the owner switches, which default off', async () => {
  const off = setup();
  const ctx = await guard(off.handle, EMPLOYEE, { roles: STAFF });
  assert.throws(() => assertEmployeeSetting(ctx, 'employeesCanBook'), (e) => staysErrorReason(e) === 'employee_setting_off');
  assert.throws(() => assertEmployeeSetting(ctx, 'employeesCanRecordCash'), (e) => staysErrorReason(e) === 'employee_setting_off');
  const mgr = await guard(off.handle, MANAGER, { roles: STAFF });
  assert.doesNotThrow(() => assertEmployeeSetting(mgr, 'employeesCanBook'));

  const on = setup({ controls: { employeesCanBook: true } });
  const allowed = await guard(on.handle, EMPLOYEE, { roles: STAFF });
  assert.doesNotThrow(() => assertEmployeeSetting(allowed, 'employeesCanBook'));
  assert.throws(() => assertEmployeeSetting(allowed, 'employeesCanRecordCash'));
});

test('the guard hands back the controls and the facility zone, never a default zone', async () => {
  const { handle } = setup({ facility: { timeZone: 'America/Chicago' }, controls: { timeZone: 'America/Denver' } });
  const ctx = await guard(handle, OWNER);
  assert.equal(ctx.controls.timeZone, 'America/Denver');
  assert.equal(ctx.facilityTimeZone, 'America/Chicago');
  assert.equal(ctx.controls.employeesCanBook, false);
});

test('audit records carry the caller, and a failed audit write never throws', async () => {
  const { handle } = setup();
  const ctx = await guard(handle, OWNER);
  await auditStays(ctx, { eventType: 'stays.stay.created', targetType: 'stay', targetId: 'man_x' });
  assert.equal(handle.audits[0].entry.actorUid, OWNER);
  assert.equal(handle.audits[0].facilityId, FAC);
  ctx.deps.writeAudit = async () => {
    throw new Error('audit down');
  };
  await auditStays(ctx, { eventType: 'stays.stay.created', targetType: 'stay', targetId: 'man_y' });
});

test('a callable never leaks an internal error message', async () => {
  const fn = staysCallable('staysQuote', async () => {
    throw new Error('secret: https://www.airbnb.com/calendar/ical/123.ics?s=abc');
  });
  await assert.rejects(
    (fn as unknown as { run(d: unknown, c: unknown): Promise<unknown> }).run({}, callableContext(OWNER)),
    (e: unknown) =>
      e instanceof functions.https.HttpsError &&
      e.code === 'internal' &&
      staysErrorReason(e) === 'internal' &&
      !e.message.includes('airbnb'),
  );
  const typed = staysCallable('staysQuote', async () => {
    throw new functions.https.HttpsError('not-found', 'No such listing', { reason: 'not_found' });
  });
  await assert.rejects(
    (typed as unknown as { run(d: unknown, c: unknown): Promise<unknown> }).run({}, callableContext(OWNER)),
    (e: unknown) => staysErrorReason(e) === 'not_found',
  );
});

test('the guards never touched a storage-side collection', () => {
  assert.ok(all.length > 0);
  for (const fake of all) fake.assertIsolation();
});

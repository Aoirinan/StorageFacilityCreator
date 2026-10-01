import test from 'node:test';
import assert from 'node:assert/strict';
import { Timestamp } from 'firebase-admin/firestore';

import { handleGetAvailability, handleSetControls } from '../bookings/controls';
import { SEEDED_TEMPLATES, SITE_CHECK_CHECKLIST } from '../bookings/seedDefaults';
import { handleCreateStay } from '../bookings/stays';
import { reconcileTurnovers } from '../tasks/onStayWrite';
import { FakeFirestore } from './support/fakeFirestore';
import { EMPLOYEE, FAC, MANAGER, NOW, OUTSIDER, OWNER, VIEWER, callableContext, makeStay } from './support/staysFixtures';
import { P, as, listingInput, reasonOf, rid, rvInput, seedListing, setupEnv } from './support/bookingFixtures';

const all: FakeFirestore[] = [];

test('availability answers from the gate for any role, and never throws for a paused or unlisted facility', async () => {
  const env = setupEnv(all);
  assert.deepEqual(await as(env, handleGetAvailability, VIEWER, {}), { allowed: true, paused: false, exportAllowed: false });
  assert.deepEqual(await as(env, handleGetAvailability, EMPLOYEE, {}), { allowed: true, paused: false, exportAllowed: false });

  const paused = setupEnv(all, { gate: { killSwitch: true } });
  assert.deepEqual(await as(paused, handleGetAvailability, OWNER, {}), { allowed: false, paused: true, exportAllowed: false });

  const unlisted = setupEnv(all, { gate: { allowlistFacilityIds: ['someone-else'] } });
  assert.deepEqual(await as(unlisted, handleGetAvailability, OWNER, {}), { allowed: false, paused: false, exportAllowed: false });

  // A gate that cannot be read allows nothing.
  const broken = setupEnv(all);
  broken.fake.failReads = (path) => path.startsWith('staysServerConfig');
  assert.deepEqual(await as(broken, handleGetAvailability, OWNER, {}), { allowed: false, paused: false, exportAllowed: false });
});

test('calendar sending can be turned on only for a facility on the export allowlist', async () => {
  // No exportAllowlist field: nobody may turn it on, owner or manager.
  const env = setupEnv(all);
  assert.equal(
    await reasonOf(as(env, handleSetControls, OWNER, { changes: { icalExportEnabled: true } })),
    'not_available_yet',
  );
  assert.equal(
    await reasonOf(as(env, handleSetControls, MANAGER, { changes: { icalExportEnabled: true, icalSyncEnabled: true } })),
    'not_available_yet',
  );
  const untouched = env.fake.read(`${P}/stayControls/current`)!;
  assert.equal(untouched.icalExportEnabled === true, false);
  assert.equal(untouched.icalSyncEnabled === true, false, 'a refused call changes nothing');
  // Turning it off, or sending it unchanged, is always fine.
  assert.equal(await reasonOf(as(env, handleSetControls, OWNER, { changes: { icalExportEnabled: false } })), null);

  // Another facility on the list does not count.
  const other = setupEnv(all, { gate: { exportAllowlist: ['someone-else'] } });
  assert.equal(await reasonOf(as(other, handleSetControls, OWNER, { changes: { icalExportEnabled: true } })), 'not_available_yet');
  assert.deepEqual(await as(other, handleGetAvailability, OWNER, {}), { allowed: true, paused: false, exportAllowed: false });

  const listed = setupEnv(all, { gate: { exportAllowlist: [FAC] } });
  assert.deepEqual(await as(listed, handleGetAvailability, VIEWER, {}), { allowed: true, paused: false, exportAllowed: true });
  const on = await as(listed, handleSetControls, MANAGER, { changes: { icalExportEnabled: true } });
  assert.equal(on.controls.icalExportEnabled, true);
  assert.equal(listed.fake.read(`${P}/stayControls/current`)!.icalExportEnabled, true);

  // The allowlist does not reopen a paused platform.
  const paused = setupEnv(all, { gate: { exportAllowlist: [FAC], killSwitch: true } });
  assert.deepEqual(await as(paused, handleGetAvailability, OWNER, {}), { allowed: false, paused: true, exportAllowed: false });
});

test('availability tells an outsider nothing, and needs sign-in and App Check', async () => {
  const env = setupEnv(all, { gate: { killSwitch: true } });
  assert.equal(await reasonOf(as(env, handleGetAvailability, OUTSIDER, {})), 'role_not_allowed');
  assert.equal(await reasonOf(handleGetAvailability({ facilityId: FAC }, callableContext(null), env.deps)), 'unauthenticated');
  assert.equal(
    await reasonOf(handleGetAvailability({ facilityId: FAC }, callableContext(OWNER, { appCheck: false }), env.deps)),
    'app_check_required',
  );
});

test('availability is limited to 30 calls a minute per user', async () => {
  const env = setupEnv(all);
  for (let i = 0; i < 30; i++) await as(env, handleGetAvailability, VIEWER, {});
  assert.equal(await reasonOf(as(env, handleGetAvailability, VIEWER, {})), 'rate_limited');
  assert.equal(await reasonOf(as(env, handleGetAvailability, OWNER, {})), null);
});

test('Stays cannot be turned on until the zone is chosen and confirmed', async () => {
  const env = setupEnv(all, { controls: null });
  assert.equal(await reasonOf(as(env, handleSetControls, OWNER, { changes: { moduleEnabled: true } })), 'timezone_unconfirmed');
  assert.equal(
    await reasonOf(as(env, handleSetControls, OWNER, { changes: { moduleEnabled: true, timeZone: 'America/Denver' } })),
    'timezone_unconfirmed',
  );
  assert.equal(env.fake.has(`${P}/stayControls/current`), false);
  assert.equal(await reasonOf(as(env, handleSetControls, OWNER, { changes: { timeZone: 'Mountain Time' }, confirmTimeZone: true })), 'invalid_argument');

  const result = await as(env, handleSetControls, OWNER, {
    changes: { moduleEnabled: true, timeZone: 'america/denver', turnoverTasksEnabled: true },
    confirmTimeZone: true,
  });
  assert.equal(result.controls.moduleEnabled, true);
  // Stored in Intl's spelling, with who confirmed it and when.
  assert.equal(result.controls.timeZone, 'America/Denver');
  assert.equal(result.controls.timeZoneConfirmedBy, OWNER);
  assert.equal(typeof result.controls.timeZoneConfirmedAt, 'string');
  const stored = env.fake.read(`${P}/stayControls/current`)!;
  assert.equal(stored.moduleEnabled, true);
  assert.equal(stored.turnoverTasksEnabled, true);
  assert.equal(stored.icalExportEnabled, false);
  assert.equal(stored.version, 1);
  assert.equal(stored.createdBy, OWNER);
});

test('a zone chosen earlier can be confirmed later, and changing it needs a new confirmation', async () => {
  const env = setupEnv(all, { controls: null });
  await as(env, handleSetControls, OWNER, { changes: { timeZone: 'America/Denver' } });
  assert.equal(env.fake.read(`${P}/stayControls/current`)!.timeZoneConfirmedAt, null);
  await as(env, handleSetControls, MANAGER, { changes: { moduleEnabled: true }, confirmTimeZone: true });
  assert.equal(env.fake.read(`${P}/stayControls/current`)!.moduleEnabled, true);

  // While Stays is on, a different zone without confirming it is refused (every date is read in it).
  assert.equal(await reasonOf(as(env, handleSetControls, OWNER, { changes: { timeZone: 'America/Chicago' } })), 'timezone_unconfirmed');
  assert.equal(env.fake.read(`${P}/stayControls/current`)!.timeZone, 'America/Denver');
  await as(env, handleSetControls, OWNER, { changes: { timeZone: 'America/Chicago' }, confirmTimeZone: true });
  assert.equal(env.fake.read(`${P}/stayControls/current`)!.timeZone, 'America/Chicago');
});

test('a zone different from the facility setting warns; the same zone spelled another way does not', async () => {
  const env = setupEnv(all, { controls: null });
  env.fake.seed(`facilities/${FAC}`, { ...env.fake.read(`facilities/${FAC}`)!, timeZone: 'America/Chicago' });
  const r = await as(env, handleSetControls, OWNER, { changes: { moduleEnabled: true, timeZone: 'America/Denver' }, confirmTimeZone: true });
  assert.deepEqual(r.warnings.map((w) => w.code), ['facility_timezone_mismatch']);
  assert.match(r.warnings[0].message, /America\/Chicago/);

  const same = setupEnv(all, { controls: null });
  same.fake.seed(`facilities/${FAC}`, { ...same.fake.read(`facilities/${FAC}`)!, timeZone: 'US/Mountain' });
  const ok = await as(same, handleSetControls, OWNER, { changes: { moduleEnabled: true, timeZone: 'America/Denver' }, confirmTimeZone: true });
  assert.deepEqual(ok.warnings, []);
});

test('guest messaging and card payments are owner-only and not available yet', async () => {
  const env = setupEnv(all);
  assert.equal(await reasonOf(as(env, handleSetControls, OWNER, { changes: { guestMessagingEnabled: true } })), 'not_available_yet');
  assert.equal(await reasonOf(as(env, handleSetControls, OWNER, { changes: { directPaymentsEnabled: true } })), 'not_available_yet');
  assert.equal(await reasonOf(as(env, handleSetControls, MANAGER, { changes: { directPaymentsEnabled: true } })), 'role_not_allowed');
  assert.equal(await reasonOf(as(env, handleSetControls, OWNER, { changes: { guestMessagingEnabled: false } })), null);
  assert.equal(env.fake.read(`${P}/stayControls/current`)!.guestMessagingEnabled, false);
  // A settings screen that saves every field sends them unchanged: fine for a manager too.
  const saved = await as(env, handleSetControls, MANAGER, {
    changes: { guestMessagingEnabled: false, directPaymentsEnabled: false, employeesCanBook: true },
  });
  assert.equal(saved.controls.employeesCanBook, true);
  assert.equal(env.fake.read(`${P}/stayControls/current`)!.directPaymentsEnabled, false);
});

test('turning turnovers on plans a turnover for every booking already made', async () => {
  const env = setupEnv(all, { controls: { turnoverTasksEnabled: false } });
  seedListing(env.fake, 'lst_a', listingInput());
  const booked = await handleCreateStay(
    {
      facilityId: FAC,
      requestId: rid(),
      listingId: 'lst_a',
      checkIn: '2026-10-05',
      checkOut: '2026-10-08',
      kind: 'reservation',
      source: 'direct',
      guest: { displayName: 'Ann A.', adults: 2, children: 0, pets: 0, rvLengthFt: null },
    },
    callableContext(OWNER),
    env.deps,
    null,
  );
  assert.equal(env.fake.has(`${P}/stayTasks/turnover_${booked.stayId}`), false);

  const on = await as(env, handleSetControls, MANAGER, { changes: { turnoverTasksEnabled: true } });
  assert.deepEqual([on.turnovers?.ran, on.turnovers?.created], [true, 1]);
  const task = env.fake.read(`${P}/stayTasks/turnover_${booked.stayId}`)!;
  assert.deepEqual([task.status, task.dueDate, task.stayId], ['todo', '2026-10-08', booked.stayId]);
  // Saving another setting later does not run it again.
  assert.equal((await as(env, handleSetControls, OWNER, { changes: { quietHours: '10pm to 7am' } })).turnovers, null);

  // A new zone re-times every task: checkout at 11:00 is 17:00Z in Denver, 16:00Z in Chicago.
  assert.equal((task.dueStartAt as Timestamp).toDate().toISOString(), '2026-10-08T17:00:00.000Z');
  const moved = await as(env, handleSetControls, OWNER, { changes: { timeZone: 'America/Chicago' }, confirmTimeZone: true });
  assert.equal(moved.turnovers?.updated, 1);
  const retimed = env.fake.read(`${P}/stayTasks/turnover_${booked.stayId}`)!;
  assert.equal((retimed.dueStartAt as Timestamp).toDate().toISOString(), '2026-10-08T16:00:00.000Z');
});

test('turnovers switched on before Stays itself are planned when Stays is turned on', async () => {
  const env = setupEnv(all, { controls: { moduleEnabled: false } });
  seedListing(env.fake, 'lst_a', listingInput());
  // Brought in before the module was on (the CSV import, say).
  env.fake.seed(`${P}/stays/airbnb_HMEARLY001`, makeStay('lst_a', '2026-10-05', '2026-10-08', { source: 'airbnb', origin: 'csv' }) as never);
  assert.equal((await as(env, handleSetControls, OWNER, { changes: { turnoverTasksEnabled: true } })).turnovers, null);
  assert.equal(env.fake.has(`${P}/stayTasks/turnover_airbnb_HMEARLY001`), false);
  const on = await as(env, handleSetControls, OWNER, { changes: { moduleEnabled: true } });
  assert.equal(on.turnovers?.created, 1);
  assert.equal(env.fake.read(`${P}/stayTasks/turnover_airbnb_HMEARLY001`)!.status, 'todo');
});

test('a turnover catch-up that fails after the settings commit does not fail the save; the next catch-up plans them', async () => {
  const env = setupEnv(all, { controls: { turnoverTasksEnabled: false } });
  seedListing(env.fake, 'lst_a', listingInput());
  env.fake.seed(`${P}/stays/man_early`, makeStay('lst_a', '2026-10-05', '2026-10-08') as never);
  // The settings commit; from then on the controls cannot be read, so the catch-up throws.
  env.fake.onBeforeCommit = async () => {
    env.fake.failReads = (path) => path.endsWith('/stayControls/current');
  };
  const on = await as(env, handleSetControls, MANAGER, { changes: { turnoverTasksEnabled: true } });
  assert.deepEqual([on.turnovers, on.controls.turnoverTasksEnabled], [null, true]);
  assert.equal(env.fake.read(`${P}/stayControls/current`)!.turnoverTasksEnabled, true);
  assert.equal(env.fake.has(`${P}/stayTasks/turnover_man_early`), false);
  env.fake.onBeforeCommit = null;
  env.fake.failReads = null;
  assert.equal((await reconcileTurnovers(env.fake.firestore(), FAC, NOW)).created, 1);
});

test('settings are checked: unknown keys, bad values, stale versions, and who may change them', async () => {
  const env = setupEnv(all);
  assert.equal(await reasonOf(as(env, handleSetControls, OWNER, { changes: { autoSendEverything: true } })), 'invalid_argument');
  assert.equal(await reasonOf(as(env, handleSetControls, OWNER, { changes: { paymentMethods: ['cash', 'airbnb'] } })), 'invalid_argument');
  assert.equal(await reasonOf(as(env, handleSetControls, OWNER, { changes: { paymentMethods: [] } })), 'invalid_argument');
  assert.equal(await reasonOf(as(env, handleSetControls, OWNER, { changes: { employeesCanBook: 'yes' } })), 'invalid_argument');
  assert.equal(await reasonOf(as(env, handleSetControls, OWNER, { changes: { defaultCheckInTime: '3pm' } })), 'invalid_argument');
  assert.equal(await reasonOf(as(env, handleSetControls, OWNER, { changes: { dailyBriefLocalHour: 24 } })), 'invalid_argument');
  assert.equal(await reasonOf(as(env, handleSetControls, OWNER, { changes: { employeesCanBook: true }, expectedVersion: 7 })), 'version_mismatch');
  assert.equal(await reasonOf(as(env, handleSetControls, EMPLOYEE, { changes: { employeesCanBook: true } })), 'role_not_allowed');
  assert.equal(await reasonOf(as(env, handleSetControls, VIEWER, { changes: {} })), 'role_not_allowed');

  const ok = await as(env, handleSetControls, MANAGER, {
    changes: { employeesCanBook: true, paymentMethods: ['cash', 'venmo'], quietHours: '10pm–7am' },
    expectedVersion: 1,
  });
  assert.equal(ok.controls.employeesCanBook, true);
  assert.deepEqual(ok.controls.paymentMethods, ['cash', 'venmo']);
  assert.equal(ok.controls.version, 2);
  assert.equal(env.handle.audits[env.handle.audits.length - 1]?.entry.eventType, 'stays.controls.updated');
});

test('the gate still applies: a facility not on the allowlist cannot even set up', async () => {
  const env = setupEnv(all, { controls: null, gate: { allowlistFacilityIds: [] } });
  assert.equal(
    await reasonOf(as(env, handleSetControls, OWNER, { changes: { timeZone: 'America/Denver' }, confirmTimeZone: true })),
    'module_not_available',
  );
});

test('the first turn-on seeds the message templates and empty checklists, once', async () => {
  const env = setupEnv(all, { controls: null });
  seedListing(env.fake, 'lst_house', listingInput({ turnover: { ...listingInput().turnover, checklistTemplate: [] } }));
  seedListing(env.fake, 'lst_rv1', rvInput(1, { turnover: { ...rvInput(1).turnover, checklistTemplate: [] } }));
  seedListing(env.fake, 'lst_mine', rvInput(2)); // has its own checklist: left alone
  // A template she already wrote under a seeded key is left alone.
  env.fake.seed(`${P}/stayMessageTemplates/thank_you`, { facilityId: FAC, key: 'thank_you', name: 'Mine', body: 'Thanks!', kind: 'copy', seeded: false });

  const first = await as(env, handleSetControls, OWNER, { changes: { moduleEnabled: true, timeZone: 'America/Denver' }, confirmTimeZone: true });
  const templates = env.fake.list(`${P}/stayMessageTemplates`);
  assert.equal(templates.length, SEEDED_TEMPLATES.length);
  assert.deepEqual(first.seededTemplateKeys.sort(), SEEDED_TEMPLATES.map((t) => t.key).filter((k) => k !== 'thank_you').sort());
  const checkIn = env.fake.read(`${P}/stayMessageTemplates/airbnb_check_in`)!;
  assert.equal(checkIn.kind, 'copy');
  assert.equal(checkIn.seeded, true);
  assert.equal('autoSend' in checkIn, false);
  assert.match(checkIn.body as string, /\{\{doorCode\}\}/);
  assert.equal(env.fake.read(`${P}/stayMessageTemplates/thank_you`)!.body, 'Thanks!');
  assert.ok(first.controls.templatesSeededAt);

  const house = env.fake.read(`${P}/stayListings/lst_house`)!;
  assert.ok(((house.turnover as { checklistTemplate: unknown[] }).checklistTemplate).length >= 8);
  assert.equal(house.version, 2);
  assert.deepEqual((env.fake.read(`${P}/stayListings/lst_rv1`)!.turnover as { checklistTemplate: unknown }).checklistTemplate, SITE_CHECK_CHECKLIST);
  assert.equal(env.fake.read(`${P}/stayListings/lst_mine`)!.version, 1);

  // Off and on again: nothing is seeded a second time, and a template she deleted stays deleted.
  await env.fake.firestore().doc(`${P}/stayMessageTemplates/rv_welcome`).delete();
  await as(env, handleSetControls, OWNER, { changes: { moduleEnabled: false } });
  const templateWrites = env.fake.writesTo('stayMessageTemplates').length;
  const again = await as(env, handleSetControls, OWNER, { changes: { moduleEnabled: true } });
  assert.deepEqual(again.seededTemplateKeys, []);
  assert.equal(env.fake.writesTo('stayMessageTemplates').length, templateWrites);
  assert.equal(env.fake.has(`${P}/stayMessageTemplates/rv_welcome`), false);
});

test('controls never touched a storage-side collection', () => {
  assert.ok(all.length > 0);
  for (const fake of all) fake.assertIsolation();
});

// Stays (short-term rentals) security rules (spec §4, §10.4). Its own
// project id keeps it from clashing with firestore.rules.test.mjs, which
// runs in parallel against the same emulator.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import { serverTimestamp } from 'firebase/firestore';
import { deleteObject, getBytes, ref as storageRef, uploadBytes } from 'firebase/storage';

const __dirname = dirname(fileURLToPath(import.meta.url));
const rules = readFileSync(join(__dirname, '..', '..', 'firestore.rules'), 'utf8');
const storageRules = readFileSync(join(__dirname, '..', '..', 'storage.rules'), 'utf8');

const PROJECT_ID = 'sfc-rules-test-stays';
const FAC = 'fac-stays-1';
const OWNER = 'stays-owner';
const MANAGER = 'stays-manager';
const EMPLOYEE = 'stays-employee';
const EMPLOYEE2 = 'stays-employee-2';
const VIEWER = 'stays-viewer';
const OUTSIDER = 'stays-outsider';

function hostPort(envName, fallback) {
  const [host, port] = (process.env[envName] || fallback).split(':');
  return { host, port: Number(port) };
}

/** @type {import('@firebase/rules-unit-testing').RulesTestEnvironment} */
let testEnv;

test.before(async () => {
  const firestore = hostPort('FIRESTORE_EMULATOR_HOST', 'localhost:8080');
  const storage = hostPort('FIREBASE_STORAGE_EMULATOR_HOST', 'localhost:9199');
  testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: { rules, host: firestore.host, port: firestore.port },
    storage: { rules: storageRules, host: storage.host, port: storage.port },
  });
});

test.after(async () => {
  await testEnv?.cleanup();
});

test.beforeEach(async () => {
  await testEnv.clearFirestore();
  await seed();
});

/** One seeded doc per stay collection, by collection name. */
const DOCS = {
  stayControls: 'stayControls/current',
  stayListings: 'stayListings/lst1',
  stayListingAccess: 'stayListingAccess/lst1',
  stayChannels: 'stayChannels/ch1',
  stayChannelBlocks: 'stayChannelBlocks/ch1',
  stayExportLinks: 'stayExportLinks/xl1',
  staySyncLog: 'staySyncLog/run1',
  stays: 'stays/s1',
  stayPrivate: 'stayPrivate/s1',
  stayAccess: 'stayAccess/s1',
  stayFolios: 'stayFolios/s1',
  stayNightLocks: 'stayNightLocks/lst1_2026-10',
  stayTasks: 'stayTasks/t_unassigned',
  stayIncome: 'stayIncome/man_e1',
  stayExpenses: 'stayExpenses/exp_x1',
  stayImportBatches: 'stayImportBatches/b1',
  stayGuestProfiles: 'stayGuestProfiles/gp1',
  stayMessageTemplates: 'stayMessageTemplates/tpl1',
};

const VIEWER_READABLE = ['stays', 'stayListings', 'stayNightLocks', 'stayChannelBlocks', 'stayTasks', 'stayControls'];
const VIEWER_DENIED = [
  'stayPrivate',
  'stayAccess',
  'stayListingAccess',
  'stayFolios',
  'stayIncome',
  'stayExpenses',
  'stayChannels',
  'stayExportLinks',
  'stayGuestProfiles',
  'stayMessageTemplates',
  'staySyncLog',
  'stayImportBatches',
];

function stayDoc(overrides = {}) {
  return {
    facilityId: FAC,
    listingId: 'lst1',
    listingName: 'Airbnb 1',
    listingGroup: 'Airbnbs',
    listingKind: 'vacation_rental',
    kind: 'reservation',
    source: 'airbnb',
    origin: 'feed',
    status: 'confirmed',
    arrivalState: 'upcoming',
    checkIn: '2026-10-03',
    checkOut: '2026-10-06',
    nights: 3,
    checkInTime: '15:00',
    checkOutTime: '11:00',
    guestDisplayName: 'Jane D.',
    adults: 2,
    children: 0,
    pets: 0,
    rvLengthFt: null,
    paymentStatus: 'channel_collected',
    staffNotes: '',
    cleanerNotes: '',
    tags: [],
    messageMarks: {},
    checkedInAt: null,
    checkedOutAt: null,
    version: 1,
    createdAtMs: 1,
    ...overrides,
  };
}

function taskDoc(overrides = {}) {
  return {
    facilityId: FAC,
    category: 'turnover',
    listingId: 'lst1',
    stayId: 's1',
    title: 'Turnover Airbnb 1',
    notes: '',
    dueDate: '2026-10-06',
    status: 'todo',
    needsAttention: false,
    assigneeUid: null,
    assigneeName: null,
    checklist: [{ id: 'c1', label: 'Towels', done: false, doneAt: null, doneBy: null }],
    suppliesLow: [],
    issueNote: '',
    photoPaths: [],
    priority: 'normal',
    createdBy: 'system:stays-trigger',
    ...overrides,
  };
}

async function seed() {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    const fac = facilityScope(db);
    await db.collection('facilities').doc(FAC).set({
      name: 'Test Park',
      ownerUid: OWNER,
      roles: { [OWNER]: 'owner', [MANAGER]: 'manager', [EMPLOYEE]: 'employee', [EMPLOYEE2]: 'employee', [VIEWER]: 'viewer' },
    });
    const set = (path, data) => fac.doc(path).set({ facilityId: FAC, ...data });
    await set(DOCS.stayControls, { moduleEnabled: true, timeZone: 'America/Denver', version: 1 });
    await set(DOCS.stayListings, { name: 'Airbnb 1', kind: 'vacation_rental', active: true });
    await set(DOCS.stayListingAccess, { listingId: 'lst1', wifiName: 'Test Park', wifiPassword: 'secret', staticDoorCode: '1234' });
    await set(DOCS.stayChannels, { listingId: 'lst1', provider: 'airbnb', urlHost: 'www.airbnb.com' });
    await fac.doc('stayChannels/ch1/secret/current').set({ url: 'https://www.airbnb.com/calendar/ical/1.ics?s=abc' });
    await set(DOCS.stayChannelBlocks, { listingId: 'lst1', provider: 'airbnb', ranges: [] });
    await set(DOCS.stayExportLinks, { listingId: 'lst1', targetProvider: 'airbnb', scope: 'blocks_only', active: true });
    await fac.doc('stayExportLinks/xl1/secret/current').set({ token: 'a'.repeat(48) });
    await set(DOCS.staySyncLog, { channelId: 'ch1', status: 'ok' });
    await set(DOCS.stays, stayDoc());
    await set('stays/blk1', stayDoc({ kind: 'owner_block', source: 'owner', origin: 'sfc', guestDisplayName: '' }));
    await set('stays/cx1', stayDoc({ status: 'cancelled' }));
    await set('stays/in1', stayDoc({ arrivalState: 'checked_in', checkedInAt: serverTimestamp() }));
    await set('stays/out1', stayDoc({ arrivalState: 'checked_out', checkedInAt: serverTimestamp(), checkedOutAt: serverTimestamp() }));
    await set('stays/cxin1', stayDoc({ status: 'cancelled', arrivalState: 'checked_in', checkedInAt: serverTimestamp() }));
    await set(DOCS.stayPrivate, { stayId: 's1', guestProfileId: null, fullName: null, phoneLast4: '1234', privateNotes: '' });
    await set(DOCS.stayAccess, { stayId: 's1', doorCode: '1234', gateCode: null, accessNotes: '', source: 'phone_last4' });
    await set(DOCS.stayFolios, { stayId: 's1', totalCents: 45000, paidCents: 0, balanceCents: 45000 });
    await set(DOCS.stayNightLocks, { listingId: 'lst1', month: '2026-10', nights: {}, digest: 'x' });
    await set(DOCS.stayTasks, taskDoc());
    await set('stayTasks/t_mine', taskDoc({ assigneeUid: EMPLOYEE, assigneeName: 'Emp' }));
    await set('stayTasks/t_other', taskDoc({ assigneeUid: EMPLOYEE2, assigneeName: 'Other' }));
    await set('stayTasks/t_cancelled', taskDoc({ status: 'cancelled' }));
    await set('stayTasks/t_done', taskDoc({ status: 'done', completedBy: EMPLOYEE, completedAt: serverTimestamp() }));
    await set(DOCS.stayIncome, { grossCents: 5000, netCents: 5000, status: 'posted', countsAsIncome: true });
    await set(DOCS.stayExpenses, { amountCents: 2500, status: 'posted' });
    await set(DOCS.stayImportBatches, { kind: 'airbnb_earnings', status: 'committed' });
    await set(DOCS.stayGuestProfiles, {
      name: 'Jane Doe',
      nameLower: 'jane doe',
      phoneE164: null,
      email: null,
      vehicle: null,
      notes: '',
      doNotRent: false,
      doNotRentReason: null,
      consent: null,
      stayCount: 2,
      lastStayAt: null,
      createdBy: OWNER,
    });
    await set(DOCS.stayMessageTemplates, {
      key: 'airbnb_check_in',
      name: 'Check-in instructions',
      body: 'Hi {{guestFirstName}}!',
      channelHint: 'airbnb_paste',
      listingIds: [],
      kind: 'copy',
      seeded: true,
    });
    await db.collection('staysServerConfig').doc('current').set({ killSwitch: false, enabledGlobal: false, allowlistFacilityIds: [FAC] });
    await db.collection('staySyncJobs').doc(`2026-10-01T18:00_${FAC}`).set({ facilityId: FAC, status: 'pending' });
    await db.collection('stayCalendarExportTokens').doc('b'.repeat(64)).set({ facilityId: FAC, linkId: 'xl1', active: true });
  });
}

/** Paths relative to facilities/{FAC}. */
function facilityScope(db) {
  return {
    doc: (path) => db.doc(`facilities/${FAC}/${path}`),
    collection: (name) => db.collection(`facilities/${FAC}/${name}`),
  };
}

function as(uid, claims) {
  return facilityScope(testEnv.authenticatedContext(uid, claims).firestore());
}

function stamp(uid) {
  return { updatedAt: serverTimestamp(), updatedBy: uid };
}

// --- Who can read what -------------------------------------------------------

test('outsiders are denied on every stay collection', async () => {
  const outsider = as(OUTSIDER);
  for (const path of [...Object.values(DOCS), 'stays/blk1']) {
    await assertFails(outsider.doc(path).get());
    await assertFails(outsider.doc(path).set({ facilityId: FAC }));
  }
  await assertFails(outsider.collection('stays').get());
  const anon = facilityScope(testEnv.unauthenticatedContext().firestore());
  await assertFails(anon.doc(DOCS.stays).get());
});

test('viewers read the calendar side and nothing personal, secret or money', async () => {
  const viewer = as(VIEWER);
  for (const name of VIEWER_READABLE) await assertSucceeds(viewer.doc(DOCS[name]).get());
  for (const name of VIEWER_DENIED) await assertFails(viewer.doc(DOCS[name]).get());
  // Nor can they edit a stay.
  await assertFails(viewer.doc(DOCS.stays).update({ staffNotes: 'hi', ...stamp(VIEWER) }));
});

test('nobody reads a channel feed URL or a raw export token, the owner and super admin included', async () => {
  for (const db of [as(OWNER), as(MANAGER), as('super', { superadmin: true })]) {
    await assertFails(db.doc('stayChannels/ch1/secret/current').get());
    await assertFails(db.doc('stayExportLinks/xl1/secret/current').get());
    await assertFails(db.doc('stayChannels/ch1/secret/current').set({ url: 'https://evil.example' }));
  }
  // The metadata itself is owner/manager readable.
  await assertSucceeds(as(MANAGER).doc(DOCS.stayChannels).get());
  await assertFails(as(EMPLOYEE).doc(DOCS.stayChannels).get());
});

test('the top-level Stays collections are denied to everyone, the owner included', async () => {
  for (const uidClaims of [[OWNER], ['super', { superadmin: true }]]) {
    const db = testEnv.authenticatedContext(...uidClaims).firestore();
    await assertFails(db.collection('staysServerConfig').doc('current').get());
    await assertFails(db.collection('staysServerConfig').doc('current').set({ killSwitch: false, enabledGlobal: true }));
    await assertFails(db.collection('staySyncJobs').doc(`2026-10-01T18:00_${FAC}`).get());
    await assertFails(db.collection('staySyncJobs').doc('x').set({ facilityId: FAC }));
    await assertFails(db.collection('stayCalendarExportTokens').doc('b'.repeat(64)).get());
    await assertFails(db.collection('stayCalendarExportTokens').doc('c'.repeat(64)).set({ active: true }));
  }
});

// --- Stays ------------------------------------------------------------------

test('employees make quick edits to a stay', async () => {
  const stay = as(EMPLOYEE).doc(DOCS.stays);
  await assertSucceeds(stay.update({ guestDisplayName: 'Jane D.', staffNotes: 'Late arrival', adults: 3, ...stamp(EMPLOYEE) }));
  await assertSucceeds(stay.update({ messageMarks: { airbnb_check_in: serverTimestamp() }, ...stamp(EMPLOYEE) }));
  // Stamped by someone else, or without the server time: refused.
  await assertFails(stay.update({ staffNotes: 'x', updatedAt: serverTimestamp(), updatedBy: MANAGER }));
  await assertFails(stay.update({ staffNotes: 'x', updatedAt: new Date('2020-01-01'), updatedBy: EMPLOYEE }));
  // Values are bounded.
  await assertFails(stay.update({ guestDisplayName: 'x'.repeat(61), ...stamp(EMPLOYEE) }));
  await assertFails(stay.update({ adults: 51, ...stamp(EMPLOYEE) }));
  await assertFails(stay.update({ rvLengthFt: 'long', ...stamp(EMPLOYEE) }));
  await assertFails(stay.update({ tags: Array.from({ length: 11 }, (_, i) => `t${i}`), ...stamp(EMPLOYEE) }));
});

test('employees check guests in and out, stamped with the server time', async () => {
  const stay = as(EMPLOYEE).doc(DOCS.stays);
  await assertFails(stay.update({ arrivalState: 'checked_in', checkedInAt: new Date('2026-10-03T21:00:00Z'), ...stamp(EMPLOYEE) }));
  await assertSucceeds(stay.update({ arrivalState: 'checked_in', checkedInAt: serverTimestamp(), ...stamp(EMPLOYEE) }));
  // Skipping a step, or changing the check-in time on the way out, is refused.
  await assertFails(stay.update({ arrivalState: 'checked_out', checkedOutAt: serverTimestamp(), checkedInAt: serverTimestamp(), ...stamp(EMPLOYEE) }));
  await assertSucceeds(stay.update({ arrivalState: 'checked_out', checkedOutAt: serverTimestamp(), ...stamp(EMPLOYEE) }));
});

test('employees cannot undo, move, re-status, create or delete stays', async () => {
  const employee = as(EMPLOYEE);
  const checkedIn = employee.doc('stays/in1');
  await assertFails(checkedIn.update({ arrivalState: 'upcoming', checkedInAt: null, ...stamp(EMPLOYEE) }));
  const stay = employee.doc(DOCS.stays);
  await assertFails(stay.update({ checkIn: '2026-10-04', ...stamp(EMPLOYEE) }));
  await assertFails(stay.update({ checkOut: '2026-10-09', ...stamp(EMPLOYEE) }));
  await assertFails(stay.update({ listingId: 'lst2', ...stamp(EMPLOYEE) }));
  await assertFails(stay.update({ status: 'cancelled', ...stamp(EMPLOYEE) }));
  await assertFails(stay.update({ version: 9, ...stamp(EMPLOYEE) }));
  await assertFails(stay.update({ paymentStatus: 'paid', ...stamp(EMPLOYEE) }));
  await assertFails(stay.delete());
  await assertFails(employee.doc('stays/new1').set(stayDoc()));
  // Blocks and cancelled stays cannot be checked in.
  await assertFails(employee.doc('stays/blk1').update({ arrivalState: 'checked_in', checkedInAt: serverTimestamp(), ...stamp(EMPLOYEE) }));
  await assertFails(employee.doc('stays/cx1').update({ arrivalState: 'checked_in', checkedInAt: serverTimestamp(), ...stamp(EMPLOYEE) }));
});

test('tags and message marks are bounded element by element', async () => {
  const stay = as(EMPLOYEE).doc(DOCS.stays);
  await assertSucceeds(stay.update({ tags: ['late arrival', 'pets'], ...stamp(EMPLOYEE) }));
  await assertFails(stay.update({ tags: [{ big: 'x'.repeat(5000) }], ...stamp(EMPLOYEE) }));
  await assertFails(stay.update({ tags: [new Date()], ...stamp(EMPLOYEE) }));
  await assertFails(stay.update({ tags: ['x|'.repeat(300)], ...stamp(EMPLOYEE) }));
  await assertSucceeds(stay.update({ tags: Array.from({ length: 10 }, (_, i) => 't'.repeat(40 - i)), ...stamp(EMPLOYEE) }));
  await assertFails(stay.update({ tags: ['x'.repeat(41)], ...stamp(EMPLOYEE) }));
  await assertFails(stay.update({ tags: [''], ...stamp(EMPLOYEE) }));
  // A mark is this request's time under a template key; nothing else.
  await assertSucceeds(stay.update({ messageMarks: { airbnb_check_in: serverTimestamp() }, ...stamp(EMPLOYEE) }));
  await assertSucceeds(stay.update({ messageMarks: { airbnb_check_in: serverTimestamp(), checkout: serverTimestamp() }, ...stamp(EMPLOYEE) }));
  await assertFails(stay.update({ messageMarks: { note: 'x'.repeat(5000) }, ...stamp(EMPLOYEE) }));
  await assertFails(stay.update({ messageMarks: { checkout: new Date('2026-01-01') }, ...stamp(EMPLOYEE) }));
  await assertFails(stay.update({ messageMarks: { 'Bad Key!': serverTimestamp() }, ...stamp(EMPLOYEE) }));
});

test('check-out needs a stay that still holds its nights', async () => {
  const employee = as(EMPLOYEE);
  await assertFails(employee.doc('stays/cxin1').update({ arrivalState: 'checked_out', checkedOutAt: serverTimestamp(), ...stamp(EMPLOYEE) }));
  await assertFails(as(MANAGER).doc('stays/cxin1').update({ arrivalState: 'checked_out', checkedOutAt: serverTimestamp(), ...stamp(MANAGER) }));
  await assertSucceeds(employee.doc('stays/in1').update({ arrivalState: 'checked_out', checkedOutAt: serverTimestamp(), ...stamp(EMPLOYEE) }));
});

test('an undo clears its time: anything else in checkedInAt or checkedOutAt is refused', async () => {
  const manager = as(MANAGER);
  await assertFails(manager.doc('stays/in1').update({ arrivalState: 'upcoming', checkedInAt: 'yesterday', ...stamp(MANAGER) }));
  await assertFails(manager.doc('stays/in1').update({ arrivalState: 'upcoming', checkedInAt: new Date('2026-01-01'), ...stamp(MANAGER) }));
  await assertFails(manager.doc('stays/in1').update({ arrivalState: 'upcoming', ...stamp(MANAGER) }));
  await assertFails(manager.doc('stays/out1').update({ arrivalState: 'checked_in', checkedOutAt: 'later', ...stamp(MANAGER) }));
  await assertFails(manager.doc('stays/out1').update({ arrivalState: 'checked_in', checkedOutAt: null, checkedInAt: null, ...stamp(MANAGER) }));
  await assertSucceeds(manager.doc('stays/out1').update({ arrivalState: 'checked_in', checkedOutAt: null, ...stamp(MANAGER) }));
});

test('owners and managers may undo a check-in, but still cannot create, delete or re-date stays', async () => {
  const manager = as(MANAGER);
  await assertSucceeds(manager.doc('stays/in1').update({ arrivalState: 'upcoming', checkedInAt: null, ...stamp(MANAGER) }));
  await assertFails(manager.doc(DOCS.stays).update({ checkIn: '2026-10-04', ...stamp(MANAGER) }));
  await assertFails(manager.doc('stays/new1').set(stayDoc()));
  await assertFails(as(OWNER).doc(DOCS.stays).delete());
});

test('private stay details are owner/manager only, and fullName may stay null', async () => {
  await assertFails(as(EMPLOYEE).doc(DOCS.stayPrivate).get());
  const priv = as(MANAGER).doc(DOCS.stayPrivate);
  await assertSucceeds(priv.get());
  await assertSucceeds(priv.update({ privateNotes: 'Regular guest', ...stamp(MANAGER) }));
  await assertSucceeds(priv.update({ fullName: 'Jane Doe', ...stamp(MANAGER) }));
  await assertFails(priv.update({ phoneLast4: '9999', ...stamp(MANAGER) }));
  await assertFails(priv.update({ guestProfileId: 'gp9', ...stamp(MANAGER) }));
  await assertFails(priv.update({ fullName: 'x'.repeat(121), ...stamp(MANAGER) }));
  await assertFails(as(OWNER).doc('stayPrivate/new').set({ fullName: 'x', ...stamp(OWNER) }));
});

test('staff read door codes; only owners and managers write them', async () => {
  await assertSucceeds(as(EMPLOYEE).doc(DOCS.stayAccess).get());
  await assertSucceeds(as(EMPLOYEE).doc(DOCS.stayListingAccess).get());
  await assertFails(as(EMPLOYEE).doc(DOCS.stayAccess).update({ doorCode: '0000', ...stamp(EMPLOYEE) }));
  await assertFails(as(EMPLOYEE).doc(DOCS.stayListingAccess).update({ wifiPassword: 'x', ...stamp(EMPLOYEE) }));

  const access = as(MANAGER).doc('stayAccess/s2');
  const base = { facilityId: FAC, stayId: 's2', doorCode: null, gateCode: null, accessNotes: '', source: 'manual', ...stamp(MANAGER) };
  await assertSucceeds(access.set(base));
  await assertSucceeds(access.set({ ...base, doorCode: '4821' }));
  await assertFails(access.set({ ...base, doorCode: 'x'.repeat(41) }));
  await assertFails(access.set({ ...base, stayId: 'other' }));
  await assertFails(access.set({ ...base, phone: '5551234' }));
  await assertFails(access.set({ ...base, source: 'guess' }));
  await assertSucceeds(access.delete());
});

// --- Listings, controls, money: callables only ---------------------------------

test('managers cannot write controls, listings, locks, income, folios or channels', async () => {
  const manager = as(MANAGER);
  await assertFails(manager.doc(DOCS.stayControls).update({ moduleEnabled: false }));
  await assertFails(manager.doc(DOCS.stayListings).update({ name: 'Renamed' }));
  await assertFails(manager.doc('stayListings/new').set({ facilityId: FAC, name: 'New' }));
  await assertFails(manager.doc(DOCS.stayNightLocks).update({ nights: {} }));
  await assertFails(manager.doc(DOCS.stayIncome).update({ status: 'voided' }));
  await assertFails(manager.doc('stayIncome/man_new').set({ facilityId: FAC, grossCents: 100 }));
  await assertFails(manager.doc(DOCS.stayFolios).update({ paidCents: 45000 }));
  await assertFails(manager.doc(DOCS.stayChannels).update({ active: false }));
  await assertFails(manager.doc(DOCS.stayChannelBlocks).update({ ranges: [] }));
  await assertFails(manager.doc(DOCS.stayExportLinks).update({ scope: 'all' }));
  await assertFails(manager.doc(DOCS.stayExpenses).update({ status: 'voided' }));
  await assertFails(manager.doc(DOCS.stayImportBatches).delete());
  // But they read the money.
  await assertSucceeds(manager.doc(DOCS.stayIncome).get());
  await assertSucceeds(manager.doc(DOCS.stayFolios).get());
  await assertFails(as(EMPLOYEE).doc(DOCS.stayIncome).get());
});

test('managers write listing access with whitelisted keys only', async () => {
  const access = as(MANAGER).doc('stayListingAccess/lst2');
  const base = {
    facilityId: FAC,
    listingId: 'lst2',
    wifiName: 'Test Park Guest',
    wifiPassword: 'riverside',
    staticDoorCode: '4821',
    lockboxCode: '',
    gateCode: '',
    parkingNotes: '',
    trashNotes: '',
    checkoutInstructions: '',
    directionsUrl: '',
    houseRules: 'No parties.',
    ...stamp(MANAGER),
  };
  await assertSucceeds(access.set(base));
  await assertFails(access.set({ ...base, alarmCode: '9999' }));
  await assertFails(access.set({ ...base, staticDoorCode: 'x'.repeat(41) }));
  await assertFails(access.set({ ...base, listingId: 'lst9' }));
  await assertFails(access.set({ ...base, updatedBy: OWNER }));
  await assertFails(access.delete());
});

// --- Tasks ---------------------------------------------------------------------

test('employees work unassigned tasks and their own, with the allowed keys only', async () => {
  const employee = as(EMPLOYEE);
  await assertSucceeds(employee.doc(DOCS.stayTasks).update({ status: 'in_progress', startedAt: serverTimestamp(), ...stamp(EMPLOYEE) }));
  const mine = employee.doc('stayTasks/t_mine');
  await assertSucceeds(
    mine.update({
      checklist: [{ id: 'c1', label: 'Towels', done: true, doneAt: null, doneBy: EMPLOYEE }],
      suppliesLow: ['towels'],
      issueNote: 'Lamp broken',
      photoPaths: [`facilities/${FAC}/stayTaskPhotos/t_mine/p1.jpg`],
      ...stamp(EMPLOYEE),
    }),
  );
  await assertSucceeds(mine.update({ status: 'done', completedAt: serverTimestamp(), completedBy: EMPLOYEE, ...stamp(EMPLOYEE) }));

  // Someone else's task, assigning, other people's names on "done", other statuses.
  await assertFails(employee.doc('stayTasks/t_other').update({ issueNote: 'x', ...stamp(EMPLOYEE) }));
  await assertFails(employee.doc(DOCS.stayTasks).update({ assigneeUid: EMPLOYEE, ...stamp(EMPLOYEE) }));
  await assertFails(employee.doc(DOCS.stayTasks).update({ title: 'Renamed', ...stamp(EMPLOYEE) }));
  await assertFails(employee.doc(DOCS.stayTasks).update({ status: 'done', completedBy: EMPLOYEE2, completedAt: serverTimestamp(), ...stamp(EMPLOYEE) }));
  await assertFails(employee.doc(DOCS.stayTasks).update({ status: 'cancelled', ...stamp(EMPLOYEE) }));
  await assertFails(employee.doc('stayTasks/t_cancelled').update({ status: 'todo', ...stamp(EMPLOYEE) }));
  await assertFails(employee.doc(DOCS.stayTasks).update({ photoPaths: Array.from({ length: 11 }, (_, i) => `p${i}`), ...stamp(EMPLOYEE) }));
  await assertFails(employee.doc('stayTasks/new').set(taskDoc({ category: 'general', createdBy: EMPLOYEE, createdAt: serverTimestamp(), ...stamp(EMPLOYEE) })));
  await assertFails(employee.doc(DOCS.stayTasks).delete());
  await assertFails(as(VIEWER).doc(DOCS.stayTasks).update({ status: 'in_progress', ...stamp(VIEWER) }));
});

test('completion is signed and timed only as a task becomes done', async () => {
  const employee = as(EMPLOYEE);
  // Rewriting who finished a done task, or when.
  await assertFails(employee.doc('stayTasks/t_done').update({ completedBy: EMPLOYEE2, ...stamp(EMPLOYEE) }));
  await assertFails(employee.doc('stayTasks/t_done').update({ completedAt: serverTimestamp(), ...stamp(EMPLOYEE) }));
  // Signing a task that is not being finished.
  await assertFails(employee.doc('stayTasks/t_mine').update({ completedBy: EMPLOYEE, completedAt: serverTimestamp(), ...stamp(EMPLOYEE) }));
  // Finishing with a backdated time, or without one.
  await assertFails(
    employee.doc('stayTasks/t_mine').update({ status: 'done', completedBy: EMPLOYEE, completedAt: new Date('2026-01-01'), ...stamp(EMPLOYEE) }),
  );
  await assertFails(employee.doc('stayTasks/t_mine').update({ status: 'done', completedBy: EMPLOYEE, ...stamp(EMPLOYEE) }));
  // Starting with a backdated time.
  await assertFails(employee.doc('stayTasks/t_mine').update({ status: 'in_progress', startedAt: new Date('2026-01-01'), ...stamp(EMPLOYEE) }));
  // Reopening may clear the signature, not change it.
  await assertFails(employee.doc('stayTasks/t_done').update({ status: 'todo', completedBy: EMPLOYEE2, ...stamp(EMPLOYEE) }));
  await assertSucceeds(employee.doc('stayTasks/t_done').update({ status: 'todo', completedBy: null, completedAt: null, ...stamp(EMPLOYEE) }));
  await assertFails(as(MANAGER).doc('stayTasks/t_other').update({ completedBy: MANAGER, ...stamp(MANAGER) }));
});

test('managers assign tasks and create manual ones, but not automatic turnovers', async () => {
  const manager = as(MANAGER);
  await assertSucceeds(manager.doc(DOCS.stayTasks).update({ assigneeUid: EMPLOYEE, assigneeName: 'Emp', priority: 'high', ...stamp(MANAGER) }));
  await assertFails(manager.doc('stayTasks/t_other').update({ status: 'done', completedBy: EMPLOYEE2, ...stamp(MANAGER) }));
  await assertFails(manager.doc(DOCS.stayTasks).update({ stayId: 's9', ...stamp(MANAGER) }));
  const manual = taskDoc({ category: 'maintenance', stayId: null, createdBy: MANAGER, createdAt: serverTimestamp(), ...stamp(MANAGER) });
  await assertSucceeds(manager.doc('stayTasks/manual1').set(manual));
  await assertFails(manager.doc('stayTasks/turnover_s9').set(manual));
  await assertFails(manager.doc('stayTasks/manual2').set({ ...manual, category: 'turnover' }));
  await assertFails(manager.doc('stayTasks/manual3').set({ ...manual, createdBy: OWNER }));
  // Manual tasks carry task keys only, a real date and no premade signature.
  await assertFails(manager.doc('stayTasks/manual4').set({ ...manual, payload: 'x'.repeat(1000) }));
  await assertFails(manager.doc('stayTasks/manual5').set({ ...manual, plannedDigest: 'abc' }));
  await assertFails(manager.doc('stayTasks/manual6').set({ ...manual, dueDate: 'tomorrow' }));
  await assertFails(manager.doc('stayTasks/manual7').set({ ...manual, dueDate: 20261006 }));
  await assertFails(manager.doc('stayTasks/manual8').set({ ...manual, completedBy: MANAGER, completedAt: serverTimestamp() }));
  await assertFails(manager.doc('stayTasks/manual9').set({ ...manual, title: 'x'.repeat(121) }));
  await assertSucceeds(
    manager.doc('stayTasks/manual10').set({ ...manual, status: 'done', completedBy: MANAGER, completedAt: serverTimestamp() }),
  );
  await assertFails(manager.doc(DOCS.stayTasks).delete());
});

// --- Templates and guests -----------------------------------------------------

test('templates are copy-only: no autoSend key, kind must be copy', async () => {
  const manager = as(MANAGER);
  const tpl = {
    facilityId: FAC,
    key: 'checkout_reminder',
    name: 'Checkout reminder',
    body: 'Checkout is {{checkOutTime}}.',
    channelHint: 'sms',
    listingIds: [],
    kind: 'copy',
    seeded: false,
    createdAt: serverTimestamp(),
    createdBy: MANAGER,
    ...stamp(MANAGER),
  };
  await assertSucceeds(manager.doc('stayMessageTemplates/tpl2').set(tpl));
  await assertFails(manager.doc('stayMessageTemplates/tpl3').set({ ...tpl, autoSend: true }));
  await assertFails(manager.doc('stayMessageTemplates/tpl4').set({ ...tpl, kind: 'auto' }));
  await assertFails(manager.doc('stayMessageTemplates/tpl5').set({ ...tpl, body: 'x'.repeat(4001) }));
  await assertFails(manager.doc('stayMessageTemplates/tpl6').set({ ...tpl, channelHint: 'push' }));
  await assertSucceeds(as(EMPLOYEE).doc(DOCS.stayMessageTemplates).get());
  await assertFails(as(EMPLOYEE).doc('stayMessageTemplates/tpl7').set({ ...tpl, ...stamp(EMPLOYEE) }));
  // Only the server seeds; the creator and creation time are fixed.
  await assertFails(manager.doc('stayMessageTemplates/tpl8').set({ ...tpl, seeded: true }));
  await assertFails(manager.doc('stayMessageTemplates/tpl9').set({ ...tpl, createdBy: OWNER }));
  await assertFails(manager.doc('stayMessageTemplates/tpl10').set({ ...tpl, createdAt: new Date('2020-01-01') }));
  await assertFails(manager.doc('stayMessageTemplates/tpl11').set({ ...tpl, key: 'Bad Key' }));
  const tpl2 = manager.doc('stayMessageTemplates/tpl2');
  await assertSucceeds(tpl2.update({ body: 'Checkout is at {{checkOutTime}}.', ...stamp(MANAGER) }));
  await assertFails(tpl2.update({ createdBy: OWNER, ...stamp(MANAGER) }));
  await assertFails(tpl2.update({ createdAt: serverTimestamp(), ...stamp(MANAGER) }));
  await assertFails(tpl2.update({ seeded: true, ...stamp(MANAGER) }));
  await assertFails(manager.doc(DOCS.stayMessageTemplates).update({ seeded: false, ...stamp(MANAGER) }));
  await assertSucceeds(manager.doc(DOCS.stayMessageTemplates).update({ name: 'Check-in', ...stamp(MANAGER) }));
  await assertSucceeds(manager.doc('stayMessageTemplates/tpl2').delete());
});

test('guest profiles: stamped consent, server-owned counts, deletable by owners and managers', async () => {
  const manager = as(MANAGER);
  const profile = {
    facilityId: FAC,
    name: 'Rick Rover',
    nameLower: 'rick rover',
    phoneE164: null,
    email: null,
    vehicle: null,
    notes: '',
    doNotRent: false,
    doNotRentReason: null,
    consent: null,
    stayCount: 0,
    lastStayAt: null,
    createdAt: serverTimestamp(),
    createdBy: MANAGER,
    ...stamp(MANAGER),
  };
  await assertSucceeds(manager.doc('stayGuestProfiles/gp2').set(profile));
  await assertFails(manager.doc('stayGuestProfiles/gp3').set({ ...profile, stayCount: 5 }));
  await assertFails(manager.doc('stayGuestProfiles/gp4').set({ ...profile, nameLower: 'someone else' }));
  await assertFails(manager.doc('stayGuestProfiles/gp5').set({ ...profile, ssn: '123' }));
  await assertFails(
    manager.doc('stayGuestProfiles/gp6').set({
      ...profile,
      consent: { email: true, sms: false, method: 'verbal', recordedAt: new Date('2026-01-01'), recordedBy: MANAGER },
    }),
  );
  await assertFails(
    manager.doc('stayGuestProfiles/gp7').set({
      ...profile,
      consent: { email: true, sms: false, method: 'verbal', recordedAt: serverTimestamp(), recordedBy: OWNER },
    }),
  );
  // The vehicle is a small, known-shape map.
  const vehicle = { plate: 'ABC123', state: 'TX', make: 'Winnebago', rvType: 'Class A', rvLengthFt: 38 };
  await assertSucceeds(manager.doc('stayGuestProfiles/gpv1').set({ ...profile, vehicle }));
  await assertFails(manager.doc('stayGuestProfiles/gpv2').set({ ...profile, vehicle: 'x'.repeat(50_000) }));
  await assertFails(manager.doc('stayGuestProfiles/gpv3').set({ ...profile, vehicle: { ...vehicle, vin: '1HGCM82633A004352' } }));
  await assertFails(manager.doc('stayGuestProfiles/gpv4').set({ ...profile, vehicle: { ...vehicle, make: 'x'.repeat(61) } }));
  await assertFails(manager.doc('stayGuestProfiles/gpv5').set({ ...profile, vehicle: { ...vehicle, rvLengthFt: 'long' } }));
  await assertSucceeds(
    manager.doc('stayGuestProfiles/gp8').set({
      ...profile,
      consent: { email: true, sms: false, method: 'verbal', recordedAt: serverTimestamp(), recordedBy: MANAGER },
    }),
  );

  const existing = manager.doc(DOCS.stayGuestProfiles);
  await assertSucceeds(existing.update({ notes: 'Pull-through site', email: 'jane@example.com', ...stamp(MANAGER) }));
  await assertFails(existing.update({ stayCount: 99, ...stamp(MANAGER) }));
  await assertFails(existing.update({ lastStayAt: serverTimestamp(), ...stamp(MANAGER) }));
  await assertFails(
    existing.update({ consent: { email: true, sms: true, method: 'written', recordedAt: new Date(), recordedBy: MANAGER }, ...stamp(MANAGER) }),
  );
  await assertSucceeds(
    existing.update({ consent: { email: true, sms: true, method: 'written', recordedAt: serverTimestamp(), recordedBy: MANAGER }, ...stamp(MANAGER) }),
  );
  await assertFails(as(EMPLOYEE).doc(DOCS.stayGuestProfiles).get());
  await assertFails(as(EMPLOYEE).doc(DOCS.stayGuestProfiles).delete());
  await assertSucceeds(existing.delete());
});

// --- Module off: no client creates ------------------------------------------------

/** One valid client create per collection the app may create docs in. */
function clientCreates(uid) {
  const db = as(uid);
  return {
    stayListingAccess: () =>
      db.doc('stayListingAccess/lst_off').set({
        facilityId: FAC,
        listingId: 'lst_off',
        wifiName: 'Guest',
        wifiPassword: 'pw',
        staticDoorCode: '',
        lockboxCode: '',
        gateCode: '',
        parkingNotes: '',
        trashNotes: '',
        checkoutInstructions: '',
        directionsUrl: '',
        houseRules: '',
        ...stamp(uid),
      }),
    stayAccess: () =>
      db.doc('stayAccess/s_off').set({
        facilityId: FAC,
        stayId: 's_off',
        doorCode: null,
        gateCode: null,
        accessNotes: '',
        source: 'manual',
        ...stamp(uid),
      }),
    stayTasks: () =>
      db
        .doc('stayTasks/manual_off')
        .set(taskDoc({ category: 'maintenance', stayId: null, createdBy: uid, createdAt: serverTimestamp(), ...stamp(uid) })),
    stayGuestProfiles: () =>
      db.doc('stayGuestProfiles/gp_off').set({
        facilityId: FAC,
        name: 'Rick Rover',
        nameLower: 'rick rover',
        phoneE164: null,
        email: null,
        vehicle: null,
        notes: '',
        doNotRent: false,
        doNotRentReason: null,
        consent: null,
        stayCount: 0,
        lastStayAt: null,
        createdAt: serverTimestamp(),
        createdBy: uid,
        ...stamp(uid),
      }),
    stayMessageTemplates: () =>
      db.doc('stayMessageTemplates/tpl_off').set({
        facilityId: FAC,
        key: 'checkout_reminder',
        name: 'Checkout reminder',
        body: 'Checkout is {{checkOutTime}}.',
        channelHint: 'sms',
        listingIds: [],
        kind: 'copy',
        seeded: false,
        createdAt: serverTimestamp(),
        createdBy: uid,
        ...stamp(uid),
      }),
  };
}

/** Replaces stayControls/current; null deletes it. */
async function setControls(data) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const ref = facilityScope(context.firestore()).doc(DOCS.stayControls);
    if (data === null) await ref.delete();
    else await ref.set({ facilityId: FAC, timeZone: 'America/Denver', version: 1, ...data });
  });
}

test('with Stays off or never set up, the app creates no Stays docs; existing ones stay editable', async () => {
  for (const state of [{ moduleEnabled: false }, {}, null]) {
    await setControls(state);
    for (const create of Object.values(clientCreates(OWNER))) {
      await assertFails(create());
    }
  }
  // Switching the module off does not lock owners out of what already exists.
  await assertSucceeds(as(MANAGER).doc(DOCS.stayListingAccess).update({ wifiPassword: 'changed', ...stamp(MANAGER) }));
  await assertSucceeds(as(MANAGER).doc(DOCS.stayAccess).update({ doorCode: '5555', ...stamp(MANAGER) }));

  // The same creates are accepted once the module is on.
  await setControls({ moduleEnabled: true });
  for (const create of Object.values(clientCreates(OWNER))) {
    await assertSucceeds(create());
  }
});

// --- Storage: turnover photos ------------------------------------------------------

function photoRef(uid, name) {
  return storageRef(testEnv.authenticatedContext(uid).storage(), `facilities/${FAC}/stayTaskPhotos/t_mine/${name}`);
}

/**
 * Storage rules read the facility doc with firestore.get(), and the storage
 * emulator looks it up in the emulator's own project (the one
 * emulators:exec runs with), not in this file's. So the facility is seeded
 * there too. The runner runs test files one at a time, so the other file's
 * clearFirestore() cannot remove it mid-test.
 */
async function seedFacilityForStorageRules({ moduleEnabled = true } = {}) {
  const projectId = process.env.GCLOUD_PROJECT || 'sfc-rules-test';
  const firestore = hostPort('FIRESTORE_EMULATOR_HOST', 'localhost:8080');
  const lookupEnv = await initializeTestEnvironment({
    projectId,
    firestore: { host: firestore.host, port: firestore.port },
  });
  await lookupEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await db.collection('facilities').doc(FAC).set({
      name: 'Test Park',
      ownerUid: OWNER,
      roles: { [OWNER]: 'owner', [MANAGER]: 'manager', [EMPLOYEE]: 'employee', [EMPLOYEE2]: 'employee', [VIEWER]: 'viewer' },
    });
    // Uploads need Stays on and the task to exist (storage.rules).
    await db.doc(`facilities/${FAC}/stayControls/current`).set({ facilityId: FAC, moduleEnabled, version: 1 });
    await db.doc(`facilities/${FAC}/stayTasks/t_mine`).set(taskDoc({ assigneeUid: EMPLOYEE, assigneeName: 'Emp' }));
    await db.doc(`facilities/${FAC}/stayTasks/t_unassigned`).set(taskDoc());
    await db.doc(`facilities/${FAC}/stayTasks/t_other`).set(taskDoc({ assigneeUid: EMPLOYEE2, assigneeName: 'Other' }));
  });
  return lookupEnv;
}

const STORAGE_SEED_DOCS = ['stayControls/current', 'stayTasks/t_mine', 'stayTasks/t_unassigned', 'stayTasks/t_other'];

async function removeStorageSeed(lookupEnv) {
  await lookupEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    for (const path of STORAGE_SEED_DOCS) await db.doc(`facilities/${FAC}/${path}`).delete();
    await db.collection('facilities').doc(FAC).delete();
  });
  await lookupEnv.cleanup();
}

function taskPhotoRef(uid, taskId, name) {
  return storageRef(testEnv.authenticatedContext(uid).storage(), `facilities/${FAC}/stayTaskPhotos/${taskId}/${name}`);
}

test('turnover photos go only on a task that exists and is unassigned or the employee’s own', async (t) => {
  const lookupEnv = await seedFacilityForStorageRules();
  t.after(() => removeStorageSeed(lookupEnv));
  const small = new Uint8Array(1024);
  const jpeg = { contentType: 'image/jpeg' };
  await assertSucceeds(uploadBytes(taskPhotoRef(EMPLOYEE, 't_unassigned', 'a.jpg'), small, jpeg));
  await assertFails(uploadBytes(taskPhotoRef(EMPLOYEE, 't_other', 'a.jpg'), small, jpeg));
  await assertFails(uploadBytes(taskPhotoRef(EMPLOYEE, 't_missing', 'a.jpg'), small, jpeg));
  // The task's own assignee may.
  await assertSucceeds(uploadBytes(taskPhotoRef(EMPLOYEE2, 't_other', 'b.jpg'), small, jpeg));
});

test('with Stays off, employees upload no turnover photos', async (t) => {
  const lookupEnv = await seedFacilityForStorageRules({ moduleEnabled: false });
  t.after(() => removeStorageSeed(lookupEnv));
  const small = new Uint8Array(1024);
  const jpeg = { contentType: 'image/jpeg' };
  await assertFails(uploadBytes(photoRef(EMPLOYEE, 'off.jpg'), small, jpeg));
  await assertFails(uploadBytes(taskPhotoRef(EMPLOYEE, 't_unassigned', 'off.jpg'), small, jpeg));
  // No stayControls doc at all is off too.
  await lookupEnv.withSecurityRulesDisabled((context) => context.firestore().doc(`facilities/${FAC}/stayControls/current`).delete());
  await assertFails(uploadBytes(photoRef(EMPLOYEE, 'none.jpg'), small, jpeg));
});

test('employees upload turnover photos: images under 10 MB only', async (t) => {
  const lookupEnv = await seedFacilityForStorageRules();
  t.after(() => removeStorageSeed(lookupEnv));
  const small = new Uint8Array(1024);
  await assertSucceeds(uploadBytes(photoRef(EMPLOYEE, 'ok.jpg'), small, { contentType: 'image/jpeg' }));
  await assertSucceeds(getBytes(photoRef(EMPLOYEE, 'ok.jpg')));
  await assertFails(uploadBytes(photoRef(EMPLOYEE, 'notes.txt'), small, { contentType: 'text/plain' }));
  await assertFails(uploadBytes(photoRef(EMPLOYEE, 'x.svg'), small, { contentType: 'image/svg+xml' }));
  await assertSucceeds(uploadBytes(photoRef(EMPLOYEE, 'ok.heic'), small, { contentType: 'image/heic' }));
  await assertFails(uploadBytes(photoRef(EMPLOYEE, 'huge.jpg'), new Uint8Array(10 * 1024 * 1024), { contentType: 'image/jpeg' }));
  await assertFails(uploadBytes(photoRef(OUTSIDER, 'x.jpg'), small, { contentType: 'image/jpeg' }));
  await assertFails(uploadBytes(photoRef(VIEWER, 'x.jpg'), small, { contentType: 'image/jpeg' }));
  await assertFails(getBytes(photoRef(OUTSIDER, 'ok.jpg')));
  // Employees add photos; they do not replace or delete them.
  await assertFails(deleteObject(photoRef(EMPLOYEE, 'ok.jpg')));
  // Nor do they get the rest of the facility's files.
  await assertFails(
    uploadBytes(storageRef(testEnv.authenticatedContext(EMPLOYEE).storage(), `facilities/${FAC}/invoices/x.pdf`), small, {
      contentType: 'application/pdf',
    }),
  );
  await assertSucceeds(deleteObject(photoRef(MANAGER, 'ok.jpg')));
});

/**
 * Manual pre-deploy check (spec §10.2): 20 parallel applyStayMutations calls
 * book the same nights of one listing against the real Firestore emulator,
 * and exactly one may win.
 *
 * Run from the repo root after `npm run build` in functions-stays:
 *   firebase emulators:exec --only firestore "node functions-stays/scripts/emulator-concurrency.mjs"
 * or: npm run test:emulator --prefix functions-stays
 *
 * It refuses to run without FIRESTORE_EMULATOR_HOST, so it can never write to
 * a real project.
 */
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  console.error('emulator-concurrency: FIRESTORE_EMULATOR_HOST is not set. Run it through `firebase emulators:exec`.');
  process.exit(1);
}

const admin = require('firebase-admin');
const { Timestamp } = require('firebase-admin/firestore');
const { applyStayMutations } = require('../lib/common/stayWriter.js');

const PARALLEL = 20;
const projectId = process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT || 'demo-sfc-stays';
if (admin.apps.length === 0) admin.initializeApp({ projectId });
const db = admin.firestore();

const now = Date.now();
const facilityId = `fac-concurrency-${now}`;
const listingId = 'lst_race';

const controls = {
  facilityId,
  moduleEnabled: true,
  timeZone: 'America/Denver',
  timeZoneConfirmedAt: Timestamp.fromMillis(now),
  timeZoneConfirmedBy: 'script',
  icalSyncEnabled: false,
  icalExportEnabled: false,
  turnoverTasksEnabled: false,
  dailyBriefEnabled: false,
  dailyBriefLocalHour: 7,
  lodgingTaxEnabled: false,
  employeesCanBook: false,
  employeesCanRecordCash: false,
  defaultCheckInTime: '15:00',
  defaultCheckOutTime: '11:00',
  shortLeadWarningHours: 72,
  paymentMethods: ['cash'],
  parkRules: '',
  quietHours: '',
  guestMessagingEnabled: false,
  directPaymentsEnabled: false,
  templatesSeededAt: null,
  createdAt: null,
  createdBy: null,
  updatedAt: null,
  updatedBy: null,
  version: 1,
};

function ymd(daysFromNow) {
  return new Date(now + daysFromNow * 86_400_000).toISOString().slice(0, 10);
}

function stay(i) {
  const ts = Timestamp.fromMillis(now);
  return {
    facilityId,
    listingId,
    listingName: 'Race Cabin',
    listingGroup: 'Test',
    listingKind: 'cabin',
    kind: 'reservation',
    source: 'walk_up',
    origin: 'sfc',
    status: 'confirmed',
    arrivalState: 'upcoming',
    checkIn: ymd(10),
    checkOut: ymd(13),
    nights: 3,
    checkInTime: '15:00',
    checkOutTime: '11:00',
    guestDisplayName: `Guest ${i}`,
    adults: 1,
    children: 0,
    pets: 0,
    rvLengthFt: null,
    paymentStatus: 'none',
    external: null,
    sync: null,
    conflict: null,
    staffNotes: '',
    cleanerNotes: '',
    tags: [],
    messageMarks: {},
    turnoverTaskId: null,
    checkedInAt: null,
    checkedOutAt: null,
    cancelledAt: null,
    cancelledBy: null,
    cancelReason: null,
    requestId: null,
    version: 1,
    createdAtMs: now + i,
    createdAt: ts,
    createdBy: 'script',
    updatedAt: ts,
    updatedBy: 'script',
  };
}

const results = await Promise.allSettled(
  Array.from({ length: PARALLEL }, (_, i) =>
    applyStayMutations({
      db,
      facilityId,
      controls,
      mutations: [{ stayId: `man_race_${i}`, next: stay(i), mode: 'sfc', createOnly: true }],
      actor: 'script',
      maxAttempts: 10,
    }),
  ),
);

const winners = results.filter((r) => r.status === 'fulfilled').length;
const reasons = {};
for (const r of results) {
  if (r.status === 'rejected') {
    const reason = r.reason?.details?.reason ?? `untyped: ${r.reason?.message ?? r.reason}`;
    reasons[reason] = (reasons[reason] ?? 0) + 1;
  }
}
const staysSnap = await db.collection('facilities').doc(facilityId).collection('stays').get();
const lockSnap = await db.collection('facilities').doc(facilityId).collection('stayNightLocks').get();
const holders = new Set();
for (const bucket of lockSnap.docs) {
  for (const claim of Object.values(bucket.get('nights') ?? {})) holders.add(claim.s);
}

console.log(`emulator-concurrency: ${winners} winner(s) of ${PARALLEL}; rejections: ${JSON.stringify(reasons)}`);
console.log(`emulator-concurrency: ${staysSnap.size} stay doc(s); nights held by: ${[...holders].join(', ')}`);

const onlyExpectedReasons = Object.keys(reasons).every((r) => r === 'hard_conflict' || r === 'contention');
const ok = winners === 1 && staysSnap.size === 1 && holders.size === 1 && holders.has(staysSnap.docs[0].id) && onlyExpectedReasons;

// Leave the emulator as it was.
const writer = db.bulkWriter();
for (const d of [...staysSnap.docs, ...lockSnap.docs]) writer.delete(d.ref);
await writer.close();

if (!ok) {
  console.error('emulator-concurrency: FAIL — expected exactly one winner holding every night.');
  process.exit(1);
}
console.log('emulator-concurrency: OK');
process.exit(0);

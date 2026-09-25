#!/usr/bin/env node
/**
 * READ-ONLY pre-deploy counts for the online move-in changes in
 * functions-public-website (paid renters moved in or refunded, one Checkout
 * Session per reservation, the stalled-refund sweep). It only reads: no
 * set, update, delete or batch is made anywhere below.
 *
 * What it reports:
 *   1. Units whose status is available or reserved but which still carry a
 *      tenantId. Checkout and completion now refuse these (before, a move-in
 *      overwrote the link). Each should be looked at before deploying.
 *   2. publicMoveInPayments records whose automatic refund is still
 *      'pending', with their age. The new resumeStalledMoveInRefunds sweep
 *      will finish any older than 15 minutes on its first run.
 *   3. Open reservations whose checkout started within the last 24 hours
 *      and that have no checkoutSessionId: their Checkout Sessions were made
 *      before this deploy, stay payable for 24 hours and carry untagged
 *      payments. Consider expiring them in the Stripe dashboard.
 *
 * Usage (Application Default Credentials with read access to the project):
 *   gcloud auth application-default login
 *   node scripts/predeploy-online-move-in-checks.mjs [--project=storage-facility-creator]
 */
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// firebase-admin is not a root dependency; borrow the copy the functions package has.
const require = createRequire(
  path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'functions-public-website', 'package.json'),
);
const admin = require('firebase-admin');

const projectArg = process.argv.find((a) => a.startsWith('--project='));
const projectId = projectArg ? projectArg.slice('--project='.length) : 'storage-facility-creator';

admin.initializeApp({ projectId });
const db = admin.firestore();

const DAY_MS = 24 * 60 * 60 * 1000;

function iso(value) {
  return value && typeof value.toDate === 'function' ? value.toDate().toISOString() : String(value ?? '');
}

async function unitsLinkedToATenantButAvailable() {
  const found = [];
  const facilities = await db.collection('facilities').select().get();
  for (const facility of facilities.docs) {
    const units = await facility.ref.collection('units').where('status', 'in', ['available', 'reserved']).get();
    for (const unit of units.docs) {
      const data = unit.data();
      if (typeof data.tenantId === 'string' && data.tenantId.trim() !== '') {
        found.push({
          facilityId: facility.id,
          unitId: unit.id,
          unitNumber: data.unitNumber ?? '',
          status: data.status,
          tenantId: data.tenantId,
        });
      }
    }
  }
  return found;
}

async function pendingRefunds() {
  const snap = await db.collection('publicMoveInPayments').where('refund.status', '==', 'pending').get();
  return snap.docs.map((doc) => {
    const data = doc.data();
    return {
      paymentIntentId: doc.id,
      facilityId: data.facilityId ?? '',
      reservationId: data.reservationId ?? '',
      amountCents: data.amountReceivedCents ?? null,
      decidedAt: iso(data.createdAt),
    };
  });
}

async function checkoutsStartedBeforeDeploy() {
  const since = Date.now() - DAY_MS;
  const snap = await db.collection('publicReservations').where('status', 'in', ['pending', 'confirmed']).get();
  return snap.docs
    .map((doc) => ({ id: doc.id, data: doc.data() }))
    .filter(({ data }) => {
      const started = data.checkoutUpdatedAt;
      return started && typeof started.toMillis === 'function' && started.toMillis() >= since && !data.checkoutSessionId;
    })
    .map(({ id, data }) => ({
      reservationId: id,
      facilityId: data.facilityId ?? '',
      checkoutStartedAt: iso(data.checkoutUpdatedAt),
      holdExpiresAt: iso(data.expiresAt),
    }));
}

function report(title, rows) {
  console.log(`\n${title}: ${rows.length}`);
  for (const row of rows) console.log(`  ${JSON.stringify(row)}`);
}

try {
  console.log(`Project ${projectId} (read-only)`);
  report('Units available/reserved with a tenantId (now refused at checkout and move-in)', await unitsLinkedToATenantButAvailable());
  report('Move-in refunds still pending (the sweep finishes those older than 15 minutes)', await pendingRefunds());
  report('Open reservations with a checkout started in the last 24h before this deploy', await checkoutsStartedBeforeDeploy());
} catch (err) {
  console.error('Pre-deploy checks failed:', err?.message || err);
  process.exitCode = 1;
}

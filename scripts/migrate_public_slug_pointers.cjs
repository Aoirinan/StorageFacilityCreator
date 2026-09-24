#!/usr/bin/env node
'use strict';

/**
 * One-time: turn each facility's old public map slugs into pointers.
 *
 * publicFacilityMaps is keyed by the storefront's URL slug and world readable.
 * Before FacilityMapV2Service.setPublicSlug left a pointer behind, a slug
 * change left the old doc with its full unit list, never synced again, so old
 * links (/w/<old>, /#/f/<old>/rent) served a frozen list. This overwrites every
 * such doc with `{ facilityId, movedToSlug: <current slug>, movedAt }`, no units
 * or settings, which the app and the site follow to the current map. The
 * current slug is the facility's mapEngine/meta.publicSlug. Which docs change
 * is planPublicSlugPointers (functions-shared/src/hosting/publicFacilityMapSlug.ts).
 *
 * DRY RUN BY DEFAULT: prints what it would change and writes nothing. Docs
 * whose facility no longer exists are listed, not changed.
 *
 * Needs functions-shared built (its lib/ and node_modules), from repo root:
 *   npm ci --prefix functions-shared
 *   node scripts/vendor-functions-shared.cjs
 *
 * Usage (Application Default Credentials: gcloud auth application-default login):
 *   node scripts/migrate_public_slug_pointers.cjs --project=<id>
 *   node scripts/migrate_public_slug_pointers.cjs --project=<id> --facility=<facilityId>
 *   node scripts/migrate_public_slug_pointers.cjs --project=<id> --apply --confirm-project=<id>
 */

const path = require('node:path');
const { createRequire } = require('node:module');

const sharedRoot = path.join(__dirname, '..', 'functions-shared');
const requireShared = createRequire(path.join(sharedRoot, 'package.json'));

function loadDeps() {
  try {
    return {
      admin: requireShared('firebase-admin'),
      slugs: require(path.join(sharedRoot, 'lib', 'hosting', 'publicFacilityMapSlug.js')),
    };
  } catch (err) {
    throw new Error(
      `functions-shared is not built (${err.message}). From repo root run: ` +
        'npm ci --prefix functions-shared && node scripts/vendor-functions-shared.cjs',
    );
  }
}

function parseArgs(argv) {
  const values = new Map();
  for (const arg of argv.slice(2)) {
    if (!arg.startsWith('--')) continue;
    const [key, ...rest] = arg.slice(2).split('=');
    values.set(key, rest.length > 0 ? rest.join('=') : true);
  }
  return values;
}

function describe(data) {
  const units = Array.isArray(data.units) ? data.units.length : 0;
  const synced = data.inventorySyncedAt ? 'synced' : 'never synced';
  return `${units} units, ${synced}`;
}

async function main() {
  const args = parseArgs(process.argv);
  const projectId = String(args.get('project') || '').trim();
  const apply = args.get('apply') === true;
  const confirmedProject = String(args.get('confirm-project') || '').trim();
  const onlyFacility = String(args.get('facility') || '').trim();

  if (!projectId) {
    throw new Error('Pass --project=<firebase-project-id>.');
  }
  if (apply && confirmedProject !== projectId) {
    throw new Error(`Refusing to write to ${projectId}. Re-run with --apply --confirm-project=${projectId}.`);
  }

  const { admin, slugs } = loadDeps();
  admin.initializeApp({ projectId });
  const db = admin.firestore();
  const maps = db.collection(slugs.PUBLIC_FACILITY_MAPS);

  console.log(`${apply ? 'APPLY' : 'DRY RUN (nothing is written)'}: project ${projectId}` +
    (onlyFacility ? `, facility ${onlyFacility}` : ''));
  if (process.env.FIRESTORE_EMULATOR_HOST) {
    console.log(`Firestore emulator at ${process.env.FIRESTORE_EMULATOR_HOST}`);
  }

  const snap = onlyFacility
    ? await maps.where('facilityId', '==', onlyFacility).get()
    : await maps.get();
  const byFacility = new Map();
  const noFacility = [];
  for (const doc of snap.docs) {
    const facilityId = doc.get('facilityId');
    if (typeof facilityId !== 'string' || facilityId === '') {
      noFacility.push(doc.id);
      continue;
    }
    if (!byFacility.has(facilityId)) byFacility.set(facilityId, []);
    byFacility.get(facilityId).push({ id: doc.id, data: doc.data() });
  }

  const totals = { facilities: 0, pointers: 0, unitsDropped: 0, skipped: 0, orphaned: 0, written: 0, raced: 0 };
  for (const [facilityId, docs] of [...byFacility.entries()].sort(([a], [b]) => a.localeCompare(b))) {
    totals.facilities += 1;
    const facilitySnap = await db.collection('facilities').doc(facilityId).get();
    if (!facilitySnap.exists) {
      totals.orphaned += docs.length;
      console.log(`\n${facilityId}: facility does not exist; left as is: ${docs.map((d) => d.id).join(', ')}`);
      continue;
    }
    const metaSnap = await db.doc(`facilities/${facilityId}/mapEngine/meta`).get();
    const storedSlug = metaSnap.exists ? metaSnap.get('publicSlug') : null;
    const currentSlug = typeof storedSlug === 'string' ? storedSlug : null;
    const plan = slugs.planPublicSlugPointers(facilityId, currentSlug, docs);
    const name = facilitySnap.get('name') || '';

    if ('skipped' in plan) {
      totals.skipped += 1;
      console.log(`\n${facilityId} ${name}: skipped, ${plan.skipped}; docs: ${docs.map((d) => d.id).join(', ')}`);
      continue;
    }
    if (plan.changes.length === 0) continue;

    const current = docs.find((d) => d.id === plan.currentSlug);
    console.log(`\n${facilityId} ${name}: current slug ${plan.currentSlug} (${describe(current.data)})`);
    for (const change of plan.changes) {
      const doc = docs.find((d) => d.id === change.slug);
      const was = change.was === 'map' ? describe(doc.data) : `pointer to ${change.movedToSlug}`;
      console.log(`  ${change.slug}: ${was} -> pointer to ${plan.currentSlug}`);
      totals.pointers += 1;
      totals.unitsDropped += change.unitCount;
      if (!apply) continue;

      // Re-checked in the transaction: the doc is still this facility's, the
      // meta still names the same slug, and that slug still holds its map.
      const wrote = await db.runTransaction(async (txn) => {
        const [docNow, currentNow, metaNow] = await Promise.all([
          txn.get(maps.doc(change.slug)),
          txn.get(maps.doc(plan.currentSlug)),
          txn.get(db.doc(`facilities/${facilityId}/mapEngine/meta`)),
        ]);
        if (
          !docNow.exists ||
          docNow.get('facilityId') !== facilityId ||
          metaNow.get('publicSlug') !== plan.currentSlug ||
          !currentNow.exists ||
          currentNow.get('facilityId') !== facilityId ||
          slugs.movedToSlugOf(currentNow.data()) !== null
        ) {
          return false;
        }
        txn.set(
          maps.doc(change.slug),
          slugs.publicMapPointer(facilityId, plan.currentSlug, admin.firestore.FieldValue.serverTimestamp()),
        );
        return true;
      });
      if (wrote) {
        totals.written += 1;
      } else {
        totals.raced += 1;
        console.log(`    changed since it was read; left as is`);
      }
    }
  }

  if (noFacility.length > 0) {
    console.log(`\nNo facilityId, left as is: ${noFacility.join(', ')}`);
  }
  console.log(
    `\n${totals.facilities} facilities; ${totals.pointers} docs ${apply ? 'to point' : 'would point'} at their ` +
      `current slug (${totals.unitsDropped} stale unit rows dropped); ${totals.skipped} facilities skipped; ` +
      `${totals.orphaned} docs of facilities that no longer exist; ${noFacility.length} docs with no facilityId.`,
  );
  if (apply) {
    console.log(`Written: ${totals.written}; left because they changed: ${totals.raced}.`);
  } else {
    console.log(`Nothing was written. To apply: --apply --confirm-project=${projectId}`);
  }
}

main().then(
  () => process.exit(0),
  (err) => {
    console.error(err instanceof Error ? err.message : err);
    process.exit(1);
  },
);

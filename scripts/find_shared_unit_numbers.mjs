#!/usr/bin/env node
/**
 * Finds units rented twice: two or more active tenants in one facility who
 * hold the same unit. Reads only; it never writes to Firestore.
 *
 * When this was written, the online rental callables
 * (functions-public-website/src/publicMoveIn.ts) checked a unit's status,
 * listing and hold, but not its tenantId or whether an active tenant held it.
 * A unit taken only through a tenant's unit number (unit doc still
 * 'available', no tenantId) could be held, paid for and moved into by a
 * stranger, leaving two active tenants on one unit. The public map was the
 * only guard, and the app's publish and refresh dropped it on a failed tenant
 * read.
 *
 * It reports, per facility:
 *   1. Units two or more active tenants hold, with each unit doc's status and
 *      tenant link, how each tenant was matched to it, and which tenants came
 *      from an online move-in (createdBy 'publicMoveIn'). A group with an
 *      online move-in in it is the double rental this looks for.
 *   2. Units a stranger could rent online right now although they are taken
 *      (tenantId set, or an active tenant holds them): what the callables
 *      would accept, for facilities with online rentals on.
 *
 * Active is read as the inventory sync reads it (isActive exactly true, unit
 * numbers trimmed and lower-cased). Which unit a tenant holds follows the
 * tenant's unitId first, then its unitArea with the number, then the number
 * alone, because facilities may repeat unit numbers across areas. A bare
 * number that names units in several areas is reported as ambiguous.
 *
 * Usage, with Application Default Credentials for an account that can read
 * the project's Firestore (`gcloud auth application-default login`):
 *   node scripts/find_shared_unit_numbers.mjs
 *   node scripts/find_shared_unit_numbers.mjs --facility <facilityId>
 *   node scripts/find_shared_unit_numbers.mjs --names   # include tenant names
 *   node scripts/find_shared_unit_numbers.mjs --project <projectId>
 *
 * firebase-admin is not a root dependency; it is borrowed from
 * functions-public-website (run `npm ci` there first, or point NODE_PATH at a
 * node_modules that has it).
 */
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(
  path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'functions-public-website', 'package.json'),
);

const DEFAULT_PROJECT = 'storage-facility-creator';
const PAGE_SIZE = 500;
const TENANT_FIELDS = ['unitNumber', 'unitId', 'unitArea', 'isActive', 'createdAt', 'createdBy', 'leadSource', 'name'];
const UNIT_FIELDS = [
  'unitNumber', 'area', 'status', 'tenantId', 'archived', 'internalUse', 'publicListingEnabled', 'unitType', 'updatedBy',
];

function parseArgs(argv) {
  const args = { project: DEFAULT_PROJECT, facility: null, names: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--project') args.project = argv[++i];
    else if (a === '--facility') args.facility = argv[++i];
    else if (a === '--names') args.names = true;
    else if (a === '--help' || a === '-h') {
      console.log('node scripts/find_shared_unit_numbers.mjs [--facility <id>] [--names] [--project <id>]');
      process.exit(0);
    } else {
      console.error(`Unknown argument: ${a}`);
      process.exit(2);
    }
  }
  if (!args.project || (args.facility !== null && !args.facility)) {
    console.error('--project and --facility need a value.');
    process.exit(2);
  }
  return args;
}

function loadAdmin() {
  try {
    return require('firebase-admin');
  } catch {
    console.error(
      'firebase-admin not found. Run `npm ci` in functions-public-website, ' +
        'or set NODE_PATH to a node_modules that has it.',
    );
    process.exit(2);
  }
}

/** Every doc of [query], paged by id so a big facility is read in full. */
async function readEveryDoc(admin, query, fields) {
  const out = [];
  let cursor;
  for (;;) {
    let q = query.select(...fields).orderBy(admin.firestore.FieldPath.documentId()).limit(PAGE_SIZE);
    if (cursor) q = q.startAfter(cursor);
    const page = await q.get();
    out.push(...page.docs);
    if (page.size < PAGE_SIZE) break;
    cursor = page.docs[page.docs.length - 1];
  }
  return out;
}

// Unit numbers as publicFacilityMapInventorySync reads them.
const tenantUnitKey = (t) => String(t.unitNumber || '').trim().toLowerCase();
const unitKey = (u) => String(u.unitNumber ?? '').trim().toLowerCase();
const trimmedOrNull = (v) => (typeof v === 'string' && v.trim() !== '' ? v.trim() : null);
const areaKey = (v) => (trimmedOrNull(v) ?? '').toLowerCase();

/**
 * The unit docs an active tenant holds. A number alone is not enough once a
 * facility repeats numbers across areas ("12" in Complex 2 and in Complex 3),
 * so this follows the tenant's unitId first, then its unitArea with the
 * number, and only then the number by itself. A bare number that names units
 * in several areas matches all of them and is flagged ambiguous rather than
 * guessed.
 */
function claimedUnits(t, unitsById, unitsByKey) {
  const id = trimmedOrNull(t.unitId);
  if (id && unitsById.has(id)) return { units: [unitsById.get(id)], how: 'unitId', ambiguous: false };
  const candidates = unitsByKey.get(tenantUnitKey(t)) || [];
  const area = areaKey(t.unitArea);
  if (area) {
    const inArea = candidates.filter((u) => areaKey(u.area) === area);
    if (inArea.length > 0) return { units: inArea, how: 'area+number', ambiguous: inArea.length > 1 };
  }
  return { units: candidates, how: 'number', ambiguous: candidates.length > 1 };
}

const unitLabel = (u) => (trimmedOrNull(u.area) ? `${u.area.trim()} ${u.unitNumber ?? ''}` : `${u.unitNumber ?? ''}`);
const hasTenantLink = (u) => typeof u.tenantId === 'string' && u.tenantId.trim() !== '';
const storedStatus = (u) => (typeof u.status === 'string' ? u.status : '');
// functions-shared/src/units/onlineRental.ts
const isArchived = (u) => (u.archived ?? false) !== false;
const isOfferedOnline = (u) => !isArchived(u) && u.internalUse !== true && u.publicListingEnabled !== false;

function enabledTypes(settings) {
  const raw = settings?.enabledPublicUnitTypes;
  return Array.isArray(raw) ? raw.map((e) => String(e).trim()).filter((e) => e.length > 0) : [];
}

function typeOffered(u, types) {
  return types.length === 0 || types.includes(String(u.unitType || '').trim());
}

function day(value) {
  if (!value) return '?';
  const d = typeof value.toDate === 'function' ? value.toDate() : new Date(value);
  return Number.isNaN(d.getTime()) ? String(value) : d.toISOString().slice(0, 10);
}

const isOnlineMoveIn = (t) => t.createdBy === 'publicMoveIn';

async function checkFacility(admin, db, facilityId, facilityName, args) {
  const [tenantDocs, unitDocs, settingsSnap] = await Promise.all([
    readEveryDoc(admin, db.collection(`facilities/${facilityId}/tenants`), TENANT_FIELDS),
    readEveryDoc(admin, db.collection(`facilities/${facilityId}/units`), UNIT_FIELDS),
    db.doc(`facilities/${facilityId}/settings/public`).get(),
  ]);
  const settings = settingsSnap.data() || {};
  const rentalsOn = settings.publicRentalsEnabled === true;

  const units = unitDocs.map((doc) => ({ id: doc.id, ...doc.data() }));
  const unitsById = new Map(units.map((u) => [u.id, u]));
  const unitsByKey = new Map();
  for (const u of units) {
    const key = unitKey(u);
    if (!unitsByKey.has(key)) unitsByKey.set(key, []);
    unitsByKey.get(key).push(u);
  }

  // Which unit each active tenant holds. Tenants whose number names no unit
  // are kept by number, so two of them on one missing unit still show.
  const holdersByUnit = new Map();
  const unmatchedByKey = new Map();
  for (const doc of tenantDocs) {
    const t = { id: doc.id, ...doc.data() };
    if (t.isActive !== true) continue;
    const key = tenantUnitKey(t);
    if (!key && !trimmedOrNull(t.unitId)) continue;
    const claim = claimedUnits(t, unitsById, unitsByKey);
    t.claimHow = claim.how;
    t.claimAmbiguous = claim.ambiguous;
    if (claim.units.length === 0) {
      if (!key) continue;
      if (!unmatchedByKey.has(key)) unmatchedByKey.set(key, []);
      unmatchedByKey.get(key).push(t);
      continue;
    }
    for (const u of claim.units) {
      if (!holdersByUnit.has(u.id)) holdersByUnit.set(u.id, []);
      holdersByUnit.get(u.id).push(t);
    }
  }

  const shared = [
    ...[...holdersByUnit.entries()]
      .filter(([, tenants]) => tenants.length > 1)
      .map(([unitId, tenants]) => ({ units: [unitsById.get(unitId)], tenants, label: unitLabel(unitsById.get(unitId)) })),
    ...[...unmatchedByKey.values()]
      .filter((tenants) => tenants.length > 1)
      .map((tenants) => ({ units: [], tenants, label: String(tenants[0].unitNumber) })),
  ].sort((a, b) => a.label.localeCompare(b.label, undefined, { numeric: true }));

  const types = enabledTypes(settings);
  const exposed = rentalsOn
    ? units.filter((u) => {
        const st = storedStatus(u).toLowerCase();
        return (
          (st === 'available' || st === 'reserved') &&
          isOfferedOnline(u) &&
          typeOffered(u, types) &&
          (hasTenantLink(u) || holdersByUnit.has(u.id))
        );
      })
    : [];

  const result = {
    facilityId,
    rentalsOn,
    tenants: tenantDocs.length,
    units: unitDocs.length,
    sharedGroups: shared.length,
    onlineGroups: 0,
    exposed: exposed.length,
  };
  if (shared.length === 0 && exposed.length === 0) return result;

  console.log(`\n${facilityName || '(no name)'} (${facilityId}), online rentals ${rentalsOn ? 'ON' : 'off'}`);

  for (const group of shared) {
    const { units: groupUnits, tenants } = group;
    const online = tenants.some(isOnlineMoveIn);
    if (online) result.onlineGroups++;
    const unitText =
      groupUnits.length === 0
        ? 'no unit has this number'
        : groupUnits
            .map(
              (u) =>
                `unit doc ${u.id} status=${storedStatus(u) || '(none)'} ` +
                `tenantId=${hasTenantLink(u) ? u.tenantId : '(none)'}` +
                `${isArchived(u) ? ' archived' : ''}` +
                `${u.updatedBy ? ` updatedBy=${u.updatedBy}` : ''}`,
            )
            .join('; ');
    console.log(
      `  ${online ? '[ONLINE MOVE-IN] ' : ''}unit "${group.label}": ${tenants.length} active tenants; ${unitText}`,
    );
    for (const t of tenants.sort((a, b) => day(a.createdAt).localeCompare(day(b.createdAt)))) {
      const linked = groupUnits.some((u) => u.tenantId === t.id);
      console.log(
        `    - tenant ${t.id} created ${day(t.createdAt)} ` +
          `by ${t.createdBy || '?'}${t.leadSource ? ` (${t.leadSource})` : ''}` +
          `, matched by ${t.claimHow}${t.claimAmbiguous ? ' (AMBIGUOUS: no unitId, and the number names units in more than one area)' : ''}` +
          `${linked ? ', linked by the unit doc' : ''}` +
          `${args.names ? `, name "${t.name || ''}"` : ''}`,
      );
    }
  }

  if (exposed.length > 0) {
    console.log('  Rentable online right now although taken:');
    for (const u of exposed) {
      const claimants = holdersByUnit.get(u.id) || [];
      const why = [
        hasTenantLink(u) ? `tenantId=${u.tenantId}` : null,
        claimants.length > 0 ? `held by active tenant ${claimants.map((t) => `${t.id} (${t.claimHow})`).join(', ')}` : null,
      ]
        .filter(Boolean)
        .join('; ');
      console.log(`    - unit ${unitLabel(u) || '(no number)'} (${u.id}) status=${storedStatus(u)}: ${why}`);
    }
  }
  return result;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const admin = loadAdmin();
  admin.initializeApp({ credential: admin.credential.applicationDefault(), projectId: args.project });
  const db = admin.firestore();

  let facilities;
  if (args.facility) {
    const snap = await db.collection('facilities').doc(args.facility).get();
    if (!snap.exists) {
      console.error(`No facility ${args.facility} in ${args.project}.`);
      process.exit(2);
    }
    facilities = [snap];
  } else {
    facilities = await readEveryDoc(admin, db.collection('facilities'), ['name']);
  }

  console.log(`Project ${args.project}: checking ${facilities.length} facilities (read-only).`);
  const results = [];
  for (const f of facilities) {
    results.push(await checkFacility(admin, db, f.id, f.get('name'), args));
  }

  const sum = (k) => results.reduce((n, r) => n + r[k], 0);
  const withShared = results.filter((r) => r.sharedGroups > 0).length;
  console.log(
    `\nSummary: ${results.length} facilities (${results.filter((r) => r.rentalsOn).length} with online rentals on), ` +
      `${sum('tenants')} tenant docs, ${sum('units')} unit docs read.\n` +
      `  Units held by two or more active tenants: ${sum('sharedGroups')} in ${withShared} facilities; ` +
      `${sum('onlineGroups')} include an online move-in.\n` +
      `  Taken units rentable online right now: ${sum('exposed')}.`,
  );
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

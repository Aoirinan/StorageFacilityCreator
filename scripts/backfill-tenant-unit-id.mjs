#!/usr/bin/env node
/**
 * Backfill tenant.unitId and tenant.unitArea (the tenant's primary unit) for
 * tenants written before the app kept them, and for online move-ins.
 *
 * For each ACTIVE tenant with a unitNumber and no unitId, it looks for the
 * unit whose tenantId is the tenant and whose number matches the label
 * (trimmed, ignoring case). Exactly one such unit, not archived and not
 * marked available (a stale link): unitId and unitArea are set from it.
 * Anything else is reported and skipped; a tenant whose label matches no
 * unit they hold is never touched.
 *
 * DRY RUN BY DEFAULT: reads only. Writing needs --apply and at least one
 * --facility. Every run writes a before/after record to --out (default
 * backfill-records/ at the repo root, found from this script's own path so
 * the .gitignore entry applies wherever it is run from; the records hold
 * tenant names). With --apply each tenant is re-checked in its own
 * transaction (still active, same label, still no unitId, the
 * unit still theirs with that number) before it is written; only unitId and
 * unitArea change, updatedAt is left alone.
 *
 * Credentials: Application Default Credentials
 * (`gcloud auth application-default login`), project from --project,
 * GOOGLE_CLOUD_PROJECT, or storage-facility-creator.
 *
 * Usage:
 *   node scripts/backfill-tenant-unit-id.mjs --facility <id> [--facility <id> ...]
 *   node scripts/backfill-tenant-unit-id.mjs --apply --facility <id>
 *   Options: --project <id>  --out <dir>  --json (print the full plan)
 */
import { createRequire } from 'node:module';
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');

/**
 * Where records go without --out: the repo root's backfill-records/ (in
 * .gitignore), never the current directory, which may be outside the repo
 * or somewhere the ignore rule doesn't reach.
 */
export function defaultOutDir() {
  return path.join(repoRoot, 'backfill-records');
}

/** A unit number as the app compares it (unitNumberKey): trimmed, ignoring case. */
export function unitNumberKey(value) {
  return String(value ?? '').trim().toLowerCase();
}

/** A text field trimmed, or null when it is not a string or is blank (TenantModel.textField). */
export function textOf(value) {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

/** Only an exact true is active (TenantModel.isActiveField). */
function isActive(data) {
  return data?.isActive === true;
}

/**
 * What the backfill would write for one facility. Pure: [tenants] and
 * [units] are `{ id, data }` rows as read. Returns `updates` (tenantId,
 * unitId, unitArea, and the tenant's label and old values), `skipped` (each
 * with a reason and the units considered) and `counts`.
 *
 * Reasons: inactive, no-label, already-linked (no record, just counted),
 * no-held-unit-matches (label names none of the units they hold; never
 * touched), ambiguous (more than one held unit has the number),
 * match-is-available (the only match is marked available: a stale link).
 */
export function planTenantUnitIdBackfill({ tenants, units }) {
  const heldBy = new Map();
  for (const unit of units) {
    const holder = textOf(unit.data?.tenantId);
    if (!holder) continue;
    if (!heldBy.has(holder)) heldBy.set(holder, []);
    heldBy.get(holder).push(unit);
  }
  const updates = [];
  const skipped = [];
  const counts = {
    tenants: tenants.length,
    inactive: 0,
    noLabel: 0,
    alreadyLinked: 0,
    toUpdate: 0,
    noHeldUnitMatches: 0,
    ambiguous: 0,
    matchIsAvailable: 0,
  };
  for (const tenant of tenants) {
    const data = tenant.data ?? {};
    if (!isActive(data)) {
      counts.inactive++;
      continue;
    }
    const label = textOf(data.unitNumber);
    if (!label) {
      counts.noLabel++;
      continue;
    }
    if (textOf(data.unitId)) {
      counts.alreadyLinked++;
      continue;
    }
    const key = unitNumberKey(label);
    const held = heldBy.get(tenant.id) ?? [];
    const matches = held.filter((u) => u.data?.archived !== true && unitNumberKey(u.data?.unitNumber) === key);
    const describe = (u) => ({
      unitId: u.id,
      unitNumber: String(u.data?.unitNumber ?? ''),
      status: String(u.data?.status ?? ''),
      area: textOf(u.data?.area),
    });
    const base = {
      tenantId: tenant.id,
      name: String(data.name ?? '').trim(),
      label,
    };
    if (matches.length === 1 && String(matches[0].data?.status ?? '') !== 'available') {
      const unit = matches[0];
      updates.push({
        ...base,
        unitId: unit.id,
        unitArea: textOf(unit.data?.area),
        unitNumber: String(unit.data?.unitNumber ?? ''),
        before: { unitId: data.unitId ?? null, unitArea: data.unitArea ?? null },
      });
      counts.toUpdate++;
      continue;
    }
    let reason;
    if (matches.length === 0) {
      reason = 'no-held-unit-matches';
      counts.noHeldUnitMatches++;
    } else if (matches.length > 1) {
      reason = 'ambiguous';
      counts.ambiguous++;
    } else {
      reason = 'match-is-available';
      counts.matchIsAvailable++;
    }
    skipped.push({ ...base, reason, heldUnits: held.map(describe) });
  }
  return { updates, skipped, counts };
}

/** Parses argv; throws on anything it does not know. */
export function parseArgs(argv) {
  const out = { apply: false, facilities: [], project: null, outDir: null, json: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = () => {
      const v = argv[++i];
      if (v === undefined || v.startsWith('--')) throw new Error(`${arg} needs a value`);
      return v;
    };
    if (arg === '--apply') out.apply = true;
    else if (arg === '--facility') out.facilities.push(value());
    else if (arg === '--project') out.project = value();
    else if (arg === '--out') out.outDir = value();
    else if (arg === '--json') out.json = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (out.facilities.length === 0) throw new Error('Pass at least one --facility <id>.');
  return out;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const projectId = args.project || process.env.GOOGLE_CLOUD_PROJECT || 'storage-facility-creator';
  // firebase-admin is not a root dependency; borrow functions-tenant-lifecycle's copy.
  const require = createRequire(path.join(repoRoot, 'functions-tenant-lifecycle', 'package.json'));
  const { initializeApp, applicationDefault } = require('firebase-admin/app');
  const { getFirestore } = require('firebase-admin/firestore');
  initializeApp({ credential: applicationDefault(), projectId });
  const db = getFirestore();

  const outDir = path.resolve(args.outDir || defaultOutDir());
  mkdirSync(outDir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');

  console.log(`${args.apply ? 'APPLY' : 'DRY RUN'}: tenant unitId backfill, project ${projectId}`);
  for (const facilityId of args.facilities) {
    const facility = db.collection('facilities').doc(facilityId);
    const facilityName = (await facility.get()).get('name') ?? '';
    const [tenantSnap, unitSnap] = await Promise.all([
      facility.collection('tenants').where('isActive', '==', true).get(),
      facility.collection('units').get(),
    ]);
    const plan = planTenantUnitIdBackfill({
      tenants: tenantSnap.docs.map((d) => ({ id: d.id, data: d.data() })),
      units: unitSnap.docs.map((d) => ({ id: d.id, data: d.data() })),
    });

    const applied = [];
    const refused = [];
    if (args.apply) {
      for (const update of plan.updates) {
        const tenantRef = facility.collection('tenants').doc(update.tenantId);
        const unitRef = facility.collection('units').doc(update.unitId);
        try {
          const after = await db.runTransaction(async (txn) => {
            const [t, u] = await Promise.all([txn.get(tenantRef), txn.get(unitRef)]);
            const td = t.data();
            const ud = u.data();
            if (!td || td.isActive !== true) throw new Error('tenant no longer active');
            if (textOf(td.unitId)) throw new Error('tenant already has a unitId');
            if (unitNumberKey(td.unitNumber) !== unitNumberKey(update.label)) throw new Error('tenant label changed');
            if (!ud || textOf(ud.tenantId) !== update.tenantId) throw new Error('unit no longer theirs');
            if (ud.archived === true || String(ud.status ?? '') === 'available') throw new Error('unit archived or available');
            if (unitNumberKey(ud.unitNumber) !== unitNumberKey(update.label)) throw new Error('unit number changed');
            const fields = { unitId: update.unitId };
            const area = textOf(ud.area);
            if (area) fields.unitArea = area;
            txn.update(tenantRef, fields);
            return { unitId: update.unitId, unitArea: area };
          });
          applied.push({ ...update, after });
        } catch (e) {
          refused.push({ ...update, error: String(e?.message ?? e) });
        }
      }
    }

    const record = {
      mode: args.apply ? 'apply' : 'dry-run',
      projectId,
      facilityId,
      facilityName,
      ranAt: new Date().toISOString(),
      counts: { ...plan.counts, applied: applied.length, refused: refused.length },
      updates: args.apply
        ? applied
        : plan.updates.map((u) => ({ ...u, after: { unitId: u.unitId, unitArea: u.unitArea } })),
      refused,
      skipped: plan.skipped,
    };
    const file = path.join(outDir, `tenant-unit-id-${facilityId}-${record.mode}-${stamp}.json`);
    writeFileSync(file, `${JSON.stringify(record, null, 2)}\n`);

    console.log(`\n${facilityName || facilityId} (${facilityId})`);
    console.log(`  counts: ${JSON.stringify(record.counts)}`);
    for (const s of plan.skipped) {
      const held = s.heldUnits.map((u) => `${u.unitNumber}[${u.status}${u.area ? `, ${u.area}` : ''}]`).join(', ') || 'none';
      console.log(`  skip ${s.tenantId} "${s.name}" label "${s.label}": ${s.reason}; holds ${held}`);
    }
    if (args.json) console.log(JSON.stringify(record.updates, null, 2));
    for (const r of refused) console.log(`  refused ${r.tenantId}: ${r.error}`);
    console.log(`  record: ${file}`);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch((e) => {
    console.error(e?.message ?? e);
    process.exit(1);
  });
}

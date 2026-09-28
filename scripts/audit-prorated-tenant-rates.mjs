#!/usr/bin/env node
/**
 * Read-only audit: active tenants whose monthlyRate looks like a prorated
 * first month instead of a monthly rent.
 *
 * A mid-month move-in could write the prorated first month as the tenant's
 * monthlyRate: the app's Move-In wizard summed its rent line items, and an
 * older online move-in derived the rate the same way. The rent job
 * (functions-automation/src/rentChargeJob.ts) then charges monthlyRate every
 * month.
 *
 * An active tenant is flagged when
 *   - fractional-cents: monthlyRate is not a whole number of cents, or
 *   - equals-prorated-row: monthlyRate equals, to the cent, one of their
 *     prorated rent ledger rows (type 'proratedRent' as online move-ins post
 *     it, or metadata.lineItemType 'proratedRent' / metadata.isProrated as
 *     the wizard posts it).
 * A rate that is merely below the unit's rate is not flagged: negotiated
 * rates exist.
 *
 * For each flagged tenant it shows the units they hold, a proposed rate (the
 * sum of those units' rates, for the owner to confirm), and each recurring
 * rent charge with its shortfall against that rate.
 *
 * READ ONLY: it never writes, and has no option to.
 *
 * Credentials: Application Default Credentials
 * (`gcloud auth application-default login`), project from --project,
 * GOOGLE_CLOUD_PROJECT, or storage-facility-creator.
 *
 * Usage:
 *   node scripts/audit-prorated-tenant-rates.mjs                 (every facility)
 *   node scripts/audit-prorated-tenant-rates.mjs --facility <id> [--facility <id> ...]
 *   Options: --project <id>  --json (print the findings as JSON)
 */
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');

/** [amount] in whole cents, or null when it is not a finite number. */
export function toCents(amount) {
  const n = Number(amount);
  return Number.isFinite(n) ? Math.round(n * 100) : null;
}

/** Whether [amount] is a whole number of cents (within float noise). */
export function isWholeCents(amount) {
  const n = Number(amount);
  if (!Number.isFinite(n)) return false;
  return Math.abs(n * 100 - Math.round(n * 100)) < 1e-6;
}

/** A prorated rent row, as either move-in posts it. */
export function isProratedRentRow(data) {
  return (
    data?.type === 'proratedRent' ||
    data?.metadata?.lineItemType === 'proratedRent' ||
    data?.metadata?.isProrated === true
  );
}

/** A charge the rent job posted. */
function isRecurringRentCharge(data) {
  return data?.type === 'rentCharge' && data?.metadata?.recurringCharge === true;
}

/** Firestore Timestamp, Date or ISO string as YYYY-MM-DD, or null. */
export function dayOf(value) {
  if (!value) return null;
  const date =
    typeof value.toDate === 'function' ? value.toDate() : value instanceof Date ? value : new Date(value);
  return Number.isNaN(date.getTime()) ? null : date.toISOString().slice(0, 10);
}

const dollars = (cents) => (cents == null ? null : cents / 100);

/**
 * The flagged tenants of one facility. Pure: [tenants], [units] and
 * [ledgers] are `{ id, data }` rows as read (ledgers may be the facility's
 * whole ledger; rows of other tenants are ignored per tenant).
 */
export function auditTenantRates({ tenants, units, ledgers }) {
  const byTenant = (rows) => {
    const map = new Map();
    for (const row of rows) {
      const id = row.data?.tenantId;
      if (typeof id !== 'string' || !id) continue;
      if (!map.has(id)) map.set(id, []);
      map.get(id).push(row);
    }
    return map;
  };
  const ledgerOf = byTenant(ledgers);
  const unitsOf = byTenant(units);
  const flagged = [];
  let active = 0;
  for (const tenant of tenants) {
    const data = tenant.data ?? {};
    if (data.isActive !== true) continue;
    active++;
    const rate = data.monthlyRate;
    if (typeof rate !== 'number' || !Number.isFinite(rate) || rate <= 0) continue;
    const rows = ledgerOf.get(tenant.id) ?? [];
    const prorated = rows.filter((r) => isProratedRentRow(r.data));
    const reasons = [];
    if (!isWholeCents(rate)) reasons.push('fractional-cents');
    const matching = prorated.filter((r) => toCents(r.data.amount) === toCents(rate));
    if (matching.length > 0) reasons.push('equals-prorated-row');
    if (reasons.length === 0) continue;

    const held = (unitsOf.get(tenant.id) ?? []).filter(
      (u) => u.data?.archived !== true && String(u.data?.status ?? '') !== 'available',
    );
    const proposedCents =
      held.length > 0 ? held.reduce((sum, u) => sum + (toCents(u.data?.monthlyRate) ?? 0), 0) : null;
    const charges = rows
      .filter((r) => isRecurringRentCharge(r.data))
      .map((r) => ({
        ledgerId: r.id,
        year: r.data.metadata?.year ?? null,
        month: r.data.metadata?.month ?? null,
        entryDate: dayOf(r.data.entryDate),
        status: String(r.data.status ?? ''),
        amount: r.data.amount,
        shortfall: proposedCents == null ? null : dollars(proposedCents - (toCents(r.data.amount) ?? 0)),
      }))
      .sort((a, b) => String(a.entryDate).localeCompare(String(b.entryDate)));
    const postedCents = rows
      .filter((r) => r.data?.status === 'posted')
      .reduce((sum, r) => sum + (toCents(r.data.amount) ?? 0), 0);

    flagged.push({
      tenantId: tenant.id,
      name: String(data.name ?? ''),
      unitNumber: String(data.unitNumber ?? ''),
      createdBy: data.createdBy ?? null,
      createdAt: dayOf(data.createdAt),
      moveInDate: dayOf(data.moveInDate) ?? dayOf(prorated[0]?.data?.entryDate),
      monthlyRate: rate,
      reasons,
      proratedRows: prorated.map((r) => ({
        ledgerId: r.id,
        type: r.data.type,
        amount: r.data.amount,
        entryDate: dayOf(r.data.entryDate),
        status: String(r.data.status ?? ''),
        createdBy: r.data.createdBy ?? null,
      })),
      heldUnits: held.map((u) => ({
        unitId: u.id,
        unitNumber: String(u.data?.unitNumber ?? ''),
        area: u.data?.area ?? null,
        status: String(u.data?.status ?? ''),
        monthlyRate: u.data?.monthlyRate ?? null,
      })),
      proposedMonthlyRate: dollars(proposedCents),
      recurringCharges: charges,
      shortfallTotal:
        proposedCents == null
          ? null
          : dollars(
              charges
                .filter((c) => c.status === 'posted')
                .reduce((sum, c) => sum + Math.round((c.shortfall ?? 0) * 100), 0),
            ),
      ledgerBalance: dollars(postedCents),
      autopayStatus: data.autopay?.status ?? null,
    });
  }
  return { activeTenants: active, flagged };
}

export function parseArgs(argv) {
  const out = { facilities: [], project: null, json: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--facility') out.facilities.push(argv[++i]);
    else if (a === '--project') out.project = argv[++i];
    else if (a === '--json') out.json = true;
    else throw new Error(`Unknown argument: ${a}`);
  }
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

  const facilityIds =
    args.facilities.length > 0
      ? args.facilities
      : (await db.collection('facilities').select().get()).docs.map((d) => d.id);

  console.log(`READ ONLY: prorated-looking tenant rates, project ${projectId}, ${facilityIds.length} facilities`);
  const all = [];
  let activeTotal = 0;
  for (const facilityId of facilityIds) {
    const facility = db.collection('facilities').doc(facilityId);
    const [facilitySnap, tenantSnap, unitSnap, ledgerSnap] = await Promise.all([
      facility.get(),
      facility.collection('tenants').where('isActive', '==', true).get(),
      facility.collection('units').get(),
      facility.collection('ledgers').get(),
    ]);
    const rows = (snap) => snap.docs.map((d) => ({ id: d.id, data: d.data() }));
    const result = auditTenantRates({
      tenants: rows(tenantSnap),
      units: rows(unitSnap),
      ledgers: rows(ledgerSnap),
    });
    activeTotal += result.activeTenants;
    if (result.flagged.length === 0) continue;
    const facilityName = facilitySnap.get('name') ?? '';
    console.log(`\n${facilityName || facilityId} (${facilityId}): ${result.flagged.length} of ${result.activeTenants} active tenants`);
    for (const f of result.flagged) {
      all.push({ facilityId, facilityName, ...f });
      console.log(`  ${f.tenantId} "${f.name}" unit "${f.unitNumber}": monthlyRate ${f.monthlyRate} [${f.reasons.join(', ')}]`);
      console.log(`    created ${f.createdAt} by ${f.createdBy}; move-in ${f.moveInDate}; autopay ${f.autopayStatus}`);
      for (const u of f.heldUnits) {
        console.log(`    holds ${u.unitNumber}${u.area ? ` (${u.area})` : ''} [${u.status}] at ${u.monthlyRate}`);
      }
      for (const p of f.proratedRows) {
        console.log(`    prorated row ${p.ledgerId}: ${p.type} ${p.amount} on ${p.entryDate} [${p.status}] by ${p.createdBy}`);
      }
      for (const c of f.recurringCharges) {
        console.log(`    rent ${c.year}-${String(c.month).padStart(2, '0')} ${c.ledgerId}: ${c.amount} [${c.status}], short ${c.shortfall}`);
      }
      console.log(`    proposed monthlyRate ${f.proposedMonthlyRate}; shortfall so far ${f.shortfallTotal}; ledger balance ${f.ledgerBalance}`);
    }
  }
  console.log(`\n${all.length} flagged of ${activeTotal} active tenants.`);
  if (args.json) console.log(JSON.stringify(all, null, 2));
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch((e) => {
    console.error(e?.message ?? e);
    process.exit(1);
  });
}

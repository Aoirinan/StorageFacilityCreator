#!/usr/bin/env node
/**
 * Read-only audit: transfer credits written with the wrong sign.
 *
 * Completing a unit transfer posts two ledger entries: a credit for the
 * unit left (metadata.type 'transfer_refund') and a charge for the unit
 * taken (metadata.type 'transfer_charge'). A tenant's balance is the signed
 * sum of their posted amounts, so the credit must be negative. Until the
 * fix in lib/services/transfer_service.dart it was written positive: the
 * tenant's balance went UP by the credit instead of down, overstating what
 * they owed by twice the credit.
 *
 * For every facility this lists each transfer_refund entry with its sign,
 * flags the posted ones that are positive, and totals the overstatement per
 * tenant (2 x the credit: the balance holds +X where it should hold -X).
 * It also lists the facility's transfers by status so a credit can be
 * matched to the transfer that posted it.
 *
 * READ ONLY: it never writes, and has no option to. Correcting an entry is
 * a separate, deliberate step for the owner.
 *
 * Credentials: Application Default Credentials
 * (`gcloud auth application-default login`), project from --project,
 * GOOGLE_CLOUD_PROJECT, or storage-facility-creator.
 *
 * Usage:
 *   node scripts/audit-transfer-credit-signs.mjs                 (every facility)
 *   node scripts/audit-transfer-credit-signs.mjs --facility <id> [--facility <id> ...]
 *   Options: --project <id>  --json (print the findings as JSON)
 *            --modules-from <checkout> (a repo checkout whose
 *              functions-tenant-lifecycle has node_modules; for worktrees)
 */
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');

/** [value] as a finite number, or null. */
export function amountOf(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

/**
 * Classify one transfer_refund ledger row.
 * - 'wrong-sign': posted and positive (raises the balance; needs correction)
 * - 'ok': posted and negative
 * - 'zero': posted and zero
 * - 'voided' / 'pending': not counted in the balance
 * - 'unreadable': amount is not a number
 */
export function classifyRefund(data) {
  const status = data?.status;
  if (status === 'voided') return 'voided';
  if (status === 'pending') return 'pending';
  const amount = amountOf(data?.amount);
  if (amount === null) return 'unreadable';
  if (amount > 0) return 'wrong-sign';
  if (amount < 0) return 'ok';
  return 'zero';
}

/** How much a wrong-sign credit of [amount] overstates the balance. */
export function overstatement(amount) {
  const n = amountOf(amount);
  return n === null || n <= 0 ? 0 : Math.round(n * 2 * 100) / 100;
}

/** Firestore Timestamp, Date or ISO string as YYYY-MM-DD, or null. */
export function dayOf(value) {
  if (!value) return null;
  const d = typeof value.toDate === 'function' ? value.toDate() : new Date(value);
  return Number.isNaN(d.getTime()) ? null : d.toISOString().slice(0, 10);
}

function parseArgs(argv) {
  const out = { facilities: [], json: false, project: null, modulesFrom: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--facility') out.facilities.push(argv[++i]);
    else if (a === '--project') out.project = argv[++i];
    else if (a === '--modules-from') out.modulesFrom = argv[++i];
    else if (a === '--json') out.json = true;
    else if (a === '--help' || a === '-h') {
      console.log(
        'node scripts/audit-transfer-credit-signs.mjs [--facility <id>]... [--project <id>] [--json] [--modules-from <checkout>]',
      );
      process.exit(0);
    } else {
      console.error(`Unknown argument: ${a}`);
      process.exit(2);
    }
  }
  return out;
}

async function auditFacility(db, facilityId) {
  const facilityRef = db.collection('facilities').doc(facilityId);
  const [transfersSnap, refundsSnap, chargesSnap] = await Promise.all([
    facilityRef.collection('transfers').get(),
    facilityRef.collection('ledgers').where('metadata.type', '==', 'transfer_refund').get(),
    facilityRef.collection('ledgers').where('metadata.type', '==', 'transfer_charge').get(),
  ]);

  const transfersByStatus = {};
  const transfers = [];
  for (const doc of transfersSnap.docs) {
    const d = doc.data();
    const status = d.status || 'unknown';
    transfersByStatus[status] = (transfersByStatus[status] || 0) + 1;
    transfers.push({
      id: doc.id,
      status,
      tenantId: d.tenantId || null,
      transferDate: dayOf(d.transferDate),
      fromUnitProratedRent: amountOf(d.fromUnitProratedRent),
      toUnitProratedRent: amountOf(d.toUnitProratedRent),
      netAmount: amountOf(d.netAmount),
      ledgerEntryIds: Array.isArray(d.ledgerEntryIds) ? d.ledgerEntryIds : [],
    });
  }

  const refunds = [];
  const overstatedByTenant = {};
  for (const doc of refundsSnap.docs) {
    const d = doc.data();
    const cls = classifyRefund(d);
    const row = {
      id: doc.id,
      tenantId: d.tenantId || null,
      transferId: d.metadata?.transferId || null,
      status: d.status || null,
      amount: amountOf(d.amount),
      entryDate: dayOf(d.entryDate),
      classification: cls,
    };
    refunds.push(row);
    if (cls === 'wrong-sign' && row.tenantId) {
      const sum = (overstatedByTenant[row.tenantId] || 0) + overstatement(row.amount);
      overstatedByTenant[row.tenantId] = Math.round(sum * 100) / 100;
    }
  }

  const charges = chargesSnap.docs.map((doc) => {
    const d = doc.data();
    const amount = amountOf(d.amount);
    let classification = 'ok';
    if (d.status === 'voided') classification = 'voided';
    else if (amount === null) classification = 'unreadable';
    else if (amount < 0) classification = 'wrong-sign'; // charges must be positive
    return {
      id: doc.id,
      tenantId: d.tenantId || null,
      transferId: d.metadata?.transferId || null,
      status: d.status || null,
      amount,
      classification,
    };
  });

  return {
    facilityId,
    transfersByStatus,
    transfers,
    refunds,
    charges,
    wrongSignRefunds: refunds.filter((r) => r.classification === 'wrong-sign').length,
    overstatedByTenant,
  };
}

function printReport(results) {
  let totalWrong = 0;
  let totalTransfers = 0;
  for (const r of results) {
    const n = Object.values(r.transfersByStatus).reduce((a, b) => a + b, 0);
    totalTransfers += n;
    totalWrong += r.wrongSignRefunds;
    if (n === 0 && r.refunds.length === 0 && r.charges.length === 0) continue;
    console.log(`\nFacility ${r.facilityId}`);
    console.log(`  transfers: ${n} ${JSON.stringify(r.transfersByStatus)}`);
    for (const t of r.transfers) {
      console.log(
        `    transfer ${t.id} ${t.status} ${t.transferDate ?? '-'} tenant=${t.tenantId} ` +
          `from=${t.fromUnitProratedRent} to=${t.toUnitProratedRent} net=${t.netAmount} ` +
          `ledgerEntryIds=${t.ledgerEntryIds.length}`,
      );
    }
    console.log(`  transfer_refund entries: ${r.refunds.length} (wrong sign: ${r.wrongSignRefunds})`);
    for (const e of r.refunds) {
      console.log(
        `    ${e.classification.padEnd(10)} ${e.id} ${e.status} ${e.entryDate ?? '-'} ` +
          `tenant=${e.tenantId} transfer=${e.transferId} amount=${e.amount}`,
      );
    }
    console.log(`  transfer_charge entries: ${r.charges.length}`);
    for (const e of r.charges) {
      console.log(
        `    ${e.classification.padEnd(10)} ${e.id} ${e.status} tenant=${e.tenantId} ` +
          `transfer=${e.transferId} amount=${e.amount}`,
      );
    }
    for (const [tenantId, over] of Object.entries(r.overstatedByTenant)) {
      console.log(`  tenant ${tenantId}: balance overstated by ${over.toFixed(2)}`);
    }
  }
  console.log(
    `\n${results.length} facilities, ${totalTransfers} transfers, ` +
      `${totalWrong} posted transfer credits with the wrong sign.`,
  );
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const projectId = args.project || process.env.GOOGLE_CLOUD_PROJECT || 'storage-facility-creator';
  // firebase-admin is not a root dependency; borrow functions-tenant-lifecycle's copy.
  const modulesRoot = args.modulesFrom || repoRoot;
  const require = createRequire(path.join(modulesRoot, 'functions-tenant-lifecycle', 'package.json'));
  const { initializeApp, applicationDefault } = require('firebase-admin/app');
  const { getFirestore } = require('firebase-admin/firestore');
  initializeApp({ credential: applicationDefault(), projectId });
  const db = getFirestore();

  let facilityIds = args.facilities;
  if (facilityIds.length === 0) {
    const refs = await db.collection('facilities').listDocuments();
    facilityIds = refs.map((r) => r.id);
  }

  const results = [];
  for (const id of facilityIds) {
    results.push(await auditFacility(db, id));
  }

  if (args.json) {
    console.log(JSON.stringify(results, null, 2));
  } else {
    printReport(results);
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}

#!/usr/bin/env node
/**
 * One-off: set facilities/{id}/emailUsage/{YYYY-MM}.emailMonthlyLimit from
 * subscription status + functions-shared/src/constants/emailMonthlyLimits.ts
 * (does not change emailMonthlyCount).
 *
 * Usage (from repo functions/ — has firebase-admin):
 *   npm run migrate:email-limits -- --dry-run
 *   npm run migrate:email-limits
 *   npm run migrate:email-limits -- --facility <facilityId>
 *   npm run migrate:email-limits -- --month 2026-04
 *
 * Auth: uses functions/serviceAccountKey.json if present, else Application Default Credentials.
 */

const fs = require('fs');
const path = require('path');
const admin = require('firebase-admin');

const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');
const facilityIdx = args.indexOf('--facility');
const singleFacilityId =
  facilityIdx >= 0 && args[facilityIdx + 1] ? args[facilityIdx + 1] : null;
const monthIdx = args.indexOf('--month');
let monthOverride = monthIdx >= 0 && args[monthIdx + 1] ? args[monthIdx + 1] : null;
if (monthOverride && !/^\d{4}-\d{2}$/.test(monthOverride)) {
  console.error('Invalid --month (use YYYY-MM)');
  process.exit(1);
}

function loadLimitsFromSource() {
  const tsPath = path.join(__dirname, '..', '..', 'functions-shared', 'src', 'constants', 'emailMonthlyLimits.ts');
  const src = fs.readFileSync(tsPath, 'utf8');
  const trialingM = src.match(/EMAIL_MONTHLY_LIMIT_TRIALING\s*=\s*(\d+)/);
  const paidM = src.match(/EMAIL_MONTHLY_LIMIT_PAID\s*=\s*(\d+)/);
  if (!trialingM || !paidM) {
    console.error('Could not parse limits from functions-shared/src/constants/emailMonthlyLimits.ts');
    process.exit(1);
  }
  const trialing = Number(trialingM[1]);
  const paid = Number(paidM[1]);
  return {
    trialing,
    paid,
    forAccount(isTrialing) {
      return isTrialing ? trialing : paid;
    },
  };
}

function currentMonthKey() {
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
}

function initAdmin() {
  const keyPath = path.join(__dirname, '..', 'serviceAccountKey.json');
  if (fs.existsSync(keyPath)) {
    const sa = JSON.parse(fs.readFileSync(keyPath, 'utf8'));
    admin.initializeApp({ credential: admin.credential.cert(sa) });
    console.log('Using serviceAccountKey.json');
  } else {
    admin.initializeApp();
    console.log('Using Application Default Credentials');
  }
}

async function main() {
  const limits = loadLimitsFromSource();
  const monthKey = monthOverride || currentMonthKey();
  console.log(`Month: ${monthKey}  dryRun=${dryRun}`);
  console.log(`Limits from source: trialing=${limits.trialing}, paid=${limits.paid}\n`);

  initAdmin();
  const db = admin.firestore();

  let snap;
  if (singleFacilityId) {
    const ref = db.collection('facilities').doc(singleFacilityId);
    const doc = await ref.get();
    if (!doc.exists) {
      console.error(`No facility: ${singleFacilityId}`);
      process.exit(1);
    }
    snap = { docs: [doc], empty: false };
  } else {
    snap = await db.collection('facilities').get();
  }

  let updated = 0;
  let skipped = 0;

  for (const doc of snap.docs) {
    const facilityId = doc.id;
    const ownerUid = doc.get('ownerUid');
    if (!ownerUid) {
      console.log(`[skip] ${facilityId} — no ownerUid`);
      skipped++;
      continue;
    }

    const acctSnap = await db
      .collection('facilityCreatorAccounts')
      .where('ownerUid', '==', ownerUid)
      .limit(1)
      .get();

    let isTrialing = false;
    if (!acctSnap.empty) {
      const status = acctSnap.docs[0].get('subscriptionStatus');
      isTrialing = status === 'trialing';
    } else {
      console.warn(`[warn] ${facilityId} — no facilityCreatorAccounts row; using paid limit`);
    }

    const newLimit = limits.forAccount(isTrialing);
    const usageRef = db
      .collection('facilities')
      .doc(facilityId)
      .collection('emailUsage')
      .doc(monthKey);

    const before = await usageRef.get();
    const prev = before.exists ? before.get('emailMonthlyLimit') : undefined;
    const count = before.exists ? before.get('emailMonthlyCount') : undefined;

    if (prev === newLimit) {
      console.log(`[ok] ${facilityId} already ${newLimit} (count=${count ?? 'n/a'})`);
      skipped++;
      continue;
    }

    console.log(
      `[${dryRun ? 'dry' : 'set'}] ${facilityId} owner=${ownerUid} trialing=${isTrialing} ` +
        `limit ${prev ?? '(none)'} → ${newLimit} (count unchanged, was ${count ?? 'n/a'})`,
    );

    if (!dryRun) {
      await usageRef.set(
        {
          emailMonthlyLimit: newLimit,
          emailMonth: monthKey,
          lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    }
    updated++;
  }

  console.log(`\nDone. ${dryRun ? 'Would update' : 'Updated'}: ${updated}, skipped/unchanged: ${skipped}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

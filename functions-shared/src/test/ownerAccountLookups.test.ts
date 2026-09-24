import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';

/**
 * Every server lookup of an owner's account goes through findOwnerAccountDoc.
 * The callables and triggers that did their own `.where('ownerUid', ...)
 * .limit(1)` took whichever duplicate Firestore returned first, so one owner
 * could be linked, billed, rewarded or capped on a pendingApproval duplicate
 * while the app used the original. This reads the other codebases' sources
 * (CI checks out the whole repo) so a call site that goes back to its own
 * query fails here.
 */
const repoRoot = path.resolve(__dirname, '..', '..', '..');

// One-off data migrations, never run against live traffic again.
const EXCLUDED = [path.join('functions-admin', 'src', 'migrations')];

function sourceFiles(dir: string): string[] {
  if (!fs.existsSync(dir)) return [];
  const out: string[] = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === 'test' || entry.name === 'node_modules') continue;
      out.push(...sourceFiles(full));
    } else if (entry.name.endsWith('.ts')) {
      out.push(full);
    }
  }
  return out;
}

/** `.collection('facilityCreatorAccounts')` followed by a where on ownerUid. */
const OWNER_QUERY =
  /collection\(\s*['"]facilityCreatorAccounts['"]\s*\)\s*\.where\(\s*['"]ownerUid['"]/g;

test('no functions codebase queries an owner account itself', () => {
  const packages = fs
    .readdirSync(repoRoot, { withFileTypes: true })
    .filter((d) => d.isDirectory() && /^functions(-|$)/.test(d.name) && d.name !== 'functions-shared')
    .map((d) => d.name);
  assert.ok(packages.includes('functions-integrations'), `found ${packages.join(', ')}`);

  const offenders: string[] = [];
  let scanned = 0;
  for (const pkg of packages) {
    for (const file of sourceFiles(path.join(repoRoot, pkg, 'src'))) {
      const rel = path.relative(repoRoot, file);
      if (EXCLUDED.some((ex) => rel.startsWith(ex))) continue;
      scanned += 1;
      const source = fs.readFileSync(file, 'utf8');
      if (OWNER_QUERY.test(source)) offenders.push(rel);
      OWNER_QUERY.lastIndex = 0;
    }
  }
  assert.ok(scanned > 50, `scanned only ${scanned} files`);
  assert.deepEqual(offenders, [], 'use findOwnerAccountDoc from @sfc/functions-shared');
});

test('the lookups that used limit(1) now use the shared helper', () => {
  for (const rel of [
    'functions-integrations/src/reconcileAccountFacilityIds.ts',
    'functions-admin/src/superAdminCreateFacilityForOwner.ts',
    'functions-marketing/src/referralRewards.ts',
    'functions-outbound-email/src/outboundRaw.ts',
  ]) {
    const source = fs.readFileSync(path.join(repoRoot, rel), 'utf8');
    assert.match(source, /findOwnerAccountDoc\(/, rel);
  }
});

// Drives the real per-facility job against an in-memory Firestore: what it
// charges, sends, stamps and clears, not just the helpers it calls.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as admin from 'firebase-admin';
import { processDelinquencyForFacility, type DelinquencyDeps } from '../delinquencyAutomation';
import { FakeFirestore } from './fakeFirestore';

const DAY = 24 * 60 * 60 * 1000;
const NOW = new Date('2026-11-15T12:00:00Z');
const ts = (d: Date) => admin.firestore.Timestamp.fromDate(d);
const daysAgo = (n: number) => ts(new Date(NOW.getTime() - n * DAY));
/** Paid through the end of this month: not late. */
const CURRENT = ts(new Date('2026-11-30T05:00:00Z'));

const FACILITY = 'f1';
const tenantsPath = `facilities/${FACILITY}/tenants`;
const ledgersPath = `facilities/${FACILITY}/ledgers`;
const liensPath = `facilities/${FACILITY}/liens`;

function setup(billingSettings: Record<string, unknown>) {
  const db = new FakeFirestore(() => NOW);
  db.seed('facilities', FACILITY, { active: true, name: 'Example Storage', billingSettings });
  const audits: Array<{ eventType?: string; tenantId?: string }> = [];
  const emails: string[] = [];
  const deps: Partial<DelinquencyDeps> = {
    db: db.asFirestore(),
    now: () => NOW,
    writeAuditLog: (async (_facilityId: string, entry: { eventType?: string; tenantId?: string }) => {
      audits.push(entry);
    }) as DelinquencyDeps['writeAuditLog'],
    sendEmail: (async (msg: { to: string }) => {
      emails.push(msg.to);
      return { sent: true };
    }) as unknown as DelinquencyDeps['sendEmail'],
    fromEmail: () => ({ email: 'noreply@example.com', name: 'Example' }),
  };

  let ledgerSeq = 0;
  const tenant = (id: string, data: Record<string, unknown>, balance: number) => {
    db.seed(tenantsPath, id, {
      isActive: true,
      name: `Tenant ${id}`,
      email: `${id}@example.com`,
      createdAt: ts(new Date('2026-09-21T15:00:00Z')),
      ...data,
    });
    if (balance !== 0) {
      db.seed(ledgersPath, `seed${ledgerSeq++}`, {
        tenantId: id,
        type: balance > 0 ? 'rentCharge' : 'payment',
        amount: balance,
        status: 'posted',
        entryDate: daysAgo(40),
      });
    }
  };

  const lateFees = (tenantId?: string) =>
    [...db.docs(ledgersPath).values()].filter(
      (e) => e.type === 'lateFee' && (tenantId === undefined || e.tenantId === tenantId),
    );
  const stored = (id: string) => db.docs(tenantsPath).get(id)!;
  const run = () => processDelinquencyForFacility(FACILITY, false, deps);

  return { db, audits, emails, tenant, lateFees, stored, run };
}

test('no paidThrough: no late fee, no notice, no flags, even with fees and notices on', async () => {
  // Imported from a paper ledger in September, a balance on the ledger,
  // nothing recorded as paid: createdAt + 30 days + grace is long past.
  const f = setup({
    lateFeeAmount: 10,
    gracePeriodDays: 10,
    enableAutoLateFees: true,
    enableAutoNotices: true,
  });
  f.tenant('imported', {}, 150);

  const result = await f.run();

  assert.equal(result.success, true);
  assert.equal(result.skippedNoPaidThroughCount, 1);
  assert.equal(result.lateFeeAppliedCount, 0);
  assert.deepEqual(f.lateFees(), []);
  assert.deepEqual(f.emails, [], 'no notice');
  const t = f.stored('imported');
  assert.equal(t.delinquencyStatus, undefined);
  assert.equal(t.lienEligibleDate, undefined);
  assert.equal(t.lastLateFeeDate, undefined);
});

test('enableAutoLateFees missing: no late fee', async () => {
  const f = setup({ lateFeeAmount: 10, gracePeriodDays: 10 });
  f.tenant('late', { paidThrough: daysAgo(60) }, 150);

  const result = await f.run();

  assert.equal(result.lateFeeAppliedCount, 0);
  assert.deepEqual(f.lateFees(), []);
});

test('enableAutoLateFees false: no late fee', async () => {
  const f = setup({ lateFeeAmount: 10, gracePeriodDays: 10, enableAutoLateFees: false });
  f.tenant('late', { paidThrough: daysAgo(60) }, 150);

  await f.run();

  assert.deepEqual(f.lateFees(), []);
});

test('enableAutoLateFees true, paid through 60 days ago: exactly one fee', async () => {
  const f = setup({ lateFeeAmount: 10, gracePeriodDays: 10, enableAutoLateFees: true });
  f.tenant('late', { paidThrough: daysAgo(60) }, 150);

  const first = await f.run();
  assert.equal(first.lateFeeAppliedCount, 1);
  // The job runs every night; the second run this month adds nothing.
  const second = await f.run();
  assert.equal(second.lateFeeAppliedCount, 0);

  const fees = f.lateFees('late');
  assert.equal(fees.length, 1);
  assert.equal(fees[0].amount, 10);
  assert.equal(fees[0].status, 'posted');
  // 60 days since paidThrough, 10 of them grace: 50 days late, past the
  // default lockout threshold of 45. Stamped only; auto-lockout is off.
  assert.equal(f.stored('late').delinquencyStatus, 'lockout');
});

test('flags are cleared only when not late, balance <= 0 and no active lien', async () => {
  const f = setup({ lateFeeAmount: 10, gracePeriodDays: 10 });
  const flags = { delinquencyStatus: 'lien', lienEligibleDate: daysAgo(5) };
  f.tenant('caughtUp', { paidThrough: CURRENT, ...flags }, 0);
  f.tenant('credit', { paidThrough: CURRENT, ...flags }, -25);
  f.tenant('owes', { paidThrough: CURRENT, ...flags }, 50);
  f.tenant('activeLien', { paidThrough: CURRENT, ...flags }, 0);
  f.tenant('resolvedLien', { paidThrough: CURRENT, ...flags }, 0);
  f.tenant('stillLate', { paidThrough: daysAgo(60), ...flags }, 0);
  f.tenant('noPaidThroughPaidUp', { ...flags }, 0);
  f.tenant('noPaidThroughOwes', { ...flags }, 80);
  f.db.seed(liensPath, 'lien1', { tenantId: 'activeLien', status: 'active', isActive: true });
  f.db.seed(liensPath, 'lien2', { tenantId: 'resolvedLien', status: 'resolved', isActive: true });

  await f.run();

  const cleared = (id: string) =>
    f.stored(id).delinquencyStatus === undefined && f.stored(id).lienEligibleDate === undefined;
  assert.ok(cleared('caughtUp'), 'caught up and owes nothing');
  assert.ok(cleared('credit'), 'a credit balance owes nothing');
  assert.ok(cleared('resolvedLien'), 'a resolved lien does not hold the flags');
  assert.ok(cleared('noPaidThroughPaidUp'), 'nothing owed and no lateness to measure');
  assert.ok(!cleared('owes'), 'still owes');
  assert.ok(!cleared('activeLien'), 'an active lien keeps the flags');
  assert.ok(!cleared('stillLate'), 'still late by paidThrough');
  assert.ok(!cleared('noPaidThroughOwes'), 'owes, and no paidThrough to say otherwise');

  assert.deepEqual(
    f.audits
      .filter((a) => a.eventType === 'delinquency.flagsCleared')
      .map((a) => a.tenantId)
      .sort(),
    ['caughtUp', 'credit', 'noPaidThroughPaidUp', 'resolvedLien'],
  );
});

test('a dry run clears nothing', async () => {
  const f = setup({});
  f.tenant('caughtUp', { paidThrough: CURRENT, delinquencyStatus: 'late' }, 0);
  const deps = { db: f.db.asFirestore(), now: () => NOW, writeAuditLog: (async () => {}) as DelinquencyDeps['writeAuditLog'] };
  await processDelinquencyForFacility(FACILITY, true, deps);
  assert.equal(f.stored('caughtUp').delinquencyStatus, 'late');
});

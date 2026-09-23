import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import {
  DocData,
  LinkedDoc,
  TenantDeleteRecords,
  buildTenantDeletePlan,
  facilityAllowsPermanentTenantDelete,
  facilityCreatorAccountIdOf,
  hasAutopaySubscription,
  isActiveFlagSet,
  isLiveCardPaymentRow,
  isLiveInvoiceRow,
  isLiveLedgerRow,
  isLivePaymentRow,
  isTenantDeleteBlocked,
  permanentDeleteBlockers,
  scanLiveRows,
  timestampMillis,
  toTenantDeleteBlock,
} from '../tenants/permanentDeleteRules';
import { isFacilityOwnerOrManager } from '../auth/facilityAccess';

/**
 * The same table test/tenant_delete_guard_test.dart runs against TenantService.
 * Read from src/ (tsc does not copy JSON): lib/test/.. is the package root.
 */
type ParityCases = {
  scanLimit: number;
  rows: Array<{ kind: string; row: DocData; live: boolean }>;
  autopay: Array<{ billing: DocData | null; has: boolean }>;
  blockers: Array<{ counts: Record<string, number | boolean>; reasons: string[] }>;
  plans: Array<{
    name: string;
    records: Record<string, unknown>;
    reasons: string[];
    heldUnits: Array<{ unitNumber: string; status: string }>;
  }>;
};
const parity = JSON.parse(
  readFileSync(join(__dirname, '..', '..', 'src', 'test', 'fixtures', 'tenantDeleteParity.json'), 'utf8'),
) as ParityCases;

const predicates: Record<string, (row: DocData) => boolean> = {
  ledger: isLiveLedgerRow,
  invoice: isLiveInvoiceRow,
  payment: isLivePaymentRow,
  cardPayment: isLiveCardPaymentRow,
  activeFlag: isActiveFlagSet,
};

function records(tenantId: string, raw: Record<string, unknown>): TenantDeleteRecords {
  const rows = (key: string) => (raw[key] as DocData[] | undefined) ?? [];
  const units = rows('units').map(
    (u): LinkedDoc => ({ id: String(u.id), data: { tenantId, ...u } }),
  );
  return {
    tenant: (raw.tenant as DocData | undefined) ?? null,
    ledgers: rows('ledgers'),
    invoices: rows('invoices'),
    payments: rows('payments'),
    contracts: rows('contracts'),
    liens: rows('liens'),
    paymentMethods: rows('paymentMethods'),
    tenantPayments: rows('tenantPayments'),
    billing: (raw.billing as DocData | undefined) ?? null,
    units,
    gateAccess: (raw.gateAccess as LinkedDoc[] | undefined) ?? [],
  };
}

test('parity: each row predicate matches the shared table', () => {
  for (const c of parity.rows) {
    assert.equal(predicates[c.kind](c.row), c.live, `${c.kind} ${JSON.stringify(c.row)}`);
  }
});

test('parity: autopay subscription matches the shared table', () => {
  for (const c of parity.autopay) {
    assert.equal(hasAutopaySubscription(c.billing), c.has, JSON.stringify(c.billing));
  }
});

test('parity: blocker wording matches the shared table word for word', () => {
  for (const c of parity.blockers) {
    assert.deepEqual(permanentDeleteBlockers(c.counts), c.reasons, JSON.stringify(c.counts));
  }
});

test('parity: plans give the same reasons and held units as the app', () => {
  for (const c of parity.plans) {
    const plan = buildTenantDeletePlan('t1', records('t1', c.records), parity.scanLimit);
    assert.deepEqual(plan.reasons, c.reasons, c.name);
    assert.deepEqual(plan.heldUnits, c.heldUnits, c.name);
    assert.equal(isTenantDeleteBlocked(plan), c.reasons.length > 0 || c.heldUnits.length > 0, c.name);
  }
});

test('scanLiveRows: a row that cannot be read counts as live', () => {
  const scan = scanLiveRows(
    [1, 2],
    (row) => {
      if (row === 1) throw new Error('bad row');
      return false;
    },
    10,
  );
  assert.deepEqual(scan, { live: 1, inconclusive: false });
});

test('plan: carries the before snapshot, unlinks non-archived units, turns off only live gate codes', () => {
  const plan = buildTenantDeletePlan(
    't1',
    records('t1', {
      tenant: { name: ' Bo Diaz ', phone: '555' },
      units: [
        { id: 'u9', unitNumber: '9', status: 'available' },
        // The app's unit lists skip archived units, and so does the delete.
        { id: 'u10', unitNumber: '10', status: 'occupied', archived: true },
      ],
      gateAccess: [
        { id: 'g1', data: { isActive: true } },
        { id: 'g2', data: {} },
        { id: 'g3', data: { isActive: false } },
      ],
    }),
  );
  assert.equal(plan.tenantName, 'Bo Diaz');
  assert.deepEqual(plan.before, { name: ' Bo Diaz ', phone: '555' });
  assert.deepEqual(plan.unitIds, ['u9']);
  assert.deepEqual(plan.heldUnits, []);
  assert.deepEqual(plan.activeGateAccessIds, ['g1', 'g2']);
  assert.equal(isTenantDeleteBlocked(plan), false);
});

test('plan: a missing tenant doc is named by its id, and a unit held by someone else is not theirs', () => {
  const plan = buildTenantDeletePlan(
    't1',
    records('t1', { units: [{ id: 'u1', unitNumber: '1', status: 'occupied', tenantId: 't2' }] }),
  );
  assert.equal(plan.tenantName, 't1');
  assert.equal(plan.before, null);
  assert.deepEqual(plan.heldUnits, []);
  assert.deepEqual(toTenantDeleteBlock(plan), { tenantId: 't1', tenantName: 't1', reasons: [], heldUnits: [] });
});

test('owner or manager: mirrors the rules, not facility staff', () => {
  const facility = {
    ownerUid: 'owner',
    managers: { mgrMap: true, notMgr: false },
    roles: { r_owner: 'owner', r_mgr: 'manager', r_admin: 'admin', r_emp: 'employee', r_view: 'viewer' },
  };
  for (const uid of ['owner', 'mgrMap', 'r_owner', 'r_mgr', 'r_admin']) {
    assert.equal(isFacilityOwnerOrManager(facility, uid), true, uid);
  }
  // The old rule never let employees or viewers delete; the callable must not either.
  for (const uid of ['notMgr', 'r_emp', 'r_view', 'stranger']) {
    assert.equal(isFacilityOwnerOrManager(facility, uid), false, uid);
  }
  assert.equal(isFacilityOwnerOrManager({}, 'owner'), false);
});

test('entitlement: mirrors _assertFacilityAllowsPermanentTenantDeletion', () => {
  const now = Date.UTC(2026, 8, 23);
  const later = { toMillis: () => now + 86_400_000 };
  const earlier = { toMillis: () => now - 86_400_000 };

  // Facility platform subscription.
  assert.equal(facilityAllowsPermanentTenantDelete({ platformSubscriptionStatus: 'active' }, null, now), true);
  assert.equal(
    facilityAllowsPermanentTenantDelete(
      { platformSubscriptionStatus: 'trialing', platformSubscriptionTrialEnd: later },
      null,
      now,
    ),
    true,
  );
  // A facility trial needs an end date still ahead (FacilityModel.hasActivePlatformSubscription).
  for (const trialEnd of [earlier, undefined]) {
    assert.equal(
      facilityAllowsPermanentTenantDelete(
        { platformSubscriptionStatus: 'trialing', platformSubscriptionTrialEnd: trialEnd },
        null,
        now,
      ),
      false,
    );
  }
  for (const status of ['past_due', 'cancelled', 'unpaid', undefined]) {
    assert.equal(facilityAllowsPermanentTenantDelete({ platformSubscriptionStatus: status }, null, now), false);
  }

  // Creator account.
  const unpaid = {};
  assert.equal(facilityAllowsPermanentTenantDelete(unpaid, { subscriptionStatus: 'active' }, now), true);
  assert.equal(
    facilityAllowsPermanentTenantDelete(unpaid, { subscriptionStatus: 'active', suspended: true }, now),
    false,
  );
  // An account trial with no end date is open; one past its end is not.
  assert.equal(facilityAllowsPermanentTenantDelete(unpaid, { subscriptionStatus: 'trialing' }, now), true);
  assert.equal(
    facilityAllowsPermanentTenantDelete(unpaid, { subscriptionStatus: 'trialing', subscriptionTrialEnd: later }, now),
    true,
  );
  assert.equal(
    facilityAllowsPermanentTenantDelete(
      unpaid,
      { subscriptionStatus: 'trialing', subscriptionTrialEnd: earlier },
      now,
    ),
    false,
  );
  for (const status of ['pendingApproval', 'pastDue', 'cancelled', 'bogus', undefined]) {
    assert.equal(facilityAllowsPermanentTenantDelete(unpaid, { subscriptionStatus: status }, now), false, String(status));
  }

  assert.equal(facilityCreatorAccountIdOf({ facilityCreatorAccountId: 'acc1' }), 'acc1');
  assert.equal(facilityCreatorAccountIdOf({ facilityCreatorAccountId: '' }), null);
  assert.equal(facilityCreatorAccountIdOf({}), null);
});

test('timestampMillis reads Timestamps, Dates and numbers only', () => {
  assert.equal(timestampMillis({ toMillis: () => 5 }), 5);
  assert.equal(timestampMillis(new Date(7)), 7);
  assert.equal(timestampMillis(9), 9);
  assert.equal(timestampMillis('2026-01-01'), null);
  assert.equal(timestampMillis(null), null);
});

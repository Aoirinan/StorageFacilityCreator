import test from 'node:test';
import assert from 'node:assert/strict';
import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

import {
  DeleteActor,
  MAX_TENANTS_PER_DELETE,
  TenantDeleteTransaction,
  actorRoleOf,
  authorizePermanentTenantDelete,
  deleteTenantsInTransaction,
  parseDeleteTenantsRequest,
} from '../tenantPermanentDelete';

type DocData = Record<string, unknown>;
type Write = { op: 'update' | 'delete' | 'create'; path: string; fields?: DocData };

/** One tenant's records as the transaction reads them. */
type FakeTenant = {
  doc?: DocData | null;
  facilityRows?: Record<string, DocData[]>;
  ownRows?: Record<string, DocData[]>;
  billing?: DocData | null;
  units?: Array<{ id: string; data: DocData }>;
  gateAccess?: Array<{ id: string; data: DocData }>;
};

/** A transaction over fake records that, like Firestore, refuses a read after a write. */
class FakeTxn implements TenantDeleteTransaction {
  readonly writes: Write[] = [];
  readonly limits: number[] = [];

  constructor(private readonly tenants: Record<string, FakeTenant>) {}

  private get(tenantId: string): FakeTenant {
    return this.tenants[tenantId] ?? {};
  }

  private read<T>(value: T): Promise<T> {
    if (this.writes.length > 0) throw new Error('read after write');
    return Promise.resolve(value);
  }

  tenant(tenantId: string) {
    const t = this.get(tenantId);
    return this.read(t.doc === undefined ? { name: 'Ada Park' } : t.doc);
  }

  facilityRows(collection: string, tenantId: string, limit: number) {
    this.limits.push(limit);
    return this.read((this.get(tenantId).facilityRows?.[collection] ?? []).slice(0, limit));
  }

  tenantRows(tenantId: string, subcollection: string, limit: number) {
    this.limits.push(limit);
    return this.read((this.get(tenantId).ownRows?.[subcollection] ?? []).slice(0, limit));
  }

  tenantDoc(tenantId: string, subcollection: string, docId: string) {
    assert.equal(`${subcollection}/${docId}`, 'billing/default');
    return this.read(this.get(tenantId).billing ?? null);
  }

  linkedDocs(collection: 'units' | 'gateAccess', tenantId: string) {
    const t = this.get(tenantId);
    const docs = (collection === 'units' ? t.units : t.gateAccess) ?? [];
    return this.read(docs.map((d) => ({ id: d.id, data: { tenantId, ...d.data } })));
  }

  update(collection: string, docId: string, fields: DocData) {
    this.writes.push({ op: 'update', path: `${collection}/${docId}`, fields });
  }

  delete(collection: string, docId: string) {
    this.writes.push({ op: 'delete', path: `${collection}/${docId}` });
  }

  create(collection: string, fields: DocData) {
    this.writes.push({ op: 'create', path: collection, fields });
  }

  paths(): string[] {
    return this.writes.map((w) => `${w.op} ${w.path}`);
  }
}

const actor: DeleteActor = { uid: 'owner', email: 'owner@example.com', role: 'owner' };
const NOW = Date.UTC(2026, 8, 23);

function run(txn: FakeTxn, tenantIds: string[]) {
  return deleteTenantsInTransaction(txn, { facilityId: 'f1', tenantIds, actor, nowMs: NOW });
}

const { FieldValue } = admin.firestore;

test('a tenant with history is refused and nothing is written', async () => {
  const txn = new FakeTxn({ t1: { facilityRows: { ledgers: [{ status: 'posted' }] } } });
  const result = await run(txn, ['t1']);
  assert.deepEqual(result, {
    status: 'refused',
    blocked: [
      { tenantId: 't1', tenantName: 'Ada Park', reasons: ['charges or payments on the ledger'], heldUnits: [] },
    ],
  });
  assert.deepEqual(txn.writes, []);
});

test('each source is read at the scan limit the app uses', async () => {
  const txn = new FakeTxn({});
  await run(txn, ['t1']);
  assert.equal(txn.limits.length, 7);
  assert.ok(txn.limits.every((l) => l === 10));
});

test('bulk is all or nothing: one occupant refuses the lot, naming only the blocked tenant', async () => {
  const txn = new FakeTxn({
    clean: { doc: { name: 'Clean Entry' } },
    held: {
      doc: { name: 'Bo Diaz' },
      units: [{ id: 'u7', data: { unitNumber: '7', status: 'lockout' } }],
    },
    card: { doc: { name: 'Cy Lee' }, ownRows: { payments: [{ status: 'processing' }] } },
  });
  const result = await run(txn, ['clean', 'held', 'card']);
  assert.equal(result.status, 'refused');
  assert.deepEqual(result.status === 'refused' ? result.blocked : null, [
    { tenantId: 'held', tenantName: 'Bo Diaz', reasons: [], heldUnits: [{ unitNumber: '7', status: 'lockout' }] },
    {
      tenantId: 'card',
      tenantName: 'Cy Lee',
      reasons: ['a card payment in progress or payment history'],
      heldUnits: [],
    },
  ]);
  // The clean tenant was not deleted on its own either.
  assert.deepEqual(txn.writes, []);
});

test('a clean tenant: units unlinked, live gate codes off, doc deleted, audited with its before snapshot', async () => {
  const txn = new FakeTxn({
    t1: {
      doc: { name: 'Ada Park', phone: '555' },
      // A stale link on an available unit is not held, and is cleared.
      units: [
        { id: 'u9', data: { unitNumber: '9', status: 'available' } },
        { id: 'u10', data: { unitNumber: '10', status: 'occupied', archived: true } },
      ],
      gateAccess: [
        { id: 'g1', data: { isActive: true } },
        { id: 'g2', data: { isActive: false } },
      ],
      // Rows that never became history do not block.
      facilityRows: { ledgers: [{ status: 'voided' }], payments: [{ status: 'failed' }] },
      billing: { stripeSubscriptionId: null },
    },
  });
  const result = await run(txn, ['t1']);

  assert.deepEqual(result, {
    status: 'deleted',
    deleted: [{ tenantId: 't1', tenantName: 'Ada Park', unitsUnlinked: 1, gateAccessDeactivated: 1 }],
    unitsUnlinked: 1,
    gateAccessDeactivated: 1,
    bulkDeleteId: null,
  });
  // The archived unit is left alone, as the app's unit lists skip it.
  assert.deepEqual(txn.paths(), [
    'update units/u9',
    'update gateAccess/g1',
    'delete tenants/t1',
    'create auditLogs',
  ]);

  const unit = txn.writes[0].fields!;
  assert.equal(unit.status, 'available');
  for (const cleared of ['tenantId', 'tenantName', 'moveInDate']) {
    assert.ok((unit[cleared] as admin.firestore.FieldValue).isEqual(FieldValue.delete()), cleared);
  }
  for (const stamped of ['moveOutDate', 'updatedAt']) {
    assert.ok((unit[stamped] as admin.firestore.FieldValue).isEqual(FieldValue.serverTimestamp()), stamped);
  }
  assert.equal(unit.updatedBy, 'owner');

  const gate = txn.writes[1].fields!;
  assert.equal(gate.isActive, false);
  assert.equal(gate.updatedBy, 'owner');

  const audit = txn.writes[3].fields!;
  assert.equal(audit.eventType, 'tenant.deleted');
  assert.equal(audit.action, 'tenant.deleted');
  assert.equal(audit.targetId, 't1');
  assert.equal(audit.tenantId, 't1');
  assert.equal(audit.facilityId, 'f1');
  assert.equal(audit.actorUid, 'owner');
  assert.equal(audit.userId, 'owner');
  assert.equal(audit.actorEmail, 'owner@example.com');
  assert.equal(audit.actorRole, 'owner');
  assert.deepEqual(audit.before, { name: 'Ada Park', phone: '555' });
  assert.deepEqual(audit.changes, { before: { name: 'Ada Park', phone: '555' } });
  assert.deepEqual(audit.metadata, {
    unitsUnlinked: 1,
    gateAccessDeactivated: 1,
    actorRole: 'owner',
    source: 'deleteTenantsPermanently',
  });
});

test('bulk delete logs one tenant.deleted per tenant with its before snapshot, then the bulk event', async () => {
  const txn = new FakeTxn({
    t1: { doc: { name: 'Ada Park', phone: '1' } },
    t2: { doc: { name: 'Bo Diaz', phone: '2' } },
  });
  const result = await run(txn, ['t1', 't2']);
  const bulkId = `bulk_2_${NOW}`;
  assert.equal(result.status === 'deleted' ? result.bulkDeleteId : null, bulkId);
  assert.deepEqual(txn.paths(), [
    'delete tenants/t1',
    'create auditLogs',
    'delete tenants/t2',
    'create auditLogs',
    'create auditLogs',
  ]);
  const [a1, a2, bulk] = txn.writes.filter((w) => w.op === 'create').map((w) => w.fields!);
  assert.deepEqual([a1.before, a2.before], [{ name: 'Ada Park', phone: '1' }, { name: 'Bo Diaz', phone: '2' }]);
  assert.equal((a1.metadata as DocData).bulkDeleteId, bulkId);
  assert.equal(bulk.eventType, 'tenant.bulkDeleted');
  assert.equal(bulk.targetId, bulkId);
  assert.equal(bulk.before, undefined);
  assert.deepEqual((bulk.metadata as DocData).tenantIds, ['t1', 't2']);
  assert.deepEqual((bulk.metadata as DocData).tenantNames, ['Ada Park', 'Bo Diaz']);
  assert.equal((bulk.metadata as DocData).count, 2);
});

test('a missing tenant doc deletes by id, without a before snapshot', async () => {
  const txn = new FakeTxn({ gone: { doc: null } });
  const result = await run(txn, ['gone']);
  assert.equal(result.status, 'deleted');
  const audit = txn.writes.find((w) => w.op === 'create')!.fields!;
  assert.equal(audit.before, undefined);
  assert.deepEqual(audit.changes, {});
});

test('too many writes for one transaction refuses the whole call before writing', async () => {
  const gateAccess = Array.from({ length: 499 }, (_, i) => ({ id: `g${i}`, data: {} }));
  const txn = new FakeTxn({ t1: { gateAccess } });
  await assert.rejects(run(txn, ['t1']), (e: unknown) => {
    assert.ok(e instanceof functions.https.HttpsError);
    assert.equal(e.code, 'failed-precondition');
    assert.match(e.message, /Nothing was deleted/);
    return true;
  });
  assert.deepEqual(txn.writes, []);
});

test('request: ids trimmed and de-duplicated in order; anything else refused', () => {
  assert.deepEqual(parseDeleteTenantsRequest({ facilityId: ' f1 ', tenantIds: ['a', ' b', 'a'] }), {
    facilityId: 'f1',
    tenantIds: ['a', 'b'],
  });
  const bad: unknown[] = [
    null,
    {},
    { facilityId: 'f1' },
    { facilityId: 'f1', tenantIds: [] },
    { facilityId: 'f1', tenantIds: [''] },
    { facilityId: 'f1', tenantIds: [7] },
    { facilityId: 'f1', tenantIds: ['a/b'] },
    { facilityId: 'f/1', tenantIds: ['a'] },
    { facilityId: 'f1', tenantIds: Array.from({ length: MAX_TENANTS_PER_DELETE + 1 }, (_, i) => `t${i}`) },
  ];
  for (const data of bad) {
    assert.throws(
      () => parseDeleteTenantsRequest(data),
      (e: unknown) => e instanceof functions.https.HttpsError && e.code === 'invalid-argument',
      JSON.stringify(data)?.slice(0, 60),
    );
  }
});

test('authorize: owners and managers of a paid facility; never employees; super admins always', async () => {
  const paid = {
    ownerUid: 'owner',
    managers: { mgr: true },
    roles: { emp: 'employee', admin: 'admin' },
    platformSubscriptionStatus: 'active',
  };
  const noAccount = async () => {
    throw new Error('account not needed');
  };
  for (const uid of ['owner', 'mgr', 'admin']) {
    await authorizePermanentTenantDelete({ uid, superAdmin: false, facility: paid, loadAccount: noAccount, nowMs: NOW });
  }
  for (const uid of ['emp', 'stranger']) {
    await assert.rejects(
      authorizePermanentTenantDelete({ uid, superAdmin: false, facility: paid, loadAccount: noAccount, nowMs: NOW }),
      (e: unknown) => e instanceof functions.https.HttpsError && e.code === 'permission-denied',
    );
  }
  // A super admin needs no role and no subscription.
  await authorizePermanentTenantDelete({
    uid: 'stranger',
    superAdmin: true,
    facility: {},
    loadAccount: noAccount,
    nowMs: NOW,
  });
});

test('authorize: an unpaid facility falls back to its creator account, then refuses', async () => {
  const unpaid = { ownerUid: 'owner', facilityCreatorAccountId: 'acc1', platformSubscriptionStatus: 'cancelled' };
  const asked: string[] = [];
  const account = (data: DocData | null) => async (id: string) => {
    asked.push(id);
    return data;
  };
  await authorizePermanentTenantDelete({
    uid: 'owner',
    superAdmin: false,
    facility: unpaid,
    loadAccount: account({ subscriptionStatus: 'active' }),
    nowMs: NOW,
  });
  assert.deepEqual(asked, ['acc1']);

  for (const data of [{ subscriptionStatus: 'cancelled' }, { subscriptionStatus: 'active', suspended: true }, null]) {
    await assert.rejects(
      authorizePermanentTenantDelete({
        uid: 'owner',
        superAdmin: false,
        facility: unpaid,
        loadAccount: account(data),
        nowMs: NOW,
      }),
      (e: unknown) =>
        e instanceof functions.https.HttpsError &&
        e.code === 'failed-precondition' &&
        e.message.startsWith('Permanent tenant deletion requires an active paid subscription'),
    );
  }
});

test('actorRoleOf records the role the way AuditService does', () => {
  const facility = { ownerUid: 'o', roles: { m: 'manager' }, managers: { x: true } };
  assert.equal(actorRoleOf(facility, 'o', false), 'owner');
  assert.equal(actorRoleOf(facility, 'm', false), 'manager');
  assert.equal(actorRoleOf(facility, 'x', false), 'manager');
  assert.equal(actorRoleOf(facility, 's', true), 'superadmin');
  assert.equal(actorRoleOf(facility, 's', false), null);
});

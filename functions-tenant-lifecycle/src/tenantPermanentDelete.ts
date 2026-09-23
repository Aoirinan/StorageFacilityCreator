import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import {
  LinkedDoc,
  PERMANENT_TENANT_DELETE_NOT_ENTITLED_MESSAGE,
  TENANT_DELETE_SCAN_LIMIT,
  TenantDeleteBlock,
  TenantDeleteDocData as DocData,
  TenantDeletePlan,
  TenantDeleteRecords,
  buildTenantDeletePlan,
  facilityAllowsPermanentTenantDelete,
  facilityCreatorAccountIdOf,
  isFacilityOwnerOrManager,
  isTenantDeleteBlocked,
  toTenantDeleteBlock,
} from '@sfc/functions-shared';

/**
 * Server side of permanent tenant delete (the deleteTenantsPermanently
 * callable). The Firestore rules used to let owners and managers delete a
 * tenant doc directly, so an old browser tab or a direct API call could skip
 * the app's history check and orphan the tenant's ledger, invoices and
 * payments. Tenant deletes are now super-admin only in the rules and go
 * through here: the same checks as the app, run with admin reads inside the
 * transaction that deletes.
 */

/** Tenants per call. The app's bulk delete sends every selected tenant at once. */
export const MAX_TENANTS_PER_DELETE = 100;

/** Writes per transaction, at Firestore's 500 cap. */
export const MAX_WRITES_PER_DELETE = 500;

/** Tenants whose records are read at once; each is 11 reads. */
const READ_CONCURRENCY = 10;

export type DeleteTenantsRequest = { facilityId: string; tenantIds: string[] };

function isDocId(value: string): boolean {
  return value.length > 0 && !value.includes('/');
}

export function parseDeleteTenantsRequest(data: unknown): DeleteTenantsRequest {
  const input = (data && typeof data === 'object' ? data : {}) as Record<string, unknown>;
  const facilityId = typeof input.facilityId === 'string' ? input.facilityId.trim() : '';
  if (!isDocId(facilityId)) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }
  const raw = Array.isArray(input.tenantIds) ? input.tenantIds : [];
  const tenantIds: string[] = [];
  for (const value of raw) {
    const id = typeof value === 'string' ? value.trim() : '';
    if (!isDocId(id)) {
      throw new functions.https.HttpsError('invalid-argument', 'tenantIds must be tenant ids');
    }
    if (!tenantIds.includes(id)) tenantIds.push(id);
  }
  if (tenantIds.length === 0) {
    throw new functions.https.HttpsError('invalid-argument', 'tenantIds is required');
  }
  if (tenantIds.length > MAX_TENANTS_PER_DELETE) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      `Select at most ${MAX_TENANTS_PER_DELETE} tenants to delete at a time.`,
    );
  }
  return { facilityId, tenantIds };
}

/**
 * Who may permanently delete: a super admin (the custom claim the rules
 * trust), or the facility's owner or a manager while the facility is paid up
 * or trialing. Mirrors the old delete rule and the app's
 * _assertFacilityAllowsPermanentTenantDeletion. [loadAccount] is only called
 * when the facility's own subscription doesn't settle it.
 */
export async function authorizePermanentTenantDelete(input: {
  uid: string;
  superAdmin: boolean;
  facility: DocData;
  loadAccount: (accountId: string) => Promise<DocData | null>;
  nowMs: number;
}): Promise<void> {
  if (input.superAdmin) return;
  if (!isFacilityOwnerOrManager(input.facility, input.uid)) {
    throw new functions.https.HttpsError(
      'permission-denied',
      'Only the facility owner or a manager can permanently delete tenants.',
    );
  }
  if (facilityAllowsPermanentTenantDelete(input.facility, null, input.nowMs)) return;
  const accountId = facilityCreatorAccountIdOf(input.facility);
  const account = accountId ? await input.loadAccount(accountId) : null;
  if (!facilityAllowsPermanentTenantDelete(input.facility, account, input.nowMs)) {
    throw new functions.https.HttpsError('failed-precondition', PERMANENT_TENANT_DELETE_NOT_ENTITLED_MESSAGE);
  }
}

/** The actorRole an audit row records, as AuditService works it out. */
export function actorRoleOf(facility: DocData, uid: string, superAdmin: boolean): string | null {
  const roles = (facility.roles as Record<string, unknown> | undefined) || {};
  const managers = (facility.managers as Record<string, unknown> | undefined) || {};
  if (facility.ownerUid === uid) return 'owner';
  if (typeof roles[uid] === 'string') return roles[uid] as string;
  if (managers[uid] === true) return 'manager';
  return superAdmin ? 'superadmin' : null;
}

/**
 * The reads and writes of one delete transaction, under one facility. A
 * seam: the delete is tested against a fake. Every read comes before the
 * first write, as Firestore requires.
 */
export interface TenantDeleteTransaction {
  tenant(tenantId: string): Promise<DocData | null>;
  /** Up to [limit] rows of a facility collection whose tenantId is [tenantId]. */
  facilityRows(collection: string, tenantId: string, limit: number): Promise<DocData[]>;
  /** Up to [limit] rows of the tenant's own subcollection. */
  tenantRows(tenantId: string, subcollection: string, limit: number): Promise<DocData[]>;
  tenantDoc(tenantId: string, subcollection: string, docId: string): Promise<DocData | null>;
  /** Every doc of a facility collection whose tenantId is [tenantId]. */
  linkedDocs(collection: 'units' | 'gateAccess', tenantId: string): Promise<LinkedDoc[]>;
  /** [collection] is a facility subcollection. */
  update(collection: string, docId: string, fields: DocData): void;
  delete(collection: string, docId: string): void;
  /** A new doc with a generated id. */
  create(collection: string, fields: DocData): void;
}

/** The same reads as TenantService.loadDeletePlan, inside the transaction. */
export async function readTenantDeleteRecords(
  txn: TenantDeleteTransaction,
  tenantId: string,
  limit: number = TENANT_DELETE_SCAN_LIMIT,
): Promise<TenantDeleteRecords> {
  const [
    tenant,
    ledgers,
    invoices,
    payments,
    contracts,
    liens,
    paymentMethods,
    tenantPayments,
    billing,
    units,
    gateAccess,
  ] = await Promise.all([
    txn.tenant(tenantId),
    txn.facilityRows('ledgers', tenantId, limit),
    txn.facilityRows('invoices', tenantId, limit),
    txn.facilityRows('payments', tenantId, limit),
    txn.facilityRows('contracts', tenantId, limit),
    txn.facilityRows('liens', tenantId, limit),
    txn.tenantRows(tenantId, 'paymentMethods', limit),
    txn.tenantRows(tenantId, 'payments', limit),
    txn.tenantDoc(tenantId, 'billing', 'default'),
    txn.linkedDocs('units', tenantId),
    txn.linkedDocs('gateAccess', tenantId),
  ]);
  return {
    tenant,
    ledgers,
    invoices,
    payments,
    contracts,
    liens,
    paymentMethods,
    tenantPayments,
    billing,
    units,
    gateAccess,
  };
}

/** UnitService.tenantUnlinkFields: the unit is free again. */
export function tenantUnlinkFields(uid: string): DocData {
  const { FieldValue } = admin.firestore;
  return {
    status: 'available',
    tenantId: FieldValue.delete(),
    tenantName: FieldValue.delete(),
    moveInDate: FieldValue.delete(),
    moveOutDate: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: uid,
  };
}

/** What GateAccessService.updateGateAccess writes to switch a code off. */
export function gateAccessOffFields(uid: string): DocData {
  return {
    isActive: false,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedBy: uid,
  };
}

export type DeleteActor = { uid: string; email: string | null; role: string | null };

/** An auditLogs row in the shape AuditLogEntry.toFirestore writes. */
export function auditLogEntry(
  facilityId: string,
  actor: DeleteActor,
  event: {
    eventType: string;
    targetType: string;
    targetId: string;
    tenantId?: string;
    before?: DocData | null;
    metadata: DocData;
  },
): DocData {
  const before = event.before ?? null;
  return {
    eventType: event.eventType,
    actorUid: actor.uid,
    ...(actor.email ? { actorEmail: actor.email } : {}),
    ...(actor.role ? { actorRole: actor.role } : {}),
    targetType: event.targetType,
    targetId: event.targetId,
    facilityId,
    ...(event.tenantId ? { tenantId: event.tenantId } : {}),
    ...(before ? { before } : {}),
    timestamp: admin.firestore.FieldValue.serverTimestamp(),
    metadata: {
      ...event.metadata,
      ...(actor.role ? { actorRole: actor.role } : {}),
      source: 'deleteTenantsPermanently',
    },
    action: event.eventType,
    entityType: event.targetType,
    entityId: event.targetId,
    userId: actor.uid,
    userEmail: actor.email ?? '',
    changes: before ? { before } : {},
  };
}

export type DeletedTenant = {
  tenantId: string;
  tenantName: string;
  unitsUnlinked: number;
  gateAccessDeactivated: number;
};

/** What the app reads back. Held units carry their status so it can name the step that frees each one. */
export type DeleteTenantsResult =
  | { status: 'refused'; blocked: TenantDeleteBlock[] }
  | {
      status: 'deleted';
      deleted: DeletedTenant[];
      unitsUnlinked: number;
      gateAccessDeactivated: number;
      bulkDeleteId: string | null;
    };

function writesFor(plan: TenantDeletePlan): number {
  // Unit unlinks, gate codes off, the tenant delete and its audit row.
  return plan.unitIds.length + plan.activeGateAccessIds.length + 2;
}

/**
 * Reads every tenant's records, refuses them all if any one has history or
 * still holds a unit (the app's dialog said "Delete N"), and otherwise, in
 * the same transaction, unlinks their units, turns their gate codes off,
 * deletes the tenant docs and writes a tenant.deleted audit row per tenant
 * with its before snapshot, plus a tenant.bulkDeleted row for more than one.
 * Reads run inside the transaction, so a ledger row or unit assignment made
 * since the app's pre-check is seen here.
 */
export async function deleteTenantsInTransaction(
  txn: TenantDeleteTransaction,
  input: { facilityId: string; tenantIds: string[]; actor: DeleteActor; nowMs: number },
): Promise<DeleteTenantsResult> {
  const { facilityId, tenantIds, actor } = input;
  const plans: TenantDeletePlan[] = [];
  for (let i = 0; i < tenantIds.length; i += READ_CONCURRENCY) {
    const group = tenantIds.slice(i, i + READ_CONCURRENCY);
    const read = await Promise.all(
      group.map(async (id) => buildTenantDeletePlan(id, await readTenantDeleteRecords(txn, id))),
    );
    plans.push(...read);
  }

  const blocked = plans.filter(isTenantDeleteBlocked);
  if (blocked.length > 0) {
    return { status: 'refused', blocked: blocked.map(toTenantDeleteBlock) };
  }

  const bulkDeleteId = tenantIds.length > 1 ? `bulk_${tenantIds.length}_${input.nowMs}` : null;
  const writes = plans.reduce((n, p) => n + writesFor(p), bulkDeleteId ? 1 : 0);
  if (writes > MAX_WRITES_PER_DELETE) {
    // Refused whole rather than split: each call is all or nothing.
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Nothing was deleted: too many records to change in one go. Select fewer tenants and try again.',
    );
  }

  const unitOff = tenantUnlinkFields(actor.uid);
  const gateOff = gateAccessOffFields(actor.uid);
  const deleted: DeletedTenant[] = [];
  for (const plan of plans) {
    // The units were read by tenantId inside this transaction, so each one
    // still points at this tenant; a unit reassigned since the app's check
    // is not among them.
    for (const unitId of plan.unitIds) txn.update('units', unitId, unitOff);
    for (const accessId of plan.activeGateAccessIds) txn.update('gateAccess', accessId, gateOff);
    txn.delete('tenants', plan.tenantId);
    txn.create(
      'auditLogs',
      auditLogEntry(facilityId, actor, {
        eventType: 'tenant.deleted',
        targetType: 'tenant',
        targetId: plan.tenantId,
        tenantId: plan.tenantId,
        before: plan.before,
        metadata: {
          unitsUnlinked: plan.unitIds.length,
          gateAccessDeactivated: plan.activeGateAccessIds.length,
          ...(bulkDeleteId ? { bulkDeleteId } : {}),
        },
      }),
    );
    deleted.push({
      tenantId: plan.tenantId,
      tenantName: plan.tenantName,
      unitsUnlinked: plan.unitIds.length,
      gateAccessDeactivated: plan.activeGateAccessIds.length,
    });
  }

  const unitsUnlinked = deleted.reduce((n, d) => n + d.unitsUnlinked, 0);
  const gateAccessDeactivated = deleted.reduce((n, d) => n + d.gateAccessDeactivated, 0);
  if (bulkDeleteId) {
    txn.create(
      'auditLogs',
      auditLogEntry(facilityId, actor, {
        eventType: 'tenant.bulkDeleted',
        targetType: 'tenant',
        targetId: bulkDeleteId,
        metadata: {
          tenantIds,
          count: tenantIds.length,
          unitsUnlinked,
          gateAccessDeactivated,
          tenantNames: deleted.map((d) => d.tenantName),
        },
      }),
    );
  }
  return { status: 'deleted', deleted, unitsUnlinked, gateAccessDeactivated, bulkDeleteId };
}

/** [TenantDeleteTransaction] over one facility in a Firestore transaction. */
export function firestoreTenantDeleteTransaction(
  db: admin.firestore.Firestore,
  tx: admin.firestore.Transaction,
  facilityId: string,
): TenantDeleteTransaction {
  const facility = db.collection('facilities').doc(facilityId);
  const tenantRef = (tenantId: string) => facility.collection('tenants').doc(tenantId);
  const dataOf = (snap: admin.firestore.DocumentSnapshot) =>
    snap.exists ? ((snap.data() || {}) as DocData) : null;
  return {
    tenant: async (tenantId) => dataOf(await tx.get(tenantRef(tenantId))),
    facilityRows: async (collection, tenantId, limit) =>
      (await tx.get(facility.collection(collection).where('tenantId', '==', tenantId).limit(limit))).docs.map(
        (d) => d.data() as DocData,
      ),
    tenantRows: async (tenantId, subcollection, limit) =>
      (await tx.get(tenantRef(tenantId).collection(subcollection).limit(limit))).docs.map(
        (d) => d.data() as DocData,
      ),
    tenantDoc: async (tenantId, subcollection, docId) =>
      dataOf(await tx.get(tenantRef(tenantId).collection(subcollection).doc(docId))),
    linkedDocs: async (collection, tenantId) =>
      (await tx.get(facility.collection(collection).where('tenantId', '==', tenantId))).docs.map((d) => ({
        id: d.id,
        data: d.data() as DocData,
      })),
    update: (collection, docId, fields) => {
      tx.update(facility.collection(collection).doc(docId), fields);
    },
    delete: (collection, docId) => {
      tx.delete(facility.collection(collection).doc(docId));
    },
    create: (collection, fields) => {
      tx.create(facility.collection(collection).doc(), fields);
    },
  };
}


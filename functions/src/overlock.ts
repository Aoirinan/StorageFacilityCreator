import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';

const db = admin.firestore();

interface SetUnitOverlockRequest {
  facilityId: string;
  unitId: string;
  isOverlocked: boolean;
  note?: string;
}

interface SetUnitsOverlockBulkRequest {
  facilityId: string;
  unitIds: string[];
  isOverlocked: boolean;
  note?: string;
}

interface OverlockAllDelinquentRequest {
  facilityId: string;
  note?: string;
}

interface ClearOverlockByFilterRequest {
  facilityId: string;
  filterParams?: { statusFilter?: string }; // e.g. overlocked only
  confirmToken: string;
}

/** Ensure caller is owner/manager/admin (not just employee) for the facility. */
async function requireManagerOrAdmin(uid: string, facilityId: string): Promise<{ facilityData: Record<string, any>; userName: string }> {
  const facilityDoc = await db.collection('facilities').doc(facilityId).get();
  if (!facilityDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Facility not found');
  }
  const facilityData = (facilityDoc.data() || {}) as Record<string, any>;
  const ownerUid = facilityData.ownerUid as string | undefined;
  const roles = (facilityData.roles as Record<string, string>) || {};
  const managersMap = (facilityData.managers as Record<string, any>) || {};

  const managerEntry = managersMap[uid];
  const managerFromMap =
    managerEntry === true ||
    (typeof managerEntry === 'object' &&
      managerEntry !== null &&
      (managerEntry.active === true ||
        managerEntry.isActive === true ||
        managerEntry.role === 'manager' ||
        managerEntry.roleType === 'manager'));

  const isManagerOrAdmin =
    ownerUid === uid ||
    roles[uid] === 'owner' ||
    roles[uid] === 'manager' ||
    roles[uid] === 'admin' ||
    managerFromMap;

  if (!isManagerOrAdmin) {
    const userRolesSnap = await db
      .collection('user_roles')
      .where('userId', '==', uid)
      .where('facilityId', '==', facilityId)
      .where('isActive', '==', true)
      .limit(1)
      .get();
    const roleDoc = userRolesSnap.docs[0];
    const roleType = roleDoc?.data()?.roleType as string | undefined;
    const allowedRole =
      roleType === 'owner' || roleType === 'manager' || roleType === 'admin';
    if (!allowedRole) {
      throw new functions.https.HttpsError(
        'permission-denied',
        'Only owners, managers, or admins can perform overlock actions.',
      );
    }
  }

  let userName: string;
  try {
    const userDoc = await db.collection('users').doc(uid).get();
    userName = (userDoc.data()?.displayName as string) || (userDoc.data()?.email as string) || uid;
  } catch {
    userName = uid;
  }
  return { facilityData, userName };
}

/** Get ledger balance for a tenant (sum of posted ledger entries). */
async function getTenantBalance(facilityId: string, tenantId: string): Promise<number> {
  const snapshot = await db
    .collection('facilities')
    .doc(facilityId)
    .collection('ledgers')
    .where('tenantId', '==', tenantId)
    .where('status', '==', 'posted')
    .get();

  let balance = 0;
  snapshot.docs.forEach((doc) => {
    balance += (doc.data().amount as number) || 0;
  });
  return balance;
}

/** Apply overlock to one unit (transaction: unit + event + tenant sync). */
async function applyUnitOverlock(
  facilityId: string,
  unitId: string,
  isOverlocked: boolean,
  byUid: string,
  byName: string,
  note: string | undefined,
  bulkBatchId?: string,
): Promise<{ updated: boolean; alreadyInState: boolean }> {
  const unitRef = db.collection('facilities').doc(facilityId).collection('units').doc(unitId);
  const unitSnap = await unitRef.get();
  if (!unitSnap.exists) {
    throw new functions.https.HttpsError('not-found', `Unit ${unitId} not found`);
  }
  const unitData = unitSnap.data() || {};
  const current = (unitData.overlock as Record<string, any>) || {};
  const alreadyOverlocked = current.isOverlocked === true;
  if (isOverlocked === alreadyOverlocked) {
    return { updated: false, alreadyInState: true };
  }

  const now = admin.firestore.Timestamp.now();
  const action = isOverlocked ? 'OVERLOCKED' : 'REMOVED';
  const tenantId = unitData.tenantId as string | undefined;
  const tenantName = unitData.tenantName as string | undefined;

  await db.runTransaction(async (tx) => {
    tx.update(unitRef, {
      overlock: {
        isOverlocked,
        updatedAt: now,
        updatedByUid: byUid,
        updatedByName: byName,
        reasonNote: note || null,
        lastAction: action,
      },
      updatedAt: now,
    });

    const eventRef = db
      .collection('facilities')
      .doc(facilityId)
      .collection('units')
      .doc(unitId)
      .collection('overlockEvents')
      .doc();
    tx.set(eventRef, {
      action,
      at: now,
      byUid,
      byName,
      note: note || null,
      tenantId: tenantId || null,
      tenantName: tenantName || null,
      bulkBatchId: bulkBatchId || null,
    });

    if (tenantId) {
      const tenantRef = db.collection('facilities').doc(facilityId).collection('tenants').doc(tenantId);
      tx.update(tenantRef, {
        overlockIsActive: isOverlocked,
        updatedAt: now,
      });
    }
  });

  return { updated: true, alreadyInState: false };
}

export const setUnitOverlockStatus = functions.https.onCall(async (data: SetUnitOverlockRequest, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be signed in');
  }
  const { facilityId, unitId, isOverlocked, note } = data;
  if (!facilityId || !unitId || typeof isOverlocked !== 'boolean') {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId, unitId, and isOverlocked are required');
  }
  if (isOverlocked && (!note || String(note).trim() === '')) {
    throw new functions.https.HttpsError('invalid-argument', 'Note is required when setting overlock');
  }

  const { userName } = await requireManagerOrAdmin(context.auth.uid, facilityId);
  const result = await applyUnitOverlock(
    facilityId,
    unitId,
    isOverlocked,
    context.auth.uid,
    userName,
    note?.trim() || undefined,
    undefined,
  );

  if (result.alreadyInState) {
    return { ok: true, alreadyInState: true, message: isOverlocked ? 'already_overlocked' : 'already_removed' };
  }
  return { ok: true, updated: true };
});

const BULK_BATCH_SIZE = 400;

export const setUnitsOverlockStatusBulk = functions.https.onCall(async (data: SetUnitsOverlockBulkRequest, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be signed in');
  }
  const { facilityId, unitIds, isOverlocked, note } = data;
  if (!facilityId || !Array.isArray(unitIds) || typeof isOverlocked !== 'boolean') {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId, unitIds array, and isOverlocked are required');
  }
  if (isOverlocked && (!note || String(note).trim() === '')) {
    throw new functions.https.HttpsError('invalid-argument', 'Note is required for bulk overlock');
  }
  if (unitIds.length > 1000) {
    throw new functions.https.HttpsError('invalid-argument', 'Maximum 1000 units per bulk action');
  }

  const { userName } = await requireManagerOrAdmin(context.auth.uid, facilityId);
  const bulkBatchId = `bulk_${Date.now()}_${context.auth.uid.slice(-6)}`;
  const noteTrimmed = note?.trim() || undefined;

  let totalUpdated = 0;
  let alreadyInStateCount = 0;
  const errors: { unitId: string; message: string }[] = [];

  for (let i = 0; i < unitIds.length; i += BULK_BATCH_SIZE) {
    const chunk = unitIds.slice(i, i + BULK_BATCH_SIZE);
    await Promise.all(
      chunk.map(async (unitId) => {
        try {
          const result = await applyUnitOverlock(
            facilityId,
            unitId,
            isOverlocked,
            context.auth!.uid,
            userName,
            noteTrimmed,
            bulkBatchId,
          );
          if (result.updated) totalUpdated++;
          if (result.alreadyInState) alreadyInStateCount++;
        } catch (e: any) {
          errors.push({ unitId, message: e?.message || String(e) });
        }
      }),
    );
  }

  return {
    ok: true,
    totalRequested: unitIds.length,
    totalUpdated,
    alreadyInStateCount,
    errors: errors.length > 0 ? errors : undefined,
  };
});

/** Get tenant IDs that have balance > 0 (delinquent) in this facility. */
async function getDelinquentTenantIds(facilityId: string): Promise<Set<string>> {
  const ledgersSnap = await db
    .collection('facilities')
    .doc(facilityId)
    .collection('ledgers')
    .where('status', '==', 'posted')
    .get();

  const balanceByTenant: Record<string, number> = {};
  ledgersSnap.docs.forEach((doc) => {
    const d = doc.data();
    const tid = d.tenantId as string;
    if (!tid) return;
    balanceByTenant[tid] = (balanceByTenant[tid] || 0) + ((d.amount as number) || 0);
  });

  const delinquent = new Set<string>();
  Object.entries(balanceByTenant).forEach(([tenantId, balance]) => {
    if (balance > 0) delinquent.add(tenantId);
  });
  return delinquent;
}

/** Get unit IDs that are occupied by the given tenant IDs. Firestore 'in' is max 10. */
async function getUnitIdsForTenants(facilityId: string, tenantIds: Set<string>): Promise<string[]> {
  if (tenantIds.size === 0) return [];
  const arr = Array.from(tenantIds);
  const unitIds: string[] = [];
  for (let i = 0; i < arr.length; i += 10) {
    const chunk = arr.slice(i, i + 10);
    const snap = await db
      .collection('facilities')
      .doc(facilityId)
      .collection('units')
      .where('tenantId', 'in', chunk)
      .get();
    snap.docs.forEach((doc) => {
      if (tenantIds.has(doc.data().tenantId)) unitIds.push(doc.id);
    });
  }
  return unitIds;
}

export const overlockAllDelinquent = functions.https.onCall(async (data: OverlockAllDelinquentRequest, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be signed in');
  }
  const { facilityId, note } = data;
  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }
  if (!note || String(note).trim() === '') {
    throw new functions.https.HttpsError('invalid-argument', 'Note is required for overlock all delinquent');
  }

  const { userName } = await requireManagerOrAdmin(context.auth.uid, facilityId);

  const delinquentTenantIds = await getDelinquentTenantIds(facilityId);
  const unitIds = await getUnitIdsForTenants(facilityId, delinquentTenantIds);
  if (unitIds.length === 0) {
    return { ok: true, totalUpdated: 0, message: 'No delinquent units to overlock' };
  }
  const bulkBatchId = `delinquent_${Date.now()}_${context.auth.uid.slice(-6)}`;
  const noteTrimmed = note?.trim() || undefined;

  let totalUpdated = 0;
  for (let i = 0; i < unitIds.length; i += BULK_BATCH_SIZE) {
    const chunk = unitIds.slice(i, i + BULK_BATCH_SIZE);
    await Promise.all(
      chunk.map(async (unitId) => {
        const result = await applyUnitOverlock(
          facilityId,
          unitId,
          true,
          context.auth!.uid,
          userName,
          noteTrimmed,
          bulkBatchId,
        );
        if (result.updated) totalUpdated++;
      }),
    );
  }

  return { ok: true, totalUpdated, unitIdsProcessed: unitIds.length };
});

export const clearOverlockByFilter = functions.https.onCall(async (data: ClearOverlockByFilterRequest, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be signed in');
  }
  const { facilityId, confirmToken } = data;
  if (!facilityId || confirmToken !== 'CLEAR') {
    throw new functions.https.HttpsError(
      'invalid-argument',
      'facilityId and confirmToken "CLEAR" are required to clear overlock',
    );
  }

  await requireManagerOrAdmin(context.auth.uid, facilityId);

  const unitsSnap = await db
    .collection('facilities')
    .doc(facilityId)
    .collection('units')
    .where('overlock.isOverlocked', '==', true)
    .get();

  const unitIds = unitsSnap.docs.map((d) => d.id);
  if (unitIds.length === 0) {
    return { ok: true, totalUpdated: 0, message: 'No overlocked units to clear' };
  }

  const { userName } = await requireManagerOrAdmin(context.auth.uid, facilityId);
  const bulkBatchId = `clear_${Date.now()}_${context.auth.uid.slice(-6)}`;

  let totalUpdated = 0;
  for (let i = 0; i < unitIds.length; i += BULK_BATCH_SIZE) {
    const chunk = unitIds.slice(i, i + BULK_BATCH_SIZE);
    await Promise.all(
      chunk.map(async (unitId) => {
        const result = await applyUnitOverlock(
          facilityId,
          unitId,
          false,
          context.auth!.uid,
          userName,
          'Clear overlock (filtered)',
          bulkBatchId,
        );
        if (result.updated) totalUpdated++;
      }),
    );
  }

  return { ok: true, totalUpdated, unitIdsProcessed: unitIds.length };
});

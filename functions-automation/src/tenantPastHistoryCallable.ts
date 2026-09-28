import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import { enforceAppCheckOrThrow } from '@sfc/functions-shared';
import { PAST_HISTORY_COLLECTION, PastHistoryInputError, parsePastHistoryRequest } from './tenantPastHistory';
import {
  Caller,
  PastHistoryRefusal,
  PlannedWrite,
  RecordResult,
  UndoResult,
  mayEditTenantHistory,
  parseUndoRequest,
  planRecordPastHistory,
  planUndoPastHistory,
} from './tenantPastHistoryPlan';

/**
 * Enter a tenant's past rent history: dated rent charges and payments from
 * a paper ledger, posted in one transaction with the dates they happened on,
 * and paidThrough worked out from the lot. Owner, manager or super admin.
 * No late fees are posted and delinquency is not touched; no email or text
 * goes to the tenant. See tenantPastHistory.ts for the rules.
 */

function callerOf(context: functions.https.CallableContext): Caller {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be signed in');
  }
  const token = (context.auth.token || {}) as Record<string, unknown>;
  return {
    uid: context.auth.uid,
    email: typeof token.email === 'string' ? token.email : null,
    // The claim, as in the rules: an allowlisted email alone can be an
    // unverified password account.
    superAdmin: token.superadmin === true,
  };
}

function applyWrites(
  tx: admin.firestore.Transaction,
  facilityRef: admin.firestore.DocumentReference,
  writes: PlannedWrite[],
): void {
  for (const w of writes) {
    const ref = facilityRef.collection(w.collection).doc(w.id);
    if (w.kind === 'set') tx.set(ref, w.data);
    else tx.update(ref, w.data);
  }
}

function asHttpsError(error: unknown): unknown {
  if (error instanceof PastHistoryInputError) {
    return new functions.https.HttpsError('invalid-argument', error.message);
  }
  if (error instanceof PastHistoryRefusal) {
    return new functions.https.HttpsError(error.code, error.message);
  }
  return error;
}

export const recordTenantPastHistory = functions
  .runWith({ timeoutSeconds: 120, memory: '256MB' })
  .https.onCall(async (data: unknown, context): Promise<RecordResult> => {
    const caller = callerOf(context);
    enforceAppCheckOrThrow(context);
    try {
      const request = parsePastHistoryRequest(data, new Date());
      const db = admin.firestore();
      const facilityRef = db.collection('facilities').doc(request.facilityId);
      const tenantRef = facilityRef.collection('tenants').doc(request.tenantId);
      const batchRef = facilityRef.collection(PAST_HISTORY_COLLECTION).doc(request.requestId);
      const ledgerQuery = facilityRef.collection('ledgers').where('tenantId', '==', request.tenantId);

      const result = await db.runTransaction(async (tx) => {
        const [facilitySnap, tenantSnap, batchSnap] = await tx.getAll(facilityRef, tenantRef, batchRef);
        const facility = facilitySnap.exists ? (facilitySnap.data() as Record<string, unknown>) : null;
        // Who may call is settled before the tenant's ledger is read.
        if (facility && !mayEditTenantHistory(facility, caller)) {
          throw new PastHistoryRefusal('permission-denied', 'Only the facility owner or a manager can enter past history');
        }
        const ledgerSnap = await tx.get(ledgerQuery);
        const plan = planRecordPastHistory({
          request,
          caller,
          facility,
          tenant: tenantSnap.exists ? (tenantSnap.data() as Record<string, unknown>) : null,
          existingLedger: ledgerSnap.docs.map((d) => d.data()),
          existingBatch: batchSnap.exists ? (batchSnap.data() as Record<string, unknown>) : null,
          newId: () => facilityRef.collection('ledgers').doc().id,
          serverTime: admin.firestore.FieldValue.serverTimestamp(),
        });
        applyWrites(tx, facilityRef, plan.writes);
        return plan.result;
      });

      functions.logger.info('recordTenantPastHistory', {
        facilityId: request.facilityId,
        tenantId: request.tenantId,
        requestId: request.requestId,
        alreadyApplied: result.alreadyApplied,
        charges: result.chargesPosted,
        payments: result.paymentsPosted,
      });
      return result;
    } catch (error) {
      throw asHttpsError(error);
    }
  });

export const undoTenantPastHistory = functions
  .runWith({ timeoutSeconds: 120, memory: '256MB' })
  .https.onCall(async (data: unknown, context): Promise<UndoResult> => {
    const caller = callerOf(context);
    enforceAppCheckOrThrow(context);
    try {
      const { facilityId, tenantId, requestId } = parseUndoRequest(data);
      const db = admin.firestore();
      const facilityRef = db.collection('facilities').doc(facilityId);
      const tenantRef = facilityRef.collection('tenants').doc(tenantId);
      const batchRef = facilityRef.collection(PAST_HISTORY_COLLECTION).doc(requestId);

      const result = await db.runTransaction(async (tx) => {
        const [facilitySnap, tenantSnap, batchSnap] = await tx.getAll(facilityRef, tenantRef, batchRef);
        const facility = facilitySnap.exists ? (facilitySnap.data() as Record<string, unknown>) : null;
        if (facility && !mayEditTenantHistory(facility, caller)) {
          throw new PastHistoryRefusal('permission-denied', 'Only the facility owner or a manager can undo past history');
        }
        const batch = batchSnap.exists ? (batchSnap.data() as Record<string, unknown>) : null;
        const ledgerIds = Array.isArray(batch?.ledgerEntryIds) ? (batch!.ledgerEntryIds as string[]) : [];
        const paymentIds = Array.isArray(batch?.paymentIds) ? (batch!.paymentIds as string[]) : [];
        const ledgerSnaps = ledgerIds.length
          ? await tx.getAll(...ledgerIds.map((id) => facilityRef.collection('ledgers').doc(id)))
          : [];
        const paymentSnaps = paymentIds.length
          ? await tx.getAll(...paymentIds.map((id) => facilityRef.collection('payments').doc(id)))
          : [];
        const plan = planUndoPastHistory({
          facilityId,
          tenantId,
          requestId,
          caller,
          facility,
          tenant: tenantSnap.exists ? (tenantSnap.data() as Record<string, unknown>) : null,
          batch,
          ledgerEntries: ledgerSnaps.map((s) => ({ id: s.id, data: s.exists ? (s.data() as Record<string, unknown>) : null })),
          payments: paymentSnaps.map((s) => ({ id: s.id, data: s.exists ? (s.data() as Record<string, unknown>) : null })),
          newId: () => facilityRef.collection('auditLogs').doc().id,
          serverTime: admin.firestore.FieldValue.serverTimestamp(),
        });
        applyWrites(tx, facilityRef, plan.writes);
        return plan.result;
      });

      functions.logger.info('undoTenantPastHistory', { facilityId, tenantId, ...result });
      return result;
    } catch (error) {
      throw asHttpsError(error);
    }
  });

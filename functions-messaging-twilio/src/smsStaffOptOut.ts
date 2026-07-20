import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { formatPhoneNumber, getFacilityDataForUserOrThrow } from '@sfc/functions-shared';
import { enforceAppCheckOrThrow } from './appCheck';
import { enforceRateLimit } from './rateLimit';

/** Maps unexpected errors (e.g. Firestore index) to HttpsError so clients are not stuck on generic internal. */
function rethrowStaffOptOutError(operation: string, error: unknown): never {
  if (error instanceof functions.https.HttpsError) {
    throw error;
  }
  const err = error as { message?: string; code?: string | number };
  const message = typeof err?.message === 'string' ? err.message : String(error);
  functions.logger.error(`[${operation}]`, { message, code: err?.code, stack: (error as Error)?.stack });
  const lower = message.toLowerCase();
  const codeStr = String(err?.code ?? '').toLowerCase();
  const isFailedPrecondition =
    codeStr === 'failed-precondition' ||
    err?.code === 9 ||
    lower.includes('requires an index') ||
    lower.includes('the query requires an index');
  if (isFailedPrecondition) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'This action is not available right now. Please try again later or contact support.',
    );
  }
  throw new functions.https.HttpsError('internal', 'An unexpected error occurred. Please try again later.');
}

function tenantSmsOptOutDisplayName(t: Record<string, unknown>): string {
  const n = t.name != null ? String(t.name).trim() : '';
  if (n) return n;
  const first = t.firstName != null ? String(t.firstName).trim() : '';
  const last = t.lastName != null ? String(t.lastName).trim() : '';
  const combined = `${first} ${last}`.trim();
  if (combined) return combined;
  return 'Tenant';
}

/**
 * Staff: list SMS block list + tenants marked opted out (STOP / consent).
 */
export const listFacilitySmsOptOuts = functions
  .runWith({ invoker: 'public' })
  .https.onCall(async (data: { facilityId?: string }, context) => {
  try {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }
    enforceAppCheckOrThrow(context);
    const facilityId = data?.facilityId;
    if (!facilityId || typeof facilityId !== 'string') {
      throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
    }
    await getFacilityDataForUserOrThrow(context.auth.uid, facilityId);
    await enforceRateLimit({
      facilityId,
      key: 'listFacilitySmsOptOuts',
      limit: 60,
      windowSeconds: 60,
      userId: context.auth.uid,
    });

    const facilitySnap = await admin.firestore().collection('facilities').doc(facilityId).get();
    if (!facilitySnap.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }
    const fd = facilitySnap.data() as Record<string, unknown>;
    const blockList = Array.isArray((fd?.smsSettings as Record<string, unknown> | undefined)?.blockList)
      ? ((fd.smsSettings as { blockList: unknown }).blockList as string[])
      : [];

    const tenantsRef = admin.firestore().collection('facilities').doc(facilityId).collection('tenants');
    const [qOpt, qConsent] = await Promise.all([
      tenantsRef.where('smsOptOut', '==', true).limit(400).get(),
      tenantsRef.where('smsConsentStatus', '==', 'opted_out').limit(400).get(),
    ]);
    const byId = new Map<string, Record<string, unknown>>();
    for (const d of qOpt.docs) byId.set(d.id, d.data() as Record<string, unknown>);
    for (const d of qConsent.docs) {
      if (!byId.has(d.id)) byId.set(d.id, d.data() as Record<string, unknown>);
    }

    const optedOutTenants = Array.from(byId.entries()).map(([tenantId, t]) => ({
      tenantId,
      name: tenantSmsOptOutDisplayName(t),
      phone: t.phone != null ? String(t.phone) : '',
      smsOptOut: t.smsOptOut === true,
      smsConsentStatus: t.smsConsentStatus != null ? String(t.smsConsentStatus) : null,
      smsConsentSource: t.smsConsentSource != null ? String(t.smsConsentSource) : null,
    }));

    const tenantNormPhones = new Set<string>();
    for (const row of optedOutTenants) {
      const pn = formatPhoneNumber(row.phone);
      if (pn) tenantNormPhones.add(pn);
    }

    const blockListOnly: { raw: string; normalized: string | null }[] = [];
    for (const raw of blockList) {
      const s = String(raw);
      const n = formatPhoneNumber(s);
      if (n && tenantNormPhones.has(n)) continue;
      blockListOnly.push({ raw: s, normalized: n });
    }

    return { blockList, blockListOnly, optedOutTenants };
  } catch (e: unknown) {
    rethrowStaffOptOutError('listFacilitySmsOptOuts', e);
  }
  });

/** Scoped tenant lookup by normalized phone (facility-bound). */
async function findTenantByPhoneNumber(
  normalizedPhone: string,
  facilityIdHint: string | null | undefined,
): Promise<{ facilityId: string; id: string; phone: string } | null> {
  if (!facilityIdHint) return null;
  const phoneVariations = [
    normalizedPhone,
    normalizedPhone.replace('+', ''),
    normalizedPhone.replace(/^\+1/, ''),
    normalizedPhone.replace(/^\+1/, '1'),
  ];
  for (const phoneVar of phoneVariations) {
    const scopedQuery = await admin
      .firestore()
      .collection('facilities')
      .doc(facilityIdHint)
      .collection('tenants')
      .where('phone', '==', phoneVar)
      .where('isActive', '==', true)
      .limit(1)
      .get();
    if (!scopedQuery.empty) {
      const tenantDoc = scopedQuery.docs[0];
      const tenantData = tenantDoc.data() as Record<string, unknown>;
      return {
        facilityId: facilityIdHint,
        id: tenantDoc.id,
        phone: tenantData.phone as string,
      };
    }
  }
  return null;
}

/**
 * Staff: remove number from facility SMS block list and/or clear tenant SMS opt-out (re-allow SMS).
 */
export const restoreFacilitySmsForPhone = functions
  .runWith({ invoker: 'public' })
  .https.onCall(
  async (data: { facilityId?: string; phone?: string; tenantId?: string | null }, context) => {
    try {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }
    enforceAppCheckOrThrow(context);
    const facilityId = data?.facilityId;
    if (!facilityId || typeof facilityId !== 'string') {
      throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
    }
    const phoneRaw = typeof data?.phone === 'string' ? data.phone.trim() : '';
    if (!phoneRaw) {
      throw new functions.https.HttpsError('invalid-argument', 'phone is required');
    }
    const normalizedPhone = formatPhoneNumber(phoneRaw);
    if (!normalizedPhone) {
      throw new functions.https.HttpsError('invalid-argument', 'Invalid phone number');
    }

    const facilityData = await getFacilityDataForUserOrThrow(context.auth.uid, facilityId);
    await enforceRateLimit({
      facilityId,
      key: 'restoreFacilitySmsForPhone',
      limit: 40,
      windowSeconds: 60,
      userId: context.auth.uid,
    });

    const facilityRef = admin.firestore().collection('facilities').doc(facilityId);
    const facilitySnap = await facilityRef.get();
    if (!facilitySnap.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }
    const fdata = facilitySnap.data() as Record<string, unknown>;
    const smsSettings = (fdata?.smsSettings as Record<string, unknown>) || {};
    const blockList = (smsSettings.blockList as string[]) || [];
    const newBlockList = blockList.filter((entry) => {
      const n = formatPhoneNumber(String(entry));
      return n !== normalizedPhone && String(entry).trim() !== normalizedPhone && String(entry).trim() !== phoneRaw;
    });
    const removedFromBlockList = newBlockList.length < blockList.length;
    if (removedFromBlockList) {
      await facilityRef.update({
        'smsSettings.blockList': newBlockList,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    const tenantSmsUpdate: Record<string, unknown> = {
      smsOptOut: false,
      smsConsentStatus: 'opted_in',
      smsConsentTimestamp: admin.firestore.FieldValue.serverTimestamp(),
      smsConsentSource: 'staff_restored',
      smsOptInDate: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    let updatedTenantId: string | null = null;
    const tid = typeof data?.tenantId === 'string' ? data.tenantId.trim() : '';

    if (tid) {
      const tref = facilityRef.collection('tenants').doc(tid);
      const tdoc = await tref.get();
      if (!tdoc.exists) {
        throw new functions.https.HttpsError('not-found', 'Tenant not found');
      }
      await tref.update(tenantSmsUpdate);
      updatedTenantId = tid;
    } else {
      const found = await findTenantByPhoneNumber(normalizedPhone, facilityId);
      if (found && found.facilityId === facilityId) {
        await facilityRef.collection('tenants').doc(found.id).update(tenantSmsUpdate);
        updatedTenantId = found.id;
      }
    }

    let actorEmail = '';
    try {
      const u = await admin.auth().getUser(context.auth!.uid);
      actorEmail = u.email || '';
    } catch (_) {
      /* ignore */
    }
    let actorRole = 'staff';
    if (facilityData.ownerUid === context.auth.uid) {
      actorRole = 'owner';
    } else {
      const roles = (facilityData.roles as Record<string, string> | undefined) || {};
      const r = roles[context.auth.uid!];
      if (r) actorRole = r;
      else if ((facilityData.managers as Record<string, boolean> | undefined)?.[context.auth.uid!] === true) {
        actorRole = 'manager';
      }
    }

    await admin
      .firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('auditLogs')
      .add({
        eventType: 'communication.smsStaffRestored',
        action: 'communication.smsStaffRestored',
        actorUid: context.auth.uid,
        actorEmail,
        actorRole,
        userId: context.auth.uid,
        userEmail: actorEmail,
        targetType: 'smsOptOut',
        targetId: normalizedPhone,
        entityType: 'smsOptOut',
        entityId: normalizedPhone,
        facilityId,
        tenantId: updatedTenantId,
        metadata: {
          phoneE164: normalizedPhone,
          removedFromBlockList,
          tenantRecordUpdated: updatedTenantId != null,
          clientPhoneInput: phoneRaw,
        },
        changes: {},
        timestamp: admin.firestore.FieldValue.serverTimestamp(),
      });

    return {
      ok: true,
      removedFromBlockList,
      tenantRecordUpdated: updatedTenantId != null,
      tenantId: updatedTenantId,
    };
    } catch (e: unknown) {
      rethrowStaffOptOutError('restoreFacilitySmsForPhone', e);
    }
  },
);

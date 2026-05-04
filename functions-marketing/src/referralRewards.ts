/**
 * Marketing-facing referral callables (user-initiated). Webhook-side and
 * super-admin referral logic lives in @sfc/functions-shared/referral/referralRewards.
 */
import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import { enforceAppCheckOrThrow } from '@sfc/functions-shared';

const REFERRAL_CODE_CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const REFERRAL_CODE_LEN = 8;

function randomReferralCode(): string {
  let s = '';
  for (let i = 0; i < REFERRAL_CODE_LEN; i++) {
    s += REFERRAL_CODE_CHARS[Math.floor(Math.random() * REFERRAL_CODE_CHARS.length)];
  }
  return s;
}

async function resolveReferrerAccountIdFromCode(
  db: FirebaseFirestore.Firestore,
  normalizedCode: string,
): Promise<string | null> {
  const lookup = await db.collection('referralLookup').doc(normalizedCode).get();
  if (lookup.exists) {
    const aid = (lookup.data()?.accountId as string | undefined)?.trim();
    return aid && aid.length > 0 ? aid : null;
  }
  const q = await db
    .collection('facilityCreatorAccounts')
    .where('referralCode', '==', normalizedCode)
    .limit(1)
    .get();
  if (q.empty) return null;
  return q.docs[0].id;
}

export const ensureReferralCodeForAccount = functions.https.onCall(async (_data: unknown, context) => {
  if (!context.auth?.uid) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const db = admin.firestore();
  const q = await db
    .collection('facilityCreatorAccounts')
    .where('ownerUid', '==', context.auth.uid)
    .limit(1)
    .get();
  if (q.empty) {
    throw new functions.https.HttpsError('failed-precondition', 'No facility creator account yet');
  }
  const accountRef = q.docs[0].ref;
  const accountSnap = q.docs[0];
  const existing = (accountSnap.get('referralCode') as string | undefined)?.trim().toUpperCase();
  if (existing && existing.length >= 4) {
    return { referralCode: existing, accountId: accountRef.id };
  }

  for (let attempt = 0; attempt < 12; attempt++) {
    const code = randomReferralCode();
    const lookupRef = db.collection('referralLookup').doc(code);
    try {
      await db.runTransaction(async (tx) => {
        const lu = await tx.get(lookupRef);
        if (lu.exists) {
          throw new Error('collision');
        }
        const acc = await tx.get(accountRef);
        const already = (acc.get('referralCode') as string | undefined)?.trim();
        if (already && already.length >= 4) {
          return;
        }
        tx.set(lookupRef, {
          accountId: accountRef.id,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        tx.update(accountRef, {
          referralCode: code,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      });
      const after = await accountRef.get();
      const rc = (after.get('referralCode') as string | undefined)?.trim().toUpperCase();
      if (rc && rc.length >= 4) {
        return { referralCode: rc, accountId: accountRef.id };
      }
    } catch {
      // retry on collision
    }
  }
  throw new functions.https.HttpsError('internal', 'Could not allocate referral code');
});

export const claimReferralAttribution = functions.https.onCall(async (data: { referralCode?: string }, context) => {
  if (!context.auth?.uid) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const raw = String(data?.referralCode ?? '').trim().toUpperCase();
  if (!raw || raw.length < 4) {
    throw new functions.https.HttpsError('invalid-argument', 'referralCode is required');
  }

  const db = admin.firestore();
  const q = await db
    .collection('facilityCreatorAccounts')
    .where('ownerUid', '==', context.auth.uid)
    .limit(1)
    .get();
  if (q.empty) {
    throw new functions.https.HttpsError('failed-precondition', 'No facility creator account yet');
  }
  const accountRef = q.docs[0].ref;
  const myAccountId = accountRef.id;

  const existingRef = q.docs[0].get('referredByAccountId') as string | undefined;
  if (existingRef && existingRef.trim().length > 0) {
    return { ok: true, alreadyClaimed: true, referredByAccountId: existingRef.trim() };
  }

  const referrerAccountId = await resolveReferrerAccountIdFromCode(db, raw);
  if (!referrerAccountId) {
    throw new functions.https.HttpsError('not-found', 'Unknown referral code');
  }
  if (referrerAccountId === myAccountId) {
    throw new functions.https.HttpsError('invalid-argument', 'You cannot refer yourself');
  }

  await accountRef.update({
    referredByAccountId: referrerAccountId,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  const facSnap = await db
    .collection('facilities')
    .where('facilityCreatorAccountId', '==', myAccountId)
    .get();
  const batch = db.batch();
  for (const doc of facSnap.docs) {
    const cur = (doc.get('platformReferralReferredByAccountId') as string | undefined)?.trim();
    if (!cur) {
      batch.update(doc.ref, {
        platformReferralReferredByAccountId: referrerAccountId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  }
  await batch.commit();

  return { ok: true, alreadyClaimed: false, referredByAccountId: referrerAccountId };
});

export const setReferralRewardPreferredFacility = functions.https.onCall(
  async (data: { facilityId?: string | null }, context) => {
    if (!context.auth?.uid) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }
    enforceAppCheckOrThrow(context);

    const db = admin.firestore();
    const q = await db
      .collection('facilityCreatorAccounts')
      .where('ownerUid', '==', context.auth.uid)
      .limit(1)
      .get();
    if (q.empty) {
      throw new functions.https.HttpsError('failed-precondition', 'No facility creator account yet');
    }
    const accountRef = q.docs[0].ref;
    const facIds = ((q.docs[0].get('facilityIds') as string[]) || []).slice();

    const raw = data?.facilityId;
    if (raw == null || String(raw).trim() === '') {
      await accountRef.update({
        referralRewardPreferredFacilityId: admin.firestore.FieldValue.delete(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return { ok: true, cleared: true };
    }

    const fid = String(raw).trim();
    if (!facIds.includes(fid)) {
      throw new functions.https.HttpsError('permission-denied', 'Facility is not on your account');
    }
    const facSnap = await db.collection('facilities').doc(fid).get();
    if (!facSnap.exists || facSnap.get('ownerUid') !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Not the facility owner');
    }

    await accountRef.update({
      referralRewardPreferredFacilityId: fid,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return { ok: true, facilityId: fid };
  },
);

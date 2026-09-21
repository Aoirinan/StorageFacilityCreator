import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

import { decideFacilityAccountLink } from '@sfc/functions-shared';

interface LinkFacilityToAccountRequest {
  accountId?: string;
  facilityId?: string;
  /** Carried from the account when it was itself referred; optional. */
  platformReferralReferredByAccountId?: string | null;
}

/**
 * Links an owner's own facility to their own platform account.
 *
 * The client used to write `facilities/{id}.facilityCreatorAccountId` itself,
 * straight after the creation wizard. That field was then locked as
 * backend-only, correctly: entitlement is resolved by reading it and checking
 * the named account's subscription, with no check that the caller owns that
 * account, so a writable link is a free premium subscription. Locking it
 * without giving the signup path somewhere to go left every new owner failing
 * at the link step, with their facility created but orphaned.
 *
 * So the rule stays shut and the legitimate write happens here, behind an
 * explicit check that the caller owns both halves.
 */
export const linkFacilityToAccount = functions.https.onCall(
  async (data: LinkFacilityToAccountRequest, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }
    const callerUid = context.auth.uid;
    const accountId = (data?.accountId || '').toString().trim();
    const facilityId = (data?.facilityId || '').toString().trim();
    if (!accountId || !facilityId) {
      throw new functions.https.HttpsError(
        'invalid-argument',
        'accountId and facilityId are required',
      );
    }

    const db = admin.firestore();
    const facilityRef = db.collection('facilities').doc(facilityId);
    const accountRef = db.collection('facilityCreatorAccounts').doc(accountId);
    const [facilitySnap, accountSnap] = await Promise.all([facilityRef.get(), accountRef.get()]);

    const decision = decideFacilityAccountLink({
      callerUid,
      accountId,
      facility: facilitySnap.exists ? (facilitySnap.data() as Record<string, unknown>) : null,
      account: accountSnap.exists ? (accountSnap.data() as Record<string, unknown>) : null,
    });

    if (!decision.ok) {
      const code =
        decision.code === 'not-found'
          ? 'not-found'
          : decision.code === 'already-linked'
            ? 'failed-precondition'
            : 'permission-denied';
      functions.logger.warn('Refused facility/account link', {
        callerUid,
        facilityId,
        accountId,
        reason: decision.code,
      });
      throw new functions.https.HttpsError(code, decision.message);
    }

    const now = admin.firestore.FieldValue.serverTimestamp();
    const facilityUpdate: Record<string, unknown> = {
      facilityCreatorAccountId: accountId,
      updatedAt: now,
    };

    // Only stamped when the facility has no referral of its own yet, so a
    // later call cannot overwrite an existing attribution.
    const referredBy = (data?.platformReferralReferredByAccountId || '').toString().trim();
    const existingReferral = String(
      (facilitySnap.data() as Record<string, unknown> | undefined)?.platformReferralReferredByAccountId ?? '',
    ).trim();
    if (referredBy && !existingReferral) {
      facilityUpdate.platformReferralReferredByAccountId = referredBy;
    }

    await facilityRef.update(facilityUpdate);
    await accountRef.update({
      facilityIds: admin.firestore.FieldValue.arrayUnion(facilityId),
      updatedAt: now,
    });

    functions.logger.info('Linked facility to account', {
      facilityId,
      accountId,
      callerUid,
      alreadyLinked: decision.alreadyLinked,
    });
    return { success: true, alreadyLinked: decision.alreadyLinked };
  },
);

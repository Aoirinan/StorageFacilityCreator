import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import {
  isSuperAdmin,
  getStripeClient,
  getOrCreateBasePriceId,
  getOrCreateAddOnPriceId,
  appendPlatformSecurityEmailFooter,
  appendPlatformAdminBroadcastFooter,
  escapeHtml,
  initializeSendGrid,
  getSgMail,
  reservePlatformOutgoing,
  releasePlatformOutgoing,
  resolveReferralPendingItemForSuperAdmin,
} from '@sfc/functions-shared';
import { adminDeleteDocumentTree } from './admin_delete_document_tree';
import { SENDGRID_SECRETS, STRIPE_SECRETS, SENDGRID_FROM_EMAIL, SENDGRID_FROM_NAME } from './secrets';

/**
 * Super admin only: delete a user from Firebase Auth and Firestore users collection.
 */
export const superAdminDeleteUser = functions.https.onCall(async (data: { uid: string }, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  const callerEmail = context.auth.token?.email as string | undefined;
  if (!isSuperAdmin(callerEmail)) {
    throw new functions.https.HttpsError('permission-denied', 'Only super admins can delete users');
  }
  const uid = (data?.uid || '').toString().trim();
  if (!uid) {
    throw new functions.https.HttpsError('invalid-argument', 'uid is required');
  }
  const targetUser = await admin.auth().getUser(uid);
  if (isSuperAdmin(targetUser.email)) {
    throw new functions.https.HttpsError('permission-denied', 'Cannot delete a super admin account');
  }
  await admin.auth().deleteUser(uid);
  await admin.firestore().collection('users').doc(uid).delete();
  functions.logger.info('superAdminDeleteUser', { uid, deletedBy: callerEmail });
  return { success: true };
});

interface SuperAdminDeleteFacilityCreatorAccountData {
  accountId: string;
  ownerEmailConfirmation: string;
}

/**
 * Super admin only: permanently remove a facility-creator account, all facilities
 * owned by that user (full document trees), the facilityCreatorAccounts doc (and
 * its subcollections), and the owner's Firebase Auth + users/{uid} document.
 *
 * Caller must type the account owner's email exactly (case-insensitive) as confirmation.
 */
export const superAdminDeleteFacilityCreatorAccount = functions
  .https.onCall(async (data: SuperAdminDeleteFacilityCreatorAccountData, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }
    const callerEmail = context.auth.token?.email as string | undefined;
    if (!isSuperAdmin(callerEmail)) {
      throw new functions.https.HttpsError(
        'permission-denied',
        'Only super admins can delete facility creator accounts',
      );
    }

    const accountId = (data?.accountId || '').toString().trim();
    const confirmation = (data?.ownerEmailConfirmation || '').toString().trim().toLowerCase();
    if (!accountId) {
      throw new functions.https.HttpsError('invalid-argument', 'accountId is required');
    }
    if (!confirmation) {
      throw new functions.https.HttpsError(
        'invalid-argument',
        'ownerEmailConfirmation is required',
      );
    }

    const db = admin.firestore();
    const accountRef = db.collection('facilityCreatorAccounts').doc(accountId);
    const accountSnap = await accountRef.get();
    if (!accountSnap.exists) {
      throw new functions.https.HttpsError('not-found', 'Account not found');
    }

    const accountData = accountSnap.data() as Record<string, unknown>;
    const ownerUid = (accountData.ownerUid || '').toString().trim();
    const ownerEmail = (accountData.ownerEmail || '').toString().trim();
    if (!ownerUid) {
      throw new functions.https.HttpsError('failed-precondition', 'Account has no ownerUid');
    }

    if (ownerEmail.toLowerCase() !== confirmation) {
      throw new functions.https.HttpsError(
        'invalid-argument',
        'Email confirmation does not match this account owner',
      );
    }

    let ownerAuthEmail: string | undefined;
    try {
      const ownerUser = await admin.auth().getUser(ownerUid);
      ownerAuthEmail = ownerUser.email;
    } catch (e: unknown) {
      const code = (e as { code?: string })?.code;
      if (code !== 'auth/user-not-found') {
        throw e;
      }
    }

    if (isSuperAdmin(ownerAuthEmail ?? ownerEmail)) {
      throw new functions.https.HttpsError(
        'permission-denied',
        'Cannot delete an account owned by a super admin',
      );
    }

    const facilitiesSnap = await db
      .collection('facilities')
      .where('ownerUid', '==', ownerUid)
      .get();

    for (const f of facilitiesSnap.docs) {
      await adminDeleteDocumentTree(f.ref);
    }

    await adminDeleteDocumentTree(accountRef);

    try {
      await admin.auth().deleteUser(ownerUid);
    } catch (e: unknown) {
      const code = (e as { code?: string })?.code;
      if (code !== 'auth/user-not-found') {
        throw e;
      }
    }

    await db.collection('users').doc(ownerUid).delete();

    functions.logger.info('superAdminDeleteFacilityCreatorAccount', {
      accountId,
      ownerUid,
      deletedBy: callerEmail,
      facilitiesDeleted: facilitiesSnap.size,
    });

    return { success: true, facilitiesDeleted: facilitiesSnap.size };
  });

/**
 * Remove all Firebase Storage objects under `facilities/{facilityId}/` (contracts,
 * documents, branding, etc.). Best-effort: logs and does not throw so Firestore
 * cleanup can still proceed if Storage is unavailable.
 */
async function deleteFacilityStoragePrefixBestEffort(facilityId: string): Promise<void> {
  const prefix = `facilities/${facilityId}/`;
  try {
    const bucket = admin.storage().bucket();
    await bucket.deleteFiles({ prefix, force: true });
    functions.logger.info('deleteFacilityStoragePrefix: removed objects', { facilityId, prefix });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    functions.logger.warn('deleteFacilityStoragePrefix: failed (Firestore delete will still run)', {
      facilityId,
      prefix,
      error: msg,
    });
  }
}

interface SuperAdminDeleteFacilityData {
  facilityId: string;
  facilityNameConfirmation: string;
}

/**
 * Super admin only: permanently delete one facility (full Firestore subtree under
 * `facilities/{facilityId}`), remove its id from the linked facility creator account,
 * delete `publicFacilityMaps/{slug}` when it points at this facility, align Stripe
 * subscription add-on quantity when the account has an active subscription, and
 * best-effort delete all Storage files under `facilities/{facilityId}/`.
 *
 * Caller must type the facility's display name exactly (trimmed) as confirmation.
 */
export const superAdminDeleteFacility = functions
  .runWith({ secrets: STRIPE_SECRETS })
  .https.onCall(async (data: SuperAdminDeleteFacilityData, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }
    const callerEmail = context.auth.token?.email as string | undefined;
    if (!isSuperAdmin(callerEmail)) {
      throw new functions.https.HttpsError('permission-denied', 'Only super admins can delete facilities');
    }

    const facilityId = (data?.facilityId || '').toString().trim();
    const facilityNameConfirmation = (data?.facilityNameConfirmation || '').toString().trim();
    if (!facilityId) {
      throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
    }
    if (!facilityNameConfirmation) {
      throw new functions.https.HttpsError('invalid-argument', 'facilityNameConfirmation is required');
    }

    const db = admin.firestore();
    const facilityRef = db.collection('facilities').doc(facilityId);
    const facilitySnap = await facilityRef.get();
    if (!facilitySnap.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilitySnap.data() as Record<string, unknown>;
    const facilityName = String(facilityData.name || '').trim();
    const confirmed = facilityNameConfirmation.trim();
    const matchesName = facilityName.length > 0 && facilityName === confirmed;
    const matchesIdForUnnamed = facilityName.length === 0 && facilityId === confirmed;
    if (!matchesName && !matchesIdForUnnamed) {
      throw new functions.https.HttpsError(
        'invalid-argument',
        'Confirmation must match the facility name exactly, or the facility ID if it has no name.',
      );
    }

    const metaSnap = await facilityRef.collection('mapEngine').doc('meta').get();
    const publicSlug = metaSnap.exists
      ? String(metaSnap.get('publicSlug') || '').trim().toLowerCase()
      : '';

    if (publicSlug) {
      const pubRef = db.collection('publicFacilityMaps').doc(publicSlug);
      const pubSnap = await pubRef.get();
      if (pubSnap.exists && String(pubSnap.get('facilityId') || '') === facilityId) {
        await adminDeleteDocumentTree(pubRef);
      }
    }

    const accountId = String(facilityData.facilityCreatorAccountId || '').trim();
    if (accountId) {
      const accRef = db.collection('facilityCreatorAccounts').doc(accountId);
      const accSnap = await accRef.get();
      if (accSnap.exists) {
        const accountData = accSnap.data() as Record<string, unknown>;
        const oldIds = (accountData.facilityIds as string[]) || [];
        const newIds = oldIds.filter((id) => id !== facilityId);

        const accUpdates: Record<string, unknown> = {
          facilityIds: admin.firestore.FieldValue.arrayRemove(facilityId),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        };
        if (accountData.referralRewardPreferredFacilityId === facilityId) {
          accUpdates.referralRewardPreferredFacilityId = admin.firestore.FieldValue.delete();
        }
        await accRef.update(accUpdates);

        const subscriptionId = (accountData.stripeSubscriptionId as string | undefined)?.trim();
        if (subscriptionId) {
          const stripe = getStripeClient();
          const subscription = await stripe.subscriptions.retrieve(subscriptionId);
          const basePriceId = process.env.STRIPE_BASE_PRICE_ID || (await getOrCreateBasePriceId(stripe));
          const addOnPriceId = process.env.STRIPE_ADDON_PRICE_ID || (await getOrCreateAddOnPriceId(stripe));
          const facilityCount = newIds.length;
          const additionalFacilityCount = Math.max(0, facilityCount - 1);
          const baseItem = subscription.items.data.find((item: Stripe.SubscriptionItem) => item.price.id === basePriceId);
          const addOnItem = subscription.items.data.find((item: Stripe.SubscriptionItem) => item.price.id === addOnPriceId);
          const currentAddOnQty = addOnItem ? addOnItem.quantity : 0;
          if (!(baseItem?.quantity === 1 && currentAddOnQty === additionalFacilityCount)) {
            const updatesStripe: Stripe.SubscriptionUpdateParams = {
              items: [],
              proration_behavior: 'create_prorations',
            };
            if (baseItem) {
              updatesStripe.items!.push({ id: baseItem.id, quantity: 1 });
            } else {
              updatesStripe.items!.push({ price: basePriceId, quantity: 1 });
            }
            if (additionalFacilityCount > 0) {
              if (addOnItem) {
                updatesStripe.items!.push({ id: addOnItem.id, quantity: additionalFacilityCount });
              } else {
                updatesStripe.items!.push({ price: addOnPriceId, quantity: additionalFacilityCount });
              }
            } else if (addOnItem) {
              updatesStripe.items!.push({ id: addOnItem.id, deleted: true });
            }
            await stripe.subscriptions.update(subscriptionId, updatesStripe);
          }
        }
      }
    }

    await deleteFacilityStoragePrefixBestEffort(facilityId);
    await adminDeleteDocumentTree(facilityRef);

    functions.logger.info('superAdminDeleteFacility', {
      facilityId,
      facilityName,
      deletedBy: callerEmail,
      accountId: accountId || null,
    });

    return { success: true };
  });

/**
 * Super admin only: disable a user in Firebase Auth (they cannot sign in).
 */
export const superAdminDisableUser = functions.https.onCall(async (data: { uid: string }, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  const callerEmail = context.auth.token?.email as string | undefined;
  if (!isSuperAdmin(callerEmail)) {
    throw new functions.https.HttpsError('permission-denied', 'Only super admins can disable users');
  }
  const uid = (data?.uid || '').toString().trim();
  if (!uid) {
    throw new functions.https.HttpsError('invalid-argument', 'uid is required');
  }
  const targetUser = await admin.auth().getUser(uid);
  if (isSuperAdmin(targetUser.email)) {
    throw new functions.https.HttpsError('permission-denied', 'Cannot disable a super admin account');
  }
  await admin.auth().updateUser(uid, { disabled: true });
  await admin.firestore().collection('users').doc(uid).set(
    { authDisabled: true, authDisabledAt: admin.firestore.FieldValue.serverTimestamp() },
    { merge: true },
  );
  functions.logger.info('superAdminDisableUser', { uid, disabledBy: callerEmail });
  return { success: true };
});

/**
 * Super admin only: re-enable a disabled user in Firebase Auth.
 */
export const superAdminEnableUser = functions.https.onCall(async (data: { uid: string }, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  const callerEmail = context.auth.token?.email as string | undefined;
  if (!isSuperAdmin(callerEmail)) {
    throw new functions.https.HttpsError('permission-denied', 'Only super admins can enable users');
  }
  const uid = (data?.uid || '').toString().trim();
  if (!uid) {
    throw new functions.https.HttpsError('invalid-argument', 'uid is required');
  }
  await admin.auth().updateUser(uid, { disabled: false });
  await admin.firestore().collection('users').doc(uid).set(
    { authDisabled: false, authDisabledAt: admin.firestore.FieldValue.delete() },
    { merge: true },
  );
  functions.logger.info('superAdminEnableUser', { uid, enabledBy: callerEmail });
  return { success: true };
});

/**
 * Super admin only: send a password reset email to the user (Firebase Auth link via SendGrid).
 */
export const superAdminSendPasswordReset = functions.runWith({ secrets: SENDGRID_SECRETS }).https.onCall(
  async (data: { uid: string }, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }
    const callerEmail = context.auth.token?.email as string | undefined;
    if (!isSuperAdmin(callerEmail)) {
      throw new functions.https.HttpsError('permission-denied', 'Only super admins can send password reset');
    }
    const uid = (data?.uid || '').toString().trim();
    if (!uid) {
      throw new functions.https.HttpsError('invalid-argument', 'uid is required');
    }
    const targetUser = await admin.auth().getUser(uid);
    const userEmail = targetUser.email;
    if (!userEmail) {
      throw new functions.https.HttpsError('invalid-argument', 'User has no email address');
    }
    const resetLink = await admin.auth().generatePasswordResetLink(userEmail);
    const sendGridFromEmail = SENDGRID_FROM_EMAIL.value();
    const fromName = SENDGRID_FROM_NAME.value();
    initializeSendGrid();
    const htmlBody = `<p>You requested a password reset. Click the link below to set a new password:</p><p><a href="${resetLink}">Reset password</a></p><p>If you did not request this, you can ignore this email.</p>`;
    const textBody = `Reset your password: ${resetLink}\n\nIf you did not request this, you can ignore this email.`;
    const { html, text } = appendPlatformSecurityEmailFooter(htmlBody, textBody);
    const msg = {
      to: userEmail,
      from: { email: sendGridFromEmail, name: fromName },
      subject: 'Reset your password - Storage Facility Creator',
      html,
      text,
    };
    await (getSgMail() as { send: (m: typeof msg) => Promise<void> }).send(msg);
    functions.logger.info('superAdminSendPasswordReset', { uid, to: userEmail, sentBy: callerEmail });
    return { success: true };
  },
);

/**
 * Super admin only: email every unique facility owner (one email per owner email address).
 * Uses platform SendGrid identity, respects configs/messagingGuard (same daily cap as staff sendEmail).
 * Does not increment per-facility monthly email usage.
 */
export const superAdminBroadcastEmailToFacilityOwners = functions
  .runWith({ secrets: SENDGRID_SECRETS, timeoutSeconds: 360, memory: '512MB' })
  .https.onCall(
    async (
      data: {
        subject?: string;
        html?: string;
        text?: string;
        includeInactiveFacilities?: boolean;
        /** 'allOwners' (default) or 'activePayingSubscribers' ($75/mo: active account sub or active per-facility platform sub) */
        recipientScope?: string;
        acknowledgment?: string;
        dryRun?: boolean;
      },
      context,
    ) => {
      if (!context.auth) {
        throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
      }
      const callerEmail = context.auth.token?.email as string | undefined;
      if (!isSuperAdmin(callerEmail)) {
        throw new functions.https.HttpsError(
          'permission-denied',
          'Only super admins can broadcast email to facility owners',
        );
      }

      const dryRun = data?.dryRun === true;
      const subject = String(data?.subject || '').trim();
      const htmlRaw = data?.html != null ? String(data.html) : '';
      const textRaw = data?.text != null ? String(data.text) : '';
      const ack = String(data?.acknowledgment || '').trim();

      if (!dryRun) {
        if (!subject || subject.length > 300) {
          throw new functions.https.HttpsError(
            'invalid-argument',
            'subject is required (max 300 characters)',
          );
        }
        if (!htmlRaw.trim() && !textRaw.trim()) {
          throw new functions.https.HttpsError(
            'invalid-argument',
            'html or text body is required',
          );
        }
        if (htmlRaw.length > 120_000 || textRaw.length > 120_000) {
          throw new functions.https.HttpsError('invalid-argument', 'Body is too large');
        }
        if (ack !== 'BROADCAST') {
          throw new functions.https.HttpsError(
            'invalid-argument',
            'Type BROADCAST in the confirmation field to send.',
          );
        }
      }

      const includeInactive = data?.includeInactiveFacilities === true;
      const recipientScope = String(data?.recipientScope || 'allOwners').trim();
      const payingOnly = recipientScope === 'activePayingSubscribers';
      if (
        recipientScope !== 'allOwners' &&
        recipientScope !== 'activePayingSubscribers'
      ) {
        throw new functions.https.HttpsError(
          'invalid-argument',
          'recipientScope must be allOwners or activePayingSubscribers',
        );
      }

      const db = admin.firestore();
      const facSnap = includeInactive
        ? await db.collection('facilities').get()
        : await db.collection('facilities').where('active', '==', true).get();

      const ownerUids = new Set<string>();
      if (!payingOnly) {
        for (const doc of facSnap.docs) {
          const ou = String(doc.data()?.ownerUid || '').trim();
          if (ou) ownerUids.add(ou);
        }
      } else {
        const accountIds = new Set<string>();
        for (const doc of facSnap.docs) {
          const aid = String(doc.data()?.facilityCreatorAccountId || '').trim();
          if (aid) accountIds.add(aid);
        }
        const accountPaying = new Map<string, boolean>();
        const idList = Array.from(accountIds);
        for (let i = 0; i < idList.length; i += 10) {
          const chunk = idList.slice(i, i + 10);
          const refs = chunk.map((id) =>
            db.collection('facilityCreatorAccounts').doc(id),
          );
          const snaps = refs.length > 0 ? await db.getAll(...refs) : [];
          for (let j = 0; j < snaps.length; j++) {
            const s = snaps[j];
            if (!s.exists) continue;
            const d = (s.data() || {}) as Record<string, unknown>;
            const active = String(d.subscriptionStatus || '').trim() === 'active';
            const suspended = d.suspended === true;
            accountPaying.set(chunk[j], active && !suspended);
          }
        }
        for (const doc of facSnap.docs) {
          const d = doc.data() || {};
          const ou = String(d.ownerUid || '').trim();
          if (!ou) continue;
          const platformActive =
            String(d.platformSubscriptionStatus || '').trim() === 'active';
          const aid = String(d.facilityCreatorAccountId || '').trim();
          const accountActive = aid ? accountPaying.get(aid) === true : false;
          if (platformActive || accountActive) {
            ownerUids.add(ou);
          }
        }
      }
      const uidList = Array.from(ownerUids);

      const recipients: { uid: string; email: string }[] = [];
      const seenEmails = new Set<string>();

      for (let i = 0; i < uidList.length; i += 10) {
        const chunk = uidList.slice(i, i + 10);
        const refs = chunk.map((uid) => db.collection('users').doc(uid));
        const snaps = refs.length > 0 ? await db.getAll(...refs) : [];
        const uidsNeedingAuth: string[] = [];
        for (let j = 0; j < snaps.length; j++) {
          const uid = chunk[j];
          let email: string | null = null;
          const snap = snaps[j];
          if (snap.exists) {
            const em = String(snap.data()?.email || '').trim();
            if (em.includes('@')) email = em;
          }
          if (email) {
            const lower = email.toLowerCase();
            if (!seenEmails.has(lower)) {
              seenEmails.add(lower);
              recipients.push({ uid, email });
            }
          } else {
            uidsNeedingAuth.push(uid);
          }
        }
        for (const uid of uidsNeedingAuth) {
          try {
            const authUser = await admin.auth().getUser(uid);
            const em = authUser.email?.trim();
            if (!em || !em.includes('@')) continue;
            const lower = em.toLowerCase();
            if (seenEmails.has(lower)) continue;
            seenEmails.add(lower);
            recipients.push({ uid, email: em });
          } catch {
            // skip missing auth user
          }
        }
      }

      if (dryRun) {
        return {
          dryRun: true,
          recipientScope: payingOnly ? 'activePayingSubscribers' : 'allOwners',
          facilityDocuments: facSnap.size,
          uniqueOwnerUids: uidList.length,
          recipientCount: recipients.length,
        };
      }

      let htmlBody = htmlRaw.trim();
      let textBody = textRaw.trim();
      if (!htmlBody && textBody) {
        htmlBody = `<p>${escapeHtml(textBody).replace(/\n/g, '<br/>')}</p>`;
      }
      if (!textBody && htmlBody) {
        textBody = htmlBody.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
      }

      const { html: htmlWithFooter, text: textWithFooter } = appendPlatformAdminBroadcastFooter(
        htmlBody,
        textBody,
      );

      initializeSendGrid();
      const sendGridFromEmail = SENDGRID_FROM_EMAIL.value();
      const fromName = SENDGRID_FROM_NAME.value();

      let sent = 0;
      const failures: { uid: string; email: string; error: string }[] = [];

      for (const { uid, email } of recipients) {
        let reserved = false;
        try {
          await reservePlatformOutgoing('email');
          reserved = true;
          const msg = {
            to: email,
            from: { email: sendGridFromEmail, name: fromName },
            subject,
            html: htmlWithFooter,
            text: textWithFooter,
          };
          await (getSgMail() as { send: (m: typeof msg) => Promise<void> }).send(msg);
          sent += 1;
          reserved = false;
        } catch (e: any) {
          if (reserved) {
            await releasePlatformOutgoing('email').catch((err) =>
              functions.logger.warn('releasePlatformOutgoing after broadcast failure', err),
            );
          }
          const errMsg =
            e instanceof functions.https.HttpsError
              ? e.message
              : (e?.message || String(e));
          failures.push({ uid, email, error: errMsg });
          functions.logger.error('superAdminBroadcastEmailToFacilityOwners send failed', {
            uid,
            email,
            error: errMsg,
          });
        }
      }

      functions.logger.info('superAdminBroadcastEmailToFacilityOwners complete', {
        sentBy: callerEmail,
        sent,
        failureCount: failures.length,
        totalRecipients: recipients.length,
      });

      await db.collection('superAdminBroadcastLogs').add({
        type: 'facility_owner_email',
        subject,
        sent,
        failureCount: failures.length,
        totalRecipients: recipients.length,
        facilityDocuments: facSnap.size,
        uniqueOwnerUids: uidList.length,
        includeInactiveFacilities: includeInactive,
        recipientScope: payingOnly ? 'activePayingSubscribers' : 'allOwners',
        sentByEmail: callerEmail,
        sentByUid: context.auth.uid,
        failures: failures.slice(0, 100),
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      return {
        success: true,
        sent,
        failureCount: failures.length,
        failures,
        totalRecipients: recipients.length,
      };
    },
  );

function serializeAuthUserForSuperAdmin(
  user: admin.auth.UserRecord,
  hasFirestoreProfile: boolean,
): Record<string, unknown> {
  return {
    uid: user.uid,
    email: user.email || '',
    emailVerified: user.emailVerified,
    disabled: user.disabled,
    creationTime: user.metadata.creationTime || null,
    lastSignInTime: user.metadata.lastSignInTime || null,
    hasFirestoreProfile,
  };
}

/**
 * Super admin only: look up a Firebase Auth user by email (finds accounts with no Firestore profile).
 */
export const superAdminGetAuthUserByEmail = functions.https.onCall(
  async (data: { email?: string }, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }
    const callerEmail = context.auth.token?.email as string | undefined;
    if (!isSuperAdmin(callerEmail)) {
      throw new functions.https.HttpsError(
        'permission-denied',
        'Only super admins can look up auth users',
      );
    }
    const raw = (data?.email || '').toString().trim().toLowerCase();
    if (!raw || !raw.includes('@')) {
      throw new functions.https.HttpsError('invalid-argument', 'Valid email is required');
    }
    try {
      const user = await admin.auth().getUserByEmail(raw);
      const profileSnap = await admin.firestore().collection('users').doc(user.uid).get();
      return {
        found: true,
        user: serializeAuthUserForSuperAdmin(user, profileSnap.exists),
      };
    } catch (e: unknown) {
      const code = (e as { code?: string })?.code;
      if (code === 'auth/user-not-found') {
        return { found: false };
      }
      throw e;
    }
  },
);

/**
 * Super admin only: paginated list of Firebase Auth users (with Firestore profile flag).
 */
export const superAdminListAuthUsers = functions.https.onCall(
  async (data: { pageToken?: string; maxResults?: number }, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }
    const callerEmail = context.auth.token?.email as string | undefined;
    if (!isSuperAdmin(callerEmail)) {
      throw new functions.https.HttpsError(
        'permission-denied',
        'Only super admins can list auth users',
      );
    }
    const requested = Number(data?.maxResults);
    const maxResults = Number.isFinite(requested)
      ? Math.min(Math.max(Math.floor(requested), 1), 100)
      : 50;
    const pageToken =
      data?.pageToken && String(data.pageToken).trim()
        ? String(data.pageToken).trim()
        : undefined;

    const listResult = await admin.auth().listUsers(maxResults, pageToken);
    const db = admin.firestore();
    const uids = listResult.users.map((u) => u.uid);
    const refs = uids.map((uid) => db.collection('users').doc(uid));
    const profileSnaps = refs.length > 0 ? await db.getAll(...refs) : [];

    const users = listResult.users.map((u, i) =>
      serializeAuthUserForSuperAdmin(u, profileSnaps[i]?.exists === true),
    );

    functions.logger.info('superAdminListAuthUsers', {
      count: users.length,
      hasMore: Boolean(listResult.pageToken),
      listedBy: callerEmail,
    });

    return {
      users,
      nextPageToken: listResult.pageToken || null,
    };
  },
);

/**
 * Super admin only: list referral rewards that require manual review.
 * Source: referralRewardsPending collection written by webhook referral logic.
 */
export const superAdminListReferralRewardsPending = functions.https.onCall(
  async (data: { limit?: number }, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }
    const callerEmail = context.auth.token?.email as string | undefined;
    if (!isSuperAdmin(callerEmail)) {
      throw new functions.https.HttpsError(
        'permission-denied',
        'Only super admins can list referral pending items',
      );
    }

    const requested = Number(data?.limit);
    const limit = Number.isFinite(requested)
      ? Math.min(Math.max(Math.floor(requested), 1), 200)
      : 100;

    const snap = await admin.firestore()
      .collection('referralRewardsPending')
      .orderBy('createdAt', 'desc')
      .limit(limit)
      .get();

    return {
      items: snap.docs.map((doc) => {
        const d = doc.data() as Record<string, unknown>;
        return {
          id: doc.id,
          reason: (d.reason as string | undefined) || null,
          error: (d.error as string | undefined) || null,
          referrerAccountId: (d.referrerAccountId as string | undefined) || null,
          refereeAccountId: (d.refereeAccountId as string | undefined) || null,
          refereeFacilityId: (d.refereeFacilityId as string | undefined) || null,
          stripeInvoiceId: (d.stripeInvoiceId as string | undefined) || null,
          createdAt: (d.createdAt as admin.firestore.Timestamp | undefined)?.toMillis() || null,
          status: (d.status as string | undefined) || 'open',
          resolutionAction: (d.resolutionAction as string | undefined) || null,
          resolutionNote: (d.resolutionNote as string | undefined) || null,
          resolvedByEmail: (d.resolvedByEmail as string | undefined) || null,
          resolvedAt: (d.resolvedAt as admin.firestore.Timestamp | undefined)?.toMillis() || null,
          resolvedAppliedToFacilityId: (d.resolvedAppliedToFacilityId as string | undefined) || null,
        };
      }),
    };
  },
);

/**
 * Super admin only: resolve one pending referral queue item.
 * - resolve_only: mark item closed with note
 * - apply_reward: apply manual 3-month reward then mark closed
 */
export const superAdminResolveReferralPending = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(
  async (
    data: {
      pendingId?: string;
      action?: 'resolve_only' | 'apply_reward';
      note?: string;
      targetFacilityId?: string;
    },
    context,
  ) => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }
    const callerEmail = context.auth.token?.email as string | undefined;
    if (!isSuperAdmin(callerEmail)) {
      throw new functions.https.HttpsError(
        'permission-denied',
        'Only super admins can resolve referral pending items',
      );
    }

    const pendingId = String(data?.pendingId || '').trim();
    const action = (data?.action === 'apply_reward' ? 'apply_reward' : 'resolve_only');
    if (!pendingId) {
      throw new functions.https.HttpsError('invalid-argument', 'pendingId is required');
    }

    return resolveReferralPendingItemForSuperAdmin(getStripeClient(), {
      pendingId,
      action,
      note: data?.note,
      actorEmail: callerEmail || 'unknown',
      targetFacilityId: data?.targetFacilityId || null,
    });
  },
);
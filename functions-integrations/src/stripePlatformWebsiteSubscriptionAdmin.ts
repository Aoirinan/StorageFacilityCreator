import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import {
  enforceAppCheckOrThrow,
  getStripeClient,
} from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';
import {
  isWebsiteAddonSubscription,
  updateFacilityFromWebsiteSubscription,
} from './stripeWebhookSubscriptionInternal';
import { hasActiveBasePlatformSubscription } from './stripePlatformWebsiteSubscription';

export type WebsiteAdminAction =
  | 'grantTrial'
  | 'extendTrial'
  | 'revokeTrial'
  | 'syncStripe';

const DAY_MS = 24 * 60 * 60 * 1000;

export function calculateWebsiteAdminTrialEnd(
  action: 'grantTrial' | 'extendTrial',
  days: number,
  nowMs: number,
  currentEndMs?: number,
): number {
  if (!Number.isInteger(days) || days < 1 || days > 365) {
    throw new Error('days must be an integer from 1 to 365');
  }
  const baseMs = action === 'extendTrial' && currentEndMs && currentEndMs > nowMs
    ? currentEndMs
    : nowMs;
  return baseMs + days * DAY_MS;
}

function timestampMillis(value: unknown): number | undefined {
  if (value instanceof admin.firestore.Timestamp) return value.toMillis();
  return undefined;
}

function requireSuperAdmin(context: functions.https.CallableContext): {
  uid: string;
  email: string;
} {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);
  const email = String(context.auth.token.email || '').trim().toLowerCase();
  // Authorization is by the server-set `superadmin` custom claim only, so an
  // unverified password account matching an allowlisted email cannot
  // impersonate an admin.
  if (context.auth.token.superadmin !== true) {
    throw new functions.https.HttpsError(
      'permission-denied',
      'Only super admins can manage website subscriptions',
    );
  }
  return { uid: context.auth.uid, email };
}

export const superAdminManageWebsiteSubscription = functions
  .runWith({
    timeoutSeconds: 60,
    memory: '256MB',
    secrets: STRIPE_SECRETS,
    invoker: 'public',
  })
  .https.onCall(async (data: {
    facilityId?: string;
    action?: WebsiteAdminAction;
    days?: number;
    reason?: string;
  }, context) => {
    const caller = requireSuperAdmin(context);
    const facilityId = String(data?.facilityId || '').trim();
    const action = data?.action;
    const reason = String(data?.reason || '').trim();
    if (!facilityId || !action) {
      throw new functions.https.HttpsError(
        'invalid-argument',
        'facilityId and action are required',
      );
    }
    if (!['grantTrial', 'extendTrial', 'revokeTrial', 'syncStripe'].includes(action)) {
      throw new functions.https.HttpsError('invalid-argument', 'Unsupported action');
    }
    if (reason.length > 500) {
      throw new functions.https.HttpsError(
        'invalid-argument',
        'Reason must be 500 characters or fewer',
      );
    }

    const facilityRef = admin.firestore().collection('facilities').doc(facilityId);
    const facilitySnap = await facilityRef.get();
    if (!facilitySnap.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }
    const facility = facilitySnap.data() || {};
    const nowMs = Date.now();
    const auditReason = reason || 'Managed from the superadmin Websites tab';

    if (action === 'grantTrial' || action === 'extendTrial') {
      const accountId = String(facility.facilityCreatorAccountId || '').trim();
      const accountSnap = accountId
        ? await admin.firestore().collection('facilityCreatorAccounts').doc(accountId).get()
        : null;
      const account = accountSnap?.data() || {};
      if (!hasActiveBasePlatformSubscription(account, facility, nowMs)) {
        throw new functions.https.HttpsError(
          'failed-precondition',
          'An active, non-suspended $75 platform subscription is required',
        );
      }
      const websiteStatus = String(facility.websiteSubscriptionStatus || '').toLowerCase();
      const subscriptionId = String(facility.stripeWebsiteSubscriptionId || '').trim();
      if (
        subscriptionId.startsWith('sub_') &&
        (websiteStatus === 'active' || websiteStatus === 'trialing')
      ) {
        throw new functions.https.HttpsError(
          'failed-precondition',
          'This facility already has an active paid website subscription',
        );
      }

      const days = Number(data.days ?? 30);
      let endMs: number;
      try {
        endMs = calculateWebsiteAdminTrialEnd(
          action,
          days,
          nowMs,
          timestampMillis(facility.websiteAdminTrialEndsAt),
        );
      } catch (error) {
        throw new functions.https.HttpsError(
          'invalid-argument',
          error instanceof Error ? error.message : 'Invalid trial duration',
        );
      }
      await facilityRef.update({
        websiteAdminTrialEndsAt: admin.firestore.Timestamp.fromMillis(endMs),
        websiteAdminTrialGrantedAt: admin.firestore.FieldValue.serverTimestamp(),
        websiteAdminTrialGrantedByUid: caller.uid,
        websiteAdminTrialGrantedByEmail: caller.email,
        websiteAdminTrialReason: auditReason,
        websiteAdminTrialRevokedAt: admin.firestore.FieldValue.delete(),
        websiteAdminTrialRevokedByUid: admin.firestore.FieldValue.delete(),
        websiteAdminTrialRevokedByEmail: admin.firestore.FieldValue.delete(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      functions.logger.info('Superadmin website trial updated', {
        action,
        facilityId,
        days,
        endMs,
        callerUid: caller.uid,
      });
      return { action, facilityId, trialEndsAtMs: endMs };
    }

    if (action === 'revokeTrial') {
      await facilityRef.update({
        websiteAdminTrialEndsAt: admin.firestore.FieldValue.delete(),
        websiteAdminTrialRevokedAt: admin.firestore.FieldValue.serverTimestamp(),
        websiteAdminTrialRevokedByUid: caller.uid,
        websiteAdminTrialRevokedByEmail: caller.email,
        websiteAdminTrialReason: auditReason,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      functions.logger.info('Superadmin website trial revoked', {
        facilityId,
        callerUid: caller.uid,
      });
      return { action, facilityId };
    }

    const subscriptionId = String(facility.stripeWebsiteSubscriptionId || '').trim();
    if (!subscriptionId.startsWith('sub_')) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'This facility has no Stripe website subscription to repair',
      );
    }
    const stripe = getStripeClient();
    const subscription = await stripe.subscriptions.retrieve(subscriptionId);
    if (
      !isWebsiteAddonSubscription(subscription) ||
      subscription.metadata?.facilityId !== facilityId
    ) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Stripe subscription metadata does not match this facility website',
      );
    }
    await updateFacilityFromWebsiteSubscription(facilityId, subscription);
    functions.logger.info('Superadmin repaired website subscription from Stripe', {
      facilityId,
      subscriptionId,
      callerUid: caller.uid,
    });
    return {
      action,
      facilityId,
      subscriptionId,
      status: subscription.status,
    };
  });

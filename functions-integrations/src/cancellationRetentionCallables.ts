import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import type Stripe from 'stripe';
import { enforceAppCheckOrThrow, getStripeClient } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';
import {
  CANCELLATION_RETENTION_DOC,
  DEFAULT_CANCELLATION_RETENTION_CONFIG,
  type CancellationPlanType,
  type CancellationPromo,
  type CancellationRetentionConfig,
} from './cancellationRetentionDefaults';

const CONFIG_REF = () =>
  admin.firestore().collection('appConfig').doc(CANCELLATION_RETENTION_DOC);
const EVENTS_COL = () => admin.firestore().collection('cancellationEvents');

function requireAuth(context: functions.https.CallableContext): {
  uid: string;
  email: string;
} {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);
  return {
    uid: context.auth.uid,
    email: String(context.auth.token.email || '').trim().toLowerCase(),
  };
}

function requireSuperAdmin(context: functions.https.CallableContext): {
  uid: string;
  email: string;
} {
  const caller = requireAuth(context);
  if (context.auth?.token.superadmin !== true) {
    throw new functions.https.HttpsError(
      'permission-denied',
      'Only super admins can manage cancellation retention',
    );
  }
  return caller;
}

function asConfig(data: Record<string, unknown> | undefined): CancellationRetentionConfig {
  const base = DEFAULT_CANCELLATION_RETENTION_CONFIG;
  if (!data) return { ...base, promos: [...base.promos] };
  return {
    primaryReasons: Array.isArray(data.primaryReasons)
      ? (data.primaryReasons as CancellationRetentionConfig['primaryReasons'])
      : base.primaryReasons,
    detailReasonsByPrimary:
      data.detailReasonsByPrimary && typeof data.detailReasonsByPrimary === 'object'
        ? (data.detailReasonsByPrimary as CancellationRetentionConfig['detailReasonsByPrimary'])
        : base.detailReasonsByPrimary,
    promos: Array.isArray(data.promos)
      ? (data.promos as CancellationPromo[])
      : [...base.promos],
    lossCopy:
      data.lossCopy && typeof data.lossCopy === 'object'
        ? (data.lossCopy as CancellationRetentionConfig['lossCopy'])
        : base.lossCopy,
  };
}

export async function getOrSeedCancellationRetentionConfig(): Promise<CancellationRetentionConfig> {
  const ref = CONFIG_REF();
  const snap = await ref.get();
  if (!snap.exists) {
    const seeded = {
      ...DEFAULT_CANCELLATION_RETENTION_CONFIG,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    await ref.set(seeded);
    return DEFAULT_CANCELLATION_RETENTION_CONFIG;
  }
  return asConfig(snap.data() as Record<string, unknown>);
}

function activePromosForPlan(
  config: CancellationRetentionConfig,
  planType: CancellationPlanType,
): CancellationPromo[] {
  return config.promos
    .filter((p) => p.active && p.planTypes.includes(planType))
    .sort((a, b) => (a.sortOrder ?? 0) - (b.sortOrder ?? 0));
}

async function assertFacilityOwner(
  uid: string,
  facilityId: string,
): Promise<{ facility: Record<string, unknown>; accountId: string }> {
  const facilitySnap = await admin.firestore().collection('facilities').doc(facilityId).get();
  if (!facilitySnap.exists) {
    throw new functions.https.HttpsError('not-found', 'Facility not found');
  }
  const facility = facilitySnap.data() as Record<string, unknown>;
  if (facility.ownerUid !== uid) {
    throw new functions.https.HttpsError('permission-denied', 'Only the facility owner can cancel');
  }
  const accountId = String(facility.facilityCreatorAccountId || '').trim();
  if (!accountId) {
    throw new functions.https.HttpsError('failed-precondition', 'Facility has no billing account');
  }
  return { facility, accountId };
}

async function ensureStripeCoupon(
  stripe: Stripe,
  promo: CancellationPromo,
): Promise<string> {
  if (promo.stripeCouponId) {
    try {
      const existing = await stripe.coupons.retrieve(promo.stripeCouponId);
      if (!existing.deleted) return existing.id;
    } catch {
      // recreate below
    }
  }

  const params: Stripe.CouponCreateParams = {
    name: promo.title.slice(0, 40),
    duration: 'repeating',
    duration_in_months: Math.max(1, Math.min(36, promo.durationMonths || 1)),
    metadata: {
      sfcPromoId: promo.id,
      source: 'cancellation_retention',
    },
  };
  if (typeof promo.percentOff === 'number' && promo.percentOff > 0) {
    params.percent_off = Math.min(100, Math.max(1, Math.round(promo.percentOff)));
  } else if (typeof promo.amountOffCents === 'number' && promo.amountOffCents > 0) {
    params.amount_off = Math.round(promo.amountOffCents);
    params.currency = 'usd';
  } else {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Promotion must have percentOff or amountOffCents',
    );
  }

  const coupon = await stripe.coupons.create(params);
  return coupon.id;
}

export const getCancellationRetentionConfig = functions
  .runWith({ timeoutSeconds: 30, memory: '256MB', invoker: 'public' })
  .https.onCall(async (_data, context) => {
    requireAuth(context);
    const config = await getOrSeedCancellationRetentionConfig();
    return { config };
  });

export const submitCancellationIntent = functions
  .runWith({ timeoutSeconds: 30, memory: '256MB', invoker: 'public' })
  .https.onCall(async (data: {
    facilityId?: string;
    planType?: CancellationPlanType;
    primaryReason?: string;
    detailReason?: string;
  }, context) => {
    const caller = requireAuth(context);
    const facilityId = String(data?.facilityId || '').trim();
    const planType = data?.planType;
    const primaryReason = String(data?.primaryReason || '').trim();
    const detailReason = String(data?.detailReason || '').trim();

    if (!facilityId || (planType !== 'platform' && planType !== 'website')) {
      throw new functions.https.HttpsError(
        'invalid-argument',
        'facilityId and planType (platform|website) are required',
      );
    }
    if (!primaryReason || !detailReason) {
      throw new functions.https.HttpsError(
        'invalid-argument',
        'primaryReason and detailReason are required',
      );
    }

    const { accountId } = await assertFacilityOwner(caller.uid, facilityId);
    const config = await getOrSeedCancellationRetentionConfig();
    const primaryOk = config.primaryReasons.some((r) => r.id === primaryReason);
    const detailOk = (config.detailReasonsByPrimary[primaryReason] || []).some(
      (r) => r.id === detailReason,
    );
    if (!primaryOk || !detailOk) {
      throw new functions.https.HttpsError('invalid-argument', 'Invalid cancellation reasons');
    }

    const promos = activePromosForPlan(config, planType);
    const eventRef = EVENTS_COL().doc();
    await eventRef.set({
      accountId,
      facilityId,
      ownerUid: caller.uid,
      planType,
      primaryReason,
      detailReason,
      promoIdsShown: promos.map((p) => p.id),
      outcome: 'in_progress',
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return {
      eventId: eventRef.id,
      lossCopy: config.lossCopy[planType] || [],
      promos,
    };
  });

export const acceptCancellationRetentionOffer = functions
  .runWith({
    timeoutSeconds: 60,
    memory: '256MB',
    secrets: STRIPE_SECRETS,
    invoker: 'public',
  })
  .https.onCall(async (data: {
    eventId?: string;
    promoId?: string;
  }, context) => {
    const caller = requireAuth(context);
    const eventId = String(data?.eventId || '').trim();
    const promoId = String(data?.promoId || '').trim();
    if (!eventId || !promoId) {
      throw new functions.https.HttpsError('invalid-argument', 'eventId and promoId are required');
    }

    const eventRef = EVENTS_COL().doc(eventId);
    const eventSnap = await eventRef.get();
    if (!eventSnap.exists) {
      throw new functions.https.HttpsError('not-found', 'Cancellation event not found');
    }
    const event = eventSnap.data() as Record<string, unknown>;
    if (event.ownerUid !== caller.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }
    if (event.outcome === 'cancelled' || event.outcome === 'retained') {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'This cancellation flow is already finished',
      );
    }

    const facilityId = String(event.facilityId || '');
    const planType = event.planType as CancellationPlanType;
    const { facility } = await assertFacilityOwner(caller.uid, facilityId);

    const config = await getOrSeedCancellationRetentionConfig();
    const promo = config.promos.find((p) => p.id === promoId && p.active);
    if (!promo || !promo.planTypes.includes(planType)) {
      throw new functions.https.HttpsError('failed-precondition', 'Promotion is not available');
    }

    const subscriptionId =
      planType === 'website'
        ? (facility.stripeWebsiteSubscriptionId as string | undefined)
        : (facility.stripePlatformSubscriptionId as string | undefined) ||
          undefined;

    let resolvedSubId = subscriptionId;
    if (!resolvedSubId && planType === 'platform') {
      const accountId = String(event.accountId || '');
      const accountSnap = await admin
        .firestore()
        .collection('facilityCreatorAccounts')
        .doc(accountId)
        .get();
      resolvedSubId = accountSnap.data()?.stripeSubscriptionId as string | undefined;
    }
    if (!resolvedSubId) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'No active Stripe subscription found for this plan',
      );
    }

    try {
      const stripe = getStripeClient();
      const couponId = await ensureStripeCoupon(stripe, promo);

      // Persist coupon id on config promo for reuse
      const nextPromos = config.promos.map((p) =>
        p.id === promo.id ? { ...p, stripeCouponId: couponId } : p,
      );
      await CONFIG_REF().set(
        {
          ...config,
          promos: nextPromos,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );

      await stripe.subscriptions.update(resolvedSubId, {
        discounts: [{ coupon: couponId }],
        cancel_at_period_end: false,
      });

      await eventRef.update({
        outcome: 'retained',
        promoIdAccepted: promoId,
        stripeCouponId: couponId,
        completedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      return {
        success: true,
        message: 'Offer applied. Your subscription stays active with the discount.',
      };
    } catch (error: unknown) {
      if (error instanceof functions.https.HttpsError) throw error;
      const message = error instanceof Error ? error.message : String(error);
      functions.logger.error('acceptCancellationRetentionOffer failed', {
        eventId,
        promoId,
        message,
      });
      throw new functions.https.HttpsError(
        'internal',
        'Could not apply the stay offer. Your subscription was not cancelled.',
      );
    }
  });

export const confirmCancellationAfterSurvey = functions
  .runWith({
    timeoutSeconds: 60,
    memory: '256MB',
    secrets: STRIPE_SECRETS,
    invoker: 'public',
  })
  .https.onCall(async (data: { eventId?: string }, context) => {
    const caller = requireAuth(context);
    const eventId = String(data?.eventId || '').trim();
    if (!eventId) {
      throw new functions.https.HttpsError('invalid-argument', 'eventId is required');
    }

    const eventRef = EVENTS_COL().doc(eventId);
    const eventSnap = await eventRef.get();
    if (!eventSnap.exists) {
      throw new functions.https.HttpsError('not-found', 'Cancellation event not found');
    }
    const event = eventSnap.data() as Record<string, unknown>;
    if (event.ownerUid !== caller.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }
    if (event.outcome === 'cancelled' || event.outcome === 'retained') {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'This cancellation flow is already finished',
      );
    }
    if (!event.primaryReason || !event.detailReason) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Survey answers are required before cancelling',
      );
    }

    const facilityId = String(event.facilityId || '');
    const planType = event.planType as CancellationPlanType;
    const { facility, accountId } = await assertFacilityOwner(caller.uid, facilityId);
    const stripe = getStripeClient();

    if (planType === 'website') {
      const subscriptionId = facility.stripeWebsiteSubscriptionId as string | undefined;
      if (!subscriptionId) {
        throw new functions.https.HttpsError(
          'failed-precondition',
          'No website subscription found for this facility',
        );
      }
      await stripe.subscriptions.update(subscriptionId, { cancel_at_period_end: true });
      await admin.firestore().collection('facilities').doc(facilityId).update({
        websiteSubscriptionCancelAtPeriodEnd: true,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } else {
      const facilitySubId = facility.stripePlatformSubscriptionId as string | undefined;
      if (facilitySubId) {
        await stripe.subscriptions.update(facilitySubId, { cancel_at_period_end: true });
        await admin.firestore().collection('facilities').doc(facilityId).update({
          platformSubscriptionCancelAtPeriodEnd: true,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      } else {
        const accountSnap = await admin
          .firestore()
          .collection('facilityCreatorAccounts')
          .doc(accountId)
          .get();
        const accountSubId = accountSnap.data()?.stripeSubscriptionId as string | undefined;
        if (!accountSubId) {
          throw new functions.https.HttpsError(
            'failed-precondition',
            'No platform subscription found',
          );
        }
        await stripe.subscriptions.update(accountSubId, { cancel_at_period_end: true });
        await accountSnap.ref.update({
          subscriptionCancelAtPeriodEnd: true,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
    }

    await eventRef.update({
      outcome: 'cancelled',
      completedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return {
      success: true,
      message: 'Subscription will cancel at the end of the billing period.',
    };
  });

export const superAdminUpsertCancellationRetentionConfig = functions
  .runWith({
    timeoutSeconds: 60,
    memory: '256MB',
    secrets: STRIPE_SECRETS,
    invoker: 'public',
  })
  .https.onCall(async (data: { config?: CancellationRetentionConfig }, context) => {
    requireSuperAdmin(context);
    const incoming = data?.config;
    if (!incoming || typeof incoming !== 'object') {
      throw new functions.https.HttpsError('invalid-argument', 'config is required');
    }

    const normalized: CancellationRetentionConfig = {
      primaryReasons: Array.isArray(incoming.primaryReasons)
        ? incoming.primaryReasons
        : DEFAULT_CANCELLATION_RETENTION_CONFIG.primaryReasons,
      detailReasonsByPrimary:
        incoming.detailReasonsByPrimary && typeof incoming.detailReasonsByPrimary === 'object'
          ? incoming.detailReasonsByPrimary
          : DEFAULT_CANCELLATION_RETENTION_CONFIG.detailReasonsByPrimary,
      promos: Array.isArray(incoming.promos) ? incoming.promos : [],
      lossCopy: incoming.lossCopy || DEFAULT_CANCELLATION_RETENTION_CONFIG.lossCopy,
    };

    // Ensure Stripe coupons exist for active promos
    const stripe = getStripeClient();
    const promosWithCoupons: CancellationPromo[] = [];
    for (const promo of normalized.promos) {
      if (!promo.active) {
        promosWithCoupons.push(promo);
        continue;
      }
      try {
        const couponId = await ensureStripeCoupon(stripe, promo);
        promosWithCoupons.push({ ...promo, stripeCouponId: couponId });
      } catch (error: unknown) {
        const message = error instanceof Error ? error.message : String(error);
        functions.logger.error('Failed to sync promo coupon', { promoId: promo.id, message });
        promosWithCoupons.push(promo);
      }
    }

    const toSave = {
      ...normalized,
      promos: promosWithCoupons,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    await CONFIG_REF().set(toSave, { merge: false });
    return { success: true, config: { ...normalized, promos: promosWithCoupons } };
  });

export const superAdminListCancellationEvents = functions
  .runWith({ timeoutSeconds: 60, memory: '256MB', invoker: 'public' })
  .https.onCall(async (data: {
    planType?: CancellationPlanType | 'all';
    limit?: number;
  }, context) => {
    requireSuperAdmin(context);
    const limit = Math.min(500, Math.max(1, Number(data?.limit) || 200));
    let query: admin.firestore.Query = EVENTS_COL().orderBy('createdAt', 'desc').limit(limit);
    if (data?.planType === 'platform' || data?.planType === 'website') {
      query = EVENTS_COL()
        .where('planType', '==', data.planType)
        .orderBy('createdAt', 'desc')
        .limit(limit);
    }
    const snap = await query.get();
    const events = snap.docs.map((doc) => {
      const d = doc.data();
      return {
        id: doc.id,
        ...d,
        createdAt: d.createdAt?.toDate?.()?.toISOString?.() ?? null,
        completedAt: d.completedAt?.toDate?.()?.toISOString?.() ?? null,
      };
    });
    return { events };
  });

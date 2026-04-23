/**
 * Referral program: referred facilities get 60 days platform trial; after first paid
 * invoice post-trial, referrer earns 100% off for 3 months on one platform subscription.
 * Caps and rules are documented in product copy / support runbooks.
 */
import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import type Stripe from 'stripe';

const REFEREE_PLATFORM_TRIAL_DAYS = 60;
const REFERRAL_REWARD_FREE_MONTHS = 3;
const REFERRAL_MAX_REWARDS_PER_REFERRER_PER_YEAR = 10;
const REFERRAL_CODE_CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const REFERRAL_CODE_LEN = 8;

function enforceAppCheckOrThrow(context: functions.https.CallableContext): void {
  if (!context.app) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'App Check token required. Please update your app.',
    );
  }
}

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

/** Exported for createFacilitySubscriptionCheckout */
export function getRefereePlatformTrialDays(facilitySnap: FirebaseFirestore.DocumentSnapshot): number {
  const d = facilitySnap.data() as Record<string, unknown> | undefined;
  const refBy = (d?.platformReferralReferredByAccountId as string | undefined)?.trim();
  return refBy && refBy.length > 0 ? REFEREE_PLATFORM_TRIAL_DAYS : 30;
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

async function isFirstNonZeroPaidInvoice(
  stripe: Stripe,
  subscriptionId: string,
  currentInvoiceId: string,
): Promise<boolean> {
  const list = await stripe.invoices.list({ subscription: subscriptionId, limit: 100 });
  const paid = list.data
    .filter((inv) => inv.status === 'paid' && (inv.amount_paid ?? 0) > 0)
    .sort((a, b) => (a.created ?? 0) - (b.created ?? 0));
  return paid.length > 0 && paid[0].id === currentInvoiceId;
}

async function pickReferrerTargetSubscriptionId(
  db: FirebaseFirestore.Firestore,
  stripe: Stripe,
  referrerAccountId: string,
  preferredFacilityIdOverride?: string | null,
): Promise<{ facilityId: string; subscriptionId: string } | null> {
  const acc = await db.collection('facilityCreatorAccounts').doc(referrerAccountId).get();
  if (!acc.exists) return null;
  const ids = ((acc.get('facilityIds') as string[]) || []).slice().sort();
  const accountPreferred = (acc.get('referralRewardPreferredFacilityId') as string | undefined)?.trim();
  const preferred = (preferredFacilityIdOverride || accountPreferred || '').trim() || undefined;

  async function eligibleFor(fid: string): Promise<{ facilityId: string; subscriptionId: string } | null> {
    const f = await db.collection('facilities').doc(fid).get();
    if (!f.exists) return null;
    const subId = (f.get('stripePlatformSubscriptionId') as string | undefined)?.trim();
    const st = (f.get('platformSubscriptionStatus') as string | undefined) || '';
    if (!subId) return null;
    if (!['active', 'trialing', 'past_due'].includes(st)) return null;
    try {
      const sub = await stripe.subscriptions.retrieve(subId);
      if (sub.status === 'active' || sub.status === 'trialing' || sub.status === 'past_due') {
        return { facilityId: fid, subscriptionId: subId };
      }
    } catch {
      return null;
    }
    return null;
  }

  if (preferred && ids.includes(preferred)) {
    const t = await eligibleFor(preferred);
    if (t) return t;
  }
  for (const fid of ids) {
    if (fid === preferred) continue;
    const t = await eligibleFor(fid);
    if (t) return t;
  }
  return null;
}

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

async function applyThreeMonthFullDiscount(
  stripe: Stripe,
  subscriptionId: string,
  idempotencyKey: string,
  metadata: Record<string, string>,
): Promise<void> {
  const coupon = await stripe.coupons.create(
    {
      percent_off: 100,
      duration: 'repeating',
      duration_in_months: REFERRAL_REWARD_FREE_MONTHS,
      name: 'Referral reward (3 months)',
      metadata,
    },
    { idempotencyKey: `${idempotencyKey}_coupon` },
  );

  const sub = await stripe.subscriptions.retrieve(subscriptionId, { expand: ['discounts'] });
  const nextDiscounts: Stripe.SubscriptionUpdateParams.Discount[] = [];
  const rawDiscounts = (sub as unknown as { discounts?: Stripe.Discount[] | Stripe.ApiList<Stripe.Discount> })
    .discounts;
  const list: Stripe.Discount[] = Array.isArray(rawDiscounts)
    ? rawDiscounts
    : rawDiscounts && 'data' in rawDiscounts
      ? rawDiscounts.data
      : [];
  for (const d of list) {
    const couponField = (d as unknown as { coupon?: string | { id?: string } | null }).coupon;
    const c = typeof couponField === 'string' ? couponField : couponField?.id;
    if (c) nextDiscounts.push({ coupon: c });
  }
  nextDiscounts.push({ coupon: coupon.id });

  try {
    await stripe.subscriptions.update(
      subscriptionId,
      {
        discounts: nextDiscounts,
        proration_behavior: 'none',
      },
      { idempotencyKey: `${idempotencyKey}_sub` },
    );
  } catch (e) {
    functions.logger.warn('Referral: multi-discount update failed, applying coupon only', { subscriptionId, e });
    await stripe.subscriptions.update(
      subscriptionId,
      {
        discounts: [{ coupon: coupon.id }],
        proration_behavior: 'none',
      },
      { idempotencyKey: `${idempotencyKey}_sub_fallback` },
    );
  }
}

/**
 * Called from stripe webhook after platform facility invoice success.
 */
export async function processReferralOnPlatformInvoicePaid(
  stripe: Stripe,
  invoice: Stripe.Invoice,
  subscription: Stripe.Subscription,
  facilityId: string,
): Promise<void> {
  const db = admin.firestore();
  if ((invoice.amount_paid ?? 0) <= 0) {
    return;
  }

  const subscriptionId = subscription.id;
  const okFirst = await isFirstNonZeroPaidInvoice(stripe, subscriptionId, invoice.id);
  if (!okFirst) {
    return;
  }

  const facRef = db.collection('facilities').doc(facilityId);
  const facSnap = await facRef.get();
  if (!facSnap.exists) return;

  const referredBy = (facSnap.get('platformReferralReferredByAccountId') as string | undefined)?.trim();
  if (!referredBy) return;

  const refereeAccountId = (facSnap.get('facilityCreatorAccountId') as string | undefined)?.trim();
  if (!refereeAccountId || refereeAccountId === referredBy) {
    functions.logger.info('Referral skip: self or missing referee account', { facilityId });
    return;
  }

  if (facSnap.get('platformReferralRewardGrantedAt')) {
    return;
  }

  const year = new Date().getUTCFullYear();
  const referrerRef = db.collection('facilityCreatorAccounts').doc(referredBy);
  const referrerSnap = await referrerRef.get();
  if (!referrerSnap.exists) return;

  const y = referrerSnap.get('referralRewardsGrantedYear') as number | undefined;
  const c = (referrerSnap.get('referralRewardsGrantedCount') as number | undefined) || 0;
  const effectiveCount = y === year ? c : 0;
  if (effectiveCount >= REFERRAL_MAX_REWARDS_PER_REFERRER_PER_YEAR) {
    functions.logger.warn('Referral cap reached for referrer', { referredBy, year });
    await db.collection('referralRewardsPending').add({
      reason: 'cap',
      referrerAccountId: referredBy,
      refereeFacilityId: facilityId,
      refereeAccountId,
      stripeInvoiceId: invoice.id,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    await facRef.update({
      platformReferralRewardGrantedAt: admin.firestore.FieldValue.serverTimestamp(),
      platformReferralRewardStripeInvoiceId: invoice.id,
      platformReferralRewardReferrerAccountId: referredBy,
      platformReferralRewardPendingManual: true,
      platformReferralRewardCapReached: true,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return;
  }

  const target = await pickReferrerTargetSubscriptionId(db, stripe, referredBy);
  const idempotencyBase = `referral_reward_${facilityId}_${invoice.id}`;

  if (!target) {
    functions.logger.warn('Referral reward pending: no referrer platform subscription', {
      referredBy,
      facilityId,
    });
    await db.collection('referralRewardsPending').add({
      reason: 'no_target_subscription',
      referrerAccountId: referredBy,
      refereeFacilityId: facilityId,
      refereeAccountId,
      stripeInvoiceId: invoice.id,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    await facRef.update({
      platformReferralRewardGrantedAt: admin.firestore.FieldValue.serverTimestamp(),
      platformReferralRewardStripeInvoiceId: invoice.id,
      platformReferralRewardReferrerAccountId: referredBy,
      platformReferralRewardPendingManual: true,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return;
  }

  try {
    await applyThreeMonthFullDiscount(stripe, target.subscriptionId, idempotencyBase, {
      type: 'referral_reward',
      refereeFacilityId: facilityId,
      refereeAccountId,
      referrerAccountId: referredBy,
      referrerRewardFacilityId: target.facilityId,
    });
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    functions.logger.error('Referral Stripe discount failed', { facilityId, msg, e });
    await db.collection('referralRewardsPending').add({
      reason: 'stripe_error',
      error: msg,
      referrerAccountId: referredBy,
      refereeFacilityId: facilityId,
      refereeAccountId,
      stripeInvoiceId: invoice.id,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    await facRef.update({
      platformReferralRewardGrantedAt: admin.firestore.FieldValue.serverTimestamp(),
      platformReferralRewardStripeInvoiceId: invoice.id,
      platformReferralRewardReferrerAccountId: referredBy,
      platformReferralRewardPendingManual: true,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return;
  }

  await db.runTransaction(async (tx) => {
    const s = await tx.get(facRef);
    if (!s.exists) return;
    if (s.get('platformReferralRewardGrantedAt')) return;
    tx.update(facRef, {
      platformReferralRewardGrantedAt: admin.firestore.FieldValue.serverTimestamp(),
      platformReferralRewardStripeInvoiceId: invoice.id,
      platformReferralRewardReferrerAccountId: referredBy,
      platformReferralRewardAppliedToFacilityId: target.facilityId,
      platformReferralRewardAppliedToSubscriptionId: target.subscriptionId,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });

  await referrerRef.set(
    {
      referralRewardsGrantedYear: year,
      referralRewardsGrantedCount: effectiveCount + 1,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  functions.logger.info('Referral reward granted', {
    facilityId,
    referrerAccountId: referredBy,
    targetFacilityId: target.facilityId,
  });
}

type SuperAdminPendingAction = 'resolve_only' | 'apply_reward';

/**
 * Super admin helper: resolve pending referral queue item and optionally apply reward now.
 * Callable auth/authorization is handled in index.ts.
 */
export async function resolveReferralPendingItemForSuperAdmin(
  stripe: Stripe,
  params: {
    pendingId: string;
    action: SuperAdminPendingAction;
    note?: string;
    actorEmail: string;
    targetFacilityId?: string | null;
  },
): Promise<{ ok: true; action: SuperAdminPendingAction; pendingId: string; appliedToFacilityId?: string | null }> {
  const db = admin.firestore();
  const pendingId = params.pendingId.trim();
  if (!pendingId) {
    throw new functions.https.HttpsError('invalid-argument', 'pendingId is required');
  }
  const pendingRef = db.collection('referralRewardsPending').doc(pendingId);
  const pendingSnap = await pendingRef.get();
  if (!pendingSnap.exists) {
    throw new functions.https.HttpsError('not-found', 'Pending referral item not found');
  }

  const p = pendingSnap.data() as Record<string, unknown>;
  const referrerAccountId = (p.referrerAccountId as string | undefined)?.trim();
  const refereeFacilityId = (p.refereeFacilityId as string | undefined)?.trim();
  const refereeAccountId = (p.refereeAccountId as string | undefined)?.trim();
  const stripeInvoiceId = (p.stripeInvoiceId as string | undefined)?.trim();
  if (!referrerAccountId || !refereeFacilityId) {
    throw new functions.https.HttpsError('failed-precondition', 'Pending item missing required IDs');
  }

  if (params.action === 'resolve_only') {
    await pendingRef.set({
      status: 'resolved',
      resolutionAction: 'resolve_only',
      resolutionNote: params.note?.trim() || null,
      resolvedByEmail: params.actorEmail,
      resolvedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    return { ok: true, action: 'resolve_only', pendingId, appliedToFacilityId: null };
  }

  const target = await pickReferrerTargetSubscriptionId(
    db,
    stripe,
    referrerAccountId,
    params.targetFacilityId || null,
  );
  if (!target) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'No eligible referrer platform subscription available for manual reward',
    );
  }

  const idempotencyBase = `manual_referral_reward_${pendingId}`;
  await applyThreeMonthFullDiscount(stripe, target.subscriptionId, idempotencyBase, {
    type: 'manual_referral_reward',
    referrerAccountId,
    refereeFacilityId,
    refereeAccountId: refereeAccountId || '',
    stripeInvoiceId: stripeInvoiceId || '',
    appliedBy: params.actorEmail,
    pendingId,
  });

  const facilityRef = db.collection('facilities').doc(refereeFacilityId);
  await facilityRef.set({
    platformReferralRewardGrantedAt: admin.firestore.FieldValue.serverTimestamp(),
    platformReferralRewardStripeInvoiceId: stripeInvoiceId || null,
    platformReferralRewardReferrerAccountId: referrerAccountId,
    platformReferralRewardAppliedToFacilityId: target.facilityId,
    platformReferralRewardAppliedToSubscriptionId: target.subscriptionId,
    platformReferralRewardPendingManual: false,
    platformReferralRewardCapReached: false,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });

  const referrerRef = db.collection('facilityCreatorAccounts').doc(referrerAccountId);
  const referrerSnap = await referrerRef.get();
  const year = new Date().getUTCFullYear();
  const y = referrerSnap.get('referralRewardsGrantedYear') as number | undefined;
  const c = (referrerSnap.get('referralRewardsGrantedCount') as number | undefined) || 0;
  const effectiveCount = y === year ? c : 0;
  await referrerRef.set({
    referralRewardsGrantedYear: year,
    referralRewardsGrantedCount: effectiveCount + 1,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });

  await pendingRef.set({
    status: 'resolved',
    resolutionAction: 'apply_reward',
    resolutionNote: params.note?.trim() || null,
    resolvedByEmail: params.actorEmail,
    resolvedAt: admin.firestore.FieldValue.serverTimestamp(),
    resolvedAppliedToFacilityId: target.facilityId,
    resolvedAppliedToSubscriptionId: target.subscriptionId,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });

  return { ok: true, action: 'apply_reward', pendingId, appliedToFacilityId: target.facilityId };
}

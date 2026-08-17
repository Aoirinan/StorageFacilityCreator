/**
 * Stripe tenant billing – AutoPay arming.
 * Data model: facilities/{facilityId}/tenants/{tenantId}/billing/default
 */
import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';

const BILLING_DOC_ID = 'default';

/** Verify caller is facility owner/manager or the tenant (for portal) */
async function verifyTenantBillingAccess(
  context: functions.https.CallableContext,
  facilityId: string,
  tenantId: string,
): Promise<{ isStaff: boolean; isTenant: boolean }> {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  const uid = context.auth.uid;

  const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
  if (!facilityDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Facility not found');
  }
  const facilityData = facilityDoc.data();
  const ownerUid = facilityData?.ownerUid;
  const roles = (facilityData?.roles || {}) as Record<string, string>;

  const isStaff =
    ownerUid === uid ||
    roles[uid] === 'manager' ||
    roles[uid] === 'owner' ||
    (facilityData?.managers as Record<string, boolean>)?.[uid] === true;

  const tenantDoc = await admin.firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('tenants')
    .doc(tenantId)
    .get();
  if (!tenantDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Tenant not found');
  }

  // Tenant access: occupant with matching userId
  const tenantData = tenantDoc.data();
  const occupants = (tenantData?.occupants || []) as Array<{ userId?: string }>;
  const isTenant = occupants.some((o) => o.userId === uid);

  if (!isStaff && !isTenant) {
    throw new functions.https.HttpsError('permission-denied', 'Access denied');
  }
  return { isStaff, isTenant };
}

/** Get or create billing doc ref */
function billingRef(facilityId: string, tenantId: string) {
  return admin
    .firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('tenants')
    .doc(tenantId)
    .collection('billing')
    .doc(BILLING_DOC_ID);
}

/**
 * toggleAutopay – arm or disarm the nightly scheduled charge job for a tenant.
 *
 * The platform-account customer/SetupIntent/PaymentIntent helpers that used to
 * live in this file were removed: they charged the platform Stripe account
 * while tenant cards live on the facility's connected account, and nothing
 * called them. Connected-account equivalents live in the stripeFacility*
 * callables.
 */
export async function toggleAutopay(
  data: { facilityId: string; tenantId: string; enable: boolean },
  context: functions.https.CallableContext,
  stripe: Stripe,
): Promise<{ autopayEnabled: boolean }> {
  const { facilityId, tenantId, enable } = data;
  if (!facilityId || !tenantId || typeof enable !== 'boolean') {
    throw new functions.https.HttpsError('invalid-argument', 'Missing facilityId, tenantId, or enable');
  }
  await verifyTenantBillingAccess(context, facilityId, tenantId);

  const tenantDoc = await admin.firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('tenants')
    .doc(tenantId)
    .get();
  if (!tenantDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Tenant not found');
  }
  const tenantData = tenantDoc.data();
  const billingSnap = await billingRef(facilityId, tenantId).get();
  const billingData = billingSnap.data() || {};

  // Legacy path: AutoPay used to create a Stripe Subscription on the PLATFORM
  // account, while cards are saved on the facility's CONNECTED account and the
  // nightly job charges there. Those two never shared state, so the switch never
  // actually armed the nightly job — and any subscription that did take would
  // have billed into the platform account instead of the owner's.
  //
  // Cancel any leftover subscription on either transition. Leaving it running
  // alongside the nightly job would double-bill the tenant, which is worse than
  // ending a subscription that should not have existed.
  await cancelLegacyPlatformSubscription(stripe, facilityId, tenantId, billingData);

  if (enable) {
    const monthlyRate = (tenantData?.monthlyRate ?? 0) as number;
    if (monthlyRate <= 0) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Tenant must have a monthly rate set.',
      );
    }

    // Arm the nightly job by flagging the tenant's stored card, which lives on
    // the facility's connected account. This is the single source of truth the
    // scheduled worker reads.
    const methodsSnap = await admin
      .firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId)
      .collection('paymentMethods')
      .where('isActive', '==', true)
      .get();

    if (methodsSnap.empty) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Add a payment method first to enable AutoPay.',
      );
    }

    const target =
      methodsSnap.docs.find((doc) => doc.data().isDefault === true) ?? methodsSnap.docs[0];

    const existingSchedule = target.data().autopaySchedule ?? {};
    const dayOfMonth =
      typeof existingSchedule.dayOfMonth === 'number' ? existingSchedule.dayOfMonth : 1;

    await target.ref.update({
      autopayEnabled: true,
      autopaySchedule: {
        ...existingSchedule,
        frequency: 'monthly',
        dayOfMonth,
        // No fixed `amount`: the nightly job charges the outstanding ledger
        // balance, so rent plus any late fees are collected rather than a
        // stale fixed figure.
        autopayNextRun: admin.firestore.Timestamp.fromDate(
          firstAutopayRun(new Date(), dayOfMonth),
        ),
      },
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    // Make sure no other stored card for this tenant is also armed, or the
    // nightly job would charge the tenant once per card.
    for (const doc of methodsSnap.docs) {
      if (doc.id !== target.id && doc.data().autopayEnabled === true) {
        await doc.ref.update({ autopayEnabled: false });
      }
    }

    await billingRef(facilityId, tenantId).set(
      {
        facilityId,
        tenantId,
        autopayEnabled: true,
        autopayPaymentMethodDocId: target.id,
        stripeSubscriptionId: admin.firestore.FieldValue.delete(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    return { autopayEnabled: true };
  }

  const methodsSnap = await admin
    .firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('tenants')
    .doc(tenantId)
    .collection('paymentMethods')
    .where('autopayEnabled', '==', true)
    .get();

  for (const doc of methodsSnap.docs) {
    await doc.ref.update({
      autopayEnabled: false,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }

  await billingRef(facilityId, tenantId).set(
    {
      autopayEnabled: false,
      stripeSubscriptionId: admin.firestore.FieldValue.delete(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  return { autopayEnabled: false };
}

/**
 * First nightly-job run after AutoPay is switched on.
 *
 * Always lands in a future month so switching on today cannot trigger a charge
 * tonight for a period the tenant may already have paid. Subsequent runs are
 * advanced by the scheduled worker itself.
 */
export function firstAutopayRun(now: Date, dayOfMonth: number): Date {
  const day = Number.isFinite(dayOfMonth) && dayOfMonth >= 1 && dayOfMonth <= 28 ? dayOfMonth : 1;
  return new Date(now.getFullYear(), now.getMonth() + 1, day);
}

/** Cancel a leftover platform-account AutoPay subscription, if one exists. */
async function cancelLegacyPlatformSubscription(
  stripe: Stripe,
  facilityId: string,
  tenantId: string,
  billingData: Record<string, any>,
): Promise<void> {
  const subId = billingData.stripeSubscriptionId as string | undefined;
  if (!subId) return;

  try {
    await stripe.subscriptions.cancel(subId);
    functions.logger.warn(
      `Cancelled legacy platform-account AutoPay subscription ${subId} for facility ${facilityId} tenant ${tenantId}`,
    );
  } catch (error: any) {
    // Already gone is fine; anything else must not block the switch, but should
    // be visible because it means a subscription may still be billing.
    functions.logger.error(
      `Failed to cancel legacy AutoPay subscription ${subId} for facility ${facilityId} tenant ${tenantId}: ${error?.message}`,
    );
  }
}

/**
 * listSavedPaymentMethods – list payment methods for tenant
 */

/**
 * Stripe tenant billing – embedded payments (SetupIntent, PaymentIntent, AutoPay)
 * Data model: facilities/{facilityId}/tenants/{tenantId}/billing/default
 *            facilities/{facilityId}/tenants/{tenantId}/payments/{paymentId}
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

/** Tenant payments subcollection (Stripe payment records) */
function tenantPaymentsRef(facilityId: string, tenantId: string) {
  return admin
    .firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('tenants')
    .doc(tenantId)
    .collection('payments');
}

/**
 * getOrCreateStripeCustomer – returns stripeCustomerId for tenant
 */
export async function getOrCreateStripeCustomer(
  data: { facilityId: string; tenantId: string },
  context: functions.https.CallableContext,
  stripe: Stripe,
): Promise<{ stripeCustomerId: string }> {
  const { facilityId, tenantId } = data;
  if (!facilityId || !tenantId) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing facilityId or tenantId');
  }
  await verifyTenantBillingAccess(context, facilityId, tenantId);

  const tenantRef = admin.firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('tenants')
    .doc(tenantId);
  const tenantDoc = await tenantRef.get();
  if (!tenantDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Tenant not found');
  }
  const tenantData = tenantDoc.data();

  let customerId = tenantData?.stripeCustomerId as string | undefined;
  if (customerId) {
    try {
      await stripe.customers.retrieve(customerId);
      return { stripeCustomerId: customerId };
    } catch {
      // Customer invalid or missing; fall through to create new one
    }
  }

  const customer = await stripe.customers.create({
    email: tenantData?.email as string | undefined,
    name: tenantData?.name as string | undefined,
    metadata: { facilityId, tenantId },
  });
  customerId = customer.id;

  await tenantRef.update({
    stripeCustomerId: customerId,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  // Initialize billing doc
  await billingRef(facilityId, tenantId).set(
    {
      facilityId,
      tenantId,
      stripeCustomerId: customerId,
      defaultPaymentMethodId: null,
      autopayEnabled: false,
      stripeSubscriptionId: null,
      lastPaymentStatus: null,
      lastPaymentAt: null,
      lastFailureCode: null,
      lastFailureMessage: null,
      nextDueAt: null,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  return { stripeCustomerId: customerId };
}

/**
 * createSetupIntent – for saving card via Payment Element
 * Returns clientSecret for stripe.confirmSetup()
 */
export async function createSetupIntent(
  data: { facilityId: string; tenantId: string },
  context: functions.https.CallableContext,
  stripe: Stripe,
): Promise<{ clientSecret: string }> {
  const { facilityId, tenantId } = data;
  if (!facilityId || !tenantId) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing facilityId or tenantId');
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
  let customerId = tenantData?.stripeCustomerId as string | undefined;

  if (!customerId) {
    try {
      const customer = await stripe.customers.create({
        email: tenantData?.email as string | undefined,
        name: tenantData?.name as string | undefined,
        metadata: { facilityId, tenantId },
      });
      customerId = customer.id;
      await tenantDoc.ref.update({
        stripeCustomerId: customerId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      await billingRef(facilityId, tenantId).set(
        {
          facilityId,
          tenantId,
          stripeCustomerId: customerId,
          defaultPaymentMethodId: null,
          autopayEnabled: false,
          stripeSubscriptionId: null,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    } catch (stripeErr: any) {
      const msg = stripeErr?.message ?? 'Stripe error';
      if (stripeErr?.type === 'StripeInvalidRequestError') {
        throw new functions.https.HttpsError('invalid-argument', msg);
      }
      throw new functions.https.HttpsError('unavailable', 'Unable to create payment customer. Please try again.');
    }
  }

  try {
    const setupIntent = await stripe.setupIntents.create({
      customer: customerId,
      payment_method_types: ['card'],
      usage: 'off_session',
      metadata: { facilityId, tenantId, userId: context.auth!.uid },
    });
    return { clientSecret: setupIntent.client_secret! };
  } catch (stripeErr: any) {
    const msg = stripeErr?.message ?? 'Stripe error';
    if (stripeErr?.type === 'StripeInvalidRequestError') {
      throw new functions.https.HttpsError('invalid-argument', msg);
    }
    throw new functions.https.HttpsError('unavailable', 'Unable to create payment setup. Please try again.');
  }
}

/**
 * createOneTimePaymentIntent – create Firestore payment doc first, then PaymentIntent
 * Returns clientSecret for stripe.confirmPayment()
 */
export async function createOneTimePaymentIntent(
  data: { facilityId: string; tenantId: string; amountCents: number },
  context: functions.https.CallableContext,
  stripe: Stripe,
): Promise<{ clientSecret: string; paymentDocId: string }> {
  const { facilityId, tenantId, amountCents } = data;
  if (!facilityId || !tenantId || amountCents == null || amountCents < 50) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      'Missing facilityId, tenantId, or invalid amount (min 50 cents)',
    );
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
  const stripeCustomerId = tenantDoc.data()?.stripeCustomerId as string | undefined;
  if (!stripeCustomerId) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Tenant must have a Stripe customer. Add a card first.',
    );
  }

  const paymentsRef = tenantPaymentsRef(facilityId, tenantId);
  const paymentDocRef = paymentsRef.doc();

  const paymentDoc = {
    facilityId,
    tenantId,
    type: 'one_time',
    amountCents,
    currency: 'usd',
    stripeObjectId: null as string | null,
    status: 'processing',
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    failureCode: null as string | null,
    failureMessage: null as string | null,
  };
  await paymentDocRef.set(paymentDoc);

  const paymentDocId = paymentDocRef.id;

  const paymentIntent = await stripe.paymentIntents.create(
    {
      amount: amountCents,
      currency: 'usd',
      customer: stripeCustomerId,
      metadata: { facilityId, tenantId, paymentDocId },
      automatic_payment_methods: { enabled: true },
    },
    { idempotencyKey: paymentDocId },
  );

  await paymentDocRef.update({
    stripeObjectId: paymentIntent.id,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return {
    clientSecret: paymentIntent.client_secret!,
    paymentDocId,
  };
}

/**
 * toggleAutopay – enable/disable Stripe subscription for tenant rent
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
      .collection('paymentMethods')
      .where('tenantId', '==', tenantId)
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
    .collection('paymentMethods')
    .where('tenantId', '==', tenantId)
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
export async function listSavedPaymentMethods(
  data: { facilityId: string; tenantId: string },
  context: functions.https.CallableContext,
  stripe: Stripe,
): Promise<{
  paymentMethods: Array<{
    brand: string;
    last4: string;
    expMonth: number;
    expYear: number;
    paymentMethodId: string;
    isDefault: boolean;
  }>;
}> {
  const { facilityId, tenantId } = data;
  if (!facilityId || !tenantId) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing facilityId or tenantId');
  }
  await verifyTenantBillingAccess(context, facilityId, tenantId);

  const billingSnap = await billingRef(facilityId, tenantId).get();
  const billingData = billingSnap.data() || {};
  const stripeCustomerId = billingData.stripeCustomerId as string | undefined;
  if (!stripeCustomerId) {
    return { paymentMethods: [] };
  }

  const paymentMethods = await stripe.paymentMethods.list({
    customer: stripeCustomerId,
    type: 'card',
  });

  const defaultPm = billingData.defaultPaymentMethodId as string | undefined;
  const result = paymentMethods.data.map((pm) => {
    const card = pm.card;
    return {
      brand: card?.brand ?? 'unknown',
      last4: card?.last4 ?? '****',
      expMonth: card?.exp_month ?? 0,
      expYear: card?.exp_year ?? 0,
      paymentMethodId: pm.id,
      isDefault: pm.id === defaultPm,
    };
  });
  return { paymentMethods: result };
}

/**
 * detachPaymentMethod – remove a payment method
 * Blocks if it's default and autopay is on
 */
export async function detachPaymentMethod(
  data: { facilityId: string; tenantId: string; paymentMethodId: string },
  context: functions.https.CallableContext,
  stripe: Stripe,
): Promise<{ ok: boolean }> {
  const { facilityId, tenantId, paymentMethodId } = data;
  if (!facilityId || !tenantId || !paymentMethodId) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required parameters');
  }
  await verifyTenantBillingAccess(context, facilityId, tenantId);

  const billingSnap = await billingRef(facilityId, tenantId).get();
  const billingData = billingSnap.data() || {};
  const defaultPm = billingData.defaultPaymentMethodId as string | undefined;
  const autopayEnabled = billingData.autopayEnabled === true;

  if (paymentMethodId === defaultPm && autopayEnabled) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Turn off AutoPay before removing your default payment method.',
    );
  }

  await stripe.paymentMethods.detach(paymentMethodId);
  if (paymentMethodId === defaultPm) {
    await billingRef(facilityId, tenantId).update({
      defaultPaymentMethodId: null,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
  return { ok: true };
}

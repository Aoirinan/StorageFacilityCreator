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
): Promise<{ autopayEnabled: boolean; subscriptionId?: string }> {
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

  if (enable) {
    const defaultPaymentMethodId = billingData.defaultPaymentMethodId as string | undefined;
    if (!defaultPaymentMethodId) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Add a payment method first to enable AutoPay.',
      );
    }

    const monthlyRate = (tenantData?.monthlyRate ?? 0) as number;
    if (monthlyRate <= 0) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Tenant must have a monthly rate set.',
      );
    }

    const stripeCustomerId = (tenantData?.stripeCustomerId || billingData.stripeCustomerId) as string;
    if (!stripeCustomerId) {
      throw new functions.https.HttpsError('failed-precondition', 'Tenant has no Stripe customer.');
    }

    const productRes = await stripe.products.list({ active: true, limit: 100 });
    let product = productRes.data.find((p) => p.name === 'Storage Unit Rent');
    if (!product) {
      product = await stripe.products.create({
        name: 'Storage Unit Rent',
        description: 'Monthly storage unit rent',
        metadata: { type: 'tenant_rent' },
      });
    }
    const productId = product.id;

    const unitAmount = Math.round(monthlyRate * 100);
    const price = await stripe.prices.create({
      product: productId,
      unit_amount: unitAmount,
      currency: 'usd',
      recurring: { interval: 'month' },
      metadata: { facilityId, tenantId },
    });

    const subscription = await stripe.subscriptions.create({
      customer: stripeCustomerId,
      items: [{ price: price.id }],
      default_payment_method: defaultPaymentMethodId,
      metadata: { facilityId, tenantId },
      payment_behavior: 'default_incomplete',
      expand: ['latest_invoice'],
    });

    const nextDue = (subscription as any).current_period_end
      ? new Date((subscription as any).current_period_end * 1000)
      : null;

    await billingRef(facilityId, tenantId).set(
      {
        facilityId,
        tenantId,
        stripeCustomerId,
        defaultPaymentMethodId,
        autopayEnabled: true,
        stripeSubscriptionId: subscription.id,
        nextDueAt: nextDue ? admin.firestore.Timestamp.fromDate(nextDue) : null,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    return { autopayEnabled: true, subscriptionId: subscription.id };
  } else {
    const subId = billingData.stripeSubscriptionId as string | undefined;
    if (subId) {
      await stripe.subscriptions.update(subId, { cancel_at_period_end: true });
    }
    await billingRef(facilityId, tenantId).update({
      autopayEnabled: false,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return { autopayEnabled: false };
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

import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import {
  extractCallableClientIp,
  getStripeClient,
  rejectClientSuppliedStripeKeys,
  resolvePortalTenantSession,
} from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';

/**
 * attachTenantPaymentMethodFromPortal — record a card a tenant saved themselves.
 *
 * The portal had no way to do this. It created a SetupIntent, confirmed it in
 * the browser, and then relied entirely on the `setup_intent.succeeded` webhook
 * to write the `paymentMethods` document that autopay and toggleAutopay read.
 * That webhook never arrived: the SetupIntent lives on the facility's connected
 * account, and connected-account events are only delivered if the Stripe
 * endpoint is explicitly subscribed to Connect events. So a tenant could save a
 * card, be told it worked, and remain permanently invisible to autopay.
 *
 * Relying on a webhook whose delivery this code cannot verify is the wrong
 * shape for the one step the whole self-service flow depends on. The portal now
 * confirms the result itself, exactly as the staff-side attach callable does.
 * The webhook still writes the same document when it does arrive, and both
 * paths are idempotent on the payment method id, so whichever lands first wins
 * and the second is a no-op.
 *
 * Auth is the portal's own: email + access code, not Firebase Auth, because
 * tenants are not app users. The existing redirect-based attach callable
 * requires context.auth and therefore can never serve a tenant.
 */
export const attachTenantPaymentMethodFromPortal = functions
  .runWith({ secrets: STRIPE_SECRETS })
  .https.onCall(async (data: any, context) => {
    rejectClientSuppliedStripeKeys(data || {});

    const email = (data?.email || '').toString().trim().toLowerCase();
    const accessCode = (data?.accessCode || '').toString().trim();
    const requestedTenantId = (data?.tenantId || '').toString().trim();
    const setupIntentId = (data?.setupIntentId || '').toString().trim();

    if (!setupIntentId) {
      throw new functions.https.HttpsError('invalid-argument', 'setupIntentId is required');
    }

    const clientIp = extractCallableClientIp(context.rawRequest);
    const session = await resolvePortalTenantSession(
      email,
      accessCode,
      clientIp,
      requestedTenantId || undefined,
    );
    const { facilityId, tenantId } = session;

    const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
    const connectAccountId = facilityDoc.data()?.stripeConnectAccountId as string | undefined;
    if (!connectAccountId) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Payments are not enabled for this facility yet.',
      );
    }

    const stripe = getStripeClient();
    const setupIntent = await stripe.setupIntents.retrieve(setupIntentId, {
      stripeAccount: connectAccountId,
    });

    // The SetupIntent id comes from the browser, so confirm with Stripe that it
    // really belongs to this tenant before saving a card against them.
    if (setupIntent.metadata?.tenantId !== tenantId ||
        setupIntent.metadata?.facilityId !== facilityId) {
      throw new functions.https.HttpsError(
        'permission-denied',
        'That setup does not belong to this tenant.',
      );
    }
    if (setupIntent.status !== 'succeeded') {
      throw new functions.https.HttpsError(
        'failed-precondition',
        `Card setup is not complete (status: ${setupIntent.status}).`,
      );
    }

    const paymentMethodId =
      typeof setupIntent.payment_method === 'string'
        ? setupIntent.payment_method
        : setupIntent.payment_method?.id;
    if (!paymentMethodId) {
      throw new functions.https.HttpsError('failed-precondition', 'No payment method on the setup.');
    }
    const customerId =
      typeof setupIntent.customer === 'string' ? setupIntent.customer : setupIntent.customer?.id;

    const pm = await stripe.paymentMethods.retrieve(paymentMethodId, {
      stripeAccount: connectAccountId,
    });
    const card = pm.card;

    const tenantRef = admin
      .firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId);
    const paymentMethodsRef = tenantRef.collection('paymentMethods');

    // Idempotent on the Stripe payment method: this can race the webhook, and
    // duplicate rows would let the nightly job charge once per row.
    const existing = await paymentMethodsRef
      .where('stripePaymentMethodId', '==', paymentMethodId)
      .limit(1)
      .get();
    const targetRef = existing.empty ? paymentMethodsRef.doc() : existing.docs[0].ref;

    const others = await paymentMethodsRef.where('isDefault', '==', true).get();
    for (const doc of others.docs) {
      if (doc.id !== targetRef.id) await doc.ref.update({ isDefault: false });
    }

    await targetRef.set(
      {
        tenantId,
        // Required by the autopay worker's collection-group query.
        facilityId,
        type: 'creditCard',
        stripePaymentMethodId: paymentMethodId,
        stripeCustomerId: customerId || null,
        stripeConnectedAccountId: connectAccountId,
        last4: card?.last4 ?? null,
        brand: card?.brand ?? null,
        expiryMonth: card?.exp_month ?? null,
        expiryYear: card?.exp_year ?? null,
        isDefault: true,
        isActive: true,
        // Saving a card is not consent to be charged automatically.
        ...(existing.empty ? { autopayEnabled: false } : {}),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        ...(existing.empty
          ? {
              createdAt: admin.firestore.FieldValue.serverTimestamp(),
              createdBy: 'portalAttach',
            }
          : {}),
      },
      { merge: true },
    );

    await tenantRef.set(
      {
        'stripe.defaultPaymentMethodId': paymentMethodId,
        'stripe.customerId': customerId || null,
        'stripe.paymentMethodSummary': {
          brand: card?.brand ?? null,
          last4: card?.last4 ?? null,
          expMonth: card?.exp_month ?? null,
          expYear: card?.exp_year ?? null,
        },
        stripeConnectedCustomerId: customerId || null,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    functions.logger.info(
      `Portal attached payment method ${paymentMethodId} for tenant ${tenantId} ` +
        `(${existing.empty ? 'created' : 'updated'})`,
    );

    return {
      success: true,
      last4: card?.last4 ?? null,
      brand: card?.brand ?? null,
    };
  });

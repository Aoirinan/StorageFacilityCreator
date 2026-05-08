import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { canAccessFacility, getPlatformPublishableKey, getStripeClient, rejectClientSuppliedStripeKeys } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';
import { isTenantAutopayAllowedForFacility } from './stripeFacilityFeatureFlags';

/**
 * Create a SetupIntent on a connected account for tenant payment method capture.
 * PRECONDITION: Facility Stripe Connect state must be ENABLED (charges_enabled).
 * Returns clientSecret, publishableKey, and connectedAccountId so frontend can load Stripe with stripeAccount (avoids 401).
 */
export const createTenantSetupIntent = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  rejectClientSuppliedStripeKeys(data || {});
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  if (!context.app) {
    functions.logger.warn('createTenantSetupIntent: App Check token missing – allowing for auth-only');
  }

  const { facilityId, tenantId } = data;

  if (!facilityId || !tenantId) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required parameters: facilityId, tenantId');
  }

  const tenantAutopayAllowed = await isTenantAutopayAllowedForFacility(facilityId);
  if (!tenantAutopayAllowed) {
    throw new functions.https.HttpsError('failed-precondition', 'Payments are not enabled for this facility. Connect and complete Stripe onboarding first.');
  }

  try {
    const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data();
    const ownerUid = facilityData?.ownerUid;
    const roles = (facilityData?.roles || {}) as Record<string, string>;
    const connectAccountId = facilityData?.stripeConnectAccountId as string | undefined;

    if (!connectAccountId) {
      throw new functions.https.HttpsError('failed-precondition', 'Payments are not set up for this facility. Connect Stripe in facility settings first.');
    }

    const stripe = getStripeClient();
    const account = await stripe.accounts.retrieve(connectAccountId);
    if (!account.charges_enabled) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Payments are not enabled for this facility yet. The facility owner needs to finish Stripe onboarding.',
      );
    }

    const isStaff = ownerUid === context.auth.uid || roles[context.auth.uid] === 'manager' || roles[context.auth.uid] === 'owner';
    if (!isStaff) {
      const hasAccess = await canAccessFacility(context.auth!.uid, facilityId);
      if (!hasAccess) {
        throw new functions.https.HttpsError('permission-denied', 'User does not have permission');
      }
    }

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

    // Get or create Stripe Customer on CONNECTED account
    let customerId = tenantData?.stripeConnectedCustomerId as string | undefined;

    if (!customerId) {
      // Create Stripe Customer on connected account
      const customer = await stripe.customers.create({
        email: tenantData?.email as string | undefined,
        name: tenantData?.name as string | undefined,
        metadata: {
          facilityId,
          tenantId,
        },
      }, {
        stripeAccount: connectAccountId, // Create on connected account
      });
      customerId = customer.id;

      // Store customer ID in tenant document
      await tenantDoc.ref.update({
        stripeConnectedCustomerId: customerId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    // Create SetupIntent on CONNECTED account
    const setupIntent = await stripe.setupIntents.create({
      customer: customerId,
      payment_method_types: ['card'],
      usage: 'off_session', // For autopay
      metadata: {
        facilityId,
        tenantId,
        userId: context.auth.uid,
        chargeType: 'tenant_autopay',
      },
    }, {
      stripeAccount: connectAccountId, // Create on connected account
    });

    functions.logger.info(`SetupIntent created on connected account: ${setupIntent.id} for tenant ${tenantId}`);

    const publishableKey = getPlatformPublishableKey();
    return {
      clientSecret: setupIntent.client_secret,
      setupIntentId: setupIntent.id,
      publishableKey,
      connectedAccountId: connectAccountId,
    };
  } catch (error: any) {
    const safeError = error?.message || 'Failed to create setup intent';
    functions.logger.error('Error creating tenant SetupIntent on connected account:', {
      facilityId,
      tenantId,
      error: safeError,
    });
    throw new functions.https.HttpsError('internal', `Failed to create setup intent: ${safeError}`);
  }
});

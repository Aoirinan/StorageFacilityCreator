import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { isSuperAdmin } from '@sfc/functions-shared';

/**
 * Maintenance-only: enable Stripe Connect in Firestore appConfig.
 * Requires super-admin email and ENABLE_STRIPE_CONNECT_ADMIN_CALLABLE=true on the function runtime.
 */
export const enableStripeConnectAdmin = functions.https.onCall(async (_data: unknown, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }

  if (process.env.ENABLE_STRIPE_CONNECT_ADMIN_CALLABLE?.trim() !== 'true') {
    throw new functions.https.HttpsError(
      'permission-denied',
      'This maintenance endpoint is disabled. Set ENABLE_STRIPE_CONNECT_ADMIN_CALLABLE=true on the function to allow.',
    );
  }

  const callerEmail = context.auth.token?.email as string | undefined;
  if (!isSuperAdmin(callerEmail)) {
    throw new functions.https.HttpsError('permission-denied', 'Only super admins can enable feature flags');
  }

  try {
    const configRef = admin.firestore().collection('appConfig').doc('stripe');
    const configDoc = await configRef.get();

    if (!configDoc.exists) {
      await configRef.set({
        connectEnabledGlobal: true,
        tenantAutopayEnabledGlobal: false,
        storeEnabledGlobal: false,
        checkoutEnabledGlobal: false,
        allowlistFacilityIds: [],
        killSwitch: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return { success: true, message: 'Stripe config document created with Connect enabled!' };
    }
    await configRef.update({
      connectEnabledGlobal: true,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return { success: true, message: 'Stripe Connect enabled in existing config!' };
  } catch (error: any) {
    functions.logger.error('Error enabling Stripe Connect:', error);
    throw new functions.https.HttpsError('internal', `Failed to enable Stripe Connect: ${error.message}`);
  }
});

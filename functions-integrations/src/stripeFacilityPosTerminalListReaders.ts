import * as functions from 'firebase-functions/v1';
import { getFacilityDataForUserOrThrow, getStripeClient, rejectClientSuppliedStripeKeys } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';
import { isTenantAutopayAllowedForFacility } from './stripeFacilityFeatureFlags';

/**
 * Staff POS: list Stripe Terminal readers for the facility's connected account.
 * Uses server-driven Terminal API to avoid client/network coupling issues.
 */
export const listPosTerminalReaders = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  rejectClientSuppliedStripeKeys(data || {});
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }

  const { facilityId } = data || {};
  if (!facilityId || typeof facilityId !== 'string') {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }

  const paymentsAllowed = await isTenantAutopayAllowedForFacility(facilityId);
  if (!paymentsAllowed) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Card payments require Stripe Connect with charges enabled. Complete Connect onboarding in Payments settings.',
    );
  }

  const facilityData = await getFacilityDataForUserOrThrow(context.auth.uid, facilityId);
  const connectAccountId = facilityData?.stripeConnectAccountId as string | undefined;
  if (!connectAccountId) {
    throw new functions.https.HttpsError('failed-precondition', 'Facility must have a connected Stripe account');
  }

  const stripe = getStripeClient();
  const readers = await stripe.terminal.readers.list(
    {
      limit: 100,
    },
    {
      stripeAccount: connectAccountId,
    },
  );

  return {
    readers: readers.data.map((reader) => ({
      id: reader.id,
      label: reader.label ?? 'Unnamed reader',
      deviceType: reader.device_type ?? null,
      serialNumber: reader.serial_number ?? null,
      status: reader.status ?? 'unknown',
      location: typeof reader.location === 'string' ? reader.location : reader.location?.id ?? null,
    })),
    connectedAccountId: connectAccountId,
  };
});

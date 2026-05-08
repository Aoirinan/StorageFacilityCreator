/**
 * Firestore appConfig `stripe` document — Connect / checkout / store / tenant autopay gates.
 */
import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import { getStripeClient } from '@sfc/functions-shared';

interface StripeConfig {
  connectEnabledGlobal: boolean;
  tenantAutopayEnabledGlobal: boolean;
  storeEnabledGlobal: boolean;
  checkoutEnabledGlobal: boolean;
  allowlistFacilityIds: string[];
  killSwitch: boolean;
}

const DEFAULT_STRIPE_CONFIG: StripeConfig = {
  connectEnabledGlobal: false,
  tenantAutopayEnabledGlobal: false,
  storeEnabledGlobal: false,
  checkoutEnabledGlobal: false,
  allowlistFacilityIds: [],
  killSwitch: false,
};

async function getStripeConfig(): Promise<StripeConfig> {
  try {
    const configDoc = await admin.firestore()
      .collection('appConfig')
      .doc('stripe')
      .get();

    if (!configDoc.exists) {
      return DEFAULT_STRIPE_CONFIG;
    }

    const data = configDoc.data() || {};
    return {
      connectEnabledGlobal: data.connectEnabledGlobal ?? false,
      tenantAutopayEnabledGlobal: data.tenantAutopayEnabledGlobal ?? false,
      storeEnabledGlobal: data.storeEnabledGlobal ?? false,
      checkoutEnabledGlobal: data.checkoutEnabledGlobal ?? false,
      allowlistFacilityIds: data.allowlistFacilityIds || [],
      killSwitch: data.killSwitch ?? false,
    };
  } catch (error: any) {
    functions.logger.error('Error getting Stripe config, using defaults:', error);
    return DEFAULT_STRIPE_CONFIG;
  }
}

/**
 * Check if a feature is enabled for a specific facility
 * Feature is enabled if:
 *   - killSwitch is false (emergency brake)
 *   - AND (global flag is true OR facilityId is in allowlist)
 */
export async function isStripeFeatureEnabled(
  feature: 'connect' | 'tenantAutopay' | 'store' | 'checkout',
  facilityId?: string,
): Promise<boolean> {
  const config = await getStripeConfig();

  if (config.killSwitch) {
    return false;
  }

  const inAllowlist = facilityId ? config.allowlistFacilityIds.includes(facilityId) : false;

  let globalFlag = false;
  switch (feature) {
    case 'connect':
      globalFlag = config.connectEnabledGlobal;
      break;
    case 'tenantAutopay':
      globalFlag = config.tenantAutopayEnabledGlobal;
      break;
    case 'store':
      globalFlag = config.storeEnabledGlobal;
      break;
    case 'checkout':
      globalFlag = config.checkoutEnabledGlobal;
      break;
  }

  return globalFlag || inAllowlist;
}

/**
 * Tenant autopay / add-card is allowed if kill switch is off AND the facility has
 * Stripe Connect with charges_enabled. (No separate tenantAutopay flag required.)
 */
export async function isTenantAutopayAllowedForFacility(facilityId: string): Promise<boolean> {
  const config = await getStripeConfig();
  if (config.killSwitch) return false;
  const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
  if (!facilityDoc.exists) return false;
  const connectAccountId = facilityDoc.data()?.stripeConnectAccountId as string | undefined;
  if (!connectAccountId) return false;
  try {
    const stripe = getStripeClient();
    const account = await stripe.accounts.retrieve(connectAccountId);
    return !!account.charges_enabled;
  } catch {
    return false;
  }
}

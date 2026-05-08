/**
 * Firestore appConfig `paymentSafety` document — idempotency, duplicate detection, reconciliation.
 */
import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

interface PaymentSafetyConfig {
  idempotencyEnabled: boolean;
  duplicateDetectionEnabled: boolean;
  reconciliationEnabled: boolean;
  allowlistFacilityIds: string[];
  killSwitch: boolean;
}

const DEFAULT_PAYMENT_SAFETY_CONFIG: PaymentSafetyConfig = {
  idempotencyEnabled: false,
  duplicateDetectionEnabled: false,
  reconciliationEnabled: false,
  allowlistFacilityIds: [],
  killSwitch: false,
};

async function getPaymentSafetyConfig(): Promise<PaymentSafetyConfig> {
  try {
    const configDoc = await admin.firestore()
      .collection('appConfig')
      .doc('paymentSafety')
      .get();

    if (!configDoc.exists) {
      return DEFAULT_PAYMENT_SAFETY_CONFIG;
    }

    const data = configDoc.data() || {};
    return {
      idempotencyEnabled: data.idempotencyEnabled ?? false,
      duplicateDetectionEnabled: data.duplicateDetectionEnabled ?? false,
      reconciliationEnabled: data.reconciliationEnabled ?? false,
      allowlistFacilityIds: data.allowlistFacilityIds || [],
      killSwitch: data.killSwitch ?? false,
    };
  } catch (error: any) {
    functions.logger.error('Error getting payment safety config, using defaults:', error);
    return DEFAULT_PAYMENT_SAFETY_CONFIG;
  }
}

/**
 * Check if payment safety feature is enabled for a specific facility
 */
export async function isPaymentSafetyFeatureEnabled(
  feature: 'idempotency' | 'duplicateDetection' | 'reconciliation',
  facilityId?: string,
): Promise<boolean> {
  const config = await getPaymentSafetyConfig();

  if (config.killSwitch) {
    return false;
  }

  const inAllowlist = facilityId ? config.allowlistFacilityIds.includes(facilityId) : false;

  switch (feature) {
    case 'idempotency':
      return config.idempotencyEnabled || inAllowlist;
    case 'duplicateDetection':
      return config.duplicateDetectionEnabled || inAllowlist;
    case 'reconciliation':
      return config.reconciliationEnabled || inAllowlist;
    default:
      return false;
  }
}

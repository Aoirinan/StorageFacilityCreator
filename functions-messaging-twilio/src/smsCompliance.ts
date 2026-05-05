import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

interface SMSComplianceConfig {
  enhancedOptOutEnabled: boolean;
  quietHoursEnabled: boolean;
  rateLimitingEnabled: boolean;
  allowlistFacilityIds: string[];
  killSwitch: boolean;
}

const DEFAULT_SMS_COMPLIANCE_CONFIG: SMSComplianceConfig = {
  enhancedOptOutEnabled: false,
  quietHoursEnabled: false,
  rateLimitingEnabled: false,
  allowlistFacilityIds: [],
  killSwitch: false,
};

async function getSMSComplianceConfig(): Promise<SMSComplianceConfig> {
  try {
    const configDoc = await admin.firestore()
      .collection('appConfig')
      .doc('smsCompliance')
      .get();

    if (!configDoc.exists) {
      return DEFAULT_SMS_COMPLIANCE_CONFIG;
    }

    const data = configDoc.data() || {};
    return {
      enhancedOptOutEnabled: data.enhancedOptOutEnabled ?? false,
      quietHoursEnabled: data.quietHoursEnabled ?? false,
      rateLimitingEnabled: data.rateLimitingEnabled ?? false,
      allowlistFacilityIds: data.allowlistFacilityIds || [],
      killSwitch: data.killSwitch ?? false,
    };
  } catch (error: unknown) {
    functions.logger.error('Error getting SMS compliance config, using defaults:', error);
    return DEFAULT_SMS_COMPLIANCE_CONFIG;
  }
}

export async function isSMSComplianceFeatureEnabled(
  feature: 'enhancedOptOut' | 'quietHours' | 'rateLimiting',
  facilityId?: string,
): Promise<boolean> {
  const config = await getSMSComplianceConfig();

  if (config.killSwitch) {
    return false;
  }

  const inAllowlist = facilityId ? config.allowlistFacilityIds.includes(facilityId) : false;

  let globalFlag = false;
  switch (feature) {
    case 'enhancedOptOut':
      globalFlag = config.enhancedOptOutEnabled;
      break;
    case 'quietHours':
      globalFlag = config.quietHoursEnabled;
      break;
    case 'rateLimiting':
      globalFlag = config.rateLimitingEnabled;
      break;
  }

  return globalFlag || inAllowlist;
}

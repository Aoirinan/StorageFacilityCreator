import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { isSuperAdmin } from '@sfc/functions-shared';
import { enforceAppCheckOrThrow } from './appCheck';

/**
 * SMS Usage Limits (configurable via environment variables)
 */
const SMS_LIMIT_PER_TENANT = parseInt(process.env.SMS_LIMIT_PER_TENANT || '4', 10);
const SMS_LIMIT_PER_FACILITY = parseInt(process.env.SMS_LIMIT_PER_FACILITY || '1000', 10);
const SMS_LIMIT_PER_ACCOUNT = parseInt(process.env.SMS_LIMIT_PER_ACCOUNT || '3000', 10);
const SMS_COST_PER_MESSAGE = parseFloat(process.env.SMS_COST_PER_MESSAGE || '0.01');
const SMS_MAX_COST_PER_FACILITY = parseFloat(process.env.SMS_MAX_COST_PER_FACILITY || '40');
const SMS_EXTREME_MULTIPLIER = 3;

function capSmsLimit(limit: number): number {
  if (limit <= 0) return 0;
  const maxMessages = Math.floor(SMS_MAX_COST_PER_FACILITY / SMS_COST_PER_MESSAGE);
  return Math.min(limit, maxMessages);
}

export enum SMSUsageState {
  NORMAL = 'normal',
  APPROACHING = 'approaching',
  EXCEEDED = 'exceeded',
  EXTREME = 'extreme',
}

export async function checkAndIncrementSMSUsage(
  facilityId: string,
  tenantId?: string,
  accountId?: string,
): Promise<{
  success: boolean;
  canSendSMS: boolean;
  shouldFallbackToEmail: boolean;
  state: SMSUsageState;
  message?: string;
  warning?: string;
  usage?: {
    tenant?: { count: number; limit: number };
    facility: { count: number; limit: number };
    account?: { count: number; limit: number };
  };
}> {
  const now = new Date();
  const monthKey = `${now.getFullYear()}-${(now.getMonth() + 1).toString().padStart(2, '0')}`;

  if (!accountId) {
    const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
    if (facilityDoc.exists) {
      accountId = facilityDoc.data()?.facilityCreatorAccountId;
    }
  }

  return admin.firestore().runTransaction(async (transaction) => {
    let tenantUsage = { count: 0, limit: SMS_LIMIT_PER_TENANT };
    if (tenantId) {
      const tenantUsageRef = admin.firestore()
        .collection('tenants')
        .doc(tenantId)
        .collection('smsUsage')
        .doc(monthKey);

      const tenantUsageDoc = await transaction.get(tenantUsageRef);
      const tenantData = tenantUsageDoc.exists ? tenantUsageDoc.data() : {
        smsMonthlyCount: 0,
        smsMonth: monthKey,
      };

      tenantUsage = {
        count: (tenantData?.smsMonthlyCount || 0) + 1,
        limit: SMS_LIMIT_PER_TENANT,
      };
    }

    const facilityUsageRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('smsUsage')
      .doc(monthKey);

    const facilityUsageDoc = await transaction.get(facilityUsageRef);
    const facilityData = facilityUsageDoc.exists ? facilityUsageDoc.data() : {
      smsMonthlyCount: 0,
      smsMonthlyLimit: SMS_LIMIT_PER_FACILITY,
      smsMonth: monthKey,
      lastReset: admin.firestore.FieldValue.serverTimestamp(),
    };

    const facilityUsage = {
      count: (facilityData?.smsMonthlyCount || 0) + 1,
      limit: facilityData?.smsMonthlyLimit || SMS_LIMIT_PER_FACILITY,
    };

    let accountUsage = { count: 0, limit: SMS_LIMIT_PER_ACCOUNT };
    if (accountId) {
      const accountUsageRef = admin.firestore()
        .collection('facilityCreatorAccounts')
        .doc(accountId)
        .collection('smsUsage')
        .doc(monthKey);

      const accountUsageDoc = await transaction.get(accountUsageRef);
      const accountData = accountUsageDoc.exists ? accountUsageDoc.data() : {
        smsMonthlyCount: 0,
        smsMonthlyLimit: SMS_LIMIT_PER_ACCOUNT,
        smsMonth: monthKey,
        lastReset: admin.firestore.FieldValue.serverTimestamp(),
      };

      accountUsage = {
        count: (accountData?.smsMonthlyCount || 0) + 1,
        limit: accountData?.smsMonthlyLimit || SMS_LIMIT_PER_ACCOUNT,
      };
    }

    const accountPercentage = accountId ? (accountUsage.count / accountUsage.limit) * 100 : 0;
    const facilityPercentage = (facilityUsage.count / facilityUsage.limit) * 100;
    const tenantPercentage = tenantId ? (tenantUsage.count / tenantUsage.limit) * 100 : 0;

    let state: SMSUsageState = SMSUsageState.NORMAL;
    let canSendSMS = true;
    let shouldFallbackToEmail = false;

    const tenantExceeded = Boolean(tenantId && tenantUsage.count > tenantUsage.limit);
    const facilityExceeded = facilityUsage.count > facilityUsage.limit;
    const accountExceeded = Boolean(accountId && accountUsage.count > accountUsage.limit);
    const extremeUsage = Boolean(accountId && accountUsage.count >= (accountUsage.limit * SMS_EXTREME_MULTIPLIER));

    if (extremeUsage) {
      state = SMSUsageState.EXTREME;
      canSendSMS = false;
      shouldFallbackToEmail = true;
    } else if (tenantExceeded || facilityExceeded || accountExceeded) {
      state = SMSUsageState.EXCEEDED;
      canSendSMS = false;
      shouldFallbackToEmail = true;
    } else if (accountPercentage >= 80 || facilityPercentage >= 80 || tenantPercentage >= 80) {
      state = SMSUsageState.APPROACHING;
      canSendSMS = true;
      shouldFallbackToEmail = false;
    }

    if (state !== SMSUsageState.EXTREME) {
      if (tenantId && !tenantExceeded) {
        const tenantUsageRef = admin.firestore()
          .collection('tenants')
          .doc(tenantId)
          .collection('smsUsage')
          .doc(monthKey);
        transaction.set(tenantUsageRef, {
          smsMonthlyCount: tenantUsage.count,
          smsMonth: monthKey,
          lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      }

      if (!facilityExceeded) {
        transaction.set(facilityUsageRef, {
          ...facilityData,
          smsMonthlyCount: facilityUsage.count,
          smsMonth: monthKey,
          lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      }

      if (accountId && !accountExceeded) {
        const accountUsageRef = admin.firestore()
          .collection('facilityCreatorAccounts')
          .doc(accountId)
          .collection('smsUsage')
          .doc(monthKey);
        const existingAccountDoc = await transaction.get(accountUsageRef);
        const existingAccountData = existingAccountDoc.exists ? existingAccountDoc.data() : {
          smsMonthlyLimit: SMS_LIMIT_PER_ACCOUNT,
          smsMonth: monthKey,
          lastReset: admin.firestore.FieldValue.serverTimestamp(),
        };
        transaction.set(accountUsageRef, {
          ...existingAccountData,
          smsMonthlyCount: accountUsage.count,
          smsMonth: monthKey,
          lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      }
    }

    let warning: string | undefined;
    if (state === SMSUsageState.APPROACHING) {
      const maxPercentage = Math.max(accountPercentage, facilityPercentage, tenantPercentage);
      warning = `You are approaching the monthly SMS fair-use threshold (${Math.round(maxPercentage)}%). Additional messages may be converted to email.`;
    } else if (state === SMSUsageState.EXCEEDED) {
      warning = 'SMS fair-use limit exceeded. Messages will be sent via email instead.';
    } else if (state === SMSUsageState.EXTREME) {
      warning = `SMS usage is extremely high (${Math.round(accountPercentage)}% of limit). SMS scheduling is disabled. Please contact support if you need to increase your limit.`;
    }

    return {
      success: true,
      canSendSMS: canSendSMS && !tenantExceeded && !facilityExceeded && !accountExceeded,
      shouldFallbackToEmail,
      state,
      warning,
      usage: {
        tenant: tenantId ? tenantUsage : undefined,
        facility: facilityUsage,
        account: accountId ? accountUsage : undefined,
      },
    };
  });
}

export const getSMSUsageStatus = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId, tenantId, accountId } = data;

  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }

  try {
    const now = new Date();
    const monthKey = `${now.getFullYear()}-${(now.getMonth() + 1).toString().padStart(2, '0')}`;

    let finalAccountId = accountId;
    if (!finalAccountId) {
      const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
      if (facilityDoc.exists) {
        finalAccountId = facilityDoc.data()?.facilityCreatorAccountId;
      }
    }

    let tenantUsage = { count: 0, limit: SMS_LIMIT_PER_TENANT };
    if (tenantId) {
      const tenantUsageDoc = await admin.firestore()
        .collection('tenants')
        .doc(tenantId)
        .collection('smsUsage')
        .doc(monthKey)
        .get();

      if (tenantUsageDoc.exists) {
        const d = tenantUsageDoc.data()!;
        tenantUsage = {
          count: d.smsMonthlyCount || 0,
          limit: SMS_LIMIT_PER_TENANT,
        };
      }
    }

    const facilityUsageDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('smsUsage')
      .doc(monthKey)
      .get();

    const facilityData = facilityUsageDoc.exists ? facilityUsageDoc.data()! : {};
    const facilityUsage = {
      count: facilityData.smsMonthlyCount || 0,
      limit: capSmsLimit(facilityData.smsMonthlyLimit || SMS_LIMIT_PER_FACILITY),
    };

    let accountUsage = { count: 0, limit: SMS_LIMIT_PER_ACCOUNT };
    if (finalAccountId) {
      const accountUsageDoc = await admin.firestore()
        .collection('facilityCreatorAccounts')
        .doc(finalAccountId)
        .collection('smsUsage')
        .doc(monthKey)
        .get();

      if (accountUsageDoc.exists) {
        const d = accountUsageDoc.data()!;
        accountUsage = {
          count: d.smsMonthlyCount || 0,
          limit: capSmsLimit(d.smsMonthlyLimit || SMS_LIMIT_PER_ACCOUNT),
        };
      }
    }

    const accountPercentage = finalAccountId ? (accountUsage.count / accountUsage.limit) * 100 : 0;
    const facilityPercentage = (facilityUsage.count / facilityUsage.limit) * 100;
    const tenantPercentage = tenantId ? (tenantUsage.count / tenantUsage.limit) * 100 : 0;

    let state: SMSUsageState = SMSUsageState.NORMAL;
    if (accountUsage.count >= (accountUsage.limit * SMS_EXTREME_MULTIPLIER)) {
      state = SMSUsageState.EXTREME;
    } else if (tenantUsage.count > tenantUsage.limit || facilityUsage.count > facilityUsage.limit || accountUsage.count > accountUsage.limit) {
      state = SMSUsageState.EXCEEDED;
    } else if (accountPercentage >= 80 || facilityPercentage >= 80 || tenantPercentage >= 80) {
      state = SMSUsageState.APPROACHING;
    }

    return {
      state,
      usage: {
        tenant: tenantId ? tenantUsage : undefined,
        facility: facilityUsage,
        account: finalAccountId ? accountUsage : undefined,
      },
      canSendSMS: state === SMSUsageState.NORMAL || state === SMSUsageState.APPROACHING,
      shouldFallbackToEmail: state === SMSUsageState.EXCEEDED || state === SMSUsageState.EXTREME,
    };
  } catch (error: any) {
    functions.logger.error('Error getting SMS usage status', error);
    throw new functions.https.HttpsError('internal', `Failed to get SMS usage status: ${error.message}`);
  }
});

export const overrideSMSLimit = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  const callerEmail = context.auth.token?.email as string | undefined;
  if (!isSuperAdmin(callerEmail)) {
    throw new functions.https.HttpsError('permission-denied', 'Only super admins can override SMS limits');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId, accountId, newLimit, limitType } = data;

  if (!facilityId && !accountId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId or accountId is required');
  }

  if (!newLimit || !limitType) {
    throw new functions.https.HttpsError('invalid-argument', 'newLimit and limitType are required');
  }

  try {
    const now = new Date();
    const monthKey = `${now.getFullYear()}-${(now.getMonth() + 1).toString().padStart(2, '0')}`;

    if (limitType === 'facility' && facilityId) {
      const usageRef = admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('smsUsage')
        .doc(monthKey);

      await usageRef.set({
        smsMonthlyLimit: capSmsLimit(newLimit),
        smsMonth: monthKey,
        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
        overriddenBy: context.auth.uid,
        overriddenAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });

      return { success: true, message: `Facility SMS limit updated to ${newLimit}` };
    }

    if (limitType === 'account' && accountId) {
      const usageRef = admin.firestore()
        .collection('facilityCreatorAccounts')
        .doc(accountId)
        .collection('smsUsage')
        .doc(monthKey);

      await usageRef.set({
        smsMonthlyLimit: capSmsLimit(newLimit),
        smsMonth: monthKey,
        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
        overriddenBy: context.auth.uid,
        overriddenAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });

      return { success: true, message: `Account SMS limit updated to ${newLimit}` };
    }

    throw new functions.https.HttpsError('invalid-argument', 'Invalid limitType or missing ID');
  } catch (error: any) {
    functions.logger.error('Error overriding SMS limit', error);
    throw new functions.https.HttpsError('internal', `Failed to override SMS limit: ${error.message}`);
  }
});

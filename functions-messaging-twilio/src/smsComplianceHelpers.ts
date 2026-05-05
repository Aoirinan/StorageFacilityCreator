import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import { isSMSComplianceFeatureEnabled } from './smsCompliance';

export async function checkQuietHours(facilityId: string, tenantId?: string): Promise<{
  isQuietHours: boolean;
  canSendNow: boolean;
  nextAllowedTime?: Date;
}> {
  try {
    const complianceEnabled = await isSMSComplianceFeatureEnabled('quietHours', facilityId);
    if (!complianceEnabled) {
      return { isQuietHours: false, canSendNow: true };
    }

    const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
    const facilityData = facilityDoc.data() as Record<string, unknown> | undefined;
    const smsSettings = facilityData?.smsSettings as Record<string, unknown> | undefined;

    const facilityQuietStart = smsSettings?.quietHoursStart as string | undefined;
    const facilityQuietEnd = smsSettings?.quietHoursEnd as string | undefined;

    let tenantQuietStart: string | undefined;
    let tenantQuietEnd: string | undefined;
    if (tenantId) {
      const tenantDoc = await admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .doc(tenantId)
        .get();
      const tenantData = tenantDoc.data() as Record<string, unknown> | undefined;
      tenantQuietStart = tenantData?.smsQuietHoursStart as string | undefined;
      tenantQuietEnd = tenantData?.smsQuietHoursEnd as string | undefined;
    }

    const quietStart = tenantQuietStart || facilityQuietStart;
    const quietEnd = tenantQuietEnd || facilityQuietEnd;

    if (!quietStart || !quietEnd) {
      return { isQuietHours: false, canSendNow: true };
    }

    const now = new Date();
    const [startHour, startMinute] = quietStart.split(':').map(Number);
    const [endHour, endMinute] = quietEnd.split(':').map(Number);

    const currentHour = now.getUTCHours();
    const currentMinute = now.getUTCMinutes();
    const currentTimeMinutes = currentHour * 60 + currentMinute;
    const startTimeMinutes = startHour * 60 + startMinute;
    const endTimeMinutes = endHour * 60 + endMinute;

    let isQuietHours = false;
    if (startTimeMinutes > endTimeMinutes) {
      isQuietHours = currentTimeMinutes >= startTimeMinutes || currentTimeMinutes < endTimeMinutes;
    } else {
      isQuietHours = currentTimeMinutes >= startTimeMinutes && currentTimeMinutes < endTimeMinutes;
    }

    if (!isQuietHours) {
      return { isQuietHours: false, canSendNow: true };
    }

    const nextAllowedTime = new Date(now);
    if (startTimeMinutes > endTimeMinutes && currentTimeMinutes >= startTimeMinutes) {
      nextAllowedTime.setUTCDate(nextAllowedTime.getUTCDate() + 1);
      nextAllowedTime.setUTCHours(endHour, endMinute, 0, 0);
    } else {
      nextAllowedTime.setUTCHours(endHour, endMinute, 0, 0);
      if (nextAllowedTime <= now) {
        nextAllowedTime.setUTCDate(nextAllowedTime.getUTCDate() + 1);
      }
    }

    return {
      isQuietHours: true,
      canSendNow: false,
      nextAllowedTime,
    };
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    functions.logger.error(`Error checking quiet hours: ${message}`, error);
    return { isQuietHours: false, canSendNow: true };
  }
}

export async function checkPerTenantRateLimit(
  facilityId: string,
  tenantId: string,
): Promise<{
  canSend: boolean;
  messagesSentToday: number;
  limit: number;
  resetTime?: Date;
}> {
  try {
    const complianceEnabled = await isSMSComplianceFeatureEnabled('rateLimiting', facilityId);
    if (!complianceEnabled) {
      return { canSend: true, messagesSentToday: 0, limit: 0 };
    }

    const tenantDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId)
      .get();

    const tenantData = tenantDoc.data() as Record<string, unknown> | undefined;
    const rateLimitPerDay = (tenantData?.smsRateLimitPerDay as number | undefined) || 10;
    const lastResetRaw = tenantData?.smsLastResetDate as admin.firestore.Timestamp | undefined;
    const lastResetDate = lastResetRaw?.toDate?.();
    const messagesSentToday = (tenantData?.smsMessagesSentToday as number | undefined) || 0;

    const now = new Date();
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());

    let needsReset = false;
    if (!lastResetDate) {
      needsReset = true;
    } else {
      const lastReset = new Date(lastResetDate.getFullYear(), lastResetDate.getMonth(), lastResetDate.getDate());
      if (lastReset < today) {
        needsReset = true;
      }
    }

    if (needsReset) {
      await admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .doc(tenantId)
        .update({
          smsMessagesSentToday: 0,
          smsLastResetDate: admin.firestore.FieldValue.serverTimestamp(),
        });

      return {
        canSend: true,
        messagesSentToday: 0,
        limit: rateLimitPerDay,
        resetTime: new Date(today.getTime() + 24 * 60 * 60 * 1000),
      };
    }

    const canSend = messagesSentToday < rateLimitPerDay;
    const resetTime = new Date(today.getTime() + 24 * 60 * 60 * 1000);

    return {
      canSend,
      messagesSentToday,
      limit: rateLimitPerDay,
      resetTime,
    };
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    functions.logger.error(`Error checking per-tenant rate limit: ${message}`, error);
    return { canSend: true, messagesSentToday: 0, limit: 0 };
  }
}

export async function addOptOutFooter(facilityId: string, body: string): Promise<string> {
  try {
    const complianceEnabled = await isSMSComplianceFeatureEnabled('enhancedOptOut', facilityId);
    if (!complianceEnabled) {
      return body;
    }

    const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
    const facilityData = facilityDoc.data() as Record<string, unknown> | undefined;
    const smsSettings = facilityData?.smsSettings as Record<string, unknown> | undefined;
    const optOutFooter = smsSettings?.optOutFooter as string | undefined;

    const footer = optOutFooter || 'Reply STOP to opt out. Reply HELP for help.';

    if (body.includes('STOP') || body.includes('opt out')) {
      return body;
    }

    const maxMessageLength = 1500;
    const truncatedMessage = body.length > maxMessageLength
      ? `${body.substring(0, maxMessageLength - footer.length - 3)}...`
      : body;

    return `${truncatedMessage}\n\n${footer}`;
  } catch (error: unknown) {
    const errMsg = error instanceof Error ? error.message : String(error);
    functions.logger.error(`Error adding opt-out footer: ${errMsg}`, error);
    return body;
  }
}

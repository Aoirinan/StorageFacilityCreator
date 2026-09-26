import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import {
  formatPhoneNumber,
  getOutboundGateConfig,
  isCustomerRecipientAllowed,
  tenantUnitLabel,
} from '@sfc/functions-shared';
import {
  SENDGRID_SECRETS,
  TWILIO_ACCOUNT_SID,
  TWILIO_AUTH_TOKEN,
  TWILIO_DRY_RUN,
  TWILIO_PHONE_NUMBER,
  TWILIO_SECRETS,
} from './secrets';
import { createOrUpdateMessageLog } from './messageLog';
import { reservePlatformOutgoing } from './platformOutgoing';
import { addOptOutFooter, checkPerTenantRateLimit, checkQuietHours } from './smsComplianceHelpers';
import { isSMSComplianceFeatureEnabled } from './smsCompliance';
import { checkAndIncrementSMSUsage } from './smsUsage';
import { evaluateSharedNumberSend, recordSharedNumberSend } from './sharedNumberGuard';
import {
  buildRentReminderMessage,
  decideRentReminder,
  RentReminderTenant,
} from './rentReminderHelpers';

/**
 * Automatic rent reminders by text.
 *
 * The app has offered "Rent Due" reminder schedules with an SMS channel for a
 * while, but nothing ever executed them: `reminderSchedules` was read by no
 * Cloud Function, and the client-side processor had no caller. The only
 * automated reminder that ran was email-only, and it skipped any tenant with
 * no `paidThrough` — which is every tenant imported from a rent roll. This job
 * is the missing half.
 *
 * Runs hourly and sends to each facility whose local time has reached its
 * configured send hour, so a facility in Mountain time is not texted at 3am.
 */

const DEFAULT_REMINDER_DAYS = 3;
const DEFAULT_SEND_HOUR = 9;

interface FacilityReminderSettings {
  enabled: boolean;
  reminderDays: number;
  sendHour: number;
}

/**
 * Reads the facility's reminder settings from the Notification Settings screen.
 *
 * That screen has always written `paymentReminderChannel` as email, sms or
 * both, along with the lead time and the hour of day. Nothing on the server
 * read the sms half, so choosing it changed nothing. Texting stays off unless
 * the operator has actually chosen it.
 */
export function readReminderSettings(facilityData: Record<string, any>): FacilityReminderSettings {
  const billing = (facilityData?.billingSettings ?? {}) as Record<string, any>;
  const channel = String(billing.paymentReminderChannel ?? 'email').toLowerCase();
  const days = Number(billing.paymentReminderDays);
  const hour = Number(billing.sendTimeHour);
  return {
    enabled: billing.enablePaymentReminders !== false && (channel === 'sms' || channel === 'both'),
    reminderDays: Number.isFinite(days) && days >= 0 && days <= 30 ? days : DEFAULT_REMINDER_DAYS,
    sendHour: Number.isFinite(hour) && hour >= 0 && hour <= 23 ? hour : DEFAULT_SEND_HOUR,
  };
}

/** The hour of the day at the facility, from its IANA time zone. */
export function facilityLocalHour(timeZone: string | undefined, now: Date): number {
  try {
    const formatted = new Intl.DateTimeFormat('en-US', {
      timeZone: timeZone && timeZone.trim() ? timeZone : 'America/Chicago',
      hour: 'numeric',
      hour12: false,
    }).format(now);
    const parsed = Number(formatted);
    return Number.isFinite(parsed) ? parsed % 24 : now.getUTCHours();
  } catch {
    return now.getUTCHours();
  }
}

/** Posted ledger balance for one tenant. Positive means they owe. */
async function tenantBalance(facilityId: string, tenantId: string): Promise<number> {
  const snapshot = await admin
    .firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('ledgers')
    .where('tenantId', '==', tenantId)
    .where('status', '==', 'posted')
    .get();
  let balance = 0;
  for (const doc of snapshot.docs) {
    balance += Number(doc.data()?.amount) || 0;
  }
  return balance;
}

function toDate(value: any): Date | null {
  if (!value) return null;
  if (value instanceof Date) return value;
  if (typeof value.toDate === 'function') return value.toDate();
  return null;
}

/**
 * Sends one reminder, applying the same rules the operator's own Send SMS
 * button applies: the pre-launch customer gate, quiet hours, the per-tenant
 * rate limit, the facility's monthly allowance, the STOP/HELP footer, and the
 * facility-name prefix when the message goes out on the shared number.
 */
async function sendReminderSms(params: {
  facilityId: string;
  facilityData: Record<string, any>;
  tenantId: string;
  tenantName: string;
  tenantEmail: string | null;
  toPhone: string;
  message: string;
}): Promise<'sent' | 'blocked' | 'failed'> {
  const { facilityId, facilityData, tenantId, tenantName, tenantEmail, toPhone, message } = params;

  const phoneNumber = formatPhoneNumber(toPhone);
  if (!phoneNumber) return 'blocked';

  const blockList = ((facilityData?.smsSettings ?? {}).blockList ?? []) as string[];
  if (Array.isArray(blockList) && blockList.includes(phoneNumber)) return 'blocked';

  const quietHoursEnabled = await isSMSComplianceFeatureEnabled('quietHours', facilityId);
  if (quietHoursEnabled) {
    const quiet = await checkQuietHours(facilityId, tenantId);
    if (quiet.isQuietHours) return 'blocked';
  }

  const rateLimitingEnabled = await isSMSComplianceFeatureEnabled('rateLimiting', facilityId);
  if (rateLimitingEnabled) {
    const limit = await checkPerTenantRateLimit(facilityId, tenantId);
    if (!limit.canSend) return 'blocked';
  }

  // No text reaches a real customer before launch. Checked before any quota is
  // reserved so a blocked send costs nothing.
  const gate = await getOutboundGateConfig();
  if (!isCustomerRecipientAllowed(phoneNumber, gate)) {
    functions.logger.info('[rentReminderSms] held by pre-launch customer contact gate', {
      facilityId,
      tenantId,
    });
    return 'blocked';
  }

  const usage = await checkAndIncrementSMSUsage(facilityId, tenantId);
  if (!usage.success || !usage.canSendSMS) {
    functions.logger.warn('[rentReminderSms] facility SMS allowance exhausted', {
      facilityId,
      message: usage.message ?? null,
    });
    return 'blocked';
  }

  let body = await addOptOutFooter(facilityId, message);

  const platformNumber = (TWILIO_PHONE_NUMBER.value() || '').trim();
  const facilityNumber = ((facilityData?.twilioPhoneNumberE164 as string | undefined) || '').trim();
  const a2pApproved = ((facilityData?.a2pStatus as string) || 'draft').toLowerCase() === 'approved';
  const fromNumber = a2pApproved && facilityNumber ? facilityNumber : platformNumber;
  if (!fromNumber) return 'failed';

  // A facility still on the shared number may only send while it is in trial
  // or waiting on its own registration, and within a monthly ceiling. See
  // sharedNumberPolicy.ts for why the shared number is a starting point
  // rather than a destination.
  const sharedDecision = await evaluateSharedNumberSend({
    facilityId,
    facilityData,
    usesOwnNumber: fromNumber !== platformNumber,
  });
  if (!sharedDecision.allowed) {
    functions.logger.info('[rentReminderSms] held by shared-number policy', {
      facilityId,
      tenantId,
      refusal: sharedDecision.refusal,
    });
    return 'blocked';
  }

  if (fromNumber === platformNumber) {
    const label = ((facilityData?.name as string | undefined) || '').trim();
    if (label && !body.toLowerCase().startsWith(label.toLowerCase())) {
      body = `${label}: ${body}`;
    }
  }

  const messageLogId = `sms-reminder-${Date.now()}-${Math.random().toString(36).substring(2, 9)}`;
  // The log is written once, after the outcome is known. The operator's
  // Messaging tab reads these, and an automated send has no signed-in user
  // behind it, so it is attributed to the scheduler rather than to a person.
  const writeLog = (
    status: 'sent' | 'failed',
    extra: { providerMessageId?: string | null; errorCode?: string | null; errorMessage?: string | null } = {},
  ) =>
    createOrUpdateMessageLog(facilityId, messageLogId, {
      tenantId,
      tenantName,
      tenantEmail,
      tenantPhone: phoneNumber,
      channel: 'sms',
      direction: 'outbound',
      source: 'automation',
      templateId: null,
      previewText: body.substring(0, 200),
      status,
      provider: 'twilio',
      providerMessageId: extra.providerMessageId ?? null,
      errorCode: extra.errorCode ?? null,
      errorMessage: extra.errorMessage ?? null,
      sentAt: status === 'sent' ? admin.firestore.Timestamp.now() : null,
      createdByUid: 'system:rent-reminder',
      createdByEmail: null,
    });

  if ((TWILIO_DRY_RUN.value() || 'false').toLowerCase() === 'true') {
    await writeLog('sent', { providerMessageId: `DRYRUN-${messageLogId}` });
    return 'sent';
  }

  const accountSid = (TWILIO_ACCOUNT_SID.value() || '').trim();
  const authToken = (TWILIO_AUTH_TOKEN.value() || '').trim();
  if (!accountSid || !authToken) return 'failed';

  await reservePlatformOutgoing('sms');

  const form = new URLSearchParams();
  form.append('To', phoneNumber);
  form.append('From', fromNumber);
  form.append('Body', body);

  const response = await fetch(
    `https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages.json`,
    {
      method: 'POST',
      headers: {
        Authorization: `Basic ${Buffer.from(`${accountSid}:${authToken}`).toString('base64')}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: form.toString(),
    },
  );

  if (!response.ok) {
    const detail = await response.text().catch(() => '');
    functions.logger.error('[rentReminderSms] Twilio rejected the message', {
      facilityId,
      tenantId,
      status: response.status,
      detail: detail.substring(0, 300),
    });
    await writeLog('failed', {
      errorCode: String(response.status),
      errorMessage: detail.substring(0, 300),
    });
    return 'failed';
  }

  const payload = (await response.json()) as { sid?: string };
  await writeLog('sent', { providerMessageId: payload?.sid ?? null });
  if (fromNumber === platformNumber) {
    await recordSharedNumberSend(facilityId);
  }
  return 'sent';
}

/**
 * A tenant doc as [decideRentReminder] reads it. Active is `isActive` exactly
 * true, as in the app's TenantModel and every other server job; this read a
 * missing isActive as active.
 */
export function rentReminderTenantFromDoc(id: string, data: Record<string, any>): RentReminderTenant {
  return {
    id,
    name: data.name,
    phone: data.phone,
    isActive: data.isActive === true,
    paidThrough: toDate(data.paidThrough),
    smsOptOut: data.smsOptOut === true,
    smsOptInDate: toDate(data.smsOptInDate),
    smsConsentStatus: data.smsConsentStatus ?? null,
    monthlyRate: Number(data.monthlyRate) || 0,
    lastSmsPaymentReminderDate: toDate(data.lastSmsPaymentReminderDate),
  };
}

export const processRentDueTextReminders = functions
  .runWith({
    secrets: [...TWILIO_SECRETS, ...SENDGRID_SECRETS],
    timeoutSeconds: 540,
    memory: '512MB',
  })
  .pubsub.schedule('0 * * * *')
  .timeZone('UTC')
  .onRun(async () => {
    const now = new Date();
    let sent = 0;
    let considered = 0;

    const facilities = await admin
      .firestore()
      .collection('facilities')
      .where('active', '==', true)
      .get();

    for (const facilityDoc of facilities.docs) {
      const facilityId = facilityDoc.id;
      const facilityData = facilityDoc.data() as Record<string, any>;
      const settings = readReminderSettings(facilityData);
      if (!settings.enabled) continue;

      // Once a day, at the facility's own hour rather than the server's.
      if (facilityLocalHour(facilityData?.timeZone, now) !== settings.sendHour) continue;

      const tenants = await facilityDoc.ref.collection('tenants').where('isActive', '==', true).get();

      for (const tenantDoc of tenants.docs) {
        const data = tenantDoc.data() as Record<string, any>;
        const tenant = rentReminderTenantFromDoc(tenantDoc.id, data);

        // Balance is the expensive read, so only ask for it once the cheap
        // checks have passed.
        const preflight = decideRentReminder({ tenant, balance: 1, reminderDays: settings.reminderDays, now });
        if (!preflight.send) continue;

        const balance = await tenantBalance(facilityId, tenantDoc.id);
        const decision = decideRentReminder({
          tenant,
          balance,
          reminderDays: settings.reminderDays,
          now,
        });
        if (!decision.send || !decision.dueDate) continue;

        considered += 1;
        const amount = balance > 0 ? balance : Number(data.monthlyRate) || 0;
        const message = buildRentReminderMessage({
          tenantName: tenant.name,
          amount,
          dueDate: decision.dueDate,
          // "12 (Complex 2)" once the facility numbers units per area; the
          // stored number, untouched, until then.
          unitNumber: tenantUnitLabel(data, facilityData),
        });

        try {
          const result = await sendReminderSms({
            facilityId,
            facilityData,
            tenantId: tenantDoc.id,
            tenantName: String(data.name ?? ''),
            tenantEmail: (data.email as string | undefined)?.trim() || null,
            toPhone: String(data.phone ?? ''),
            message,
          });
          if (result === 'sent') {
            sent += 1;
            await tenantDoc.ref.update({
              lastSmsPaymentReminderDate: admin.firestore.Timestamp.fromDate(now),
            });
          }
        } catch (error: any) {
          functions.logger.error('[rentReminderSms] send failed', {
            facilityId,
            tenantId: tenantDoc.id,
            error: error?.message ?? String(error),
          });
        }
      }
    }

    functions.logger.info('[rentReminderSms] run complete', { considered, sent });
    return null;
  });

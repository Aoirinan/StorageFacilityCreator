import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import {
  formatPhoneNumber,
  getOutboundGateConfig,
  isCustomerRecipientAllowed,
  splitLedgerBalance,
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
import { releasePlatformOutgoing, reservePlatformOutgoing } from './platformOutgoing';
import { addOptOutFooter, checkPerTenantRateLimit, checkQuietHours } from './smsComplianceHelpers';
import { isSMSComplianceFeatureEnabled } from './smsCompliance';
import { checkAndIncrementSMSUsage } from './smsUsage';
import { evaluateSharedNumberSend, recordSharedNumberSend } from './sharedNumberGuard';
import { isFeatureFlagEnabled } from './featureFlags';
import { decideTenantRecipientConsent, findFacilityTenantsForNumber } from './tenantSmsConsent';
import {
  buildRentReminderMessage,
  claimActionFor,
  clampReminderDays,
  creditCoversRent,
  decideRentReminder,
  localDateTimeIn,
  RentReminderTenant,
  runSendAttempt,
  selectReminderFromNumber,
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
 * The reminder goes out [reminderDays] before the 1st (the facility's local
 * calendar date) to every active, consenting tenant with a rent and a unit
 * who is not already paid for that month. See rentReminderHelpers.ts.
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
  const hour = Number(billing.sendTimeHour);
  return {
    enabled: billing.enablePaymentReminders !== false && (channel === 'sms' || channel === 'both'),
    reminderDays: clampReminderDays(billing.paymentReminderDays, DEFAULT_REMINDER_DAYS),
    sendHour: Number.isFinite(hour) && hour >= 0 && hour <= 23 ? hour : DEFAULT_SEND_HOUR,
  };
}

/** The hour of the day at the facility, from its IANA time zone. */
export function facilityLocalHour(timeZone: string | undefined, now: Date): number {
  return localDateTimeIn(timeZone, now).hour;
}

/**
 * Posted ledger balance for one tenant, as a reminder may quote it. Positive
 * means they owe. Exported for tests.
 *
 * Card-dispute rows are left out, as autopay leaves them out: the text quoted
 * the balance as rent due, so a disputed amount was asked for again, and paid
 * twice when the facility then won. Staff collect a disputed amount by hand.
 */
export async function tenantBalance(facilityId: string, tenantId: string): Promise<number> {
  const snapshot = await admin
    .firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('ledgers')
    .where('tenantId', '==', tenantId)
    .where('status', '==', 'posted')
    .get();
  return splitLedgerBalance(snapshot.docs.map((doc) => doc.data())).collectible;
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
  /** Called just before the Twilio request, so the caller knows it may have gone out. */
  markRequestStarted?: () => void;
}): Promise<'sent' | 'blocked' | 'failed'> {
  const { facilityId, facilityData, tenantId, tenantName, tenantEmail, toPhone, message } = params;

  const phoneNumber = formatPhoneNumber(toPhone);
  if (!phoneNumber) return 'blocked';

  const blockList = ((facilityData?.smsSettings ?? {}).blockList ?? []) as string[];
  if (Array.isArray(blockList) && blockList.includes(phoneNumber)) return 'blocked';

  // Same rule as sendSMS: if any record at this facility with this number
  // (matched on digits) is opted out, the number said STOP and is not texted,
  // even though this tenancy's own record still shows consent.
  const numberTenants = await findFacilityTenantsForNumber(facilityId, phoneNumber, tenantId);
  const numberConsent = decideTenantRecipientConsent(numberTenants, tenantId);
  if (!numberConsent.allowed) {
    functions.logger.info('[rentReminderSms] held: number opted out or without consent at this facility', {
      facilityId,
      tenantId,
      refusal: numberConsent.refusal,
    });
    return 'blocked';
  }

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

  // Customer contact gate (launch flag and blockedFacilityIds). Checked before
  // any quota is reserved so a blocked send costs nothing.
  const gate = await getOutboundGateConfig();
  if (!isCustomerRecipientAllowed(phoneNumber, { facilityId, channel: 'sms' }, gate)) {
    functions.logger.info('[rentReminderSms] held by customer contact gate', {
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
  // Same rule as sendSMS: the facility's own number only once onboarding is on,
  // the registration is approved and a super admin has approved the facility.
  const fromNumber = selectReminderFromNumber({
    platformNumber,
    facilityNumber: facilityData?.twilioPhoneNumberE164 as string | undefined,
    textingOnboardingFlag: await isFeatureFlagEnabled('TEXTING_ONBOARDING_V1'),
    facilityData,
  });
  if (!fromNumber) return 'failed';

  // A facility on the shared number may send while its account is in good
  // standing, within a monthly ceiling. See sharedNumberPolicy.ts.
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

  params.markRequestStarted?.();

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
    // Twilio refused it, so nothing went out: give the platform quota back.
    await releasePlatformOutgoing('sms').catch(() => undefined);
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
    unitNumber: data.unitNumber == null ? null : String(data.unitNumber),
    lastSmsPaymentReminderDate: toDate(data.lastSmsPaymentReminderDate),
    lastSmsPaymentReminderDueDate:
      typeof data.lastSmsPaymentReminderDueDate === 'string' ? data.lastSmsPaymentReminderDueDate : null,
  };
}

/**
 * Claims the one reminder a tenant gets for one due date. create() fails when
 * the document exists, so two overlapping runs (a retry, a slow hour) cannot
 * both send. Kept off the tenant document so a claim does not fire the tenant
 * triggers. Released again if the text does not go out.
 */
function reminderClaimRef(facilityId: string, tenantId: string, dueKey: string) {
  return admin
    .firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('rentReminderSends')
    .doc(`${tenantId}_${dueKey}`);
}

async function claimReminder(facilityId: string, tenantId: string, dueKey: string): Promise<boolean> {
  try {
    await reminderClaimRef(facilityId, tenantId, dueKey).create({
      tenantId,
      dueDate: dueKey,
      channel: 'sms',
      status: 'claimed',
      claimedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return true;
  } catch (error: any) {
    // 6 = ALREADY_EXISTS: another run has sent (or is sending) this one.
    if (error?.code === 6 || /already exists/i.test(String(error?.message ?? ''))) return false;
    throw error;
  }
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

      const local = localDateTimeIn(facilityData?.timeZone, now);
      const today = { year: local.year, month: local.month, day: local.day };
      const gate = await getOutboundGateConfig();

      const tenants = await facilityDoc.ref.collection('tenants').where('isActive', '==', true).get();

      for (const tenantDoc of tenants.docs) {
        const data = tenantDoc.data() as Record<string, any>;
        const tenant = rentReminderTenantFromDoc(tenantDoc.id, data);

        const decision = decideRentReminder({
          tenant,
          reminderDays: settings.reminderDays,
          today,
          timeZone: facilityData?.timeZone,
        });
        if (!decision.send || !decision.dueDate || !decision.dueKey) continue;

        // A tenant the gate will refuse is skipped before any read or write, so
        // a blocked facility costs nothing each month. sendReminderSms asks
        // again; this is only the cheap early exit.
        const formatted = formatPhoneNumber(String(data.phone ?? ''));
        if (!formatted || !isCustomerRecipientAllowed(formatted, { facilityId, channel: 'sms' }, gate)) continue;

        // Paid ahead through the portal: a ledger credit that already covers
        // the month. Online payments do not move paidThrough.
        const monthlyRate = Number(data.monthlyRate) || 0;
        const balance = await tenantBalance(facilityId, tenantDoc.id);
        if (creditCoversRent(balance, monthlyRate)) continue;

        considered += 1;
        const message = buildRentReminderMessage({
          facilityName: (facilityData?.name as string | undefined) ?? null,
          tenantName: tenant.name,
          amount: monthlyRate,
          balance,
          dueDate: decision.dueDate,
          // "12 (Complex 2)" once the facility numbers units per area; the
          // stored number, untouched, until then.
          unitNumber: tenantUnitLabel(data, facilityData),
        });

        let claimed = false;
        try {
          claimed = await claimReminder(facilityId, tenantDoc.id, decision.dueKey);
        } catch (error: any) {
          functions.logger.error('[rentReminderSms] could not claim reminder', {
            facilityId,
            tenantId: tenantDoc.id,
            error: error?.message ?? String(error),
          });
          continue;
        }
        if (!claimed) continue;

        const attempt = await runSendAttempt((markRequestStarted) =>
          sendReminderSms({
            facilityId,
            facilityData,
            tenantId: tenantDoc.id,
            tenantName: String(data.name ?? ''),
            tenantEmail: (data.email as string | undefined)?.trim() || null,
            toPhone: String(data.phone ?? ''),
            message,
            markRequestStarted,
          }),
        );
        if (attempt.error) {
          functions.logger.error('[rentReminderSms] send failed', {
            facilityId,
            tenantId: tenantDoc.id,
            outcome: attempt.outcome,
            error: (attempt.error as any)?.message ?? String(attempt.error),
          });
        }

        const claimRef = reminderClaimRef(facilityId, tenantDoc.id, decision.dueKey);
        const action = claimActionFor(attempt.outcome);
        try {
          if (action === 'mark-sent') {
            sent += 1;
            await claimRef
              .update({ status: 'sent', sentAt: admin.firestore.FieldValue.serverTimestamp() })
              .catch(() => undefined);
            await tenantDoc.ref.update({
              lastSmsPaymentReminderDate: admin.firestore.Timestamp.fromDate(now),
              lastSmsPaymentReminderDueDate: decision.dueKey,
            });
          } else if (action === 'release') {
            // Certainly not sent (blocked, refused, or failed before the
            // request): free the claim so a retry this hour can send.
            await claimRef.delete();
          } else {
            // The request may have reached Twilio: keep the claim so a retry
            // never texts twice, and say so for whoever reads the log.
            await claimRef.update({ status: 'unknown' }).catch(() => undefined);
          }
        } catch (error: any) {
          functions.logger.error('[rentReminderSms] could not settle reminder claim', {
            facilityId,
            tenantId: tenantDoc.id,
            action,
            error: error?.message ?? String(error),
          });
        }
      }
    }

    functions.logger.info('[rentReminderSms] run complete', { considered, sent });
    return null;
  });

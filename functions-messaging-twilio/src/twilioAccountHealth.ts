import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { defineString } from 'firebase-functions/params';
import { getSuperAdminEmails, getSgMail, initializeSendGrid } from '@sfc/functions-shared';
import { getTwilioClient, isTwilioDryRunEnabled } from './twilioClient';
import {
  SENDGRID_FROM_EMAIL,
  SENDGRID_FROM_NAME,
  SENDGRID_SECRETS,
  TWILIO_ACCOUNT_SID,
  TWILIO_SECRETS,
} from './secrets';

/**
 * Watch the Twilio account itself, not just individual sends.
 *
 * On 2026-09-13 the account sat suspended on a negative balance. Twilio's own
 * low-balance email went to the account owner and was missed, `sendSMS` would
 * have failed on every call, and nothing in the product said so. With near
 * zero traffic there were not even failed sends to notice. This job asks
 * Twilio directly, every six hours, whether the account is active and what
 * the balance is, records the answer where the super-admin UI can show it,
 * and emails the super admins when it is not healthy.
 */

const HEALTH_DOC_PATH = 'platform/twilioAccountHealth';

/** Balance below this (in the account currency, USD) triggers an alert. */
export const TWILIO_LOW_BALANCE_ALERT = defineString('TWILIO_LOW_BALANCE_ALERT_USD', { default: '10' });

/** Re-send an unchanged alert at most this often. */
const REALERT_INTERVAL_MS = 24 * 60 * 60 * 1000;

export type TwilioAccountHealth = {
  status: string;
  balance: number | null;
  currency: string | null;
  lowBalanceThreshold: number;
  healthy: boolean;
  problems: string[];
  checkedAt: FirebaseFirestore.FieldValue | FirebaseFirestore.Timestamp;
  lastAlertAt?: FirebaseFirestore.Timestamp | null;
  lastAlertKey?: string | null;
  error?: string | null;
};

type HealthProbe = {
  status: string;
  balance: number | null;
  currency: string | null;
  error: string | null;
};

async function probeTwilio(): Promise<HealthProbe> {
  const twilio = getTwilioClient() as any;
  const accountSid = TWILIO_ACCOUNT_SID.value().trim();
  try {
    const [account, balance] = await Promise.all([
      twilio.api.v2010.accounts(accountSid).fetch(),
      twilio.balance.fetch(),
    ]);
    const parsed = Number.parseFloat(String(balance?.balance ?? ''));
    return {
      status: String(account?.status || 'unknown').toLowerCase(),
      balance: Number.isFinite(parsed) ? parsed : null,
      currency: balance?.currency ? String(balance.currency) : null,
      error: null,
    };
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    // A 401 here means the auth token itself is wrong or rotated, which is
    // as fatal for texting as a suspension and deserves the same alert.
    return { status: 'unreachable', balance: null, currency: null, error: message };
  }
}

export function evaluateHealth(probe: HealthProbe, lowBalanceThreshold: number): { healthy: boolean; problems: string[] } {
  const problems: string[] = [];
  if (probe.error) {
    problems.push(`Twilio API could not be reached: ${probe.error}`);
  } else if (probe.status !== 'active') {
    problems.push(`Account status is "${probe.status}" (expected "active"). Every SMS send is rejected while it stays this way.`);
  }
  if (probe.balance !== null && probe.balance < lowBalanceThreshold) {
    problems.push(
      `Balance is ${probe.balance.toFixed(2)} ${probe.currency || ''}, below the ${lowBalanceThreshold.toFixed(2)} alert line. ` +
      'If auto-recharge is not firing the account will suspend once it goes negative.',
    );
  }
  return { healthy: problems.length === 0, problems };
}

async function emailSuperAdmins(subject: string, text: string): Promise<void> {
  const to = getSuperAdminEmails();
  if (to.length === 0) {
    functions.logger.warn('[twilioAccountHealth] no super admin emails configured; alert not sent');
    return;
  }
  initializeSendGrid();
  const sgMail = getSgMail() as { send: (msg: unknown) => Promise<unknown> };
  await sgMail.send({
    to,
    from: { email: SENDGRID_FROM_EMAIL.value(), name: SENDGRID_FROM_NAME.value() || 'Storage Facility Creator' },
    subject,
    text,
  });
}

function alertKey(probe: HealthProbe, problems: string[]): string {
  // Status changes and reachability are the events worth a fresh email;
  // the balance drifting by cents within the low band is not.
  return `${probe.status}|${probe.error ? 'error' : 'ok'}|${problems.length}`;
}

export async function checkTwilioAccountHealth(): Promise<TwilioAccountHealth> {
  const db = admin.firestore();
  const ref = db.doc(HEALTH_DOC_PATH);
  const previous = (await ref.get()).data() as Partial<TwilioAccountHealth> | undefined;

  const threshold = Number.parseFloat(TWILIO_LOW_BALANCE_ALERT.value() || '10');
  const lowBalanceThreshold = Number.isFinite(threshold) ? threshold : 10;

  const probe = await probeTwilio();
  const { healthy, problems } = evaluateHealth(probe, lowBalanceThreshold);

  const now = Date.now();
  const key = healthy ? null : alertKey(probe, problems);
  const previousKey = previous?.lastAlertKey ?? null;
  const previousAlertAt = previous?.lastAlertAt?.toMillis?.() ?? 0;
  const wasAlerting = Boolean(previousKey);

  let sendAlert = false;
  let sendRecovery = false;
  if (!healthy) {
    sendAlert = key !== previousKey || now - previousAlertAt > REALERT_INTERVAL_MS;
  } else if (wasAlerting) {
    sendRecovery = true;
  }

  const summaryLines = [
    `Account: ${TWILIO_ACCOUNT_SID.value().trim()}`,
    `Status: ${probe.status}`,
    `Balance: ${probe.balance === null ? 'unknown' : `${probe.balance.toFixed(2)} ${probe.currency || ''}`}`,
    `Alert line: ${lowBalanceThreshold.toFixed(2)}`,
    '',
    'Billing: https://1console.twilio.com/ > Billing > Overview',
    'Notes: docs/TWILIO_SENDER_REGISTRATION.md in the repo',
  ];

  try {
    if (sendAlert) {
      await emailSuperAdmins(
        `[SFC] Twilio account needs attention: ${problems.length === 1 ? problems[0].split('.')[0] : `${problems.length} problems`}`,
        ['Storage Facility Creator cannot rely on Twilio right now.', '', ...problems.map((p) => `- ${p}`), '', ...summaryLines].join('\n'),
      );
    } else if (sendRecovery) {
      await emailSuperAdmins(
        '[SFC] Twilio account is healthy again',
        ['The Twilio account is active and funded; SMS sending should work.', '', ...summaryLines].join('\n'),
      );
    }
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err);
    functions.logger.error('[twilioAccountHealth] alert email failed', { message });
    // Fall through and still record the probe; the next run will retry the email.
    sendAlert = false;
  }

  const record: TwilioAccountHealth = {
    status: probe.status,
    balance: probe.balance,
    currency: probe.currency,
    lowBalanceThreshold,
    healthy,
    problems,
    error: probe.error,
    checkedAt: admin.firestore.FieldValue.serverTimestamp(),
    lastAlertKey: healthy ? null : key,
    lastAlertAt: sendAlert
      ? admin.firestore.Timestamp.fromMillis(now)
      : healthy
        ? null
        : (previous?.lastAlertAt ?? null),
  };
  await ref.set(record, { merge: true });

  functions.logger.info('[twilioAccountHealth] checked', {
    status: probe.status,
    balance: probe.balance,
    healthy,
    problems,
    alerted: sendAlert,
    recovered: sendRecovery,
  });
  return record;
}

export const checkTwilioAccountHealthScheduled = functions
  .runWith({ secrets: [...TWILIO_SECRETS, ...SENDGRID_SECRETS], timeoutSeconds: 120, memory: '256MB' })
  .pubsub.schedule('30 */6 * * *')
  .timeZone('UTC')
  .onRun(async () => {
    if (isTwilioDryRunEnabled()) {
      functions.logger.info('Twilio dry-run enabled; skipping account health check');
      return null;
    }
    await checkTwilioAccountHealth();
    return null;
  });

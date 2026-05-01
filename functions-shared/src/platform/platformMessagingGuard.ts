import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

const GUARD_DOC = () => admin.firestore().collection('configs').doc('messagingGuard');
const ROLLUP_DOC = () => admin.firestore().collection('configs').doc('messagingDailyRollup');

function utcDateKey(): string {
  return new Date().toISOString().slice(0, 10);
}

export interface MessagingGuardConfig {
  enabled: boolean;
  dailySmsLimit: number;
  dailyEmailLimit: number;
}

export async function readMessagingGuardConfig(): Promise<MessagingGuardConfig> {
  const snap = await GUARD_DOC().get();
  const d = snap.data() || {};
  return {
    enabled: d.enabled !== false,
    dailySmsLimit: typeof d.dailySmsLimit === 'number' && d.dailySmsLimit > 0 ? d.dailySmsLimit : 1000,
    dailyEmailLimit: typeof d.dailyEmailLimit === 'number' && d.dailyEmailLimit > 0 ? d.dailyEmailLimit : 1000,
  };
}

/**
 * Staff-facing sendEmail / sendSMS / sendDigest only.
 * Reserves one slot in the platform daily counter (throws if disabled or over cap).
 */
export async function reservePlatformOutgoing(kind: 'sms' | 'email'): Promise<void> {
  const cfg = await readMessagingGuardConfig();
  if (!cfg.enabled) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Messaging has been disabled by a platform administrator.',
    );
  }
  const limit = kind === 'sms' ? cfg.dailySmsLimit : cfg.dailyEmailLimit;
  const today = utcDateKey();
  const rollupRef = ROLLUP_DOC();

  await admin.firestore().runTransaction(async (txn) => {
    const snap = await txn.get(rollupRef);
    const data = snap.data() || {};
    let smsSent = 0;
    let emailSent = 0;
    if (data.date === today) {
      smsSent = Number(data.smsSent) || 0;
      emailSent = Number(data.emailSent) || 0;
    }
    if (kind === 'sms') {
      if (smsSent >= limit) {
        throw new functions.https.HttpsError(
          'resource-exhausted',
          'Daily platform SMS limit reached. If this was unexpected, check the Super Admin messaging panel.',
        );
      }
      smsSent += 1;
    } else {
      if (emailSent >= limit) {
        throw new functions.https.HttpsError(
          'resource-exhausted',
          'Daily platform email limit reached. If this was unexpected, check the Super Admin messaging panel.',
        );
      }
      emailSent += 1;
    }
    txn.set(
      rollupRef,
      {
        date: today,
        smsSent,
        emailSent,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  });
}

/** Best-effort undo when SendGrid/Twilio fails after a reservation. */
export async function releasePlatformOutgoing(kind: 'sms' | 'email'): Promise<void> {
  const today = utcDateKey();
  const rollupRef = ROLLUP_DOC();
  await admin.firestore().runTransaction(async (txn) => {
    const snap = await txn.get(rollupRef);
    const data = snap.data();
    if (!data || data.date !== today) return;
    const smsSent = Math.max(0, (Number(data.smsSent) || 0) - (kind === 'sms' ? 1 : 0));
    const emailSent = Math.max(0, (Number(data.emailSent) || 0) - (kind === 'email' ? 1 : 0));
    txn.set(
      rollupRef,
      {
        date: today,
        smsSent,
        emailSent,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  });
}

import * as admin from 'firebase-admin';
import { isFeatureFlagEnabled } from './featureFlags';
import {
  decideSharedNumberSend,
  SharedNumberDecision,
} from './sharedNumberPolicy';

/**
 * Gathers the live inputs the shared-number policy needs, and counts what a
 * facility has already sent on that number this month.
 *
 * Kept apart from the rule itself so the rule stays testable without Firestore.
 */

/** One facility's ceiling on the shared number, per calendar month. */
const DEFAULT_SHARED_MONTHLY_CAP = 500;

function monthKey(now: Date): string {
  return `${now.getFullYear()}-${(now.getMonth() + 1).toString().padStart(2, '0')}`;
}

function sharedUsageRef(facilityId: string, now: Date) {
  return admin
    .firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('smsUsage')
    .doc(monthKey(now));
}

/**
 * Reads the platform-wide cap, so it can be raised without a deploy when the
 * toll-free's registered volume is raised.
 */
async function readSharedMonthlyCap(): Promise<number> {
  try {
    const doc = await admin.firestore().collection('appConfig').doc('outbound').get();
    const value = Number(doc.data()?.sharedNumberMonthlyCapPerFacility);
    if (Number.isFinite(value) && value > 0) return value;
  } catch {
    // Fall through to the default: a missing config must not stop sending.
  }
  return DEFAULT_SHARED_MONTHLY_CAP;
}

export async function evaluateSharedNumberSend(params: {
  facilityId: string;
  facilityData: Record<string, any>;
  usesOwnNumber: boolean;
  now?: Date;
}): Promise<SharedNumberDecision> {
  const { facilityId, facilityData, usesOwnNumber } = params;
  const now = params.now ?? new Date();

  if (usesOwnNumber) {
    return { allowed: true };
  }

  const accountId = facilityData?.facilityCreatorAccountId as string | undefined;
  let inTrial = false;
  if (accountId) {
    try {
      const accountDoc = await admin
        .firestore()
        .collection('facilityCreatorAccounts')
        .doc(accountId)
        .get();
      const status = String(accountDoc.data()?.subscriptionStatus ?? '').toLowerCase();
      inTrial = status === 'trialing';
    } catch {
      // An account we cannot read is treated as in trial: refusing to send
      // because of our own read failure would be the worse mistake.
      inTrial = true;
    }
  } else {
    inTrial = true;
  }

  const [registrationAvailable, sharedMonthlyCap, usageDoc] = await Promise.all([
    isFeatureFlagEnabled('TEXTING_ONBOARDING_V1'),
    readSharedMonthlyCap(),
    sharedUsageRef(facilityId, now).get(),
  ]);

  const sharedSendsThisMonth = Number(usageDoc.data()?.sharedNumberSends) || 0;

  return decideSharedNumberSend({
    usesOwnNumber: false,
    a2pStatus: facilityData?.a2pStatus as string | undefined,
    registrationAvailable,
    inTrial,
    sharedSendsThisMonth,
    sharedMonthlyCap,
  });
}

/**
 * Counts one message against the facility's shared-number allowance.
 *
 * Called after the message is accepted by Twilio, so a failed send does not
 * consume somebody's month.
 */
export async function recordSharedNumberSend(facilityId: string, now: Date = new Date()): Promise<void> {
  try {
    await sharedUsageRef(facilityId, now).set(
      {
        sharedNumberSends: admin.firestore.FieldValue.increment(1),
        sharedNumberMonth: monthKey(now),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  } catch {
    // Counting is not worth failing a message that has already gone out.
  }
}

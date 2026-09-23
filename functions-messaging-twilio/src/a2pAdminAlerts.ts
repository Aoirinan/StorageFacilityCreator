import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { getSuperAdminEmails, getSgMail, initializeSendGrid, isSuperAdmin } from '@sfc/functions-shared';
import { isTwilioDryRunEnabled } from './twilioClient';
import { SENDGRID_FROM_EMAIL, SENDGRID_FROM_NAME, SENDGRID_SECRETS } from './secrets';

/**
 * Email the super admins when a facility's texting registration moves.
 *
 * Every registration is created under the platform's Twilio account, but
 * nothing told the platform when an owner submitted one or when carriers ruled
 * on it: Twilio's own review mail goes to the account owner without saying
 * which facility it is about, and the product only showed the result on that
 * facility's Texting page. A carrier approval also does nothing for the owner
 * until a super admin grants platform approval, so an unnoticed approval
 * leaves an owner waiting on us.
 *
 * This watches the facility document rather than the code paths that change
 * it, so the hourly poll, the owner's refresh button and the submit callable
 * are all covered. Mail goes to super admins only, never to the owner, and
 * each event is also recorded in `platformA2PEvents` for the super-admin
 * Messaging tab.
 */

type FacilityData = Record<string, any>;

export type A2PAdminAlert = {
  kind:
    | 'bundle_failed_check'
    | 'bundle_submitted'
    | 'bundle_approved'
    | 'bundle_rejected'
    | 'campaign_submitted'
    | 'campaign_approved'
    | 'campaign_rejected';
  headline: string;
  detail: string[];
};

function lower(value: unknown): string {
  return String(value ?? '').trim().toLowerCase();
}

function text(value: unknown): string {
  return String(value ?? '').trim();
}

function bundleRejected(data: FacilityData): boolean {
  return (
    lower(data.a2pBundleProfileStatus) === 'twilio-rejected' ||
    lower(data.a2pBundleProductStatus) === 'twilio-rejected'
  );
}

/**
 * The registration events between two versions of a facility document, in the
 * order they happen. Empty when nothing an admin needs to hear about changed.
 */
export function describeA2PTransition(before: FacilityData, after: FacilityData): A2PAdminAlert[] {
  const alerts: A2PAdminAlert[] = [];

  // Business profile (TrustHub bundle). Saving compliant details submits the
  // bundle for Twilio review in the same call and sets a2pBundleReady.
  const issues = text(after.a2pBundleIssues);
  if (after.a2pBundleReady === false && issues && issues !== text(before.a2pBundleIssues)) {
    alerts.push({
      kind: 'bundle_failed_check',
      headline: "Business details failed Twilio's pre-check",
      detail: [
        'The owner saved business details, but Twilio flagged problems before review, so nothing was submitted and no fee was charged.',
        `Twilio said: ${issues}`,
        'The owner sees this on their Texting page and needs to correct it.',
      ],
    });
  }
  if (after.a2pBundleReady === true && before.a2pBundleReady !== true) {
    alerts.push({
      kind: 'bundle_submitted',
      headline: 'Business profile submitted to Twilio',
      detail: [
        'The owner saved business details that passed the pre-check and the profile went to Twilio for review (typically about a business day).',
        'Twilio console: Trust Hub > Customer Profiles.',
      ],
    });
  }
  if (after.a2pBundleApproved === true && before.a2pBundleApproved !== true) {
    alerts.push({
      kind: 'bundle_approved',
      headline: 'Business profile approved by Twilio',
      detail: ['The owner can now submit the brand and campaign from their Texting page.'],
    });
  }
  if (bundleRejected(after) && !bundleRejected(before)) {
    alerts.push({
      kind: 'bundle_rejected',
      headline: 'Business profile rejected by Twilio',
      detail: [
        `Profile: ${lower(after.a2pBundleProfileStatus) || 'unknown'}, product: ${lower(after.a2pBundleProductStatus) || 'unknown'}.`,
        'Twilio console: Trust Hub > Customer Profiles shows the reason. The owner has to correct the details and save again.',
      ],
    });
  }

  // Brand and campaign (carrier review).
  const status = lower(after.a2pStatus);
  if (status !== lower(before.a2pStatus)) {
    if (status === 'submitted') {
      alerts.push({
        kind: 'campaign_submitted',
        headline: 'Brand and campaign submitted to carriers',
        detail: [
          'Carrier review usually takes 1-5 business days. The hourly poll will pick up the outcome.',
          'Twilio console: Messaging > Regulatory Compliance.',
        ],
      });
    } else if (status === 'approved') {
      alerts.push({
        kind: 'campaign_approved',
        headline: 'Carriers approved texting - platform approval needed',
        detail: [
          'Texting from their own number stays off until a super admin turns on platform approval.',
          "Approve it from the super admin panel > Messaging > Texting registrations, or on the facility's Settings > Texting page.",
        ],
      });
    } else if (status === 'rejected') {
      alerts.push({
        kind: 'campaign_rejected',
        headline: 'Carriers rejected the texting registration',
        detail: [
          `Reason: ${text(after.a2pRejectionReason) || 'not given'}`,
          'The owner sees the reason on their Texting page and can fix and resubmit, which restarts review.',
        ],
      });
    }
  }

  return alerts;
}

export function buildA2PAdminAlertEmail(
  facilityId: string,
  facility: FacilityData,
  alerts: A2PAdminAlert[],
): { subject: string; text: string } {
  const name = text(facility.name) || facilityId;
  const legalName = text(facility.textingBusinessData?.legalBusinessName);
  const subject =
    alerts.length === 1
      ? `[SFC] Texting: ${alerts[0].headline} - ${name}`
      : `[SFC] Texting: ${alerts.length} registration updates - ${name}`;
  const lines = [
    `Facility: ${name}`,
    ...(legalName ? [`Legal business name: ${legalName}`] : []),
    `Facility ID: ${facilityId}`,
    '',
  ];
  for (const alert of alerts) {
    lines.push(alert.headline, ...alert.detail.map((d) => `- ${d}`), '');
  }
  lines.push('Notes: docs/TWILIO_SENDER_REGISTRATION.md in the repo');
  return { subject, text: lines.join('\n') };
}

/** Where each registration event is recorded for the super-admin panel. */
export const A2P_EVENTS_COLLECTION = 'platformA2PEvents';

export const notifyAdminsOfA2PChanges = functions
  .runWith({ secrets: SENDGRID_SECRETS, timeoutSeconds: 60, memory: '256MB' })
  .firestore.document('facilities/{facilityId}')
  .onUpdate(async (change, context) => {
    const before = change.before.data() || {};
    const after = change.after.data() || {};
    const alerts = describeA2PTransition(before, after);
    if (alerts.length === 0) return null;

    const facilityId = context.params.facilityId as string;
    const email = buildA2PAdminAlertEmail(facilityId, after, alerts);

    // Triggers are delivered at least once. Keying the record on the event ID
    // and creating it before sending keeps a redelivered event from emailing
    // twice; the same record is what the super-admin panel lists.
    const record = admin.firestore().collection(A2P_EVENTS_COLLECTION).doc(context.eventId);
    try {
      await record.create({
        facilityId,
        facilityName: text(after.name) || null,
        legalBusinessName: text(after.textingBusinessData?.legalBusinessName) || null,
        a2pStatus: lower(after.a2pStatus) || null,
        alerts,
        subject: email.subject,
        emailStatus: 'pending',
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } catch (err: any) {
      if (err?.code === 6 || err?.code === 'already-exists') return null;
      throw err;
    }

    const kinds = alerts.map((a) => a.kind);
    if (isTwilioDryRunEnabled()) {
      functions.logger.info('[a2pAdminAlerts] dry-run; not emailing', { facilityId, kinds });
      await record.update({ emailStatus: 'skipped', emailError: 'Twilio dry-run is enabled' });
      return null;
    }

    const to = getSuperAdminEmails();
    if (to.length === 0) {
      functions.logger.warn('[a2pAdminAlerts] no super admin emails configured; alert not sent', { facilityId });
      await record.update({ emailStatus: 'skipped', emailError: 'No super admin emails configured' });
      return null;
    }

    try {
      initializeSendGrid();
      const sgMail = getSgMail() as { send: (msg: unknown) => Promise<unknown> };
      await sgMail.send({
        to,
        from: { email: SENDGRID_FROM_EMAIL.value(), name: SENDGRID_FROM_NAME.value() || 'Storage Facility Creator' },
        subject: email.subject,
        text: email.text,
      });
      await record.update({ emailStatus: 'sent', sentAt: admin.firestore.FieldValue.serverTimestamp() });
      functions.logger.info('[a2pAdminAlerts] sent', { facilityId, kinds });
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : String(err);
      functions.logger.error('[a2pAdminAlerts] email failed', { facilityId, message });
      await record.update({ emailStatus: 'failed', emailError: message }).catch(() => undefined);
    }
    return null;
  });

/**
 * Super-admin list of recent registration events, newest first. Read through
 * a callable rather than Firestore rules so the collection stays closed to
 * every client.
 */
export const listA2PAdminEvents = functions.https.onCall(async (data: { limit?: number }, context) => {
  if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  if (!isSuperAdmin(context.auth.token?.email as string | undefined)) {
    throw new functions.https.HttpsError('permission-denied', 'Only super admins can list texting registration events');
  }
  const limit = Math.min(Math.max(Number(data?.limit) || 50, 1), 200);
  const snap = await admin
    .firestore()
    .collection(A2P_EVENTS_COLLECTION)
    .orderBy('createdAt', 'desc')
    .limit(limit)
    .get();
  return {
    events: snap.docs.map((doc) => {
      const d = doc.data();
      return {
        id: doc.id,
        facilityId: d.facilityId ?? null,
        facilityName: d.facilityName ?? null,
        legalBusinessName: d.legalBusinessName ?? null,
        a2pStatus: d.a2pStatus ?? null,
        alerts: Array.isArray(d.alerts) ? d.alerts : [],
        emailStatus: d.emailStatus ?? null,
        emailError: d.emailError ?? null,
        createdAtMs: d.createdAt?.toMillis?.() ?? null,
      };
    }),
  };
});

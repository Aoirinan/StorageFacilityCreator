import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import {
  buildFacilityDisconnectUpdate,
  buildOffboardedEmail,
  buildOffboardingAdminSummaryEmail,
  buildOffboardingNoticeEmail,
  buildTenantPiiRedaction,
  deauthorizeConnectedAccount,
  getPublicAppUrl,
  getSgMail,
  getStripeClient,
  anyCancelFailed,
  cancelSubscriptions,
  collectSubscriptionsToCancel,
  summarizeCancelOutcomes,
  getSuperAdminEmails,
  initializeSendGrid,
  isOrphanedConnectedAccount,
  isOwnerOnboardingEmailAllowed,
  offboardingDueAt,
  selectFacilitiesForOffboarding,
  sweepSummaryHasActivity,
  type EmailContent,
  type FacilityDisconnectReason,
  type OffboardingCandidate,
  type OffboardingSweepSummary,
} from '@sfc/functions-shared';
import {
  SENDGRID_FROM_EMAIL,
  SENDGRID_FROM_NAME,
  SENDGRID_SECRETS,
  STRIPE_CONNECT_CLIENT_ID,
  STRIPE_SECRETS_WITH_CONNECT,
} from './secrets';

const TENANT_SUBCOLLECTIONS = ['tenants', 'oldTenants'] as const;
const MAX_CONNECTED_ACCOUNTS_PER_SWEEP = 1000;

/**
 * Pre-launch rule: no email or text reaches a customer until the build is
 * done. Owner-facing offboarding mail is therefore off unless
 * appConfig/offboarding.ownerEmailsEnabled is true. While it is off, the
 * removal step is paused too: a facility must never lose its tenant data
 * without having been told first. The super-admin summary is unaffected.
 */
async function ownerEmailsEnabled(): Promise<boolean> {
  try {
    const doc = await admin.firestore().collection('appConfig').doc('offboarding').get();
    return doc.exists && doc.get('ownerEmailsEnabled') === true;
  } catch (error) {
    functions.logger.warn('Could not read appConfig/offboarding; treating owner emails as off', {
      error: errorMessage(error),
    });
    return false;
  }
}

function toDate(value: unknown): Date | null {
  if (!value) return null;
  if (value instanceof Date) return value;
  if (typeof (value as { toDate?: () => Date }).toDate === 'function') {
    return (value as { toDate: () => Date }).toDate();
  }
  return null;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

async function deauthorizeIfConfigured(accountId: string, logContext: Record<string, unknown>) {
  const clientId = STRIPE_CONNECT_CLIENT_ID.value().trim();
  if (!clientId) {
    functions.logger.error('STRIPE_CONNECT_CLIENT_ID missing; cannot deauthorize', { accountId, ...logContext });
    return 'skipped' as const;
  }
  return deauthorizeConnectedAccount(getStripeClient(), clientId, accountId);
}

/**
 * The owner is a platform user, not a tenant, so their address comes from
 * Firebase Auth. Facility-level contact fields are the fallback for older
 * records whose owner user has been removed.
 */
async function resolveOwnerContact(
  facility: Record<string, unknown>,
): Promise<{ email: string | null; name: string | null }> {
  const ownerUid = ((facility.ownerUid as string | undefined) || '').trim();
  if (ownerUid) {
    try {
      const user = await admin.auth().getUser(ownerUid);
      if (user.email) return { email: user.email, name: user.displayName || null };
    } catch (error) {
      functions.logger.warn('Owner lookup failed for offboarding email', { ownerUid, error: errorMessage(error) });
    }
  }
  const fallback =
    (facility.ownerEmail as string | undefined) ||
    (facility.contactEmail as string | undefined) ||
    (facility.email as string | undefined) ||
    null;
  return { email: fallback, name: null };
}

/**
 * Transactional platform mail (no unsubscribe group): the owner must get these.
 *
 * Still behind the pre-launch owner gate, which is the same switch the
 * onboarding mail uses. Before launch the only owners are test accounts and
 * they are allowlisted, so nothing real is withheld; after launch
 * ownerEmailsEnabled opens it for everyone. Without this an offboarding notice
 * was the one platform-to-owner mail that could go out while the rule said no
 * customer hears from us yet.
 */
async function sendPlatformEmail(to: string, content: EmailContent): Promise<void> {
  if (!(await isOwnerOnboardingEmailAllowed(to))) {
    functions.logger.info('Skipped offboarding email (pre-launch owner gate)', {
      subject: content.subject,
    });
    return;
  }
  initializeSendGrid();
  await (getSgMail() as { send: (msg: unknown) => Promise<unknown> }).send({
    to,
    from: { email: SENDGRID_FROM_EMAIL.value(), name: SENDGRID_FROM_NAME.value() },
    subject: content.subject,
    html: content.html,
    text: content.text,
  });
}

function emailInput(facility: Record<string, unknown>, ownerName: string | null, offboardingDate: Date) {
  return {
    facilityName: (facility.name as string | undefined) || 'your facility',
    ownerName,
    offboardingDate,
    appUrl: getPublicAppUrl(),
    supportEmail: SENDGRID_FROM_EMAIL.value(),
  };
}

/**
 * Blank tenant PII for one offboarded facility. Saved payment-method records
 * are removed too: they hold the Stripe customer and payment-method ids that
 * only make sense while the platform can still reach the connected account.
 */
async function redactFacilityTenants(facilityId: string, reason: FacilityDisconnectReason): Promise<number> {
  const db = admin.firestore();
  const facilityRef = db.collection('facilities').doc(facilityId);
  let redacted = 0;
  for (const sub of TENANT_SUBCOLLECTIONS) {
    const tenants = await facilityRef.collection(sub).get();
    for (const tenantDoc of tenants.docs) {
      if (tenantDoc.data().piiRedactedAt) continue;
      const batch = db.batch();
      batch.update(
        tenantDoc.ref,
        buildTenantPiiRedaction({ reason, now: admin.firestore.FieldValue.serverTimestamp() }),
      );
      const paymentMethods = await tenantDoc.ref.collection('paymentMethods').get();
      for (const pm of paymentMethods.docs) batch.delete(pm.ref);
      const billing = await tenantDoc.ref.collection('billing').get();
      for (const b of billing.docs) {
        batch.update(b.ref, {
          autopayEnabled: false,
          stripeSubscriptionId: null,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
      await batch.commit();
      redacted += 1;
    }
  }
  return redacted;
}

/**
 * Tell the owner once, at the start of the grace period, what will happen and
 * when. Idempotent through offboardingNoticeSentAt.
 */
async function sendOffboardingNoticeIfNeeded(
  facilityId: string,
  cancelledAtFallback: Date,
  summary: OffboardingSweepSummary,
): Promise<void> {
  const facilityRef = admin.firestore().collection('facilities').doc(facilityId);
  const snap = await facilityRef.get();
  if (!snap.exists) return;
  const data = snap.data() || {};
  if (data.offboardingNoticeSentAt) return;

  const cancelledAt = toDate(data.platformSubscriptionCancelledAt) || cancelledAtFallback;
  const offboardingDate = offboardingDueAt(cancelledAt);
  const owner = await resolveOwnerContact(data);
  if (!owner.email) {
    summary.errors.push({ where: `notice ${facilityId}`, message: 'no owner email on file' });
    return;
  }
  await sendPlatformEmail(owner.email, buildOffboardingNoticeEmail(emailInput(data, owner.name, offboardingDate)));
  await facilityRef.update({ offboardingNoticeSentAt: admin.firestore.FieldValue.serverTimestamp() });
  summary.noticesSent.push({
    facilityId,
    facilityName: (data.name as string | undefined) || facilityId,
    offboardingDate,
  });
  functions.logger.info('Offboarding notice sent', { facilityId, offboardingDate: offboardingDate.toISOString() });
}

async function offboardCancelledFacility(facilityId: string, summary: OffboardingSweepSummary): Promise<void> {
  const db = admin.firestore();
  const facilityRef = db.collection('facilities').doc(facilityId);
  const snap = await facilityRef.get();
  if (!snap.exists) return;
  const data = snap.data() || {};
  const accountId = (data.stripeConnectAccountId as string | undefined) || null;
  const reason: FacilityDisconnectReason = 'subscription_cancelled';

  let stripeResult: 'deauthorized' | 'already_disconnected' | 'skipped' = 'skipped';
  if (accountId) {
    stripeResult = await deauthorizeIfConfigured(accountId, { facilityId });
    if (stripeResult === 'skipped') {
      // Do not redact or mark offboarded while the platform still holds access;
      // the next sweep retries once the secret is configured.
      summary.errors.push({ where: `offboard ${facilityId}`, message: 'STRIPE_CONNECT_CLIENT_ID not configured' });
      return;
    }
  }

  // Stop billing the owner for a facility whose data we are about to strip.
  // Nothing else in this sweep did, so a customer who left kept paying.
  const subscriptions = collectSubscriptionsToCancel(data, null);
  if (subscriptions.length > 0) {
    const outcomes = await cancelSubscriptions(getStripeClient(), subscriptions);
    functions.logger.info('Cancelled subscriptions during offboarding', {
      facilityId,
      outcomes: summarizeCancelOutcomes(outcomes),
    });
    if (anyCancelFailed(outcomes)) {
      // Leave the facility intact and retry next run. Redacting tenant data
      // while the card is still being charged is the worst of both.
      summary.errors.push({
        where: `offboard ${facilityId}`,
        message: `subscription cancel failed: ${summarizeCancelOutcomes(outcomes)}`,
      });
      return;
    }
  }

  await facilityRef.update({
    ...buildFacilityDisconnectUpdate({
      accountId,
      reason,
      now: admin.firestore.FieldValue.serverTimestamp(),
    }),
    offboardedAt: admin.firestore.FieldValue.serverTimestamp(),
    offboardingReason: reason,
  });
  const redacted = await redactFacilityTenants(facilityId, reason);
  const facilityName = (data.name as string | undefined) || facilityId;
  summary.offboarded.push({ facilityId, facilityName, tenantsRedacted: redacted, stripe: stripeResult });
  functions.logger.info('Facility offboarded', { facilityId, accountId, stripe: stripeResult, tenantsRedacted: redacted });

  const owner = await resolveOwnerContact(data);
  if (!owner.email) {
    summary.errors.push({ where: `offboarded email ${facilityId}`, message: 'no owner email on file' });
    return;
  }
  await sendPlatformEmail(owner.email, buildOffboardedEmail(emailInput(data, owner.name, summary.runAt)));
  await facilityRef.update({ offboardedNoticeSentAt: admin.firestore.FieldValue.serverTimestamp() });
}

/**
 * Connected accounts created by this platform carry metadata.facilityId. Any
 * whose facility document is gone (client-side deletes bypass every function)
 * get detached so the platform key can no longer act on them.
 */
async function sweepOrphanedConnectedAccounts(summary: OffboardingSweepSummary): Promise<number> {
  const stripe = getStripeClient();
  const db = admin.firestore();
  let scanned = 0;
  for await (const account of stripe.accounts.list({ limit: 100 })) {
    scanned += 1;
    if (scanned > MAX_CONNECTED_ACCOUNTS_PER_SWEEP) {
      functions.logger.warn('Orphan sweep stopped at cap; raise MAX_CONNECTED_ACCOUNTS_PER_SWEEP or paginate by cursor');
      break;
    }
    const facilityId = account.metadata?.facilityId;
    if (!facilityId) continue;
    const facilitySnap = await db.collection('facilities').doc(facilityId).get();
    if (!isOrphanedConnectedAccount(account, facilitySnap.exists)) continue;
    try {
      const result = await deauthorizeIfConfigured(account.id, { facilityId, orphan: true });
      if (result !== 'skipped') summary.orphansDetached.push({ accountId: account.id, facilityId });
      functions.logger.info('Orphaned connected account detached', { accountId: account.id, facilityId, result });
    } catch (error) {
      summary.errors.push({ where: `orphan ${account.id}`, message: errorMessage(error) });
      functions.logger.error('Failed to detach orphaned connected account', {
        accountId: account.id,
        facilityId,
        error: errorMessage(error),
      });
    }
  }
  return scanned;
}

async function emailSuperAdmins(summary: OffboardingSweepSummary): Promise<void> {
  if (!sweepSummaryHasActivity(summary)) return;
  const content = buildOffboardingAdminSummaryEmail(summary);
  for (const to of getSuperAdminEmails()) {
    try {
      await sendPlatformEmail(to, content);
    } catch (error) {
      functions.logger.error('Failed to send offboarding summary', { to, error: errorMessage(error) });
    }
  }
}

/**
 * Daily: offboard facilities whose platform subscription has been cancelled
 * for the grace period (detach Stripe, blank tenant PII, drop saved cards),
 * detach Connect accounts whose facility no longer exists, tell the owners
 * at each step, and tell the super admins on nights something happened.
 */
export const processFacilityOffboarding = functions
  .runWith({ secrets: [...STRIPE_SECRETS_WITH_CONNECT, ...SENDGRID_SECRETS], timeoutSeconds: 540, memory: '512MB' })
  .pubsub.schedule('0 6 * * *') // Daily at 6:00 AM UTC
  .timeZone('UTC')
  .onRun(async () => {
    const db = admin.firestore();
    const now = new Date();
    const summary: OffboardingSweepSummary = {
      runAt: now,
      noticesSent: [],
      offboarded: [],
      orphansDetached: [],
      waiting: 0,
      errors: [],
    };

    const cancelled = await db
      .collection('facilities')
      .where('platformSubscriptionStatus', '==', 'cancelled')
      .get();

    const candidates: OffboardingCandidate[] = cancelled.docs.map((doc) => {
      const data = doc.data();
      return {
        id: doc.id,
        platformSubscriptionStatus: data.platformSubscriptionStatus,
        platformSubscriptionCancelledAt: toDate(data.platformSubscriptionCancelledAt),
        offboardedAt: toDate(data.offboardedAt),
      };
    });
    const selection = selectFacilitiesForOffboarding(candidates, now);
    summary.waiting = selection.waiting.length + selection.needsClockStart.length;

    // Facilities cancelled before this job existed have no timestamp; start
    // their grace period today rather than offboarding them without warning.
    for (const facilityId of selection.needsClockStart) {
      await db.collection('facilities').doc(facilityId).update({
        platformSubscriptionCancelledAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    const customerMailAllowed = await ownerEmailsEnabled();
    if (!customerMailAllowed) {
      functions.logger.info('Owner emails are off (appConfig/offboarding.ownerEmailsEnabled); notices and removals paused', {
        waiting: selection.waiting.length + selection.needsClockStart.length,
        due: selection.due.length,
      });
      summary.pausedDue = [...selection.due];
    }

    if (customerMailAllowed) {
      for (const facilityId of [...selection.needsClockStart, ...selection.waiting]) {
        try {
          await sendOffboardingNoticeIfNeeded(facilityId, now, summary);
        } catch (error) {
          summary.errors.push({ where: `notice ${facilityId}`, message: errorMessage(error) });
          functions.logger.error('Offboarding notice failed', { facilityId, error: errorMessage(error) });
        }
      }

      for (const facilityId of selection.due) {
        try {
          await offboardCancelledFacility(facilityId, summary);
        } catch (error) {
          summary.errors.push({ where: `offboard ${facilityId}`, message: errorMessage(error) });
          functions.logger.error('Facility offboarding failed', { facilityId, error: errorMessage(error) });
        }
      }
    }

    let orphanAccountsScanned = 0;
    try {
      orphanAccountsScanned = await sweepOrphanedConnectedAccounts(summary);
    } catch (error) {
      summary.errors.push({ where: 'orphan sweep', message: errorMessage(error) });
      functions.logger.error('Orphaned connected account sweep failed', { error: errorMessage(error) });
    }

    await emailSuperAdmins(summary);

    functions.logger.info('Facility offboarding sweep complete', {
      cancelledFacilities: cancelled.size,
      clockStarted: selection.needsClockStart.length,
      noticesSent: summary.noticesSent.length,
      waiting: summary.waiting,
      due: selection.due.length,
      offboarded: summary.offboarded.length,
      orphanAccountsScanned,
      orphanAccountsDetached: summary.orphansDetached.length,
      errors: summary.errors.length,
    });
    return null;
  });

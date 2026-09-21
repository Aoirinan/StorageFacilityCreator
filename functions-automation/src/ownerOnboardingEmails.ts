import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

import {
  buildAccountApprovedEmail,
  buildAccountUnderReviewEmail,
  buildNewAccountAdminAlertEmail,
  getPublicAppUrl,
  getSgMail,
  initializeSendGrid,
  isOwnerOnboardingEmailAllowed,
} from '@sfc/functions-shared';
import { getSuperAdminEmails } from '@sfc/functions-shared/auth/superAdmin';

import { SENDGRID_FROM_EMAIL, SENDGRID_FROM_NAME, SENDGRID_SECRETS } from './secrets';

/**
 * Automated onboarding mail for facility owners.
 *
 * Before this existed, a new owner heard nothing after signing up and nothing
 * when they were approved, and whoever ran the platform only discovered a
 * pending account by opening Platform Control and noticing a banner. The
 * pending-approval screen in the app has always promised "You receive an
 * approval email"; this is that email.
 *
 * Every send is recorded in the top-level `platformEmailLogs` collection,
 * including the ones the pre-launch gate suppresses, so the super admin can
 * see what did and did not go out. Facility `messageLogs` cannot be used: a
 * brand new owner has no facility to hang a log under.
 */

/** Pricing shown to owners. Kept in step with marketing/src/config/site.ts. */
const PRICE_MONTHLY = 75;
const ONLINE_RENTALS_ADDON_MONTHLY = 25;
const SUPPORT_PHONE = '855-526-4544';

/**
 * `ownerName` defaults to this placeholder when an account document is created,
 * so it must never reach a greeting: "Hi Facility," helps nobody.
 */
const PLACEHOLDER_OWNER_NAME = 'facility creator';

export type OnboardingEmailType = 'account_under_review' | 'account_approved' | 'new_account_admin_alert';

interface EmailContent {
  subject: string;
  html: string;
  text: string;
}

interface PlatformEmailLogEntry {
  accountId: string;
  ownerUid: string | null;
  ownerEmail: string;
  ownerName: string | null;
  type: OnboardingEmailType;
  to: string;
  subject: string;
  previewText: string;
  status: 'sent' | 'failed' | 'skipped';
  skippedReason: string | null;
  provider: 'sendgrid';
  providerMessageId: string | null;
  errorMessage: string | null;
  trigger: 'automatic' | 'resend';
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** Transactional platform mail: no unsubscribe group, the owner must get these. */
async function sendPlatformEmail(to: string, content: EmailContent): Promise<string | null> {
  initializeSendGrid();
  const [result] = (await (getSgMail() as {
    send: (msg: unknown) => Promise<Array<{ headers?: Record<string, string> }>>;
  }).send({
    to,
    from: { email: SENDGRID_FROM_EMAIL.value(), name: SENDGRID_FROM_NAME.value() },
    subject: content.subject,
    html: content.html,
    text: content.text,
  })) || [];
  return (result?.headers?.['x-message-id'] as string) || null;
}

async function writePlatformEmailLog(entry: PlatformEmailLogEntry): Promise<void> {
  try {
    await admin.firestore().collection('platformEmailLogs').add({
      ...entry,
      channel: 'email',
      direction: 'outbound',
      source: 'automation',
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      sentAt: entry.status === 'sent' ? admin.firestore.FieldValue.serverTimestamp() : null,
    });
  } catch (error) {
    // A logging failure must never cost the owner their email.
    functions.logger.error('Could not write platformEmailLogs entry', {
      accountId: entry.accountId,
      type: entry.type,
      error: errorMessage(error),
    });
  }
}

function previewOf(text: string): string {
  return text.replace(/\s+/g, ' ').trim().substring(0, 200);
}

/**
 * Sends one onboarding email and records the outcome. Owner-facing mail runs
 * through the pre-launch gate; a suppressed message is logged as 'skipped' so
 * it is visible rather than silently absent.
 */
async function deliver(params: {
  accountId: string;
  ownerUid: string | null;
  ownerEmail: string;
  ownerName: string | null;
  type: OnboardingEmailType;
  to: string;
  content: EmailContent;
  gated: boolean;
  trigger: 'automatic' | 'resend';
}): Promise<boolean> {
  const base = {
    accountId: params.accountId,
    ownerUid: params.ownerUid,
    ownerEmail: params.ownerEmail,
    ownerName: params.ownerName,
    type: params.type,
    to: params.to,
    subject: params.content.subject,
    previewText: previewOf(params.content.text),
    provider: 'sendgrid' as const,
    trigger: params.trigger,
  };

  if (params.gated && !(await isOwnerOnboardingEmailAllowed(params.to))) {
    functions.logger.info('Owner onboarding email suppressed by pre-launch gate', {
      accountId: params.accountId,
      type: params.type,
    });
    await writePlatformEmailLog({
      ...base,
      status: 'skipped',
      skippedReason: 'prelaunch_gate',
      providerMessageId: null,
      errorMessage: null,
    });
    return false;
  }

  try {
    const providerMessageId = await sendPlatformEmail(params.to, params.content);
    await writePlatformEmailLog({
      ...base,
      status: 'sent',
      skippedReason: null,
      providerMessageId,
      errorMessage: null,
    });
    return true;
  } catch (error) {
    functions.logger.error('Owner onboarding email failed', {
      accountId: params.accountId,
      type: params.type,
      error: errorMessage(error),
    });
    await writePlatformEmailLog({
      ...base,
      status: 'failed',
      skippedReason: null,
      providerMessageId: null,
      errorMessage: errorMessage(error),
    });
    return false;
  }
}

/**
 * The account document's `ownerName` is a placeholder on create, and the auth
 * record often has no display name, so try every source before giving up and
 * letting the greeting fall back to a plain "Hi,".
 */
async function resolveOwnerName(
  accountData: Record<string, unknown>,
  ownerUid: string | null,
): Promise<string | null> {
  const fromAccount = String(accountData.ownerName ?? '').trim();
  if (fromAccount && fromAccount.toLowerCase() !== PLACEHOLDER_OWNER_NAME) return fromAccount;

  if (ownerUid) {
    try {
      const user = await admin.auth().getUser(ownerUid);
      const displayName = (user.displayName || '').trim();
      if (displayName) return displayName;
    } catch {
      // Deleted or unreadable auth user; fall through.
    }
    try {
      const snap = await admin.firestore().collection('users').doc(ownerUid).get();
      const data = snap.data() || {};
      for (const key of ['displayName', 'name', 'fullName', 'ownerName']) {
        const value = String((data as Record<string, unknown>)[key] ?? '').trim();
        if (value) return value;
      }
    } catch {
      // Fall through to null.
    }
  }
  return null;
}

async function resolveOwnerEmail(
  accountData: Record<string, unknown>,
  ownerUid: string | null,
): Promise<string> {
  const fromAccount = String(accountData.ownerEmail ?? '').trim();
  if (fromAccount) return fromAccount;
  if (ownerUid) {
    try {
      const user = await admin.auth().getUser(ownerUid);
      return (user.email || '').trim();
    } catch {
      return '';
    }
  }
  return '';
}

function toDate(value: unknown): Date | null {
  if (!value) return null;
  const ts = value as { toDate?: () => Date };
  if (typeof ts.toDate === 'function') return ts.toDate();
  if (value instanceof Date) return value;
  return null;
}

/**
 * Fires on every write to a platform account. Three things can happen:
 * the account appears (tell the owner it is under review, tell the admins it
 * is waiting), a super admin approves it (send the owner everything they need
 * to get running), or someone asks for a resend from Platform Control.
 *
 * Each send is recorded on the account document so a retried delivery, or a
 * later unrelated edit, cannot mail the same owner twice.
 */
export const onFacilityCreatorAccountWrite = functions
  .runWith({ secrets: SENDGRID_SECRETS, timeoutSeconds: 120, memory: '256MB' })
  .firestore.document('facilityCreatorAccounts/{accountId}')
  .onWrite(async (change, context) => {
    const accountId = context.params.accountId as string;
    if (!change.after.exists) return;

    const after = (change.after.data() || {}) as Record<string, unknown>;
    const before = (change.before.data() || {}) as Record<string, unknown>;
    const wasCreated = !change.before.exists;

    const sentState = (after.onboardingEmails || {}) as Record<string, unknown>;
    const resendType = String(after.onboardingEmailResendType ?? '').trim();
    const resendRequested = Boolean(after.onboardingEmailResendRequestedAt) && resendType.length > 0;

    const beforeStatus = String(before.subscriptionStatus ?? '');
    const afterStatus = String(after.subscriptionStatus ?? '');
    const justApproved = beforeStatus === 'pendingApproval' && afterStatus === 'trialing';

    const needsUnderReview = wasCreated && !sentState.underReviewSentAt;
    const needsAdminAlert = wasCreated && !sentState.adminAlertSentAt;
    const needsApproved = justApproved && !sentState.approvedSentAt;

    if (!needsUnderReview && !needsAdminAlert && !needsApproved && !resendRequested) return;

    const ownerUid = String(after.ownerUid ?? '').trim() || null;
    const ownerEmail = await resolveOwnerEmail(after, ownerUid);
    if (!ownerEmail) {
      functions.logger.warn('Platform account has no owner email; onboarding mail skipped', { accountId });
      return;
    }
    const ownerName = await resolveOwnerName(after, ownerUid);
    const appUrl = getPublicAppUrl();
    const supportEmail = SENDGRID_FROM_EMAIL.value() || 'support@storagefacilitycreator.com';
    const copyInput = { ownerName, appUrl: `${appUrl}/#/login`, supportEmail, supportPhone: SUPPORT_PHONE };

    const marks: Record<string, unknown> = {};

    const sendApproved = async (trigger: 'automatic' | 'resend') => {
      const trialEndDate =
        toDate(after.subscriptionTrialEnd) ?? new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);
      const ok = await deliver({
        accountId,
        ownerUid,
        ownerEmail,
        ownerName,
        type: 'account_approved',
        to: ownerEmail,
        content: buildAccountApprovedEmail({
          ...copyInput,
          trialEndDate,
          priceMonthly: PRICE_MONTHLY,
          onlineRentalsAddonMonthly: ONLINE_RENTALS_ADDON_MONTHLY,
        }),
        gated: true,
        trigger,
      });
      if (ok) marks['onboardingEmails.approvedSentAt'] = admin.firestore.FieldValue.serverTimestamp();
    };

    const sendUnderReview = async (trigger: 'automatic' | 'resend') => {
      const ok = await deliver({
        accountId,
        ownerUid,
        ownerEmail,
        ownerName,
        type: 'account_under_review',
        to: ownerEmail,
        content: buildAccountUnderReviewEmail(copyInput),
        gated: true,
        trigger,
      });
      if (ok) marks['onboardingEmails.underReviewSentAt'] = admin.firestore.FieldValue.serverTimestamp();
    };

    if (needsUnderReview) await sendUnderReview('automatic');

    if (needsAdminAlert) {
      // Internal mail, deliberately not gated: the whole point is that a
      // pending account never again sits unnoticed for hours.
      const content = buildNewAccountAdminAlertEmail({
        ownerName,
        ownerEmail,
        accountId,
        signedUpAt: toDate(after.createdAt) ?? new Date(),
        superAdminUrl: `${appUrl}/#/super-admin`,
      });
      let anyDelivered = false;
      for (const to of getSuperAdminEmails()) {
        const ok = await deliver({
          accountId,
          ownerUid,
          ownerEmail,
          ownerName,
          type: 'new_account_admin_alert',
          to,
          content,
          gated: false,
          trigger: 'automatic',
        });
        anyDelivered = anyDelivered || ok;
      }
      if (anyDelivered) marks['onboardingEmails.adminAlertSentAt'] = admin.firestore.FieldValue.serverTimestamp();
    }

    if (needsApproved) await sendApproved('automatic');

    if (resendRequested) {
      if (resendType === 'account_approved') await sendApproved('resend');
      else if (resendType === 'account_under_review') await sendUnderReview('resend');
      else functions.logger.warn('Unknown onboarding resend type', { accountId, resendType });
      // Clear the request either way, so a bad value cannot wedge the trigger.
      marks.onboardingEmailResendRequestedAt = admin.firestore.FieldValue.delete();
      marks.onboardingEmailResendType = admin.firestore.FieldValue.delete();
    }

    if (Object.keys(marks).length > 0) {
      // This write re-enters the trigger; the marks above are exactly what make
      // the second pass a no-op.
      await change.after.ref.update(marks);
    }
  });

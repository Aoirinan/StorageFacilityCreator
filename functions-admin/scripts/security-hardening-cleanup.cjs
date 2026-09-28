#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const admin = require('firebase-admin');

function parseArgs(argv) {
  const values = new Map();
  for (const arg of argv.slice(2)) {
    if (!arg.startsWith('--')) continue;
    const [key, ...rest] = arg.slice(2).split('=');
    values.set(key, rest.length > 0 ? rest.join('=') : true);
  }
  return values;
}

function randomToken() {
  return crypto.randomBytes(24).toString('hex');
}

function storagePathFromPublicUrl(raw) {
  if (typeof raw !== 'string' || raw.trim() === '') return null;
  try {
    const url = new URL(raw);
    if (url.hostname !== 'storage.googleapis.com') return null;
    const parts = url.pathname.split('/').filter(Boolean);
    if (parts.length < 2) return null;
    return decodeURIComponent(parts.slice(1).join('/'));
  } catch {
    return null;
  }
}

/**
 * Fields a rotated payment link must not inherit. The checkout ones name the
 * old token's Stripe session: the new link would hand that session back, and
 * a payment on it carries the old (now revoked) token, so it is recorded as
 * paid after revoke instead of paying the new link. The new link starts its
 * own checkout.
 */
const LINK_FIELDS_NOT_ROTATED = [
  'checkoutSessionId',
  'checkoutSessionIds',
  'checkoutAttempt',
  'checkoutExpiresAt',
];

function rotatedLinkData(current, replacementToken, rotatedFrom, rotatedAt) {
  const data = { ...current };
  for (const field of LINK_FIELDS_NOT_ROTATED) delete data[field];
  return { ...data, token: replacementToken, rotatedFrom, rotatedAt };
}

/** Every Checkout Session id a link has issued, newest last, without repeats. */
function linkSessionIds(link) {
  const ids = Array.isArray(link.checkoutSessionIds) ? [...link.checkoutSessionIds] : [];
  if (typeof link.checkoutSessionId === 'string' && link.checkoutSessionId) ids.push(link.checkoutSessionId);
  return [...new Set(ids.filter((id) => typeof id === 'string' && id))];
}

function isMissingSession(error) {
  return error && (error.code === 'resource_missing' || error.statusCode === 404);
}

/**
 * Whether a pending link may be rotated, and which of its sessions are
 * still open.
 *
 * Rotation drops the old token's checkout fields, so the new link offers a
 * fresh Pay Now. That is only safe once none of the old sessions can still
 * be, or has already been, paid. A link whose session is complete but not
 * yet marked paid (checkout.session.completed unsubscribed or not yet
 * processed) would otherwise charge the tenant twice. So each session is
 * looked up on the facility's accounts: a complete one skips the link for a
 * person to settle, an open one is expired before rotating, and anything
 * that cannot be checked skips the link rather than guessing.
 *
 * [accountIds] is the facility's current account, then the one it was
 * connected to before (stripeConnectPreviousAccountId). A link started
 * before a reconnect has its sessions on the old account; looked up only on
 * the new one they read as missing, and a paid link was rotated.
 */
async function planLinkRotation(link, { stripe, accountIds }) {
  const sessionIds = linkSessionIds(link);
  if (sessionIds.length === 0) return { rotate: true, openSessions: [] };
  if (!stripe) return { rotate: false, reason: 'stripe_not_checked', sessionIds };
  const accounts = [...new Set((accountIds || []).filter((id) => typeof id === 'string' && id))];
  if (accounts.length === 0) return { rotate: false, reason: 'facility_has_no_stripe_account', sessionIds };
  const openSessions = [];
  for (const id of sessionIds) {
    for (const account of accounts) {
      let session;
      try {
        session = await stripe.checkout.sessions.retrieve(id, {}, { stripeAccount: account });
      } catch (error) {
        // Not on this account: try the other. Missing on every account
        // means there is no session to pay.
        if (isMissingSession(error)) continue;
        return { rotate: false, reason: 'session_lookup_failed', sessionId: id, account, error: String(error && error.message) };
      }
      if (session.status === 'complete' || session.payment_status === 'paid') {
        return { rotate: false, reason: 'session_completed', sessionId: id, account };
      }
      if (session.status === 'open') openSessions.push({ id, account });
      break;
    }
  }
  return { rotate: true, openSessions };
}

/**
 * Rotates every pending link whose token is legacy/predictable, after
 * [planLinkRotation] clears it. Reports every link: rotated, would rotate
 * (dry run), or skipped with the reason. Exported for tests.
 */
async function rotatePendingPaymentLinks({ db, stripe, apply, report, fieldValue, newToken = randomToken }) {
  const pendingLinks = await db.collection('publicPaymentLinks').where('status', '==', 'pending').get();
  const facilityAccounts = new Map();
  for (const doc of pendingLinks.docs) {
    // Current server-generated tokens are 48 lowercase hex characters. Only
    // rotate legacy/predictable tokens so this cleanup remains idempotent.
    if (/^[a-f0-9]{48}$/.test(doc.id)) continue;
    const link = doc.data();
    const facilityId = link.facilityId || null;
    if (facilityId && !facilityAccounts.has(facilityId)) {
      const facility = await db.collection('facilities').doc(facilityId).get();
      facilityAccounts.set(
        facilityId,
        facility.exists ? [facility.get('stripeConnectAccountId'), facility.get('stripeConnectPreviousAccountId')] : [],
      );
    }
    const accountIds = facilityId ? facilityAccounts.get(facilityId) : [];
    const entry = { oldToken: doc.id, facilityId, tenantId: link.tenantId || null };
    const plan = await planLinkRotation(link, { stripe, accountIds });
    if (!plan.rotate) {
      report.paymentLinks.push({ ...entry, action: 'skipped', ...plan });
      continue;
    }
    const openSessionIds = plan.openSessions.map((session) => session.id);

    if (apply) {
      let expireFailure = null;
      for (const session of plan.openSessions) {
        try {
          // On the account the session was found on.
          await stripe.checkout.sessions.expire(session.id, {}, { stripeAccount: session.account });
        } catch (error) {
          // Most likely paid in the meantime: leave the link for a person.
          expireFailure = { sessionId: session.id, error: String(error && error.message) };
          break;
        }
      }
      if (expireFailure) {
        report.paymentLinks.push({ ...entry, action: 'skipped', reason: 'session_expire_failed', ...expireFailure });
        continue;
      }
    }

    const replacementToken = newToken();
    const replacementRef = db.collection('publicPaymentLinks').doc(replacementToken);
    report.paymentLinks.push({
      ...entry,
      action: apply ? 'rotated' : 'would_rotate',
      replacementToken,
      expiredSessionIds: openSessionIds,
    });
    if (apply) {
      await db.runTransaction(async (txn) => {
        const current = await txn.get(doc.ref);
        if (!current.exists || current.get('status') !== 'pending') return;
        txn.create(
          replacementRef,
          rotatedLinkData(current.data(), replacementToken, doc.id, fieldValue.serverTimestamp()),
        );
        txn.update(doc.ref, {
          status: 'revoked',
          revokedAt: fieldValue.serverTimestamp(),
          rotatedTo: replacementToken,
        });
      });
    }
  }
}

function exportJobIdFromFileName(name) {
  const match = /^exports\/([^/]+)\/(.+)_\d+\.csv$/.exec(name);
  return match ? { facilityId: match[1], jobId: match[2] } : null;
}

async function main() {
  const args = parseArgs(process.argv);
  const projectId = String(args.get('project') || '').trim();
  const apply = args.get('apply') === true;
  const confirmedProject = String(args.get('confirm-project') || '').trim();
  const retentionDays = Number(args.get('retention-days') || 7);

  if (!projectId) {
    throw new Error('Pass --project=<firebase-project-id>.');
  }
  if (!Number.isInteger(retentionDays) || retentionDays < 1 || retentionDays > 90) {
    throw new Error('--retention-days must be an integer from 1 to 90.');
  }
  if (apply && confirmedProject !== projectId) {
    throw new Error(
      `Refusing to mutate ${projectId}. Re-run with --apply --confirm-project=${projectId}.`,
    );
  }

  admin.initializeApp({
    projectId,
    storageBucket: `${projectId}.firebasestorage.app`,
  });
  const db = admin.firestore();
  const bucket = admin.storage().bucket();
  const now = Date.now();
  const retentionMs = retentionDays * 24 * 60 * 60 * 1000;
  const report = {
    projectId,
    mode: apply ? 'apply' : 'dry-run',
    generatedAt: new Date(now).toISOString(),
    paymentLinks: [],
    reservations: [],
    exports: [],
    suspiciousSubscriptions: [],
    suspiciousRoles: [],
  };

  // The platform's Stripe key, to check each link's sessions on the
  // facility's account before rotating it. Without it, links that ever
  // started a checkout are skipped and reported, not rotated.
  const stripeKey = String(process.env.STRIPE_SECRET_KEY || '').trim();
  const stripe = stripeKey
    ? new (require('stripe').default)(stripeKey, { apiVersion: '2026-02-25.clover' })
    : null;
  if (!stripe) {
    console.error('STRIPE_SECRET_KEY not set: payment links with a checkout session will be skipped.');
  }
  await rotatePendingPaymentLinks({
    db,
    stripe,
    apply,
    report,
    fieldValue: admin.firestore.FieldValue,
  });

  const activeReservations = await db
    .collection('publicReservations')
    .where('status', 'in', ['pending', 'confirmed'])
    .get();
  for (const doc of activeReservations.docs) {
    if (doc.get('securityTokenRotatedAt')) continue;
    const replacementToken = randomToken();
    report.reservations.push({
      reservationId: doc.id,
      oldToken: doc.get('moveInToken') || null,
      replacementToken,
      facilityId: doc.get('facilityId') || null,
      email: doc.get('email') || null,
    });
    if (apply) {
      await doc.ref.update({
        moveInToken: replacementToken,
        securityTokenRotatedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  }

  const [files] = await bucket.getFiles({ prefix: 'exports/' });
  for (const file of files) {
    const [metadata] = await file.getMetadata();
    const createdAtMs = Date.parse(metadata.timeCreated || '') || now;
    const expired = createdAtMs + retentionMs <= now;
    const jobIdentity = exportJobIdFromFileName(file.name);
    const expiresAt = new Date(Math.max(now, createdAtMs) + retentionMs);
    report.exports.push({
      storagePath: file.name,
      action: expired ? 'delete' : 'make-private',
      expiresAt: expired ? null : expiresAt.toISOString(),
      job: jobIdentity,
    });
    if (!apply) continue;

    const jobRef = jobIdentity
      ? db
          .collection('facilities')
          .doc(jobIdentity.facilityId)
          .collection('exportJobs')
          .doc(jobIdentity.jobId)
      : null;
    if (expired) {
      await file.delete({ ignoreNotFound: true });
      if (jobRef) {
        await jobRef.set(
          {
            status: 'expired',
            downloadUrl: admin.firestore.FieldValue.delete(),
            storagePath: admin.firestore.FieldValue.delete(),
            expiredAt: admin.firestore.FieldValue.serverTimestamp(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
      }
    } else {
      await file.makePrivate({ strict: false });
      await file.setMetadata({
        metadata: {
          ...(metadata.metadata || {}),
          securityHardenedAt: new Date(now).toISOString(),
          retentionExpiresAt: expiresAt.toISOString(),
        },
      });
      if (jobRef) {
        await jobRef.set(
          {
            storagePath: file.name,
            expiresAt: admin.firestore.Timestamp.fromDate(expiresAt),
            downloadUrl: admin.firestore.FieldValue.delete(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
      }
    }
  }

  const activeAccounts = await db
    .collection('facilityCreatorAccounts')
    .where('subscriptionStatus', '==', 'active')
    .get();
  for (const doc of activeAccounts.docs) {
    const data = doc.data();
    if (!data.stripeSubscriptionId) {
      report.suspiciousSubscriptions.push({
        accountId: doc.id,
        ownerUid: data.ownerUid || null,
        reason: 'active account has no stripeSubscriptionId',
      });
    }
  }

  const facilityCache = new Map();
  const roles = await db.collection('user_roles').get();
  for (const roleDoc of roles.docs) {
    const role = roleDoc.data();
    const facilityId = typeof role.facilityId === 'string' ? role.facilityId : '';
    if (!facilityId) {
      report.suspiciousRoles.push({
        roleId: roleDoc.id,
        reason: 'missing facilityId',
      });
      continue;
    }
    if (!facilityCache.has(facilityId)) {
      facilityCache.set(facilityId, await db.collection('facilities').doc(facilityId).get());
    }
    const facilitySnap = facilityCache.get(facilityId);
    if (!facilitySnap.exists) {
      report.suspiciousRoles.push({
        roleId: roleDoc.id,
        facilityId,
        reason: 'facility does not exist',
      });
      continue;
    }
    const facility = facilitySnap.data() || {};
    const assignedBy = role.assignedBy;
    const assignerRole = (facility.roles || {})[assignedBy];
    const assignerIsAuthorized =
      assignedBy === facility.ownerUid ||
      (facility.managers || {})[assignedBy] === true ||
      ['owner', 'manager', 'admin'].includes(assignerRole);
    if (!assignerIsAuthorized) {
      report.suspiciousRoles.push({
        roleId: roleDoc.id,
        facilityId,
        userId: role.userId || null,
        assignedBy: assignedBy || null,
        reason: 'assignedBy is not current facility management',
      });
    }
  }

  console.log(JSON.stringify(report, null, 2));
  if (!apply) {
    console.error(
      `Dry run only. To apply, re-run with --apply --confirm-project=${projectId}.`,
    );
  }
}

// Run only as a script; tests load it for rotatedLinkData.
if (require.main === module) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.stack : error);
    process.exitCode = 1;
  });
}

module.exports = { LINK_FIELDS_NOT_ROTATED, planLinkRotation, rotatePendingPaymentLinks, rotatedLinkData };

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

/** The link's checkout fields, compared again inside the rotation transaction. */
function checkoutFingerprint(link) {
  return JSON.stringify({
    checkoutSessionId: link.checkoutSessionId ?? null,
    checkoutSessionIds: Array.isArray(link.checkoutSessionIds) ? link.checkoutSessionIds : [],
    checkoutAttempt: link.checkoutAttempt ?? null,
  });
}

/** Whether a Checkout Session has been, or is being, paid. */
function sessionTookPayment(session) {
  return session.status === 'complete' || session.payment_status === 'paid';
}

/** A string for a Stripe search query: single-quoted, with quotes and backslashes escaped. */
function searchLiteral(value) {
  return `'${String(value).replace(/\\/g, '\\\\').replace(/'/g, "\\'")}'`;
}

/** Most pages of sessions listed per account when looking for a link's token. */
const MAX_SESSION_PAGES = 50;

/**
 * Every Checkout Session and PaymentIntent on [accounts] that carries the
 * link's token in its metadata (`paymentLinkToken`: every link checkout has
 * set it on its session, and newer ones on the PaymentIntent too).
 *
 * For a link with no recorded session ids, which is every legacy production
 * link: links only started recording them with the payment-link fix, so
 * such a link may still have been paid. Sessions cannot be searched by
 * metadata, so each account's sessions are listed (from a day before the
 * link was created) and filtered; PaymentIntents are searched as well.
 *
 * Returns { payments, openSessions, inProgress }, or { error } when the
 * search could not be completed (a failed call, or more sessions than it
 * lists). The caller then leaves the link alone.
 */
async function findLinkPaymentsByToken(token, link, { stripe, accounts }) {
  const payments = [];
  const openSessions = [];
  const inProgress = [];
  const createdAt = link.createdAt && typeof link.createdAt.toMillis === 'function' ? link.createdAt.toMillis() : null;
  const createdFilter = createdAt ? { created: { gte: Math.floor(createdAt / 1000) - 24 * 60 * 60 } } : {};
  for (const account of accounts) {
    try {
      let startingAfter;
      let pages = 0;
      for (;;) {
        pages += 1;
        const page = await stripe.checkout.sessions.list(
          { limit: 100, ...createdFilter, ...(startingAfter ? { starting_after: startingAfter } : {}) },
          { stripeAccount: account },
        );
        for (const session of page.data || []) {
          if (!session.metadata || session.metadata.paymentLinkToken !== token) continue;
          const paymentIntentId =
            typeof session.payment_intent === 'string'
              ? session.payment_intent
              : (session.payment_intent && session.payment_intent.id) || null;
          if (sessionTookPayment(session)) {
            payments.push({
              sessionId: session.id,
              paymentIntentId,
              account,
              amountCents: session.amount_total ?? null,
              currency: session.currency || null,
              settled: session.payment_status === 'paid',
            });
          } else if (session.status === 'open') {
            openSessions.push({ id: session.id, account });
          }
        }
        if (!page.has_more || !page.data || page.data.length === 0) break;
        if (pages >= MAX_SESSION_PAGES) return { error: 'too_many_sessions_to_search', account };
        startingAfter = page.data[page.data.length - 1].id;
      }
      const found = await stripe.paymentIntents.search(
        { query: `metadata['paymentLinkToken']:${searchLiteral(token)}`, limit: 100 },
        { stripeAccount: account },
      );
      for (const pi of found.data || []) {
        if (payments.some((p) => p.paymentIntentId === pi.id)) continue;
        if (pi.status === 'succeeded') {
          payments.push({
            sessionId: null,
            paymentIntentId: pi.id,
            account,
            amountCents: pi.amount ?? null,
            currency: pi.currency || null,
            settled: true,
          });
        } else if (pi.status === 'processing' || pi.status === 'requires_capture') {
          inProgress.push({ paymentIntentId: pi.id, account, status: pi.status });
        }
      }
    } catch (error) {
      return { error: 'token_search_failed', account, detail: String(error && error.message) };
    }
  }
  return { payments, openSessions, inProgress };
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
 * that cannot be checked skips the link rather than guessing. A recorded
 * session found on none of the accounts is one of those: it was created, so
 * "not found" says the lookup is wrong, not that nobody paid.
 *
 * A link with no recorded session (every legacy production link) used to be
 * rotated without asking Stripe, so a paid-but-unmarked one became a fresh
 * payable link. Its token is searched for instead ([findLinkPaymentsByToken]):
 * a payment found marks the link paid (`markPaid`), an open session is
 * expired before rotating, and a search that cannot be completed leaves the
 * link alone.
 *
 * [accountIds] is the facility's current account, then the one it was
 * connected to before (stripeConnectPreviousAccountId). A link started
 * before a reconnect has its sessions on the old account; looked up only on
 * the new one they read as missing, and a paid link was rotated.
 */
async function planLinkRotation(link, { stripe, accountIds, token }) {
  const sessionIds = linkSessionIds(link);
  if (!stripe) return { rotate: false, reason: 'stripe_not_checked', sessionIds };
  const accounts = [...new Set((accountIds || []).filter((id) => typeof id === 'string' && id))];
  if (accounts.length === 0) return { rotate: false, reason: 'facility_has_no_stripe_account', sessionIds };

  if (sessionIds.length === 0) {
    const search = await findLinkPaymentsByToken(token, link, { stripe, accounts });
    if (search.error) return { rotate: false, reason: search.error, account: search.account, error: search.detail };
    if (search.inProgress.length > 0) {
      const [first] = search.inProgress;
      return { rotate: false, reason: 'payment_in_progress', paymentIntentId: first.paymentIntentId, account: first.account };
    }
    if (search.payments.length > 1) {
      return { rotate: false, reason: 'paid_more_than_once', payments: search.payments };
    }
    if (search.payments.length === 1) {
      const [payment] = search.payments;
      const linkCents = typeof link.amount === 'number' && Number.isFinite(link.amount) ? Math.round(link.amount * 100) : null;
      if (!payment.settled) return { rotate: false, reason: 'session_completed', payment };
      if (payment.amountCents !== linkCents || String(payment.currency || '').toLowerCase() !== 'usd') {
        return { rotate: false, reason: 'paid_amount_differs', payment };
      }
      return { rotate: false, markPaid: payment };
    }
    return { rotate: true, openSessions: search.openSessions, searchedByToken: true };
  }

  const openSessions = [];
  for (const id of sessionIds) {
    let found = false;
    for (const account of accounts) {
      let session;
      try {
        session = await stripe.checkout.sessions.retrieve(id, {}, { stripeAccount: account });
      } catch (error) {
        // Not on this account: try the other.
        if (isMissingSession(error)) continue;
        return { rotate: false, reason: 'session_lookup_failed', sessionId: id, account, error: String(error && error.message) };
      }
      found = true;
      if (sessionTookPayment(session)) {
        return { rotate: false, reason: 'session_completed', sessionId: id, account };
      }
      if (session.status === 'open') openSessions.push({ id, account });
      break;
    }
    if (!found) return { rotate: false, reason: 'session_not_found', sessionId: id, accounts };
  }
  return { rotate: true, openSessions };
}

function formatDollars(cents) {
  return `$${((cents || 0) / 100).toFixed(2)}`;
}

/**
 * Marks a legacy link paid for a payment [findLinkPaymentsByToken] found,
 * in one transaction that first checks the link is still pending with the
 * checkout fields it was planned from. Like a payment the webhook finds on
 * an untracked session (functions-shared completePublicLinkPayment.ts), it
 * leaves an exception record and a notification asking staff to check the
 * ledger shows the payment: a legacy checkout's PaymentIntent carried no
 * tenant, so the webhook may never have posted it. Returns why nothing was
 * written, or null.
 */
async function markLinkPaidFromSearch({ db, doc, planned, payment, fieldValue }) {
  const exceptionId = payment.sessionId || payment.paymentIntentId;
  const exceptionRef = db.collection('publicPaymentLinkExceptions').doc(exceptionId);
  return db.runTransaction(async (txn) => {
    const current = await txn.get(doc.ref);
    if (!current.exists || current.get('status') !== 'pending') return 'link_no_longer_pending';
    if (checkoutFingerprint(current.data()) !== checkoutFingerprint(planned)) return 'link_checkout_changed';
    const exception = await txn.get(exceptionRef);
    const link = current.data();
    const facilityRef = db.collection('facilities').doc(link.facilityId);
    const now = fieldValue.serverTimestamp();
    const sessionIds = Array.isArray(link.checkoutSessionIds) ? link.checkoutSessionIds : [];
    txn.update(doc.ref, {
      status: 'paid',
      paymentIntentId: payment.paymentIntentId,
      ...(payment.sessionId
        ? { checkoutSessionId: payment.sessionId, checkoutSessionIds: [...new Set([...sessionIds, payment.sessionId])] }
        : {}),
      paidAt: now,
      paidVia: 'security_cleanup',
      amountPaidCents: payment.amountCents,
      needsLedgerCheck: true,
      updatedAt: now,
    });
    if (!exception.exists) {
      const message =
        `A payment of ${formatDollars(payment.amountCents)} was made on a payment link checkout started before payment ` +
        'links recorded payments automatically. Check the tenant ledger shows it, and record it if not.';
      txn.create(exceptionRef, {
        facilityId: link.facilityId,
        tenantId: link.tenantId || null,
        paymentLinkToken: doc.id,
        reason: 'untracked_session',
        message,
        checkoutSessionId: payment.sessionId,
        paymentIntentId: payment.paymentIntentId,
        amountCents: payment.amountCents,
        currency: payment.currency,
        linkStatus: 'pending',
        connectedAccountId: payment.account,
        source: 'security_cleanup',
        resolution: 'open',
        createdAt: now,
      });
      txn.set(facilityRef.collection('Notifications').doc(`publicLinkException_${exceptionId}`), {
        facilityId: link.facilityId,
        tenantId: link.tenantId || null,
        tenantName: null,
        type: 'STRIPE_ACTION_REQUIRED',
        message,
        readAt: null,
        createdAt: now,
        createdBy: 'system@security-cleanup',
        metadata: {
          reason: 'untracked_session',
          checkoutSessionId: payment.sessionId,
          paymentIntentId: payment.paymentIntentId,
          amountCents: payment.amountCents,
        },
      });
    }
    return null;
  });
}

/**
 * Rotates every pending link whose token is legacy/predictable, after
 * [planLinkRotation] clears it, or marks it paid when Stripe shows it was.
 * Reports every link: rotated, would rotate (dry run), marked paid, would
 * mark paid, or skipped with the reason. Dry run unless [apply]. Exported
 * for tests.
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
    const plan = await planLinkRotation(link, { stripe, accountIds, token: doc.id });

    if (plan.markPaid) {
      const payment = plan.markPaid;
      const paidEntry = {
        ...entry,
        checkoutSessionId: payment.sessionId,
        paymentIntentId: payment.paymentIntentId,
        account: payment.account,
        amountCents: payment.amountCents,
      };
      if (!apply) {
        report.paymentLinks.push({ ...paidEntry, action: 'would_mark_paid' });
        continue;
      }
      const refusal = await markLinkPaidFromSearch({ db, doc, planned: link, payment, fieldValue });
      report.paymentLinks.push(
        refusal ? { ...paidEntry, action: 'skipped', reason: refusal } : { ...paidEntry, action: 'marked_paid' },
      );
      continue;
    }
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
    const rotatedEntry = {
      ...entry,
      replacementToken,
      expiredSessionIds: openSessionIds,
      ...(plan.searchedByToken ? { searchedByToken: true } : {}),
    };
    if (!apply) {
      report.paymentLinks.push({ ...rotatedEntry, action: 'would_rotate' });
      continue;
    }
    const refusal = await db.runTransaction(async (txn) => {
      const current = await txn.get(doc.ref);
      if (!current.exists || current.get('status') !== 'pending') return 'link_no_longer_pending';
      // A checkout started (or a session recorded) since the plan was made
      // is one the plan never checked: rotating now would drop it and offer
      // a second Pay Now alongside it.
      if (checkoutFingerprint(current.data()) !== checkoutFingerprint(link)) return 'link_checkout_changed';
      txn.create(
        replacementRef,
        rotatedLinkData(current.data(), replacementToken, doc.id, fieldValue.serverTimestamp()),
      );
      txn.update(doc.ref, {
        status: 'revoked',
        revokedAt: fieldValue.serverTimestamp(),
        rotatedTo: replacementToken,
      });
      return null;
    });
    report.paymentLinks.push(
      refusal
        ? { ...entry, action: 'skipped', reason: refusal, expiredSessionIds: openSessionIds }
        : { ...rotatedEntry, action: 'rotated' },
    );
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

  // The platform's Stripe key, to check each link's sessions (or, for a
  // link that recorded none, search for its token) on the facility's
  // accounts before rotating it. Without it no link is rotated: each is
  // skipped and reported.
  const stripeKey = String(process.env.STRIPE_SECRET_KEY || '').trim();
  const stripe = stripeKey
    ? new (require('stripe').default)(stripeKey, { apiVersion: '2026-02-25.clover' })
    : null;
  if (!stripe) {
    console.error('STRIPE_SECRET_KEY not set: every legacy payment link will be skipped, not rotated.');
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

module.exports = {
  LINK_FIELDS_NOT_ROTATED,
  findLinkPaymentsByToken,
  planLinkRotation,
  rotatePendingPaymentLinks,
  rotatedLinkData,
};

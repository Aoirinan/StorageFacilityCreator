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

  const pendingLinks = await db
    .collection('publicPaymentLinks')
    .where('status', '==', 'pending')
    .get();
  for (const doc of pendingLinks.docs) {
    // Current server-generated tokens are 48 lowercase hex characters. Only
    // rotate legacy/predictable tokens so this cleanup remains idempotent.
    if (/^[a-f0-9]{48}$/.test(doc.id)) continue;
    const replacementToken = randomToken();
    const replacementRef = db.collection('publicPaymentLinks').doc(replacementToken);
    report.paymentLinks.push({
      oldToken: doc.id,
      replacementToken,
      facilityId: doc.get('facilityId') || null,
      tenantId: doc.get('tenantId') || null,
    });
    if (apply) {
      await db.runTransaction(async (txn) => {
        const current = await txn.get(doc.ref);
        if (!current.exists || current.get('status') !== 'pending') return;
        txn.create(replacementRef, {
          ...current.data(),
          token: replacementToken,
          rotatedFrom: doc.id,
          rotatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        txn.update(doc.ref, {
          status: 'revoked',
          revokedAt: admin.firestore.FieldValue.serverTimestamp(),
          rotatedTo: replacementToken,
        });
      });
    }
  }

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

main().catch((error) => {
  console.error(error instanceof Error ? error.stack : error);
  process.exitCode = 1;
});

import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { enforceAppCheckOrThrow } from './guardrails';

const EXPORT_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
const SIGNED_URL_LIFETIME_MS = 60 * 60 * 1000;

async function assertOwnerOrManager(facilityId: string, uid: string): Promise<void> {
  const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();

  if (!facilityDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Facility not found');
  }

  const facilityData = facilityDoc.data();
  const role = facilityData?.roles?.[uid];
  const managerEntry = facilityData?.managers?.[uid];
  const managerFromMap =
    managerEntry === true ||
    (
      typeof managerEntry === 'object' &&
      managerEntry !== null &&
      (
        managerEntry.active === true ||
        managerEntry.isActive === true ||
        managerEntry.role === 'manager' ||
        managerEntry.roleType === 'manager'
      )
    );
  if (
    facilityData?.ownerUid !== uid &&
    !managerFromMap &&
    role !== 'manager' &&
    role !== 'owner' &&
    role !== 'admin'
  ) {
    throw new functions.https.HttpsError('permission-denied', 'User does not have permission');
  }
}

/**
 * Process export job (for large datasets)
 * Generates CSV and stores in Firebase Storage
 */
export const processExportJob = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const facilityId = String(data?.facilityId || '').trim();
  const jobId = String(data?.jobId || '').trim();
  const type = String(data?.type || '').trim();
  const filters = data?.filters;

  if (!/^[^/]{1,128}$/.test(facilityId) || !/^[^/]{1,128}$/.test(jobId) || !type) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId, jobId, and type are required');
  }

  await assertOwnerOrManager(facilityId, context.auth.uid);
  const jobRef = admin.firestore().collection('facilities').doc(facilityId).collection('exportJobs').doc(jobId);

  try {
    await jobRef.update({
      status: 'processing',
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    let csvContent = '';
    let recordCount = 0;

    if (type === 'tenants') {
      const result = await exportTenantsToCSV(facilityId, filters);
      csvContent = result.csv;
      recordCount = result.count;
    } else if (type === 'payments') {
      const result = await exportPaymentsToCSV(facilityId, filters);
      csvContent = result.csv;
      recordCount = result.count;
    } else if (type === 'auditLogs') {
      const result = await exportAuditLogsToCSV(facilityId, filters);
      csvContent = result.csv;
      recordCount = result.count;
    } else {
      throw new functions.https.HttpsError('invalid-argument', `Unsupported export type: ${type}`);
    }

    const bucket = admin.storage().bucket();
    const fileName = `exports/${facilityId}/${jobId}_${Date.now()}.csv`;
    const file = bucket.file(fileName);

    await file.save(csvContent, {
      metadata: {
        contentType: 'text/csv',
        metadata: {
          facilityId,
          jobId,
          type,
          createdBy: context.auth.uid,
        },
      },
    });

    const expiresAt = admin.firestore.Timestamp.fromMillis(Date.now() + EXPORT_RETENTION_MS);

    await jobRef.update({
      status: 'completed',
      storagePath: fileName,
      expiresAt,
      downloadUrl: admin.firestore.FieldValue.delete(),
      recordCount,
      completedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return {
      success: true,
      jobId,
      recordCount,
      expiresAt: expiresAt.toDate().toISOString(),
    };
  } catch (error: any) {
    try {
      await jobRef.update({
        status: 'failed',
        errorMessage: error.message,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } catch (updateError: any) {
      functions.logger.error('Error updating export job with error:', updateError);
    }

    functions.logger.error('Error processing export job:', error);
    if (error instanceof functions.https.HttpsError) {
      throw error;
    }
    throw new functions.https.HttpsError('internal', `Failed to process export: ${error.message}`);
  }
});

/**
 * Return a short-lived download URL for an authorized export.
 */
export const getExportDownloadUrl = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId, jobId } = data;
  if (!facilityId || !jobId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId and jobId are required');
  }

  await assertOwnerOrManager(facilityId, context.auth.uid);

  const jobDoc = await admin
    .firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('exportJobs')
    .doc(jobId)
    .get();

  if (!jobDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Export job not found');
  }

  const job = jobDoc.data();
  const storagePath = job?.storagePath;
  const expiresAt = job?.expiresAt;

  if (job?.status !== 'completed' || typeof storagePath !== 'string' || !(expiresAt instanceof admin.firestore.Timestamp)) {
    throw new functions.https.HttpsError('failed-precondition', 'Export is not available for download');
  }
  if (!storagePath.startsWith(`exports/${facilityId}/`)) {
    throw new functions.https.HttpsError('failed-precondition', 'Export storage path is invalid');
  }
  if (expiresAt.toMillis() <= Date.now()) {
    throw new functions.https.HttpsError('failed-precondition', 'Export has expired');
  }

  const signedUrlExpiresAt = new Date(
    Math.min(Date.now() + SIGNED_URL_LIFETIME_MS, expiresAt.toMillis()),
  );
  const [downloadUrl] = await admin.storage().bucket().file(storagePath).getSignedUrl({
    action: 'read',
    expires: signedUrlExpiresAt,
    version: 'v4',
  });

  return {
    downloadUrl,
    expiresAt: signedUrlExpiresAt.toISOString(),
  };
});

/**
 * Delete expired export files and their job documents every day.
 */
export const cleanupExpiredExports = functions.pubsub
  .schedule('0 3 * * *')
  .timeZone('UTC')
  .onRun(async () => {
    const now = admin.firestore.Timestamp.now();
    const bucket = admin.storage().bucket();

    let matchedCount = 0;
    let deletedCount = 0;
    let cursor: admin.firestore.QueryDocumentSnapshot | undefined;

    while (true) {
      let query = admin
        .firestore()
        .collectionGroup('exportJobs')
        .where('expiresAt', '<=', now)
        .orderBy('expiresAt')
        .limit(100);
      if (cursor) {
        query = query.startAfter(cursor);
      }

      const expiredJobs = await query.get();
      if (expiredJobs.empty) {
        break;
      }
      matchedCount += expiredJobs.size;

      await Promise.all(
        expiredJobs.docs.map(async (jobDoc) => {
          const storagePath = jobDoc.get('storagePath');
          const facilityId = jobDoc.ref.parent.parent?.id;
          try {
            if (
              typeof storagePath === 'string' &&
              facilityId &&
              storagePath.startsWith(`exports/${facilityId}/`)
            ) {
              await bucket.file(storagePath).delete({ ignoreNotFound: true });
            }
            await jobDoc.ref.delete();
            deletedCount += 1;
          } catch (error) {
            functions.logger.error('Failed to clean up expired export', {
              jobPath: jobDoc.ref.path,
              storagePath,
              error,
            });
          }
        }),
      );

      cursor = expiredJobs.docs[expiredJobs.docs.length - 1];
      if (expiredJobs.size < 100) {
        break;
      }
    }

    functions.logger.info('Expired export cleanup completed', {
      matchedCount,
      deletedCount,
    });
    return null;
  });

async function exportTenantsToCSV(
  facilityId: string,
  filters?: Record<string, unknown>,
): Promise<{ csv: string; count: number }> {
  let query: admin.firestore.Query = admin.firestore().collection('facilities').doc(facilityId).collection('tenants');

  if (filters?.isActive !== undefined) {
    query = query.where('isActive', '==', filters.isActive);
  }

  if (filters?.startDate) {
    query = query.where('createdAt', '>=', admin.firestore.Timestamp.fromDate(new Date(filters.startDate as string)));
  }

  if (filters?.endDate) {
    query = query.where('createdAt', '<=', admin.firestore.Timestamp.fromDate(new Date(filters.endDate as string)));
  }

  const snapshot = await query.limit(50000).get();

  const csvRows: string[] = [];
  csvRows.push('ID,Name,Email,Phone,Unit Number,Monthly Rate,Status,Created At,Notes');

  for (const doc of snapshot.docs) {
    const data = doc.data();
    csvRows.push(
      [
        doc.id,
        escapeCsvField(data.name || ''),
        escapeCsvField(data.email || ''),
        escapeCsvField(data.phone || ''),
        escapeCsvField(data.unitNumber || ''),
        (data.monthlyRate || 0).toString(),
        data.isActive === true ? 'Active' : 'Inactive',
        data.createdAt ? (data.createdAt as admin.firestore.Timestamp).toDate().toISOString() : '',
        escapeCsvField(data.notes || ''),
      ].join(','),
    );
  }

  return {
    csv: csvRows.join('\n'),
    count: snapshot.size,
  };
}

async function exportPaymentsToCSV(
  facilityId: string,
  filters?: Record<string, unknown>,
): Promise<{ csv: string; count: number }> {
  let query: admin.firestore.Query = admin
    .firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('payments')
    .where('isActive', '==', true);

  if (filters?.status) {
    query = query.where('status', '==', filters.status);
  }

  if (filters?.startDate) {
    query = query.where('createdAt', '>=', admin.firestore.Timestamp.fromDate(new Date(filters.startDate as string)));
  }

  if (filters?.endDate) {
    query = query.where('createdAt', '<=', admin.firestore.Timestamp.fromDate(new Date(filters.endDate as string)));
  }

  const snapshot = await query.limit(50000).get();

  const csvRows: string[] = [];
  csvRows.push('ID,Tenant ID,Amount,Status,Method,Due Date,Paid Date,Transaction ID,Created At');

  for (const doc of snapshot.docs) {
    const data = doc.data();
    csvRows.push(
      [
        doc.id,
        escapeCsvField(data.tenantId || ''),
        (data.amount || 0).toString(),
        escapeCsvField(data.status || ''),
        escapeCsvField(data.method || ''),
        data.dueDate ? (data.dueDate as admin.firestore.Timestamp).toDate().toISOString() : '',
        (data.paidDate || data.paidAt)
          ? ((data.paidDate || data.paidAt) as admin.firestore.Timestamp).toDate().toISOString()
          : '',
        escapeCsvField(data.transactionId || data.externalPaymentId || ''),
        data.createdAt ? (data.createdAt as admin.firestore.Timestamp).toDate().toISOString() : '',
      ].join(','),
    );
  }

  return {
    csv: csvRows.join('\n'),
    count: snapshot.size,
  };
}

async function exportAuditLogsToCSV(
  facilityId: string,
  filters?: Record<string, unknown>,
): Promise<{ csv: string; count: number }> {
  let query: admin.firestore.Query = admin
    .firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('auditLogs')
    .orderBy('timestamp', 'desc');

  if (filters?.eventType) {
    query = query.where('eventType', '==', filters.eventType);
  }

  if (filters?.startDate) {
    query = query.where('timestamp', '>=', admin.firestore.Timestamp.fromDate(new Date(filters.startDate as string)));
  }

  if (filters?.endDate) {
    query = query.where('timestamp', '<=', admin.firestore.Timestamp.fromDate(new Date(filters.endDate as string)));
  }

  const snapshot = await query.limit(50000).get();

  const csvRows: string[] = [];
  csvRows.push('ID,Event Type,Actor Email,Actor Role,Target Type,Target ID,Tenant ID,Timestamp,Metadata');

  for (const doc of snapshot.docs) {
    const data = doc.data();
    const metadata = data.metadata || {};
    csvRows.push(
      [
        doc.id,
        escapeCsvField(data.eventType || ''),
        escapeCsvField(data.actorEmail || ''),
        escapeCsvField(data.actorRole || ''),
        escapeCsvField(data.targetType || ''),
        escapeCsvField(data.targetId || ''),
        escapeCsvField(data.tenantId || ''),
        data.timestamp ? (data.timestamp as admin.firestore.Timestamp).toDate().toISOString() : '',
        escapeCsvField(JSON.stringify(metadata)),
      ].join(','),
    );
  }

  return {
    csv: csvRows.join('\n'),
    count: snapshot.size,
  };
}

function escapeCsvField(field: string): string {
  if (field.includes(',') || field.includes('"') || field.includes('\n')) {
    return `"${field.replace(/"/g, '""')}"`;
  }
  return field;
}

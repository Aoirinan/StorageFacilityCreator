import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { enforceAppCheckOrThrow } from './guardrails';

/**
 * Process export job (for large datasets)
 * Generates CSV and stores in Firebase Storage
 */
export const processExportJob = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId, jobId, type, filters } = data;

  if (!facilityId || !jobId || !type) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId, jobId, and type are required');
  }

  try {
    const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data();
    const ownerUid = facilityData?.ownerUid;
    const roles = facilityData?.roles || {};

    if (ownerUid !== context.auth.uid && roles[context.auth.uid] !== 'manager' && roles[context.auth.uid] !== 'owner') {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission');
    }

    const jobRef = admin.firestore().collection('facilities').doc(facilityId).collection('exportJobs').doc(jobId);

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

    await file.makePublic();

    const downloadUrl = `https://storage.googleapis.com/${bucket.name}/${fileName}`;

    await jobRef.update({
      status: 'completed',
      downloadUrl,
      recordCount,
      completedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return {
      success: true,
      jobId,
      downloadUrl,
      recordCount,
    };
  } catch (error: any) {
    try {
      const jobRef = admin.firestore().collection('facilities').doc(facilityId).collection('exportJobs').doc(jobId);

      await jobRef.update({
        status: 'failed',
        errorMessage: error.message,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } catch (updateError: any) {
      functions.logger.error('Error updating export job with error:', updateError);
    }

    functions.logger.error('Error processing export job:', error);
    throw new functions.https.HttpsError('internal', `Failed to process export: ${error.message}`);
  }
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

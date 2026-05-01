import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

/**
 * Write standardized audit log entry
 * Uses standardized schema: eventType, actorUid, actorRole, targetType, targetId, before, after, timestamp, etc.
 */
export async function writeAuditLog(
  facilityId: string,
  entry: {
    eventType?: string;
    action?: string;
    userId?: string;
    actorUid?: string;
    actorEmail?: string;
    actorRole?: string;
    targetType?: string;
    targetId?: string;
    entityType?: string;
    entityId?: string;
    tenantId?: string;
    before?: Record<string, unknown>;
    after?: Record<string, unknown>;
    timestamp?: admin.firestore.Timestamp;
    ipAddress?: string;
    userAgent?: string;
    metadata?: Record<string, unknown>;
    details?: Record<string, unknown>;
    [key: string]: unknown;
  },
): Promise<void> {
  try {
    const eventType = entry.eventType || entry.action || 'unknown';
    const actorUid = entry.actorUid || entry.userId || 'system';
    const targetType = entry.targetType || entry.entityType || 'unknown';
    const targetId = entry.targetId || entry.entityId || 'unknown';
    const metadata = entry.metadata || entry.details || {};

    let actorEmail: string | undefined;
    let actorRole: string | undefined;

    if (actorUid !== 'system') {
      try {
        const userRecord = await admin.auth().getUser(actorUid);
        actorEmail = userRecord.email;

        const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();

        if (facilityDoc.exists) {
          const facilityData = facilityDoc.data();
          if (facilityData?.ownerUid === actorUid) {
            actorRole = 'owner';
          } else if (facilityData?.roles?.[actorUid]) {
            actorRole = facilityData.roles[actorUid] as string;
          } else if (facilityData?.managers?.[actorUid] === true) {
            actorRole = 'manager';
          }
        }
      } catch {
        functions.logger.warn(`Could not get user info for audit log: ${actorUid}`);
      }
    }

    const auditEntry: Record<string, unknown> = {
      eventType,
      actorUid,
      facilityId,
      targetType,
      targetId,
      timestamp: entry.timestamp || admin.firestore.FieldValue.serverTimestamp(),
    };

    if (actorEmail) auditEntry.actorEmail = actorEmail;
    if (actorRole) auditEntry.actorRole = actorRole;
    if (entry.tenantId) auditEntry.tenantId = entry.tenantId;
    if (entry.before) auditEntry.before = entry.before;
    if (entry.after) auditEntry.after = entry.after;
    if (entry.ipAddress) auditEntry.ipAddress = entry.ipAddress;
    if (entry.userAgent) auditEntry.userAgent = entry.userAgent;
    if (Object.keys(metadata).length > 0) auditEntry.metadata = metadata;

    Object.keys(entry).forEach((key) => {
      if (
        ![
          'eventType',
          'action',
          'userId',
          'actorUid',
          'actorEmail',
          'actorRole',
          'targetType',
          'targetId',
          'entityType',
          'entityId',
          'tenantId',
          'before',
          'after',
          'timestamp',
          'ipAddress',
          'userAgent',
          'metadata',
          'details',
          'facilityId',
        ].includes(key)
      ) {
        if (!auditEntry.metadata) auditEntry.metadata = {};
        (auditEntry.metadata as Record<string, unknown>)[key] = entry[key];
      }
    });

    await admin
      .firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('auditLogs')
      .add(auditEntry);

    functions.logger.debug(`Audit log written: ${eventType} for ${targetType}:${targetId}`);
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    functions.logger.error(`Error writing audit log: ${message}`, error);
  }
}

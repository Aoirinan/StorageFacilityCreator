import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

type RateLimitConfig = {
  facilityId: string | undefined;
  key: string;
  limit: number;
  windowSeconds: number;
  userId?: string | null;
};

export async function enforceRateLimit(config: RateLimitConfig): Promise<void> {
  const { facilityId, key, limit, windowSeconds, userId } = config;
  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required for rate limiting');
  }

  const now = Math.floor(Date.now() / 1000);
  const windowStart = Math.floor(now / windowSeconds) * windowSeconds;
  const docId = `${key}_${windowStart}`;
  const ref = admin
    .firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('rateLimits')
    .doc(docId);

  await admin.firestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const current = snap.exists ? (snap.data()?.count as number) || 0 : 0;
    if (current >= limit) {
      throw new functions.https.HttpsError(
        'resource-exhausted',
        `Rate limit exceeded for ${key}. Try again shortly.`,
      );
    }
    tx.set(
      ref,
      {
        count: current + 1,
        windowStart: new Date(windowStart * 1000),
        windowSeconds,
        key,
        facilityId,
        lastUserId: userId || null,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  });
}

/** Write standardized audit log entry */
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
    before?: Record<string, any>;
    after?: Record<string, any>;
    timestamp?: admin.firestore.Timestamp;
    ipAddress?: string;
    userAgent?: string;
    metadata?: Record<string, any>;
    details?: Record<string, any>;
    [key: string]: any;
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
      } catch (e) {
        functions.logger.warn(`Could not get user info for audit log: ${actorUid}`);
      }
    }

    const auditEntry: Record<string, any> = {
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
        auditEntry.metadata[key] = entry[key];
      }
    });

    await admin.firestore().collection('facilities').doc(facilityId).collection('auditLogs').add(auditEntry);

    functions.logger.debug(`Audit log written: ${eventType} for ${targetType}:${targetId}`);
  } catch (error: any) {
    functions.logger.error(`Error writing audit log: ${error.message}`, error);
  }
}

export function enforceAppCheckOrThrow(context: functions.https.CallableContext): void {
  if (!context.app) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'App Check token required. Please update your app.',
    );
  }
}

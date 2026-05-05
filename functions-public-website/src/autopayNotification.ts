import * as admin from 'firebase-admin';

/** Create a facility notification and an AutopayEvents log entry */
export async function createAutopayNotificationAndEvent(
  facilityId: string,
  tenantId: string,
  tenantName: string,
  notificationType: 'AUTOPAY_DISABLED' | 'AUTOPAY_ENABLED' | 'AUTOPAY_REQUESTED' | 'STRIPE_ACTION_REQUIRED',
  eventAction: 'REQUESTED' | 'ENABLED' | 'DISABLED',
  source: 'TENANT' | 'FACILITY' | 'SYSTEM',
  message: string,
  reason: string | null,
): Promise<void> {
  const batch = admin.firestore().batch();
  const notifRef = admin.firestore().collection('facilities').doc(facilityId).collection('Notifications').doc();
  batch.set(notifRef, {
    type: notificationType,
    tenantId,
    tenantName,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    readAt: null,
    message,
    metadata: reason ? { reason } : {},
  });
  const eventRef = admin.firestore().collection('facilities').doc(facilityId).collection('AutopayEvents').doc();
  batch.set(eventRef, {
    facilityId,
    tenantId,
    tenantName,
    action: eventAction,
    source,
    reason: reason || null,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  await batch.commit();
}

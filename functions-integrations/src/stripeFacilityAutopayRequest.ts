import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { canAccessFacility } from '@sfc/functions-shared';
import { createAutopayNotificationAndEvent } from './stripeAutopayEvents';

/**
 * requestTenantAutopay — Set autopay requested=true, enabled=false, status=REQUESTED. Creates notification + event.
 */
export const requestTenantAutopay = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  const { facilityId, tenantId, source } = data;
  if (!facilityId || !tenantId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId and tenantId are required');
  }
  const src = (source === 'TENANT' || source === 'FACILITY' || source === 'SYSTEM') ? source : 'SYSTEM';

  const hasAccess = await canAccessFacility(context.auth.uid, facilityId);
  if (!hasAccess) {
    throw new functions.https.HttpsError('permission-denied', 'Access denied');
  }

  const tenantRef = admin.firestore().collection('facilities').doc(facilityId).collection('tenants').doc(tenantId);
  const tenantDoc = await tenantRef.get();
  if (!tenantDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Tenant not found');
  }
  const tenantData = tenantDoc.data()!;
  const tenantName = (tenantData.name as string) || 'Tenant';

  const now = admin.firestore.FieldValue.serverTimestamp();
  await tenantRef.update({
    'autopay.requested': true,
    'autopay.enabled': false,
    'autopay.status': 'REQUESTED',
    'autopay.updatedBy': src,
    'autopay.updatedAt': now,
    updatedAt: now,
  });
  await createAutopayNotificationAndEvent(
    facilityId, tenantId, tenantName,
    'AUTOPAY_REQUESTED', 'REQUESTED', src,
    `${tenantName} requested autopay.`,
    null,
  );
  return { status: 'REQUESTED', requested: true };
});

import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import {
  duplicatePaymentWindowStartMs,
  shouldRejectDuplicatePayment,
} from './stripeFacilityProcessPaymentDuplicateCheckHelpers';

/**
 * When duplicate detection is enabled, reject if a matching paid payment exists in the recent window.
 */
export async function throwIfDuplicateRecentPayment(
  facilityId: string,
  tenantId: string,
  amount: number,
): Promise<void> {
  const nowMs = Date.now();
  const recentPaymentsSnapshot = await admin.firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('payments')
    .where('tenantId', '==', tenantId)
    .where('amount', '==', amount)
    .where('status', '==', 'paid')
    .where('createdAt', '>', admin.firestore.Timestamp.fromMillis(duplicatePaymentWindowStartMs(nowMs)))
    .limit(1)
    .get();

  if (shouldRejectDuplicatePayment(!recentPaymentsSnapshot.empty)) {
    const recentPayment = recentPaymentsSnapshot.docs[0].data();
    functions.logger.warn(`Duplicate payment detected: ${recentPayment.externalPaymentId || 'unknown'} for tenant ${tenantId}`);
    throw new functions.https.HttpsError(
      'already-exists',
      'A payment with the same amount was processed recently. Please verify this is not a duplicate.',
    );
  }
}

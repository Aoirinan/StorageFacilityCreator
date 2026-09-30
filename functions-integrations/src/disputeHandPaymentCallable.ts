import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { canAccessFacility, recordDisputeHandPayment } from '@sfc/functions-shared';

/**
 * recordDisputePaymentByHand: the Ledger's "Record payment for this dispute"
 * for cash, check, Venmo, Zelle, bank transfer or other.
 *
 * The app wrote these payments itself, capped only by its dialog, which
 * reads the ledger it opened with; two staff recording one dispute at once
 * both took its full amount. The payment, its Payment History copy and its
 * ledger row are now written here, in one transaction with the check that
 * the dispute is this tenant's, still open, and has at least this much left
 * (functions-shared ledger/disputePayment.ts recordDisputeHandPayment).
 *
 * Request: { facilityId, tenantId, disputeId, amount, method, reference?,
 * notes?, requestId } where requestId is the app's id for one press of
 * "Record payment" (a retry returns the same payment).
 */
export const recordDisputePaymentByHand = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  const facilityId = typeof data?.facilityId === 'string' ? data.facilityId.trim() : '';
  const tenantId = typeof data?.tenantId === 'string' ? data.tenantId.trim() : '';
  if (!/^[^/]{1,128}$/.test(facilityId) || !/^[^/]{1,128}$/.test(tenantId)) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId and tenantId are required.');
  }
  if (!(await canAccessFacility(context.auth.uid, facilityId))) {
    throw new functions.https.HttpsError('permission-denied', 'User does not have permission');
  }

  const result = await recordDisputeHandPayment({
    db: admin.firestore(),
    facilityId,
    tenantId,
    disputeId: data?.disputeId,
    amount: data?.amount,
    method: data?.method,
    reference: data?.reference,
    notes: data?.notes,
    requestId: data?.requestId,
    actorUid: context.auth.uid,
  });
  if (result.outcome === 'refused') {
    throw new functions.https.HttpsError(
      result.reason === 'invalid_request' ? 'invalid-argument' : 'failed-precondition',
      result.message,
      { reason: result.reason },
    );
  }
  functions.logger.info('Dispute payment recorded by hand', {
    facilityId,
    tenantId,
    outcome: result.outcome,
    paymentId: result.paymentId,
  });
  return { success: true, outcome: result.outcome, paymentId: result.paymentId };
});

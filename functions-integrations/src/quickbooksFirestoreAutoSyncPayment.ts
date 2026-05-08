import * as functions from 'firebase-functions/v1';
import * as quickBooksAccounting from './accounting/quickbooks';
import { QUICKBOOKS_SECRETS, QUICKBOOKS_VPC_CONNECTOR, getQuickBooksConfig } from './secrets';

export const autoSyncPaymentToQuickBooks = functions
  .runWith({
    secrets: QUICKBOOKS_SECRETS,
    timeoutSeconds: 120,
    memory: '256MB',
    ...QUICKBOOKS_VPC_CONNECTOR,
  })
  .firestore.document('facilities/{facilityId}/payments/{paymentId}')
  .onWrite(async (change, context) => {
    if (!change.after.exists) return;

    const afterData = (change.after.data() || {}) as Record<string, unknown>;
    const beforeData = (change.before.data() || {}) as Record<string, unknown>;
    const afterQuickbooks = (afterData.quickbooks || {}) as Record<string, unknown>;

    if (typeof afterQuickbooks.paymentId === 'string' && String(afterQuickbooks.paymentId).trim() !== '') return;

    const status = String(afterData.status || '').toLowerCase();
    const isPaidStatus = status === 'paid' || status === 'completed';
    if (!isPaidStatus) return;

    const beforeStatus = String(beforeData.status || '').toLowerCase();
    const becamePaid = beforeStatus !== 'paid' && beforeStatus !== 'completed';
    if (!change.before.exists || becamePaid) {
      const facilityId = context.params.facilityId as string;
      const paymentId = context.params.paymentId as string;
      await quickBooksAccounting.autoSyncPaymentIfEligible(facilityId, paymentId, getQuickBooksConfig());
    }
  });

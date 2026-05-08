import * as functions from 'firebase-functions/v1';
import * as quickBooksAccounting from './accounting/quickbooks';
import { QUICKBOOKS_SECRETS, QUICKBOOKS_VPC_CONNECTOR, getQuickBooksConfig } from './secrets';

export const autoSyncInvoiceToQuickBooks = functions
  .runWith({
    secrets: QUICKBOOKS_SECRETS,
    timeoutSeconds: 120,
    memory: '256MB',
    ...QUICKBOOKS_VPC_CONNECTOR,
  })
  .firestore.document('facilities/{facilityId}/invoices/{invoiceId}')
  .onWrite(async (change, context) => {
    if (!change.after.exists) return;

    const afterData = (change.after.data() || {}) as Record<string, unknown>;
    const beforeData = (change.before.data() || {}) as Record<string, unknown>;
    const afterQuickbooks = (afterData.quickbooks || {}) as Record<string, unknown>;

    if (typeof afterQuickbooks.invoiceId === 'string' && String(afterQuickbooks.invoiceId).trim() !== '') return;

    const status = String(afterData.status || '').toLowerCase();
    if (status === '' || status === 'draft' || status === 'voided') return;

    const beforeStatus = String(beforeData.status || '').toLowerCase();
    const beforeQuickbooks = (beforeData.quickbooks || {}) as Record<string, unknown>;
    const hadQboInvoiceId =
      typeof beforeQuickbooks.invoiceId === 'string' && String(beforeQuickbooks.invoiceId).trim() !== '';
    const statusChanged = beforeStatus !== status;
    const createdNow = !change.before.exists;
    const lineItemsChanged =
      JSON.stringify(beforeData.lineItems || []) !== JSON.stringify(afterData.lineItems || []);
    const totalChanged = Number(beforeData.total || 0) !== Number(afterData.total || 0);

    if (!createdNow && !statusChanged && !lineItemsChanged && !totalChanged && !hadQboInvoiceId) return;

    const facilityId = context.params.facilityId as string;
    const invoiceId = context.params.invoiceId as string;
    await quickBooksAccounting.autoSyncInvoiceIfEligible(facilityId, invoiceId, getQuickBooksConfig());
  });

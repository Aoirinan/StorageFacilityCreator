import * as functions from 'firebase-functions/v1';
import { enforceAppCheckOrThrow } from '@sfc/functions-shared';
import * as quickBooksAccounting from './accounting/quickbooks';
import { QUICKBOOKS_SECRETS, QUICKBOOKS_VPC_CONNECTOR, getQuickBooksConfig } from './secrets';

export const syncPaymentToQuickBooks = functions
  .runWith({ secrets: QUICKBOOKS_SECRETS, ...QUICKBOOKS_VPC_CONNECTOR })
  .https.onCall(async (data: any, context) => {
    enforceAppCheckOrThrow(context);
    return quickBooksAccounting.syncPaymentToQuickBooks(data, context, getQuickBooksConfig());
  });

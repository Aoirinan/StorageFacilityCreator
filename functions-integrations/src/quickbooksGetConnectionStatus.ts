import * as functions from 'firebase-functions/v1';
import { enforceAppCheckOrThrow } from '@sfc/functions-shared';
import * as quickBooksAccounting from './accounting/quickbooks';
import { getQuickBooksConfig } from './secrets';

export const getQuickBooksConnectionStatus = functions.https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
  return quickBooksAccounting.getQuickBooksConnectionStatus(data, context, getQuickBooksConfig());
});

import * as functions from 'firebase-functions/v1';
import { enforceAppCheckOrThrow } from '@sfc/functions-shared';
import * as quickBooksAccounting from './accounting/quickbooks';

export const setQuickBooksAutoSync = functions.https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
  return quickBooksAccounting.setQuickBooksAutoSync(data, context);
});

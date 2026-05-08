import * as functions from 'firebase-functions/v1';
import { enforceAppCheckOrThrow } from '@sfc/functions-shared';
import * as quickBooksAccounting from './accounting/quickbooks';
import { QUICKBOOKS_SECRETS, getQuickBooksConfig } from './secrets';

export const getQuickBooksConnectUrl = functions.runWith({ secrets: QUICKBOOKS_SECRETS }).https.onCall(
  async (data: any, context) => {
    enforceAppCheckOrThrow(context);
    return quickBooksAccounting.getQuickBooksConnectUrl(data, context, getQuickBooksConfig());
  },
);

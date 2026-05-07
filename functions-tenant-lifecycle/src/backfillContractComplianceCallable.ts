import * as functions from 'firebase-functions/v1';
import { isSuperAdmin } from '@sfc/functions-shared';
import { backfillContractCompliance } from './migrations/backfill_contract_compliance';

/** Super-admin only: one-shot migration for contract/template compliance fields. */
export const backfillContractComplianceFields = functions.https.onCall(async (_data: unknown, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }

  const callerEmail = context.auth.token?.email as string | undefined;
  if (!isSuperAdmin(callerEmail)) {
    throw new functions.https.HttpsError('permission-denied', 'Only super admins can run migrations');
  }

  try {
    const result = await backfillContractCompliance();
    functions.logger.info('Contract compliance backfill completed', result);
    return {
      success: true,
      message: 'Contract compliance backfill completed',
      ...result,
    };
  } catch (error: any) {
    functions.logger.error('Migration error:', error);
    throw new functions.https.HttpsError('internal', `Migration failed: ${error.message}`);
  }
});

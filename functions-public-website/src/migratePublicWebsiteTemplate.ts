import * as functions from 'firebase-functions/v1';
import { isSuperAdmin } from '@sfc/functions-shared';
import { migratePublicWebsiteV4OptionalFields } from './migrations/public_website_v4_optional_fields';

// Cloud Function to normalize public website optional v4 field containers
export const migratePublicWebsiteTemplateV4OptionalFields = functions.https.onCall(async (_data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  const callerEmail = context.auth.token?.email as string | undefined;
  if (!isSuperAdmin(callerEmail)) {
    throw new functions.https.HttpsError('permission-denied', 'Only super admins can run migrations');
  }

  try {
    const result = await migratePublicWebsiteV4OptionalFields();
    functions.logger.info('Public website v4 optional fields migration completed', result);
    return {
      success: true,
      message: 'Public website v4 optional field migration completed',
      ...result,
    };
  } catch (error: any) {
    functions.logger.error('Migration error:', error);
    throw new functions.https.HttpsError('internal', `Migration failed: ${error.message}`);
  }
});

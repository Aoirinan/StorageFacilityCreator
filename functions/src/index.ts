/**
 * Default Firebase Functions codebase — bootstrap only.
 * Stripe / facility payment HTTPS callables live in `functions-integrations` (codebase: integrations).
 */
import { defineString } from 'firebase-functions/params';
import { ensureFirebaseAdminApp, registerHostingConfigProvider } from '@sfc/functions-shared';

ensureFirebaseAdminApp();

const HOSTING_PROJECT_ID = defineString('HOSTING_PROJECT_ID', { default: 'storage-facility-creator' });
const HOSTING_SITE_ID = defineString('HOSTING_SITE_ID', { default: 'storage-facility-creator' });
registerHostingConfigProvider({
  getProjectId: () => HOSTING_PROJECT_ID.value(),
  getSiteId: () => HOSTING_SITE_ID.value(),
});

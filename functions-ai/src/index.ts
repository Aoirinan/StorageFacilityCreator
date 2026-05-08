import { ensureFirebaseAdminApp, ensureSentryForFunctions } from '@sfc/functions-shared/init';

ensureFirebaseAdminApp();
ensureSentryForFunctions();

export { aiAssistant, aiAssistantChat, aiAssistantExecuteAction } from './aiHandlers';

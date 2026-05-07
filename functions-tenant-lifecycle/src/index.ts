import { ensureFirebaseAdminApp, ensureSentryForFunctions } from '@sfc/functions-shared/init';

ensureFirebaseAdminApp();
ensureSentryForFunctions();

import {
  registerSendgridMailConfigProvider,
  registerStripeKeysProvider,
} from '@sfc/functions-shared';

import {
  SENDGRID_API_KEY,
  SENDGRID_FROM_EMAIL,
  STRIPE_PUBLISHABLE_KEY,
  STRIPE_SECRET_KEY,
} from './secrets';

registerStripeKeysProvider({
  getSecretKey: () => STRIPE_SECRET_KEY.value(),
  getPublishableKey: () => STRIPE_PUBLISHABLE_KEY.value(),
});

registerSendgridMailConfigProvider({
  getApiKey: () => SENDGRID_API_KEY.value(),
  getFromEmail: () => SENDGRID_FROM_EMAIL.value(),
});

export {
  getContractBySigningToken,
  uploadSignedContract,
  uploadSignedContractHttp,
  uploadContractPdfHttp,
  proxyContractPdfHttp,
  onContractSigned,
  tenantPortalFetch,
  tenantUpdateProfile,
  createTenantPortalPaymentCheckout,
} from './contractsPortal';

export { processMoveOut, createTenantPortalAdditionalUnitHold } from './moveOutPortalHold';

export { computeDocumentHash, mergeSignatureIntoPdf } from './documentSigningCallables';

export { backfillContractComplianceFields } from './backfillContractComplianceCallable';

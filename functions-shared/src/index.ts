export { ensureFirebaseAdminApp, ensureSentryForFunctions } from './init';
export { getFirestore } from './firestoreLazy';

export {
  SUPER_ADMIN_EMAILS_HARDCODED,
  getSuperAdminEmails,
  isSuperAdmin,
} from './auth/superAdmin';
export { enforceAppCheckOrThrow } from './auth/appCheck';
export { getFacilityDataForUserOrThrow, canAccessFacility } from './auth/facilityAccess';

export {
  extractCallableClientIp,
  validatePortalAccessCodeFormat,
  enforcePortalAuthRateLimit,
  recordPortalAuthFailure,
  clearPortalAuthFailures,
  authenticatePortalTenant,
  authenticatePortalTenantForFacility,
  resolvePortalTenantSession,
} from './portal/portalAuth';
export type { PortalTenantSession } from './portal/portalAuth';
export {
  tenantsSharePortalAccount,
  buildTenantPortalPaymentIntentMetadata,
} from './portal/portalAccountLink';
export type { PortalAccountTenantFields } from './portal/portalAccountLink';

export {
  checkSigningTokenRateLimit,
  isSigningTokenExpired,
  validateSigningTokenForContract,
} from './contracts/signingToken';

export type { RateLimitConfig } from './rateLimits/facilityRateLimit';
export { enforceRateLimit } from './rateLimits/facilityRateLimit';
export { enforceUserRateLimit } from './rateLimits/userRateLimit';
export { enforceAndConsumeDailyAiQuota, DAILY_AI_USER_LIMIT } from './rateLimits/aiDailyQuota';

export { writeAuditLog } from './audit/writeAuditLog';

export { getPublicAppUrl } from './email/urls';
export {
  escapeHtml,
  buildFacilityFooter,
  appendPlatformSecurityEmailFooter,
  appendPlatformAdminBroadcastFooter,
} from './email/footers';
export {
  getEmailUnsubscribeSecretKey,
  buildEmailUnsubscribeToken,
  parseEmailUnsubscribeToken,
} from './email/unsubscribe';
export { registerSendgridMailConfigProvider } from './email/sendgridRegistry';
export { getSgMail, getSendgridAsmGroupId, initializeSendGrid } from './email/sendgridLazy';
export { sendFacilityEmailWithCompliance, isFacilityEmailSuppressed } from './email/complianceSend';

export { registerStripeKeysProvider } from './stripe/keysRegistry';
export {
  validateStripeKeyMode,
  rejectClientSuppliedStripeKeys,
  getPlatformPublishableKey,
  getStripeClient,
} from './stripe/client';
export { subPeriodEnd, subPeriodStart, invoiceSubscriptionId } from './stripe/invoiceHelpers';
export { parseWebhookSecrets, verifyWithAnySecret } from './stripe/webhookSecrets';
export { mapStripeErrorToUserMessage } from './stripe/errors';
export { getOrCreateBasePriceId, getOrCreateAddOnPriceId } from './stripe/subscriptionPricing';

export { registerTwilioConfigProvider } from './twilio/configRegistry';
export { registerHostingConfigProvider } from './hosting/hostingConfigRegistry';
export type { HostingConfig } from './hosting/hostingConfigRegistry';
export { getTwilioClient, isTwilioDryRunEnabled } from './twilio/client';
export { verifyTwilioWebhookSignature } from './twilio/webhooks';
export type { A2PStatus } from './twilio/textingOnboardingHelpers';
export {
  buildA2PRejectionReason,
  parseA2PErrors,
} from './twilio/a2pFailureDetails';
export type { A2PFailureDetail } from './twilio/a2pFailureDetails';
export {
  formatA2PValidationIssues,
  isValidEinLast4,
  isValidFullEin,
  isValidUsPhone,
  isValidWebsite,
  validateA2PBusinessData,
} from './twilio/a2pBusinessValidation';
export type {
  A2PBusinessData,
  A2PValidationIssue,
} from './twilio/a2pBusinessValidation';
export {
  A2P_BUSINESS_IDENTITY,
  A2P_BUSINESS_INDUSTRY,
  A2P_REGIONS_OF_OPERATION,
  A2P_REGISTRATION_IDENTIFIER,
  buildA2pMessagingProfileAttributes,
  buildAddressPayload,
  buildAuthorizedRepresentativeAttributes,
  buildBusinessInformationAttributes,
  formatEvaluationFailures,
  mapBusinessType,
  normalizeEin,
  normalizeWebsiteUrl,
  summarizeEvaluation,
  toE164UsPhone,
} from './twilio/a2pTrustBundleMapping';
export type {
  AppBusinessType,
  EvaluationFieldFailure,
  EvaluationSummary,
  TrustBundleInput,
  TrustHubBusinessType,
  TrustHubCompanyType,
} from './twilio/a2pTrustBundleMapping';
export {
  normalizeKeyword,
  isStopKeyword,
  isStartKeyword,
  isHelpKeyword,
  computeA2PStatus,
  ensureIdempotentResource,
} from './twilio/textingOnboardingHelpers';

export {
  readMessagingGuardConfig,
  reservePlatformOutgoing,
  releasePlatformOutgoing,
} from './platform/platformMessagingGuard';
export type { MessagingGuardConfig } from './platform/platformMessagingGuard';

export {
  EMAIL_MONTHLY_LIMIT_TRIALING,
  EMAIL_MONTHLY_LIMIT_PAID,
  emailMonthlyLimitForAccount,
} from './constants/emailMonthlyLimits';

export { formatPhoneNumber } from './utils/phoneFormat';

export { registerSfcLeadConfigProvider } from './marketing/sfcLeadConfigRegistry';
export type { SfcLeadConfigProvider } from './marketing/sfcLeadConfigRegistry';
export {
  escapeXml,
  getConfiguredSfcLeadLine,
  isSfcLeadLineMatch,
  upsertSfcLeadFromInboundContact,
  processSfcLeadInboundSMSWebhook,
} from './marketing/sfcLeads';

export {
  getRefereePlatformTrialDays,
  processReferralOnPlatformInvoicePaid,
  resolveReferralPendingItemForSuperAdmin,
} from './referral/referralRewards';

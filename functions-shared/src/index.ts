export { ensureFirebaseAdminApp, ensureSentryForFunctions } from './init';

export {
  SUPER_ADMIN_EMAILS_HARDCODED,
  getSuperAdminEmails,
  isSuperAdmin,
} from './auth/superAdmin';
export { enforceAppCheckOrThrow } from './auth/appCheck';
export { getFacilityDataForUserOrThrow, canAccessFacility } from './auth/facilityAccess';

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
export { mapStripeErrorToUserMessage } from './stripe/errors';
export { getOrCreateBasePriceId, getOrCreateAddOnPriceId } from './stripe/subscriptionPricing';

export { registerTwilioConfigProvider } from './twilio/configRegistry';
export { registerHostingConfigProvider } from './hosting/hostingConfigRegistry';
export type { HostingConfig } from './hosting/hostingConfigRegistry';
export { getTwilioClient, isTwilioDryRunEnabled } from './twilio/client';
export { verifyTwilioWebhookSignature } from './twilio/webhooks';

export {
  readMessagingGuardConfig,
  reservePlatformOutgoing,
  releasePlatformOutgoing,
} from './platform/platformMessagingGuard';
export type { MessagingGuardConfig } from './platform/platformMessagingGuard';

export {
  superAdminGetHostingCustomDomainStatus,
  superAdminProvisionHostingCustomDomain,
} from './hosting/hostingCustomDomains';

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

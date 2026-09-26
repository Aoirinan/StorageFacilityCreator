export { ensureFirebaseAdminApp, ensureSentryForFunctions } from './init';
export { getFirestore } from './firestoreLazy';

export {
  SUPER_ADMIN_EMAILS_HARDCODED,
  getSuperAdminEmails,
  isSuperAdmin,
} from './auth/superAdmin';
export { enforceAppCheckOrThrow } from './auth/appCheck';
export {
  getFacilityDataForUserOrThrow,
  canAccessFacility,
  isFacilityOwnerOrManager,
} from './auth/facilityAccess';

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
export {
  isCustomerRecipientAllowed,
  isCustomerEmailAllowed,
  getOutboundGateConfig,
  resetOutboundGateCache,
  DEFAULT_OUTBOUND_GATE,
} from './email/customerOutboundGate';
export type { OutboundGateConfig } from './email/customerOutboundGate';
export {
  isOwnerOnboardingRecipientAllowed,
  isOwnerOnboardingEmailAllowed,
  getOwnerOnboardingGateConfig,
  resetOwnerOnboardingGateCache,
  DEFAULT_OWNER_ONBOARDING_GATE,
} from './email/ownerOnboardingGate';
export type { OwnerOnboardingGateConfig } from './email/ownerOnboardingGate';
export {
  buildAccountUnderReviewEmail,
  buildAccountApprovedEmail,
  buildNewAccountAdminAlertEmail,
} from './email/ownerOnboardingEmails';
export type {
  OwnerOnboardingEmailInput,
  AccountApprovedEmailInput,
  NewAccountAdminAlertInput,
} from './email/ownerOnboardingEmails';
export {
  buildPortalAccessCodeReminderEmail,
  buildTenantPortalInviteEmail,
  generatePortalAccessCode,
  maskEmail,
  PORTAL_ACCESS_CODE_ALPHABET,
  PORTAL_ACCESS_CODE_LENGTH,
} from './portal/portalInviteEmail';
export type { PortalInviteEmailInput } from './portal/portalInviteEmail';

export { registerStripeKeysProvider } from './stripe/keysRegistry';
export {
  validateStripeKeyMode,
  rejectClientSuppliedStripeKeys,
  getPlatformPublishableKey,
  getStripeClient,
} from './stripe/client';
export { subPeriodEnd, subPeriodStart, invoiceSubscriptionId } from './stripe/invoiceHelpers';
export { parseWebhookSecrets, verifyWithAnySecret } from './stripe/webhookSecrets';
export {
  OFFBOARDING_GRACE_DAYS,
  REDACTED_TENANT_NAME,
  buildFacilityDisconnectUpdate,
  buildTenantPiiRedaction,
  deauthorizeConnectedAccount,
  isNotConnectedStripeError,
  isOffboardingDue,
  isOrphanedConnectedAccount,
  offboardingDueAt,
  selectFacilitiesForOffboarding,
} from './stripe/connectOffboarding';
export type { FacilityDisconnectReason, OffboardingCandidate, OffboardingSelection } from './stripe/connectOffboarding';
export {
  buildOffboardingNoticeEmail,
  buildOffboardedEmail,
  buildOffboardingAdminSummaryEmail,
  sweepSummaryHasActivity,
} from './stripe/offboardingEmails';
export type { OffboardingEmailInput, OffboardingSweepSummary, EmailContent } from './stripe/offboardingEmails';
export {
  collectSubscriptionsToCancel,
  cancelSubscriptions,
  isAlreadyEndedError,
  isOrphanedSubscription,
  summarizeCancelOutcomes,
  anyCancelFailed,
} from './stripe/subscriptionCleanup';
export type {
  CancellableSubscription,
  CancelOutcome,
  CancelStatus,
  SubscriptionLabel,
  SubscriptionCanceller,
} from './stripe/subscriptionCleanup';
export { mapStripeErrorToUserMessage } from './stripe/errors';
export { getOrCreateBasePriceId, getOrCreateAddOnPriceId } from './stripe/subscriptionPricing';
export { FIRST_MONTH_FREE_COUPON_ID, getOrCreateFirstMonthFreeCouponId } from './stripe/firstMonthFreeCoupon';
export { computeAccountRollup, isLocalTrialExpired } from './subscription/accountRollup';
export type {
  AccountSubscriptionStatus,
  AccountRollupInput,
  AccountRollupResult,
  FacilitySubscriptionSnapshot,
} from './subscription/accountRollup';
export {
  OWNER_ACCOUNT_READ_LIMIT,
  OWNER_ACCOUNT_STANDING_FIELD,
  accountWriteAffectsStanding,
  buildOwnerAccountStanding,
  findOwnerAccountDoc,
  listOwnerAccountDocs,
  preferredOwnerAccountDoc,
  sameOwnerAccountStanding,
  syncOwnerAccountStanding,
} from './platform/ownerAccount';
export type { AccountDocLike, OwnerAccountStanding, OwnerStandingSyncDeps } from './platform/ownerAccount';

export { registerTwilioConfigProvider } from './twilio/configRegistry';
export { registerHostingConfigProvider } from './hosting/hostingConfigRegistry';
export type { HostingConfig } from './hosting/hostingConfigRegistry';
export { getTwilioClient, isTwilioDryRunEnabled } from './twilio/client';
export { verifyTwilioWebhookSignature, twilioWebhookUrl } from './twilio/webhooks';
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
  isSoleProprietorBusinessType,
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

export { decideFacilityAccountLink } from './platform/facilityAccountLink';
export type {
  FacilityAccountLinkDecision,
  LinkableAccount,
  LinkableFacility,
  LinkRefusalCode,
} from './platform/facilityAccountLink';

export {
  buildFacilityForOwner,
  buildOwnerRoleRow,
  FacilityForOwnerError,
  DEFAULT_GRACE_PERIOD_DAYS,
  DEFAULT_LATE_FEE_AMOUNT,
  DEFAULT_TIME_ZONE,
} from './platform/facilityForOwner';
export type { FacilityForOwnerInput, FacilityForOwnerDoc } from './platform/facilityForOwner';

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

export type {
  DocData as TenantDeleteDocData,
  HeldUnit,
  LinkedDoc,
  TenantDeleteBlock,
  TenantDeletePlan,
  TenantDeleteRecords,
  TenantHistoryCounts,
  UnitStatus,
} from './tenants/permanentDeleteRules';
export {
  MAX_TENANTS_PER_PERMANENT_DELETE,
  PERMANENT_TENANT_DELETE_NOT_ENTITLED_MESSAGE,
  TENANT_DELETE_SCAN_LIMIT,
  UNIT_STATUSES,
  buildTenantDeletePlan,
  facilityAllowsPermanentTenantDelete,
  facilityCreatorAccountIdOf,
  hasAutopaySubscription,
  isActiveFlagSet,
  isArchivedUnit,
  isLiveCardPaymentRow,
  isLiveInvoiceRow,
  isLiveLedgerRow,
  isLivePaymentRow,
  isTenantDeleteBlocked,
  permanentDeleteBlockers,
  scanLiveRows,
  tenantDisplayName,
  timestampMillis,
  toTenantDeleteBlock,
  unitStatusOf,
  unitsHeldByTenant,
} from './tenants/permanentDeleteRules';

export type { UnitNotOfferedReason } from './units/onlineRental';
export {
  enabledOnlineUnitTypes,
  isArchivedForOnlineRental,
  isInternalUseUnit,
  isUnitOfferedOnline,
  isUnitTypeOfferedOnline,
  isUnlistedUnit,
  unitNotOfferedOnlineReason,
} from './units/onlineRental';

export type { UnitLabelOptions, UnitLabelStyle } from './units/unitLabel';
export { formatUnitLabel, tenantUnitLabel, unitLabelsIncludeArea } from './units/unitLabel';

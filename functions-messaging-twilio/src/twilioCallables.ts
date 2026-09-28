import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import * as crypto from 'crypto';
import {
  formatPhoneNumber,
  isSuperAdmin,
  decideCustomerRecipient,
  isCustomerRecipientAllowed,
  getOutboundGateConfig,
  sendFacilityEmailWithCompliance,
} from '@sfc/functions-shared';
import {
  buildA2PRejectionReason,
  computeA2PStatus,
  ensureIdempotentResource,
  formatA2PValidationIssues,
  formatEvaluationFailures,
  normalizeEin,
  validateA2PBusinessData,
  isSoleProprietorBusinessType,
} from '@sfc/functions-shared';
import {
  assertTrustProductEditable,
  buildAndEvaluateTrustBundle,
  fetchTrustBundleState,
  describeBusinessDetailsLock,
  isBundleWithTwilio,
  resolveA2PPolicySids,
  type TrustBundleState,
} from './a2pTrustBundle';
import {
  buildBrandRegistrationParams,
  campaignFilingFields,
  facilityDisplayName,
  fetchUsAppToPersonCampaign,
  fileCampaignWhenBrandApproved,
  normalizeConsentMethods,
  planRegistrationReset,
  withSenderPrefix,
  type CampaignFilingResult,
} from './a2pCampaign';
import {
  assertReadyForPaidSubmission,
  resolvePaidSubmissionInput,
  runPaidSubmission,
  withA2PSubmitLease,
  type LeaseDb,
  type PaidStep,
  type PaidSubmissionReadiness,
} from './a2pSubmission';
import { reservePlatformOutgoing, releasePlatformOutgoing } from './platformOutgoing';
import { createOrUpdateMessageLog } from './messageLog';
import { getTenantInfo } from './tenantInfo';
import {
  TWILIO_ACCOUNT_SID,
  TWILIO_AUTH_TOKEN,
  TWILIO_PHONE_NUMBER,
  SENDGRID_FROM_EMAIL,
  SENDGRID_FROM_NAME,
  TWILIO_SECRETS,
  SENDGRID_SECRETS,
} from './secrets';
import { getA2PTwilioClient, getTwilioClient, isTwilioDryRunEnabled } from './twilioClient';
import { enforceRateLimit } from './rateLimit';
import { enforceAppCheckOrThrow } from './appCheck';
import { isFeatureFlagEnabled } from './featureFlags';
import { isSMSComplianceFeatureEnabled } from './smsCompliance';
import { checkQuietHours, checkPerTenantRateLimit, addOptOutFooter } from './smsComplianceHelpers';
import { SMSUsageState, checkAndIncrementSMSUsage } from './smsUsage';
import { evaluateSharedNumberSend, recordSharedNumberSend } from './sharedNumberGuard';
import { decideTenantRecipientConsent, findFacilityTenantsForNumber, tenantOptedOut } from './tenantSmsConsent';
import type { A2PTwilioClient } from './a2pTwilioTypes';

interface SMSRequest {
  to: string;
  message: string;
  facilityId: string;
  tenantId?: string; // Optional: for per-tenant tracking
  accountId?: string; // Optional: for per-account tracking
  forceSend?: boolean; // Optional: allow manual override for extreme usage
  fallbackToEmail?: boolean; // Optional: if true, send as email when SMS limit exceeded
  source?: 'manual' | 'bulk' | 'automation'; // Optional: source of the message
}

/**
 * Send SMS text message via Twilio with fair-use safeguards
 * Automatically falls back to email if SMS limits are exceeded
 */
export const sendSMS = functions.runWith({
  secrets: [...TWILIO_SECRETS, ...SENDGRID_SECRETS],
}).https.onCall(async (data: SMSRequest, context) => {
  // Verify authentication
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated to send SMS');
  }
  enforceAppCheckOrThrow(context);

  await enforceRateLimit({
    facilityId: data.facilityId,
    key: 'sendSMS',
    limit: 120, // per minute per facility; fair-use will still gate harder
    windowSeconds: 60,
    userId: context.auth.uid,
  });

  const { to, message, facilityId, tenantId, accountId, forceSend = false, fallbackToEmail = true, source } = data;

  // Validate required fields
  if (!to || !message || !facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required fields: to, message, facilityId');
  }

  // Generate message log ID early
  const messageLogId = `sms-${Date.now()}-${Math.random().toString(36).substring(2, 9)}`;

  // Format phone number early (needed in error handlers)
  let phoneNumber: string | null = null;
  try {
    phoneNumber = formatPhoneNumber(to);
  } catch (e) {
    // Will be validated later
  }

  let platformSmsReserved = false;
  let twilioSmsSendCommitted = false;
  try {
    // Verify user has access to the facility (owner or manager)
    const facilityRef = admin.firestore().collection('facilities').doc(facilityId);
    const facilityDoc = await facilityRef.get();
    const facilityData = facilityDoc.data() as Record<string, any> | undefined;

    if (!facilityDoc.exists || !facilityData) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const ownerUid = facilityData.ownerUid;
    const managersMap = (facilityData.managers ?? {}) as Record<string, any>;
    const isOwner = ownerUid === context.auth.uid;
    const isManager = managersMap[context.auth.uid ?? ''] === true;

    if (!isOwner && !isManager) {
      throw new functions.https.HttpsError(
        'permission-denied',
        'User is not authorized to send SMS for this facility',
      );
    }

    // Get account ID from facility if not provided
    const finalAccountId = accountId || facilityData.facilityCreatorAccountId;

    // Validate phone number format
    if (!phoneNumber) {
      phoneNumber = formatPhoneNumber(to);
      if (!phoneNumber) {
        throw new functions.https.HttpsError('invalid-argument', 'Invalid phone number format');
      }
    }

    // Get tenant information for message logging
    const tenantInfo = await getTenantInfo(
      facilityId,
      tenantId,
      null,
      phoneNumber,
    );

    const textingOnboardingFlag = await isFeatureFlagEnabled('TEXTING_ONBOARDING_V1');
    const textingOnboardingEnabled = textingOnboardingFlag && facilityData.textingOnboardingEnabled === true;
    const facilityA2PStatus = ((facilityData.a2pStatus as string) || 'draft').toLowerCase();
    const textingPlatformApproved = facilityData.textingPlatformApproved === true;
    // A facility whose own 10DLC campaign is not approved yet does not lose
    // texting: it sends from the platform's verified toll-free number until
    // its number clears (see resolvedFromNumber below). Blocking here left
    // Keepsake unable to text for months while its campaign sat in draft.
    if (textingOnboardingEnabled && facilityA2PStatus !== 'approved') {
      functions.logger.info('[sendSMS] facility number not approved; sending from platform number', {
        facilityId,
        a2pStatus: facilityA2PStatus,
      });
    }
    if (textingOnboardingEnabled && facilityA2PStatus === 'approved' && !textingPlatformApproved && !forceSend) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Texting is awaiting platform approval. A superadmin must approve this facility before SMS can be sent.',
      );
    }

    // Tenant opt-out and consent, enforced for every facility. Any tenant of
    // this facility whose phone is the recipient number (matched on digits,
    // as the inbound STOP handler matches) is checked, and neither the
    // facility's feature settings nor forceSend turn it off: a tenant who
    // replied STOP, or never consented, is not texted. A number that belongs
    // to no tenant (staff, a prospect) is not decided here.
    const numberTenants = await findFacilityTenantsForNumber(facilityId, phoneNumber, tenantInfo.tenantId);
    const tenantConsent = decideTenantRecipientConsent(numberTenants, tenantInfo.tenantId);
    let targetOptedOut = false;
    if (tenantInfo.tenantId && !numberTenants.some((t) => t.id === tenantInfo.tenantId)) {
      // The client named a tenant whose stored phone is not this number. Their
      // STOP still counts, as it always did.
      const targetDoc = await admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .doc(tenantInfo.tenantId)
        .get();
      targetOptedOut = targetDoc.exists && tenantOptedOut({ id: targetDoc.id, ...targetDoc.data() });
    }
    if (targetOptedOut || tenantConsent.refusal === 'opted_out') {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Tenant has opted out of SMS messages. Cannot send SMS to this number.',
      );
    }
    if (tenantConsent.refusal === 'no_consent') {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Tenant SMS consent is required before sending messages.',
      );
    }

    // Facility block list (STOP adds to it when enhancedOptOut is on).
    const smsSettings = facilityData?.smsSettings as Record<string, any> | undefined;
    const blockList = smsSettings?.blockList as string[] | undefined;
    if (Array.isArray(blockList) && blockList.includes(phoneNumber)) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'This phone number is on the facility SMS block list. Cannot send SMS.',
      );
    }

    // Check quiet hours (if enabled)
    const quietHoursEnabled = await isSMSComplianceFeatureEnabled('quietHours', facilityId);
    if (quietHoursEnabled && tenantInfo.tenantId) {
      const quietHoursCheck = await checkQuietHours(facilityId, tenantInfo.tenantId);
      if (quietHoursCheck.isQuietHours && !forceSend) {
        throw new functions.https.HttpsError(
          'failed-precondition',
          `Cannot send SMS during quiet hours. Next allowed time: ${quietHoursCheck.nextAllowedTime?.toISOString() || 'unknown'}`,
        );
      }
    }

    // Check per-tenant rate limit (if enabled)
    const rateLimitingEnabled = await isSMSComplianceFeatureEnabled('rateLimiting', facilityId);
    if (rateLimitingEnabled && tenantInfo.tenantId) {
      const rateLimitCheck = await checkPerTenantRateLimit(facilityId, tenantInfo.tenantId);
      if (!rateLimitCheck.canSend && !forceSend) {
        throw new functions.https.HttpsError(
          'resource-exhausted',
          `Tenant daily SMS limit reached (${rateLimitCheck.messagesSentToday}/${rateLimitCheck.limit}). Limit resets at ${rateLimitCheck.resetTime?.toISOString() || 'unknown'}.`,
        );
      }
    }

    // Every outbound text carries the STOP/HELP footer (see addOptOutFooter).
    let finalMessage = await addOptOutFooter(facilityId, message);

    // Get user email for message logging
    const userRecord = await admin.auth().getUser(context.auth.uid);
    const userEmail = userRecord.email;

    // Customer contact gate: the same appConfig/outbound switch that governs
    // tenant email governs this. A facility in blockedFacilityIds never texts a
    // customer; any other facility may once customerEmailsEnabled is on.
    // Numbers in allowedTestRecipients (Russell's own number is already there)
    // always go through so the team can test end to end. Checked before the
    // message log and platform-quota reservation so a blocked send is a clean
    // no-op. See functions-shared/src/email/customerOutboundGate.ts.
    const outboundGate = await getOutboundGateConfig();
    if (!isCustomerRecipientAllowed(phoneNumber, { facilityId, channel: 'sms' }, outboundGate)) {
      const gateReason = decideCustomerRecipient(phoneNumber, { facilityId, channel: 'sms' }, outboundGate).reason;
      functions.logger.info('[sendSMS] blocked by customer contact gate', {
        facilityId,
        reason: gateReason,
        toMasked: `${phoneNumber.substring(0, 5)}***${phoneNumber.slice(-2)}`,
      });
      throw new functions.https.HttpsError(
        'failed-precondition',
        gateReason === 'facility_blocked'
          ? 'Customer texting is turned off for this facility. This number is not on the test allow-list. ' +
            'A super admin can allow it by removing the facility from blockedFacilityIds or adding the ' +
            'number to allowedTestRecipients in appConfig/outbound.'
          : 'Customer texting is turned off until launch. This number is not on the test allow-list. ' +
            'A super admin can allow it by setting customerEmailsEnabled or adding the number to ' +
            'allowedTestRecipients in appConfig/outbound.',
      );
    }

    // Create message log with status "queued"
    const previewText = finalMessage.substring(0, 200);
    await createOrUpdateMessageLog(facilityId, messageLogId, {
      tenantId: tenantInfo.tenantId,
      tenantName: tenantInfo.tenantName,
      tenantEmail: tenantInfo.tenantEmail,
      tenantPhone: tenantInfo.tenantPhone || phoneNumber,
      channel: 'sms',
      direction: 'outbound',
      source: source || 'manual',
      templateId: null,
      subject: null,
      previewText: previewText,
      bodyHtmlStored: false,
      bodyTextStored: false,
      status: 'queued',
      provider: 'twilio',
      providerMessageId: null,
      errorCode: null,
      errorMessage: null,
      sentAt: null,
      createdByUid: context.auth.uid,
      createdByEmail: userEmail || null,
    });

    // Check and increment SMS usage (with all limits)
    const usageCheck = await checkAndIncrementSMSUsage(facilityId, tenantId, finalAccountId);
    
    // Handle different usage states
    if (usageCheck.state === SMSUsageState.EXTREME && !forceSend) {
      // Extreme usage: prevent all SMS unless explicitly forced
      if (fallbackToEmail) {
        // Fallback to email
        return await sendSMSAsEmail(to, message, facilityId, usageCheck);
      }
      throw new functions.https.HttpsError(
        'resource-exhausted',
        'SMS usage is extremely high. SMS scheduling is disabled. Please contact support if you need to increase your limit.',
      );
    }

    if (usageCheck.shouldFallbackToEmail && !forceSend) {
      // Exceeded limit: fallback to email
      if (fallbackToEmail) {
        return await sendSMSAsEmail(to, message, facilityId, usageCheck);
      }
      throw new functions.https.HttpsError(
        'resource-exhausted',
        usageCheck.warning || 'SMS fair-use limit exceeded. Messages will be sent via email instead.',
      );
    }

    if (!usageCheck.canSendSMS && !forceSend) {
      // Limit exceeded but not in fallback mode
      if (fallbackToEmail) {
        return await sendSMSAsEmail(to, message, facilityId, usageCheck);
      }
      throw new functions.https.HttpsError(
        'resource-exhausted',
        usageCheck.warning || 'SMS quota exceeded',
      );
    }

    // Phone number already formatted above

    // Send SMS via Twilio
    // Get credentials from Firebase Functions secrets
    // #region agent log
    functions.logger.info('ðŸ” [sendSMS:H6] Starting credential retrieval', {
      facilityId,
      toNumberMasked: `${phoneNumber.substring(0, 4)}****${phoneNumber.substring(phoneNumber.length - 4)}`,
      messageLength: message.length,
    });
    // #endregion
    
    let twilioAccountSid: string;
    let twilioAuthToken: string;
    let twilioPhoneNumber: string;
    
    try {
      // Trim whitespace (including \r\n) that may be present if secrets were set via echo/file
      twilioAccountSid = TWILIO_ACCOUNT_SID.value().trim();
      // #region agent log
      functions.logger.info('ðŸ” [sendSMS:H6] Account SID retrieved', {
        accountSidLength: twilioAccountSid.length,
        accountSidPrefix: twilioAccountSid.substring(0, 8),
        isEmpty: !twilioAccountSid,
      });
      // #endregion
    } catch (e: any) {
      // #region agent log
      functions.logger.error('âŒ [sendSMS:H6] Failed to retrieve TWILIO_ACCOUNT_SID', {
        error: e.message,
        errorType: e.constructor.name,
      });
      // #endregion
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Twilio Account SID not configured. Please set TWILIO_ACCOUNT_SID in Firebase Functions environment.',
        { originalError: e.message },
      );
    }
    
    try {
      twilioAuthToken = TWILIO_AUTH_TOKEN.value().trim();
      // #region agent log
      functions.logger.info('ðŸ” [sendSMS:H6] Auth Token retrieved', {
        authTokenLength: twilioAuthToken.length,
        authTokenMasked: `****${twilioAuthToken.substring(Math.max(0, twilioAuthToken.length - 4))}`,
        isEmpty: !twilioAuthToken,
      });
      // #endregion
    } catch (e: any) {
      // #region agent log
      functions.logger.error('âŒ [sendSMS:H6] Failed to retrieve TWILIO_AUTH_TOKEN', {
        error: e.message,
        errorType: e.constructor.name,
      });
      // #endregion
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Twilio Auth Token not configured. Please set TWILIO_AUTH_TOKEN secret in Firebase Functions.',
        { originalError: e.message },
      );
    }
    
    try {
      twilioPhoneNumber = TWILIO_PHONE_NUMBER.value().trim();
      // #region agent log
      functions.logger.info('ðŸ” [sendSMS:H6] Phone Number retrieved', {
        phoneNumber: twilioPhoneNumber,
        isEmpty: !twilioPhoneNumber,
      });
      // #endregion
    } catch (e: any) {
      // #region agent log
      functions.logger.error('âŒ [sendSMS:H6] Failed to retrieve TWILIO_PHONE_NUMBER', {
        error: e.message,
        errorType: e.constructor.name,
      });
      // #endregion
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Twilio Phone Number not configured. Please set TWILIO_PHONE_NUMBER in Firebase Functions environment.',
        { originalError: e.message },
      );
    }

    if (!twilioAccountSid || !twilioAuthToken || !twilioPhoneNumber) {
      // #region agent log
      functions.logger.error('âŒ [sendSMS:H6] Twilio credentials validation failed', {
        hasAccountSid: !!twilioAccountSid,
        hasAuthToken: !!twilioAuthToken,
        hasPhoneNumber: !!twilioPhoneNumber,
        accountSidLength: twilioAccountSid?.length || 0,
        authTokenLength: twilioAuthToken?.length || 0,
        phoneNumberLength: twilioPhoneNumber?.length || 0,
      });
      // #endregion
      throw new functions.https.HttpsError(
        'failed-precondition',
        'SMS service not configured. One or more Twilio credentials are missing. Please configure TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN (secret), and TWILIO_PHONE_NUMBER in Firebase Functions.',
      );
    }

    const facilityDedicatedFromNumber = (facilityData.twilioPhoneNumberE164 as string | undefined) || null;
    const resolvedFromNumber = (textingOnboardingEnabled && facilityA2PStatus === 'approved' && facilityDedicatedFromNumber)
      ? facilityDedicatedFromNumber
      : twilioPhoneNumber;

    // A facility on the shared number may send while its account is in good
    // standing (trialing, active or billing-exempt), whether or not it has
    // filed its own registration, and within a monthly ceiling. Enforced here
    // as well as in the automated reminder job, so the rule cannot be
    // sidestepped by sending by hand. forceSend does not override it: this is
    // a carrier-facing limit, not a convenience check.
    const sharedDecision = await evaluateSharedNumberSend({
      facilityId,
      facilityData,
      usesOwnNumber: resolvedFromNumber !== twilioPhoneNumber,
    });
    if (!sharedDecision.allowed) {
      functions.logger.info('[sendSMS] held by shared-number policy', {
        facilityId,
        refusal: sharedDecision.refusal,
      });
      throw new functions.https.HttpsError(
        'failed-precondition',
        sharedDecision.message ?? 'Texting for this facility is not available right now.',
      );
    }

    // Every text opens with the facility's name. On the shared platform number
    // that is the only way the recipient can tell who is texting; on a
    // facility's own registered number it keeps live traffic identical to the
    // samples filed with the facility's campaign, which all open with the name.
    finalMessage = withSenderPrefix(facilityData, finalMessage);

    // Safe debug logging (masked for security)
    // #region agent log
    functions.logger.info('ðŸ” [sendSMS:H6] Twilio Credentials Validated', {
      accountSid: twilioAccountSid, // Full SID is safe to log (it's public)
      accountSidLength: twilioAccountSid.length,
      authTokenMasked: `****${twilioAuthToken.substring(twilioAuthToken.length - 4)}`, // Last 4 chars only
      authTokenLength: twilioAuthToken.length,
      fromNumber: resolvedFromNumber,
      toNumberMasked: `${phoneNumber.substring(0, 4)}****${phoneNumber.substring(phoneNumber.length - 4)}`, // First 4 + last 4
      messageLength: message.length,
    });
    // #endregion

    // Use Twilio REST API to send SMS
    await reservePlatformOutgoing('sms');
    platformSmsReserved = true;
    const twilioUrl = `https://api.twilio.com/2010-04-01/Accounts/${twilioAccountSid}/Messages.json`;
    const auth = Buffer.from(`${twilioAccountSid}:${twilioAuthToken}`).toString('base64');

    // #region agent log
    functions.logger.info('ðŸ” [sendSMS:H6] Preparing Twilio API request', {
      twilioUrl: twilioUrl.substring(0, 50) + '...', // Log URL structure only
      authHeaderPrefix: `Basic ${auth.substring(0, 10)}...`, // First 10 chars of base64
      toNumber: phoneNumber,
      fromNumber: resolvedFromNumber,
      messageLength: message.length,
    });
    // #endregion

    const formData = new URLSearchParams();
    formData.append('To', phoneNumber);
    formData.append('From', resolvedFromNumber);
    formData.append('Body', finalMessage); // Use finalMessage which includes footer if compliance enabled

    let response: Awaited<ReturnType<typeof fetch>>;
    let errorResponse: any = null;

    try {
      // #region agent log
      functions.logger.info('ðŸ” [sendSMS:H6] Calling Twilio API', {
        url: twilioUrl,
        method: 'POST',
        hasAuthHeader: !!auth,
        authHeaderLength: auth.length,
      });
      // #endregion
      
      response = await fetch(twilioUrl, {
        method: 'POST',
        headers: {
          'Authorization': `Basic ${auth}`,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: formData.toString(),
      });

      // #region agent log
      functions.logger.info('ðŸ” [sendSMS:H6] Twilio API response received', {
        status: response.status,
        statusText: response.statusText,
        ok: response.ok,
      });
      // #endregion

      if (!response.ok) {
        const errorText = await response.text();
        try {
          errorResponse = JSON.parse(errorText);
        } catch {
          errorResponse = { message: errorText };
        }

        // Log structured Twilio error
        // #region agent log
        functions.logger.error('âŒ [sendSMS:H6] Twilio API Error:', {
          status: response.status,
          statusText: response.statusText,
          errorCode: errorResponse.code,
          errorMessage: errorResponse.message,
          moreInfo: errorResponse.more_info,
          accountSidUsed: twilioAccountSid, // For debugging
          accountSidPrefix: twilioAccountSid.substring(0, 8),
          authTokenLength: twilioAuthToken.length,
          phoneNumber: twilioPhoneNumber,
          toNumber: phoneNumber,
        });
        // #endregion

        // Map Twilio errors to proper HttpsError
        if (response.status === 401) {
          // Authentication error - credentials are wrong
          throw new functions.https.HttpsError(
            'unauthenticated',
            `Twilio authentication failed: ${errorResponse.message || 'Invalid Account SID or Auth Token'}. Please verify credentials in Firebase Secrets.`,
            {
              twilioErrorCode: errorResponse.code,
              twilioMoreInfo: errorResponse.more_info,
              accountSidUsed: twilioAccountSid.substring(0, 8) + '...', // First 8 chars for debugging
            },
          );
        } else if (response.status === 400) {
          // Bad request - might be A2P, invalid number, etc.
          throw new functions.https.HttpsError(
            'invalid-argument',
            `Twilio request failed: ${errorResponse.message || 'Invalid request parameters'}`,
            {
              twilioErrorCode: errorResponse.code,
              twilioMoreInfo: errorResponse.more_info,
            },
          );
        } else if (response.status === 403) {
          // Forbidden - A2P or permission issue
          // Check for specific A2P 10DLC error codes
          const errorCode = errorResponse.code?.toString() || '';
          const errorMessage = errorResponse.message || '';
          let userMessage = errorMessage || 'A2P registration may be required or account lacks permissions';
          
          if (errorCode === '30034' || errorCode === '30008' || errorMessage.toLowerCase().includes('a2p') || errorMessage.toLowerCase().includes('unregistered')) {
            userMessage = 'A2P 10DLC registration is not complete. Your message was accepted by Twilio but cannot be delivered until A2P 10DLC brand and campaign registration is approved (typically takes 24-48 hours). Please check your A2P 10DLC registration status in Twilio Console > Messaging > Regulatory Compliance.';
          }
          
          throw new functions.https.HttpsError(
            'permission-denied',
            `Twilio request forbidden: ${userMessage}`,
            {
              twilioErrorCode: errorResponse.code,
              twilioMoreInfo: errorResponse.more_info,
              a2pRegistrationRequired: errorCode === '30034' || errorCode === '30008',
            },
          );
        } else {
          // Other errors
          throw new functions.https.HttpsError(
            'internal',
            `Twilio API error (${response.status}): ${errorResponse.message || 'Unknown error'}`,
            {
              twilioErrorCode: errorResponse.code,
              twilioMoreInfo: errorResponse.more_info,
            },
          );
        }
      }
    } catch (e) {
      // If it's already an HttpsError, rethrow it
      if (e instanceof functions.https.HttpsError) {
        throw e;
      }
      // Network or other errors
      functions.logger.error('âŒ [sendSMS] Unexpected error calling Twilio:', e);
      throw new functions.https.HttpsError(
        'internal',
        `Failed to communicate with Twilio: ${e instanceof Error ? e.message : 'Unknown error'}`,
        { originalError: e instanceof Error ? e.toString() : String(e) },
      );
    }

    const result = await response.json();

    // Log full Twilio response for debugging delivery status
    functions.logger.info(`âœ… [sendSMS] Twilio API Response:`, {
      messageId: result.sid,
      status: result.status, // 'queued', 'sent', 'delivered', 'failed', 'undelivered'
      to: result.to,
      from: result.from,
      dateCreated: result.date_created,
      dateSent: result.date_sent,
      errorCode: result.error_code,
      errorMessage: result.error_message,
      price: result.price,
      priceUnit: result.price_unit,
      uri: result.uri,
    });

    // Check for A2P 10DLC errors even with 200 status (message accepted but not deliverable)
    const errorCode = result.error_code?.toString() || '';
    const errorMessage = result.error_message || '';
    const messageStatus = result.status || '';

    // A2P 10DLC errors: 30034 (unregistered number), 30008 (A2P registration required)
    if (errorCode === '30034' || errorCode === '30008' || 
        errorMessage.toLowerCase().includes('a2p') || 
        errorMessage.toLowerCase().includes('unregistered') ||
        (messageStatus === 'undelivered' && (errorCode === '30034' || errorCode === '30008'))) {
      
      functions.logger.warn(`âš ï¸ [sendSMS] A2P 10DLC Registration Required:`, {
        messageId: result.sid,
        status: messageStatus,
        errorCode: errorCode,
        errorMessage: errorMessage,
        to: result.to,
      });

      // Update message log to "failed"
      await createOrUpdateMessageLog(facilityId, messageLogId, {
        tenantId: tenantInfo.tenantId,
        tenantName: tenantInfo.tenantName,
        tenantEmail: tenantInfo.tenantEmail,
        tenantPhone: tenantInfo.tenantPhone || phoneNumber,
        channel: 'sms',
        direction: 'outbound',
        source: source || 'manual',
        templateId: null,
        subject: null,
        previewText: previewText,
        bodyHtmlStored: false,
        bodyTextStored: false,
        status: 'failed',
        provider: 'twilio',
        providerMessageId: result.sid,
        errorCode: errorCode,
        errorMessage: errorMessage,
        sentAt: null,
        createdByUid: context.auth.uid,
        createdByEmail: userEmail || null,
      });

      // Also log to legacy smsLogs collection
      await admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('smsLogs')
        .add({
          to: phoneNumber,
          message,
          status: 'failed',
          messageId: result.sid,
          twilioStatus: messageStatus,
          errorCode: errorCode,
          errorMessage: errorMessage,
          a2pRegistrationRequired: true,
          timestamp: admin.firestore.FieldValue.serverTimestamp(),
          facilityId,
          sentBy: context.auth.uid,
        });

      // Return error to user with helpful message
      throw new functions.https.HttpsError(
        'failed-precondition',
        'A2P 10DLC registration is not complete. Your message was accepted by Twilio but cannot be delivered until A2P 10DLC brand and campaign registration is approved (typically takes 24-48 hours). Please check your A2P 10DLC registration status in Twilio Console > Messaging > Regulatory Compliance.',
        {
          twilioErrorCode: errorCode,
          twilioErrorMessage: errorMessage,
          messageId: result.sid,
          a2pRegistrationRequired: true,
        },
      );
    }

    // Check for "queued" status - message accepted but waiting for delivery (often A2P campaign pending)
    if (messageStatus === 'queued') {
      functions.logger.warn(`âš ï¸ [sendSMS] Message queued (may be waiting for A2P campaign approval):`, {
        messageId: result.sid,
        status: messageStatus,
        to: result.to,
        dateCreated: result.date_created,
      });
      
      // Still log as success since Twilio accepted it, but note the queued status
      // The message will deliver once A2P campaign is approved
    }

    // Update message log to "sent"
    const finalStatus = (messageStatus === 'failed' || messageStatus === 'undelivered') ? 'failed' : 'sent';
    await createOrUpdateMessageLog(facilityId, messageLogId, {
      tenantId: tenantInfo.tenantId,
      tenantName: tenantInfo.tenantName,
      tenantEmail: tenantInfo.tenantEmail,
      tenantPhone: tenantInfo.tenantPhone || phoneNumber,
      channel: 'sms',
      direction: 'outbound',
      source: source || 'manual',
      templateId: null,
      subject: null,
      previewText: previewText,
      bodyHtmlStored: false,
      bodyTextStored: false,
      status: finalStatus,
      provider: 'twilio',
      providerMessageId: result.sid,
      errorCode: errorCode || null,
      errorMessage: errorMessage || null,
      sentAt: admin.firestore.Timestamp.now(),
      createdByUid: context.auth.uid,
      createdByEmail: userEmail || null,
    });

    // Also log to legacy smsLogs collection
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('smsLogs')
      .add({
        to: phoneNumber,
        message: finalMessage, // Use finalMessage which includes footer if compliance enabled
        status: messageStatus || 'sent', // Use Twilio's status
        messageId: result.sid,
        twilioStatus: messageStatus,
        errorCode: errorCode || null,
        errorMessage: errorMessage || null,
        timestamp: admin.firestore.FieldValue.serverTimestamp(),
        facilityId,
        sentBy: context.auth.uid,
      });

    // Warn if status indicates potential issues
    if (messageStatus === 'failed' || messageStatus === 'undelivered' || errorCode) {
      functions.logger.warn(`âš ï¸ [sendSMS] Twilio message may have delivery issues:`, {
        messageId: result.sid,
        status: messageStatus,
        errorCode: errorCode,
        errorMessage: errorMessage,
        to: result.to,
      });
    }

    functions.logger.info(`SMS sent successfully to ${phoneNumber} for facility ${facilityId}`, {
      messageId: result.sid,
      twilioStatus: messageStatus,
      facilityId,
    });

    // Prepare status message based on Twilio response status.
    // "queued" is Twilio's normal first status; only warn about A2P when the
    // message went out on a facility's own number whose campaign is not yet
    // approved. Sends from the shared, carrier-verified toll-free number
    // deliver normally, so do not scare the operator with a campaign notice.
    const sentFromPlatformNumber = resolvedFromNumber === twilioPhoneNumber;
    let statusMessage: string | undefined;
    if (messageStatus === 'queued') {
      statusMessage = sentFromPlatformNumber
        ? 'Message accepted and queued for delivery.'
        : 'Message accepted and queued. It will be delivered once this facility\'s A2P 10DLC campaign is approved (typically 1-7 business days). Check Twilio Console for campaign status.';
    } else if (messageStatus === 'sent') {
      statusMessage = 'Message sent to carrier. Delivery confirmation pending.';
    } else if (messageStatus === 'delivered') {
      statusMessage = 'Message delivered successfully.';
    }

    twilioSmsSendCommitted = true;
    // Counted only once the carrier has it, so a failed send does not consume
    // the facility's shared-number allowance for the month.
    if (resolvedFromNumber === twilioPhoneNumber) {
      await recordSharedNumberSend(facilityId);
    }
    return {
      success: true,
      messageId: result.sid,
      messageLogId: messageLogId,
      status: finalStatus,
      provider: 'twilio',
      providerMessageId: result.sid,
      twilioStatus: messageStatus,
      statusMessage: statusMessage,
      usageWarning: usageCheck.warning,
      usageState: usageCheck.state,
      fallbackUsed: false,
      usage: usageCheck.usage,
    };

  } catch (error: any) {
    if (platformSmsReserved && !twilioSmsSendCommitted) {
      await releasePlatformOutgoing('sms').catch((err) =>
        functions.logger.warn('releasePlatformOutgoing sms', err),
      );
    }
    // If it's already an HttpsError (from Twilio auth, invalid args, etc.), rethrow it
    if (error instanceof functions.https.HttpsError) {
      // Update message log to "failed"
      try {
        const tenantInfo = await getTenantInfo(facilityId, tenantId, null, phoneNumber || to);
        const userRecord = await admin.auth().getUser(context.auth.uid);
        const userEmail = userRecord.email;
        const previewText = message.substring(0, 200);

        await createOrUpdateMessageLog(facilityId, messageLogId, {
          tenantId: tenantInfo.tenantId,
          tenantName: tenantInfo.tenantName,
          tenantEmail: tenantInfo.tenantEmail,
          tenantPhone: tenantInfo.tenantPhone || phoneNumber || to,
          channel: 'sms',
          direction: 'outbound',
          source: source || 'manual',
          templateId: null,
          subject: null,
          previewText: previewText,
          bodyHtmlStored: false,
          bodyTextStored: false,
          status: 'failed',
          provider: 'twilio',
          providerMessageId: null,
          errorCode: error.code,
          errorMessage: error.message || 'Unknown error',
          sentAt: null,
          createdByUid: context.auth.uid,
          createdByEmail: userEmail || null,
        });
      } catch (logError) {
        // Don't fail if logging fails
        functions.logger.warn('Failed to log SMS failure to messageLogs:', logError);
      }

      // Also log to legacy smsLogs collection
      try {
        await admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('smsLogs')
          .add({
            to: phoneNumber || to,
            message,
            status: 'failed',
            error: error.message,
            timestamp: admin.firestore.FieldValue.serverTimestamp(),
            facilityId,
            sentBy: context.auth.uid,
          });
      } catch (logError) {
        // Don't fail if logging fails
        functions.logger.warn('Failed to log SMS failure to Firestore:', logError);
      }
      throw error; // Rethrow the original HttpsError with proper code
    }

    // For unexpected errors, convert to internal error
    functions.logger.error(
      `Failed to send SMS to ${to} for facility ${facilityId}`,
      { error: error?.message, stack: error?.stack, facilityId, to },
    );

    // Update message log to "failed"
    try {
      const phoneNumber = formatPhoneNumber(to);
      const tenantInfo = await getTenantInfo(facilityId, tenantId, null, phoneNumber || to);
      const userRecord = await admin.auth().getUser(context.auth.uid);
      const userEmail = userRecord.email;
      const previewText = message.substring(0, 200);

      await createOrUpdateMessageLog(facilityId, messageLogId, {
        tenantId: tenantInfo.tenantId,
        tenantName: tenantInfo.tenantName,
        tenantEmail: tenantInfo.tenantEmail,
        tenantPhone: tenantInfo.tenantPhone || phoneNumber || to,
        channel: 'sms',
        direction: 'outbound',
        source: source || 'manual',
        templateId: null,
        subject: null,
        previewText: previewText,
        bodyHtmlStored: false,
        bodyTextStored: false,
        status: 'failed',
        provider: 'twilio',
        providerMessageId: null,
        errorCode: 'internal',
        errorMessage: error?.message || 'Unknown error',
        sentAt: null,
        createdByUid: context.auth.uid,
        createdByEmail: userEmail || null,
      });
    } catch (logError) {
      // Don't fail if logging fails
      functions.logger.warn('Failed to log SMS failure to messageLogs:', logError);
    }

    // Also log to legacy smsLogs collection
    try {
      await admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('smsLogs')
        .add({
          to,
          message,
          status: 'failed',
          error: error.message,
          timestamp: admin.firestore.FieldValue.serverTimestamp(),
          facilityId,
          sentBy: context.auth.uid,
        });
    } catch (logError) {
      // Don't fail if logging fails
      functions.logger.warn('Failed to log SMS failure to Firestore:', logError);
    }

    throw new functions.https.HttpsError('internal', `Failed to send SMS: ${error.message}`);
  }
});

/**
 * Fallback function: Send SMS message as email when SMS limits are exceeded
 */
async function sendSMSAsEmail(
  to: string,
  message: string,
  facilityId: string,
  usageCheck: any,
): Promise<{
  success: boolean;
  fallbackUsed: boolean;
  messageId?: string;
  usageWarning?: string;
  usageState: string;
}> {
  let platformEmailReserved = false;
  let fallbackEmailActuallySent = false;
  try {
    // Get tenant email if 'to' is a phone number, or use 'to' if it's already an email
    let emailAddress = to;
    
    // If 'to' looks like a phone number, try to find tenant email
    const phoneDigits = to.replace(/\D/g, '');
    if (/^\+?[1-9]\d{1,14}$/.test(phoneDigits)) {
      // It's a phone number - try to find tenant by phone (normalize formats)
      const phoneVariations = [
        to, // Original
        phoneDigits, // Digits only
        `+1${phoneDigits}`, // US format
        phoneDigits.startsWith('1') ? phoneDigits : `1${phoneDigits}`, // With country code
      ];

      let tenantFound = false;
      for (const phoneVar of phoneVariations) {
        const tenantsQuery = await admin.firestore()
          .collection('tenants')
          .where('phone', '==', phoneVar)
          .limit(1)
          .get();
        
        if (!tenantsQuery.empty) {
          const tenantData = tenantsQuery.docs[0].data();
          emailAddress = tenantData.email;
          if (emailAddress) {
            tenantFound = true;
            break;
          }
        }
      }

      if (!tenantFound || !emailAddress) {
        // No tenant found or no email - can't send email fallback
        functions.logger.warn(`Cannot send email fallback: no tenant email found for phone ${to}`);
        return {
          success: false,
          fallbackUsed: true,
          usageState: usageCheck.state,
          usageWarning: 'SMS limit exceeded and no email address found for fallback',
        };
      }
    }

    // Format message as email with SMS-style template
    const emailSubject = 'Message from Storage Facility';
    const emailHtml = `
      <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
        <h2 style="color: #333;">Message from Your Storage Facility</h2>
        <div style="background-color: #f5f5f5; padding: 20px; border-radius: 5px; margin: 20px 0;">
          <p style="margin: 0; white-space: pre-wrap;">${message}</p>
        </div>
        <p style="color: #666; font-size: 12px; margin-top: 20px;">
          This message was sent via email because SMS fair-use limits have been reached.
          All features remain available - messages are automatically converted to email when needed.
        </p>
      </div>
    `;
    const emailText = message + '\n\n---\nThis message was sent via email because SMS fair-use limits have been reached.';

    const facilitySnap = await admin.firestore().collection('facilities').doc(facilityId).get();
    const fd = facilitySnap.exists ? facilitySnap.data() : {};
    const facilityName = (fd?.name as string) || 'Storage Facility';

    let tenantIdForToken = '';
    try {
      const tenantsSnap = await admin
        .firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .where('email', '==', emailAddress)
        .limit(1)
        .get();
      if (!tenantsSnap.empty) tenantIdForToken = tenantsSnap.docs[0].id;
    } catch {
      /* ignore lookup failures */
    }

    await reservePlatformOutgoing('email');
    platformEmailReserved = true;
    const sendResult = await sendFacilityEmailWithCompliance(
      {
        to: emailAddress,
        from: {
          email: SENDGRID_FROM_EMAIL.value(),
          name: (fd?.name as string) || SENDGRID_FROM_NAME.value(),
        },
        subject: emailSubject,
      },
      emailHtml,
      emailText,
      {
        facilityId,
        tenantId: tenantIdForToken || null,
        facilityName,
        facilityAddress: (fd?.address as string) || null,
        facilityPhone: (fd?.phone as string) || null,
      },
    );

    if (!sendResult.sent) {
      await releasePlatformOutgoing('email').catch((err) =>
        functions.logger.warn('releasePlatformOutgoing sms-as-email', err),
      );
      platformEmailReserved = false;
      // The shared helper asks the customer contact gate (email channel, this
      // facility) before it sends. The local copy this used to call did not,
      // so the SMS-limit email fallback reached tenants the gate had closed.
      const blockedByGate = sendResult.blocked === 'prelaunch';
      functions.logger.warn(
        blockedByGate
          ? 'SMS email fallback blocked by customer contact gate'
          : 'SMS email fallback skipped (unsubscribed)',
        { facilityId },
      );
      return {
        success: false,
        fallbackUsed: true,
        usageState: usageCheck.state,
        usageWarning: blockedByGate
          ? 'SMS limit exceeded; email not sent (customer contact is turned off for this facility).'
          : 'SMS limit exceeded; email not sent (recipient unsubscribed).',
      };
    }

    fallbackEmailActuallySent = true;
    const messageId = sendResult.messageId || `email-${Date.now()}`;

    // Log fallback email send
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('smsLogs')
      .add({
        to: emailAddress,
        originalTo: to,
        message,
        status: 'sent_via_email_fallback',
        messageId: messageId,
        timestamp: admin.firestore.FieldValue.serverTimestamp(),
        facilityId,
        usageState: usageCheck.state,
        reason: 'SMS limit exceeded - automatic email fallback',
      });

    functions.logger.info(`SMS fallback: Sent as email to ${emailAddress} for facility ${facilityId}`, {
      messageId,
      facilityId,
      usageState: usageCheck.state,
    });

    return {
      success: true,
      fallbackUsed: true,
      messageId: messageId,
      usageWarning: usageCheck.warning,
      usageState: usageCheck.state,
    };
  } catch (error: any) {
    if (platformEmailReserved && !fallbackEmailActuallySent) {
      await releasePlatformOutgoing('email').catch((err) =>
        functions.logger.warn('releasePlatformOutgoing sms-as-email (catch)', err),
      );
    }
    functions.logger.error(`Failed to send SMS fallback email: ${error.message}`, error);
    return {
      success: false,
      fallbackUsed: true,
      usageState: usageCheck.state,
      usageWarning: 'SMS limit exceeded and email fallback failed',
    };
  }
}

type A2PStatus = 'draft' | 'submitted' | 'pending' | 'approved' | 'rejected';

interface TextingBusinessData {
  legalBusinessName: string;
  dba?: string;
  businessType: 'LLC' | 'Corp' | 'Nonprofit' | 'Sole Prop';
  ein?: string;
  soleProprietorTaxIdLast4?: string;
  /**
   * Owner's mobile for sole-proprietor registration. Twilio texts a one-time
   * code to it to verify the owner in place of an EIN. Required only when
   * businessType is 'Sole Prop'.
   */
  mobilePhone?: string;
  addressLine1: string;
  city: string;
  state: string;
  postalCode: string;
  country?: string;
  website: string;
  supportEmail: string;
  supportPhone: string;
  /**
   * Authorized representative the carrier can hold accountable for the brand.
   * Required by the customer profile policy (`authorized_representative_1`).
   */
  representativeFirstName?: string;
  representativeLastName?: string;
  representativeBusinessTitle?: string;
}

interface CampaignData {
  useCases: string[];
  sampleMessages: string[];
  consentConfirmed: boolean;
  /** How tenants agree to texts; see CONSENT_METHODS in a2pCampaign.ts. */
  consentMethods?: string[];
  /** Preferred area code for the facility's number. */
  areaCode?: string;
}

interface TextingOnboardingState {
  a2pStatus: A2PStatus;
  a2pLastError?: string;
  textingPlatformApproved?: boolean;
  textingPlatformApprovedAt?: admin.firestore.Timestamp;
  twilioMessagingServiceSid?: string;
  twilioTrustProfileSid?: string;
  twilioTrustProductSid?: string;
  twilioBrandSid?: string;
  twilioCampaignSid?: string;
  twilioPhoneNumberSid?: string;
  twilioPhoneNumberE164?: string;
}

async function assertTextingOnboardingEnabled(facilityId: string): Promise<void> {
  const enabled = await isFeatureFlagEnabled('TEXTING_ONBOARDING_V1');
  if (!enabled) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Texting onboarding is disabled. Enable TEXTING_ONBOARDING_V1 first.',
    );
  }
}

async function getFacilityForTextingMutation(
  facilityId: string,
  uid: string,
): Promise<{ ref: admin.firestore.DocumentReference; data: Record<string, any> }> {
  const ref = admin.firestore().collection('facilities').doc(facilityId);
  const doc = await ref.get();
  const data = doc.data() as Record<string, any> | undefined;
  if (!doc.exists || !data) {
    throw new functions.https.HttpsError('not-found', 'Facility not found');
  }

  const ownerUid = data.ownerUid;
  const managersMap = (data.managers ?? {}) as Record<string, any>;
  const rolesMap = (data.roles ?? {}) as Record<string, any>;
  const isOwner = ownerUid === uid;
  const isManager = managersMap[uid] === true || rolesMap[uid] === 'manager' || rolesMap[uid] === 'owner';
  if (!isOwner && !isManager) {
    throw new functions.https.HttpsError('permission-denied', 'Not authorized for this facility');
  }

  return { ref, data };
}

function buildTwilioDryRunSid(prefix: string, facilityId: string): string {
  const normalized = facilityId.replace(/[^a-zA-Z0-9]/g, '').slice(0, 24).padEnd(24, '0');
  return `${prefix}${normalized}`;
}

async function ensureMessagingServiceForFacility(
  facilityRef: admin.firestore.DocumentReference,
  facilityData: Record<string, any>,
  requestId: string,
): Promise<{ messagingServiceSid: string; created: boolean }> {
  const existing = facilityData.twilioMessagingServiceSid as string | undefined;
  const idempotent = await ensureIdempotentResource(
    existing,
    async () => {
      if (isTwilioDryRunEnabled()) {
        return { sid: buildTwilioDryRunSid('MG', facilityRef.id) };
      }
      const twilio = getTwilioClient() as any;
      return await twilio.messaging.v1.services.create({
        friendlyName: `SFC-${facilityRef.id}-Messaging`,
      });
    },
    (resource: any) => resource.sid as string,
  );

  if (idempotent.created) {
    await facilityRef.set({
      twilioMessagingServiceSid: idempotent.sid,
      a2pLastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    functions.logger.info('Created messaging service', { requestId, facilityId: facilityRef.id });
  }
  return { messagingServiceSid: idempotent.sid, created: idempotent.created };
}

async function provisionFacilityPhoneNumber(
  facilityRef: admin.firestore.DocumentReference,
  facilityData: Record<string, any>,
  areaCode: string | undefined,
  requestId: string,
): Promise<{ phoneNumberSid: string; phoneNumberE164: string; created: boolean }> {
  const existingSid = facilityData.twilioPhoneNumberSid as string | undefined;
  const existingE164 = facilityData.twilioPhoneNumberE164 as string | undefined;
  if (existingSid && existingE164) {
    return { phoneNumberSid: existingSid, phoneNumberE164: existingE164, created: false };
  }

  if (isTwilioDryRunEnabled()) {
    const sid = buildTwilioDryRunSid('PN', facilityRef.id);
    const e164 = `+1555${Math.floor(Math.random() * 9000000 + 1000000)}`;
    await facilityRef.set({
      twilioPhoneNumberSid: sid,
      twilioPhoneNumberE164: e164,
      a2pLastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    return { phoneNumberSid: sid, phoneNumberE164: e164, created: true };
  }

  const twilio = getTwilioClient() as any;
  const numbers = await twilio.availablePhoneNumbers('US').local.list({
    smsEnabled: true,
    limit: 1,
    ...(areaCode ? { areaCode } : {}),
  });
  if (!numbers?.length) {
    throw new functions.https.HttpsError('resource-exhausted', 'No local Twilio number available for requested area');
  }

  const purchased = await twilio.incomingPhoneNumbers.create({
    phoneNumber: numbers[0].phoneNumber,
  });

  await facilityRef.set({
    twilioPhoneNumberSid: purchased.sid,
    twilioPhoneNumberE164: purchased.phoneNumber,
    a2pLastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });
  functions.logger.info('Provisioned Twilio number', { requestId, facilityId: facilityRef.id, phoneSid: purchased.sid });
  return { phoneNumberSid: purchased.sid, phoneNumberE164: purchased.phoneNumber, created: true };
}

async function attachPhoneNumberToMessagingService(
  messagingServiceSid: string,
  phoneNumberSid: string,
): Promise<void> {
  if (isTwilioDryRunEnabled()) return;
  const twilio = getTwilioClient() as any;
  const existing = await twilio.messaging.v1.services(messagingServiceSid).phoneNumbers.list({ limit: 200 });
  const exists = (existing || []).some((p: any) => p.phoneNumberSid === phoneNumberSid);
  if (!exists) {
    await twilio.messaging.v1.services(messagingServiceSid).phoneNumbers.create({
      phoneNumberSid,
    });
  }
}

/** Stored business fields that only feed the campaign, never a TrustHub bundle. */
const CAMPAIGN_ONLY_BUSINESS_FIELDS = ['dba'] as const;

/**
 * Save the owner's business details and build/evaluate the TrustHub bundles.
 *
 * The customer profile and the A2P trust product are separate stages. When the
 * profile is already with Twilio (in review or approved) its details cannot
 * change, so the stored details are used as they are — only campaign-only
 * fields (the DBA) are taken from the request — and the run goes on to
 * rebuild, evaluate and submit the trust product. The EIN is needed, and
 * required, only when the profile itself is written.
 */
async function createOrUpdateA2PProfileInternal(
  facilityRef: admin.firestore.DocumentReference,
  facilityData: Record<string, any>,
  businessData: TextingBusinessData,
): Promise<{
  trustProfileSid: string;
  trustProductSid: string;
  bundleReady: boolean;
  bundleIssues: string;
  profileStatus: string | null;
  productStatus: string | null;
  profileSkipped: boolean;
  replacedProductSid: string | null;
}> {
  if (facilityData.twilioBrandSid) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      "This facility's brand has already been filed with the carriers, so its business " +
        'details can no longer be changed here. If the registration is rejected, use ' +
        '"Reset and review" on the Texting page first.',
    );
  }

  const twilio: A2PTwilioClient | null = isTwilioDryRunEnabled() ? null : getA2PTwilioClient();
  const state: TrustBundleState = twilio
    ? await fetchTrustBundleState(twilio, facilityData)
    : { profile: null, product: null };
  assertTrustProductEditable(state);

  const stored = (facilityData.textingBusinessData || {}) as Record<string, any>;
  const profileLocked = Boolean(state.profile) && isBundleWithTwilio(state.profile?.status);
  let effective: TextingBusinessData = businessData;
  if (profileLocked && stored.legalBusinessName) {
    // The profile under review is the source of truth; ignore edits to its
    // fields rather than silently diverging from what Twilio is reviewing.
    effective = { ...(stored as TextingBusinessData), ein: undefined };
    for (const field of CAMPAIGN_ONLY_BUSINESS_FIELDS) {
      if (typeof businessData[field] === 'string') effective[field] = businessData[field];
    }
  }

  const validationIssues = validateA2PBusinessData(effective, { requireEin: !profileLocked });
  if (validationIssues.length > 0) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      `Business details cannot be submitted for carrier review yet. ${formatA2PValidationIssues(validationIssues)}`,
      { validationIssues },
    );
  }

  let trustProfileSid: string;
  let trustProductSid: string;
  let bundleReady = false;
  let bundleIssues = '';
  let profileStatus: string | null = null;
  let productStatus: string | null = null;
  let profileSkipped = false;
  let replacedProductSid: string | null = null;

  if (!twilio) {
    trustProfileSid = buildTwilioDryRunSid('BU', facilityRef.id);
    trustProductSid = buildTwilioDryRunSid('TP', facilityRef.id);
    bundleReady = true;
  } else {
    const policySids = resolveA2PPolicySids();

    // Build the full bundle — business information, authorized representative
    // and registered address — then evaluate it. The full EIN is passed through
    // here and never persisted below.
    const result = await buildAndEvaluateTrustBundle(
      twilio,
      facilityRef,
      facilityData,
      {
        legalBusinessName: effective.legalBusinessName,
        businessType: effective.businessType,
        ein: effective.ein,
        mobilePhone: effective.mobilePhone,
        addressLine1: effective.addressLine1,
        city: effective.city,
        state: effective.state,
        postalCode: effective.postalCode,
        country: effective.country,
        website: effective.website,
        supportEmail: effective.supportEmail,
        supportPhone: effective.supportPhone,
        representativeFirstName: effective.representativeFirstName || '',
        representativeLastName: effective.representativeLastName || '',
        representativeBusinessTitle: effective.representativeBusinessTitle,
      },
      policySids,
      state,
    );

    trustProfileSid = result.sids.trustProfileSid;
    trustProductSid = result.sids.trustProductSid;
    bundleReady = result.readyForBrand;
    profileStatus = result.profileStatus;
    productStatus = result.productStatus;
    profileSkipped = result.profileSkipped;
    replacedProductSid = result.replacedProductSid ?? null;
    bundleIssues = [
      formatEvaluationFailures(result.customerProfileEvaluation),
      formatEvaluationFailures(result.trustProductEvaluation),
    ]
      .filter(Boolean)
      .join(' | ');
  }

  // Never store full tax IDs in Firestore. The last four is written only when
  // a full EIN was actually sent; a save without one (a product-only rebuild)
  // leaves the stored last four alone instead of nulling it.
  const einDigits = profileLocked ? '' : normalizeEin(effective.ein);
  await facilityRef.set({
    twilioTrustProfileSid: trustProfileSid,
    twilioTrustProductSid: trustProductSid,
    textingBusinessData: {
      legalBusinessName: effective.legalBusinessName,
      dba: effective.dba || null,
      businessType: effective.businessType,
      ...(einDigits.length === 9 ? { einLast4: einDigits.slice(-4) } : {}),
      soleProprietorTaxIdLast4: effective.soleProprietorTaxIdLast4 || null,
      // A contact mobile, not a tax ID, so it is safe to persist; needed to
      // resend the sole-proprietor OTP and to show the owner which number
      // Twilio will text.
      mobilePhone: effective.mobilePhone || null,
      addressLine1: effective.addressLine1,
      city: effective.city,
      state: effective.state,
      postalCode: effective.postalCode,
      country: effective.country || 'US',
      website: effective.website,
      supportEmail: effective.supportEmail,
      supportPhone: effective.supportPhone,
      representativeFirstName: effective.representativeFirstName || null,
      representativeLastName: effective.representativeLastName || null,
      representativeBusinessTitle: effective.representativeBusinessTitle || null,
    },
    a2pStatus: 'draft',
    textingPlatformApproved: false,
    textingPlatformApprovedAt: null,
    textingPlatformApprovedBy: null,
    a2pLastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });

  return {
    trustProfileSid,
    trustProductSid,
    bundleReady,
    bundleIssues,
    profileStatus,
    productStatus,
    profileSkipped,
    replacedProductSid,
  };
}

/**
 * Refuse to submit a brand unless Twilio has approved both TrustHub bundles.
 *
 * A2P brand registration charges per attempt and carriers vet the bundle
 * contents, so submitting an unapproved bundle burns the fee and returns a
 * rejection days later. Saving business details now builds the full bundle and
 * hands it to Twilio for review, but review is asynchronous — the bundle sits
 * in `pending-review` for a while before it becomes `twilio-approved`, and it
 * can come back rejected. Both cases must block the paid step.
 */
async function assertTrustBundleReadyForBrand(
  twilio: A2PTwilioClient,
  trustProfileSid: string | undefined,
  trustProductSid: string | undefined,
): Promise<void> {
  if (!trustProfileSid || !trustProductSid) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Business profile has not been created yet. Save your business details first.',
    );
  }

  const [profile, product] = await Promise.all([
    twilio.trusthub.v1.customerProfiles(trustProfileSid).fetch(),
    twilio.trusthub.v1.trustProducts(trustProductSid).fetch(),
  ]);

  const approved = (status: unknown) => String(status || '').toLowerCase() === 'twilio-approved';
  if (approved(profile.status) && approved(product.status)) return;

  functions.logger.error('Refusing brand submission: TrustHub bundles not approved', {
    trustProfileSid,
    trustProductSid,
    profileStatus: profile.status,
    productStatus: product.status,
  });

  const pending = (status: unknown) =>
    ['pending-review', 'in-review'].includes(String(status || '').toLowerCase());

  if (pending(profile.status) || pending(product.status)) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Your business profile is still being reviewed by Twilio. This usually takes about a ' +
        'business day. You will be able to submit for carrier registration once it is approved — ' +
        'no action is needed in the meantime.',
    );
  }

  throw new functions.https.HttpsError(
    'failed-precondition',
    'Your business profile has not been approved by Twilio yet, so carrier brand registration ' +
      `cannot be submitted (profile: ${profile.status}, A2P profile: ${product.status}). ` +
      'Submitting now would incur the registration fee and be rejected. Re-save your business ' +
      'details to rebuild and resubmit the profile.',
  );
}

async function submitBrandRegistrationInternal(
  facilityRef: admin.firestore.DocumentReference,
  facilityData: Record<string, any>,
): Promise<string> {
  if (facilityData.twilioBrandSid) return facilityData.twilioBrandSid as string;

  let sid: string;
  if (isTwilioDryRunEnabled()) {
    sid = buildTwilioDryRunSid('BN', facilityRef.id);
  } else {
    const twilio = getA2PTwilioClient();

    // Brand registration costs a non-refundable fee per attempt and is vetted
    // against public records, so refuse to submit unless Twilio has approved
    // both the customer profile and the A2P trust product.
    await assertTrustBundleReadyForBrand(
      twilio,
      facilityData.twilioTrustProfileSid as string | undefined,
      facilityData.twilioTrustProductSid as string | undefined,
    );

    const brand = await twilio.messaging.v1.brandRegistrations.create(
      buildBrandRegistrationParams(facilityData),
    );
    sid = brand.sid;
  }

  await facilityRef.set({
    twilioBrandSid: sid,
    a2pStatus: 'submitted',
    textingPlatformApproved: false,
    textingPlatformApprovedAt: null,
    textingPlatformApprovedBy: null,
    a2pSubmittedAt: admin.firestore.FieldValue.serverTimestamp(),
    a2pLastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });
  return sid;
}

async function submitCampaignInternal(
  facilityRef: admin.firestore.DocumentReference,
  facilityData: Record<string, any>,
  campaignData: Pick<CampaignData, 'useCases' | 'consentConfirmed'>,
  readiness: PaidSubmissionReadiness,
): Promise<string> {
  if (facilityData.twilioCampaignSid) return facilityData.twilioCampaignSid as string;
  if (!facilityData.twilioBrandSid || !facilityData.twilioMessagingServiceSid || !facilityData.twilioPhoneNumberSid) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Missing Twilio brand, messaging service, or phone number. Complete previous steps first.',
    );
  }

  // Samples and consent methods were validated by assertReadyForPaidSubmission
  // before anything was bought; they are stored so a deferred filing by the
  // hourly poll uses exactly what the owner submitted.
  const withMethods = { ...facilityData, textingConsentMethods: readiness.consentMethods };
  const dryRun = isTwilioDryRunEnabled();
  const filing: CampaignFilingResult = dryRun
    ? {
        filed: true,
        brandStatus: 'APPROVED',
        sid: buildTwilioDryRunSid('QE', facilityRef.id),
        campaignId: buildTwilioDryRunSid('CM', facilityRef.id),
        campaignStatus: 'VERIFIED',
      }
    : await fileCampaignWhenBrandApproved(getA2PTwilioClient(), withMethods, readiness.samples);

  await facilityRef.set({
    ...campaignFilingFields(filing),
    a2pCampaignFilingFailures: 0,
    a2pLastError: null,
    textingUseCases: Array.isArray(campaignData.useCases) ? campaignData.useCases : [],
    textingSampleMessages: readiness.samples,
    textingConsentMethods: readiness.consentMethods,
    textingConsentConfirmedAt: campaignData.consentConfirmed ? admin.firestore.FieldValue.serverTimestamp() : null,
    a2pStatus: dryRun ? 'approved' : filing.filed ? 'pending' : 'submitted',
    textingPlatformApproved: false,
    textingPlatformApprovedAt: null,
    textingPlatformApprovedBy: null,
    a2pLastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
    ...(dryRun ? { a2pApprovedAt: admin.firestore.FieldValue.serverTimestamp() } : {}),
  }, { merge: true });

  if (!dryRun) {
    await attachPhoneNumberToMessagingService(
      facilityData.twilioMessagingServiceSid as string,
      facilityData.twilioPhoneNumberSid as string,
    );
  }

  return filing.sid ?? '';
}

function leaseDb(): LeaseDb {
  return admin.firestore() as unknown as LeaseDb;
}

async function readFacilityData(ref: admin.firestore.DocumentReference): Promise<Record<string, any>> {
  const data = (await ref.get()).data();
  if (!data) throw new functions.https.HttpsError('not-found', 'Facility not found');
  return data;
}

type PaidScope = 'service' | 'number' | 'brand' | 'campaign' | 'all';

/**
 * Run a paid texting-registration sequence for one facility.
 *
 * Holds the facility's submission lease for the whole sequence, checks every
 * prerequisite (live bundle approval, samples, consent) before the first
 * purchase, and re-reads the facility before each step so a number or brand
 * bought by an earlier run is reused rather than bought again. Creating the
 * messaging service alone is free and skips the readiness check.
 */
async function runGatedPaidSubmission(
  ref: admin.firestore.DocumentReference,
  uid: string,
  scope: PaidScope,
  campaignData: Partial<CampaignData> | undefined,
): Promise<{ requestId: string; facility: Record<string, any> }> {
  const requestId = crypto.randomUUID();
  const holder = `${uid}:${requestId}`;
  const facility = await withA2PSubmitLease(leaseDb(), ref, holder, async () => {
    const first = await readFacilityData(ref);
    const readiness =
      scope === 'service'
        ? null
        : await assertReadyForPaidSubmission(
            isTwilioDryRunEnabled() ? null : getA2PTwilioClient(),
            first,
            resolvePaidSubmissionInput(campaignData, first),
          );

    const wants = (step: PaidScope) => scope === 'all' || scope === step;
    const steps: PaidStep[] = [];
    if (scope !== 'brand') {
      steps.push(async (d) => {
        await ensureMessagingServiceForFacility(ref, d, requestId);
      });
    }
    if (wants('number')) {
      steps.push(async (d) => {
        await provisionFacilityPhoneNumber(ref, d, campaignData?.areaCode, requestId);
      });
      steps.push(async (d) => {
        await attachPhoneNumberToMessagingService(
          String(d.twilioMessagingServiceSid),
          String(d.twilioPhoneNumberSid),
        );
      });
    }
    if (wants('brand')) {
      steps.push(async (d) => {
        await submitBrandRegistrationInternal(ref, d);
      });
    }
    if (wants('campaign') && readiness) {
      steps.push(async (d) => {
        await submitCampaignInternal(
          ref,
          d,
          {
            useCases: campaignData?.useCases ?? d.textingUseCases ?? [],
            consentConfirmed: resolvePaidSubmissionInput(campaignData, d).consentConfirmed === true,
          },
          readiness,
        );
      });
    }
    return runPaidSubmission(() => readFacilityData(ref), steps);
  });
  return { requestId, facility };
}

function getTextingOnboardingState(facilityData: Record<string, any>): TextingOnboardingState {
  return {
    a2pStatus: ((facilityData.a2pStatus as string) || 'draft') as A2PStatus,
    a2pLastError: facilityData.a2pLastError as string | undefined,
    textingPlatformApproved: facilityData.textingPlatformApproved === true,
    textingPlatformApprovedAt: facilityData.textingPlatformApprovedAt as admin.firestore.Timestamp | undefined,
    twilioMessagingServiceSid: facilityData.twilioMessagingServiceSid as string | undefined,
    twilioTrustProfileSid: facilityData.twilioTrustProfileSid as string | undefined,
    twilioTrustProductSid: facilityData.twilioTrustProductSid as string | undefined,
    twilioBrandSid: facilityData.twilioBrandSid as string | undefined,
    twilioCampaignSid: facilityData.twilioCampaignSid as string | undefined,
    twilioPhoneNumberSid: facilityData.twilioPhoneNumberSid as string | undefined,
    twilioPhoneNumberE164: facilityData.twilioPhoneNumberE164 as string | undefined,
  };
}

function mapTextingOnboardingError(operation: string, error: unknown): functions.https.HttpsError {
  if (error instanceof functions.https.HttpsError) return error;

  const err = error as any;
  const message = (err?.message as string) || 'Unexpected texting onboarding error';
  const code = (err?.code as string | undefined) || undefined;

  functions.logger.error('Texting onboarding operation failed', {
    operation,
    code: code || null,
    message,
    stack: err?.stack || null,
  });

  const passthroughCodes = new Set([
    'invalid-argument',
    'failed-precondition',
    'permission-denied',
    'not-found',
    'resource-exhausted',
    'unauthenticated',
  ]);

  if (code && passthroughCodes.has(code)) {
    return new functions.https.HttpsError(code as any, message);
  }

  return new functions.https.HttpsError(
    'internal',
    `Texting onboarding failed during ${operation}: ${message}`,
  );
}

export const getTextingOnboardingStatus = functions.https.onCall(async (data: { facilityId: string }, context) => {
  if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  const { facilityId } = data || {};
  if (!facilityId) throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  await assertTextingOnboardingEnabled(facilityId);
  const { data: facilityData } = await getFacilityForTextingMutation(facilityId, context.auth.uid);
  return {
    ...getTextingOnboardingState(facilityData),
    businessData: facilityData.textingBusinessData || null,
    useCases: Array.isArray(facilityData.textingUseCases) ? facilityData.textingUseCases : [],
    sampleMessages: Array.isArray(facilityData.textingSampleMessages) ? facilityData.textingSampleMessages : [],
    hasTrustProfile: Boolean(facilityData.twilioTrustProfileSid && facilityData.twilioTrustProductSid),
    ...describeBusinessDetailsLock(facilityData),
    bundleReady: facilityData.a2pBundleReady === true,
    bundleApproved: facilityData.a2pBundleApproved === true,
    bundleIssues: facilityData.a2pBundleIssues || null,
    bundleProfileStatus: facilityData.a2pBundleProfileStatus || null,
    bundleProductStatus: facilityData.a2pBundleProductStatus || null,
    twilioCampaignId: facilityData.twilioCampaignId || null,
    campaignPending: facilityData.a2pCampaignPending === true,
    consentMethods: normalizeConsentMethods(facilityData.textingConsentMethods),
    // The name every text and filed sample opens with.
    senderName: facilityDisplayName(facilityData),
    hasPhoneNumber: Boolean(facilityData.twilioPhoneNumberSid && facilityData.twilioPhoneNumberE164),
    submittedAt: facilityData.a2pSubmittedAt || null,
    approvedAt: facilityData.a2pApprovedAt || null,
    rejectedAt: facilityData.a2pRejectedAt || null,
    rejectionReason: facilityData.a2pRejectionReason || null,
  };
});

export const saveTextingBusinessInfo = functions.runWith({ secrets: TWILIO_SECRETS }).https.onCall(async (data: { facilityId: string; businessData: TextingBusinessData }, context) => {
  try {
    if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    const { facilityId, businessData } = data || {};
    if (!facilityId || !businessData?.legalBusinessName) {
      throw new functions.https.HttpsError('invalid-argument', 'facilityId and businessData are required');
    }
    // Carrier brand vetting checks the details against public records, and a
    // failed brand costs real money and days of turnaround. They are validated
    // server-side in createOrUpdateA2PProfileInternal (client validation alone
    // let a live facility through with postal code "959595"), once the live
    // bundle state is known, because a profile already in review needs no EIN.
    await assertTextingOnboardingEnabled(facilityId);
    const { ref, data: facilityData } = await getFacilityForTextingMutation(facilityId, context.auth.uid);
    await createOrUpdateA2PProfileInternal(ref, facilityData, businessData);
    await ref.set({
      textingOnboardingEnabled: true,
      a2pStatus: 'draft',
      textingPlatformApproved: false,
      textingPlatformApprovedAt: null,
      textingPlatformApprovedBy: null,
      a2pLastError: null,
      a2pLastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    return { success: true };
  } catch (error: unknown) {
    throw mapTextingOnboardingError('saveTextingBusinessInfo', error);
  }
});

export const ensureMessagingService = functions.runWith({ secrets: TWILIO_SECRETS }).https.onCall(
  async (data: { facilityId: string }, context) => {
    try {
      if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
      const { facilityId } = data || {};
      if (!facilityId) throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
      await assertTextingOnboardingEnabled(facilityId);
      const { ref } = await getFacilityForTextingMutation(facilityId, context.auth.uid);
      const { requestId, facility } = await runGatedPaidSubmission(ref, context.auth.uid, 'service', undefined);
      return { success: true, requestId, messagingServiceSid: facility.twilioMessagingServiceSid || null };
    } catch (error: unknown) {
      throw mapTextingOnboardingError('ensureMessagingService', error);
    }
  },
);

export const createOrUpdateA2PProfile = functions.runWith({ secrets: TWILIO_SECRETS }).https.onCall(
  async (data: { facilityId: string; businessData: TextingBusinessData }, context) => {
    try {
      if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
      const { facilityId, businessData } = data || {};
      if (!facilityId || !businessData?.legalBusinessName) {
        throw new functions.https.HttpsError('invalid-argument', 'facilityId and businessData are required');
      }
      await assertTextingOnboardingEnabled(facilityId);
      const { ref, data: facilityData } = await getFacilityForTextingMutation(facilityId, context.auth.uid);
      const result = await createOrUpdateA2PProfileInternal(ref, facilityData, businessData);
      return { success: true, ...result };
    } catch (error: unknown) {
      throw mapTextingOnboardingError('createOrUpdateA2PProfile', error);
    }
  },
);

export const setTextingPlatformApproval = functions.https.onCall(
  async (data: { facilityId: string; approved: boolean }, context) => {
    try {
      if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
      const callerEmail = context.auth.token?.email as string | undefined;
      if (!isSuperAdmin(callerEmail)) {
        throw new functions.https.HttpsError('permission-denied', 'Only super admins can change texting platform approval');
      }

      const { facilityId, approved } = data || {};
      if (!facilityId || typeof approved !== 'boolean') {
        throw new functions.https.HttpsError('invalid-argument', 'facilityId and approved(boolean) are required');
      }

      await assertTextingOnboardingEnabled(facilityId);
      const ref = admin.firestore().collection('facilities').doc(facilityId);
      const doc = await ref.get();
      const facilityData = doc.data() as Record<string, any> | undefined;
      if (!doc.exists || !facilityData) {
        throw new functions.https.HttpsError('not-found', 'Facility not found');
      }

      const carrierApproved = ((facilityData.a2pStatus as string) || '').toLowerCase() === 'approved';
      if (approved && !carrierApproved) {
        throw new functions.https.HttpsError(
          'failed-precondition',
          'Carrier approval is required before platform approval can be granted.',
        );
      }

      await ref.set({
        textingPlatformApproved: approved,
        textingPlatformApprovedAt: approved ? admin.firestore.FieldValue.serverTimestamp() : null,
        textingPlatformApprovedBy: approved ? callerEmail || context.auth.uid : null,
        a2pLastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });

      return { success: true, facilityId, approved };
    } catch (error: unknown) {
      throw mapTextingOnboardingError('setTextingPlatformApproval', error);
    }
  },
);

/**
 * Reserve the facility's own number. Buys a number, so it runs the full
 * readiness check first (both bundles approved, samples, consent); the client
 * now reserves the number through submitTextingOnboarding instead, and this
 * stays for older clients with the same guard.
 */
export const provisionPhoneNumber = functions.runWith({ secrets: TWILIO_SECRETS }).https.onCall(
  async (data: { facilityId: string; areaCode?: string } & Partial<CampaignData>, context) => {
    try {
      if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
      const { facilityId } = data || {};
      if (!facilityId) throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
      await assertTextingOnboardingEnabled(facilityId);
      const { ref } = await getFacilityForTextingMutation(facilityId, context.auth.uid);
      const { requestId, facility } = await runGatedPaidSubmission(ref, context.auth.uid, 'number', data);
      return {
        success: true,
        requestId,
        messagingServiceSid: facility.twilioMessagingServiceSid || null,
        phoneNumberSid: facility.twilioPhoneNumberSid || null,
        phoneNumberE164: facility.twilioPhoneNumberE164 || null,
      };
    } catch (error: unknown) {
      throw mapTextingOnboardingError('provisionPhoneNumber', error);
    }
  },
);

export const submitTextingOnboarding = functions.runWith({ secrets: TWILIO_SECRETS }).https.onCall(
  async (data: { facilityId: string; campaignData: CampaignData }, context) => {
    try {
      if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
      const { facilityId, campaignData } = data || {};
      if (!facilityId || !campaignData?.consentConfirmed) {
        throw new functions.https.HttpsError('invalid-argument', 'facilityId and consent confirmation are required');
      }
      await assertTextingOnboardingEnabled(facilityId);
      const { ref } = await getFacilityForTextingMutation(facilityId, context.auth.uid);
      // Messaging service, number, brand, campaign — in that order, under the
      // facility's lease, and only after every prerequisite has been checked.
      const { requestId, facility } = await runGatedPaidSubmission(ref, context.auth.uid, 'all', campaignData);

      return {
        success: true,
        requestId,
        // Without a campaign SID the brand is still in review and the hourly
        // poll files the campaign once it clears.
        a2pStatus: facility.a2pStatus || 'submitted',
        twilioBrandSid: facility.twilioBrandSid || null,
        twilioCampaignSid: facility.twilioCampaignSid || null,
        twilioMessagingServiceSid: facility.twilioMessagingServiceSid || null,
        twilioPhoneNumberSid: facility.twilioPhoneNumberSid || null,
        twilioPhoneNumberE164: facility.twilioPhoneNumberE164 || null,
      };
    } catch (error: unknown) {
      throw mapTextingOnboardingError('submitTextingOnboarding', error);
    }
  },
);

export const submitBrandRegistration = functions.runWith({ secrets: TWILIO_SECRETS }).https.onCall(
  async (data: { facilityId: string }, context) => {
    try {
      if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
      const { facilityId } = data || {};
      if (!facilityId) throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
      await assertTextingOnboardingEnabled(facilityId);
      const { ref } = await getFacilityForTextingMutation(facilityId, context.auth.uid);
      const { facility } = await runGatedPaidSubmission(ref, context.auth.uid, 'brand', undefined);
      return { success: true, brandSid: facility.twilioBrandSid || null };
    } catch (error: unknown) {
      throw mapTextingOnboardingError('submitBrandRegistration', error);
    }
  },
);

/**
 * Re-send the sole-proprietor verification code.
 *
 * When a SOLE_PROPRIETOR brand is created, Twilio texts a one-time code to the
 * owner's mobile; the owner verifies by replying to that text. If it never
 * arrives, this asks Twilio to send it again via the brand's SmsOtp
 * subresource (POST /v1/a2p/BrandRegistrations/{Sid}/SmsOtp). It does not
 * submit anything for review or incur a fee. A mobile can be used for OTP at
 * most three times in its lifetime across all TCR registrations, so this is
 * deliberately a manual, owner-triggered action, not an automatic retry.
 */
export const resendSoleProprietorOtp = functions.runWith({ secrets: TWILIO_SECRETS }).https.onCall(
  async (data: { facilityId: string }, context) => {
    try {
      if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
      const { facilityId } = data || {};
      if (!facilityId) throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
      await assertTextingOnboardingEnabled(facilityId);
      const { data: facilityData } = await getFacilityForTextingMutation(facilityId, context.auth.uid);

      const brandSid = facilityData.twilioBrandSid as string | undefined;
      if (!brandSid) {
        throw new functions.https.HttpsError('failed-precondition', 'Register the brand before requesting a verification code.');
      }
      if (!isSoleProprietorBusinessType(facilityData.textingBusinessData?.businessType)) {
        throw new functions.https.HttpsError('failed-precondition', 'Verification codes only apply to sole-proprietor registrations.');
      }

      if (isTwilioDryRunEnabled()) {
        return { success: true, dryRun: true };
      }

      const accountSid = TWILIO_ACCOUNT_SID.value().trim();
      const authToken = TWILIO_AUTH_TOKEN.value().trim();
      const auth = Buffer.from(`${accountSid}:${authToken}`).toString('base64');
      const url = `https://messaging.twilio.com/v1/a2p/BrandRegistrations/${brandSid}/SmsOtp`;
      const resp = await fetch(url, {
        method: 'POST',
        headers: { Authorization: `Basic ${auth}`, 'Content-Type': 'application/x-www-form-urlencoded' },
      });
      if (!resp.ok) {
        const bodyText = await resp.text().catch(() => '');
        functions.logger.error('[resendSoleProprietorOtp] Twilio rejected the OTP resend', {
          facilityId,
          status: resp.status,
          body: bodyText.slice(0, 300),
        });
        throw new functions.https.HttpsError('internal', 'Could not resend the verification code. Try again shortly.');
      }
      functions.logger.info('[resendSoleProprietorOtp] verification code resent', { facilityId });
      return { success: true };
    } catch (error: unknown) {
      throw mapTextingOnboardingError('resendSoleProprietorOtp', error);
    }
  },
);

export const submitCampaign = functions.runWith({ secrets: TWILIO_SECRETS }).https.onCall(
  async (data: { facilityId: string; campaignData: CampaignData }, context) => {
    try {
      if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
      const { facilityId, campaignData } = data || {};
      if (!facilityId || !campaignData?.consentConfirmed) {
        throw new functions.https.HttpsError('invalid-argument', 'facilityId and campaignData are required');
      }
      await assertTextingOnboardingEnabled(facilityId);
      const { ref } = await getFacilityForTextingMutation(facilityId, context.auth.uid);
      const { facility } = await runGatedPaidSubmission(ref, context.auth.uid, 'campaign', campaignData);
      return { success: true, campaignSid: facility.twilioCampaignSid || null };
    } catch (error: unknown) {
      throw mapTextingOnboardingError('submitCampaign', error);
    }
  },
);

export const refreshTextingOnboardingStatus = functions.runWith({ secrets: TWILIO_SECRETS }).https.onCall(
  async (data: { facilityId: string }, context) => {
    try {
      if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
      const { facilityId } = data || {};
      if (!facilityId) throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
      await assertTextingOnboardingEnabled(facilityId);
      const { ref, data: facilityData } = await getFacilityForTextingMutation(facilityId, context.auth.uid);

      if (isTwilioDryRunEnabled()) {
        const current = (facilityData.a2pStatus as A2PStatus | undefined) || 'draft';
        const next = current === 'submitted' || current === 'pending' ? 'approved' : current;
        await ref.set({
          a2pStatus: next,
          textingPlatformApproved: false,
          textingPlatformApprovedAt: null,
          textingPlatformApprovedBy: null,
          a2pLastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
          ...(next === 'approved' ? { a2pApprovedAt: admin.firestore.FieldValue.serverTimestamp() } : {}),
        }, { merge: true });
        return { success: true, a2pStatus: next };
      }

      const twilio = getA2PTwilioClient();
      let brandStatus: string | undefined;
      let campaignStatus: string | undefined;
      let brandErrors: unknown;
      let brandFailureReason: unknown;
      let campaignErrors: unknown;
      const bundleUpdate: Record<string, unknown> = {};
      if (!facilityData.twilioBrandSid && facilityData.twilioTrustProfileSid) {
        // Before a brand exists the bundles are what is under review; read them
        // so the page (and the form lock) shows the real state.
        const bundles = await fetchTrustBundleState(twilio, facilityData);
        bundleUpdate.a2pBundleProfileStatus = bundles.profile?.status ?? null;
        bundleUpdate.a2pBundleProductStatus = bundles.product?.status ?? null;
        bundleUpdate.a2pBundleApproved =
          bundles.profile?.status === 'twilio-approved' && bundles.product?.status === 'twilio-approved';
        if (bundles.product?.policySid) bundleUpdate.a2pBundleProductPolicySid = bundles.product.policySid;
        bundleUpdate.a2pBundleStatusUpdatedAt = admin.firestore.FieldValue.serverTimestamp();
      }
      if (facilityData.twilioBrandSid) {
        const brand = await twilio.messaging.v1.brandRegistrations(facilityData.twilioBrandSid).fetch();
        brandStatus = brand.status;
        // Twilio returns the actionable detail here; the status alone is just
        // "FAILED", which tells the operator nothing about what to fix.
        brandErrors = brand.errors;
        brandFailureReason = brand.failureReason;
      }
      if (facilityData.twilioCampaignSid && facilityData.twilioMessagingServiceSid) {
        const campaign = await fetchUsAppToPersonCampaign(
          twilio,
          String(facilityData.twilioMessagingServiceSid),
          String(facilityData.twilioCampaignSid),
        );
        campaignStatus = campaign?.campaignStatus;
        campaignErrors = campaign?.errors;
      }
      const current = ((facilityData.a2pStatus as string) || 'draft') as A2PStatus;
      const next = computeA2PStatus(current, brandStatus, campaignStatus);
      const update: Record<string, any> = {
        ...bundleUpdate,
        ...(campaignStatus ? { a2pCampaignStatus: campaignStatus } : {}),
        a2pStatus: next,
        a2pLastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
        a2pLastError: null,
        a2pRejectionReason: next === 'rejected'
          ? (buildA2PRejectionReason({
              campaignErrors,
              brandErrors,
              brandFailureReason,
              campaignStatus,
              brandStatus,
            }) ?? 'Rejected by Twilio')
          : null,
        ...(next !== 'approved' ? {
          textingPlatformApproved: false,
          textingPlatformApprovedAt: null,
          textingPlatformApprovedBy: null,
        } : {}),
      };
      if (next === 'approved') update.a2pApprovedAt = admin.firestore.FieldValue.serverTimestamp();
      if (next === 'rejected') update.a2pRejectedAt = admin.firestore.FieldValue.serverTimestamp();
      await ref.set(update, { merge: true });
      return { success: true, a2pStatus: next, brandStatus, campaignStatus };
    } catch (error: unknown) {
      throw mapTextingOnboardingError('refreshTextingOnboardingStatus', error);
    }
  },
);

/**
 * Reset a rejected registration so the owner can fix it and submit again.
 *
 * Only for a registration Twilio actually rejected, and only by the facility
 * owner or a super admin: it discards filed (paid) work. It clears only what
 * was rejected — an approved brand is kept, and a failed campaign is removed
 * from the messaging service so the refiled one is the only campaign there.
 */
export const resubmitTextingOnboarding = functions.runWith({ secrets: TWILIO_SECRETS }).https.onCall(
  async (data: { facilityId: string }, context) => {
    try {
      if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
      const { facilityId } = data || {};
      if (!facilityId) throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
      await assertTextingOnboardingEnabled(facilityId);

      const ref = admin.firestore().collection('facilities').doc(facilityId);
      const initial = await readFacilityData(ref);
      const callerEmail = context.auth.token?.email as string | undefined;
      if (initial.ownerUid !== context.auth.uid && !isSuperAdmin(callerEmail)) {
        throw new functions.https.HttpsError(
          'permission-denied',
          'Only the facility owner can reset a carrier registration.',
        );
      }

      const holder = `${context.auth.uid}:${crypto.randomUUID()}`;
      const result = await withA2PSubmitLease(leaseDb(), ref, holder, async () => {
        const facilityData = await readFacilityData(ref);
        if (String(facilityData.a2pStatus || '').toLowerCase() !== 'rejected') {
          throw new functions.https.HttpsError(
            'failed-precondition',
            'Only a rejected registration can be reset.',
          );
        }

        const brandSid = String(facilityData.twilioBrandSid || '').trim();
        const campaignSid = String(facilityData.twilioCampaignSid || '').trim();
        const messagingServiceSid = String(facilityData.twilioMessagingServiceSid || '').trim();
        let brandStatus = '';
        let campaignStatus = '';
        let liveCampaignSid = '';
        const dryRun = isTwilioDryRunEnabled();
        const twilio = dryRun ? null : getA2PTwilioClient();
        if (twilio && brandSid) {
          brandStatus = String((await twilio.messaging.v1.brandRegistrations(brandSid).fetch()).status || '');
        }
        if (twilio && campaignSid && messagingServiceSid) {
          const campaign = await fetchUsAppToPersonCampaign(twilio, messagingServiceSid, campaignSid);
          campaignStatus = String(campaign?.campaignStatus || '');
          liveCampaignSid = campaign?.sid || '';
        }

        const plan = dryRun
          ? { rejected: 'campaign' as const, keepBrand: false, removeCampaign: false }
          : planRegistrationReset({
              hasBrand: Boolean(brandSid),
              brandStatus,
              hasCampaign: Boolean(campaignSid),
              campaignStatus,
            });

        if (twilio && plan.removeCampaign && liveCampaignSid && messagingServiceSid) {
          await twilio.messaging.v1.services(messagingServiceSid).usAppToPerson(liveCampaignSid).remove();
          functions.logger.info('Removed rejected A2P campaign before refiling', {
            facilityId,
            usAppToPersonSid: liveCampaignSid,
            campaignStatus,
          });
        }

        const del = admin.firestore.FieldValue.delete();
        await ref.set({
          ...(plan.keepBrand ? {} : { twilioBrandSid: del, a2pBrandStatus: del }),
          twilioCampaignSid: del,
          twilioCampaignId: del,
          a2pCampaignStatus: del,
          a2pCampaignPending: del,
          a2pCampaignFilingFailures: del,
          a2pStatus: 'draft',
          textingPlatformApproved: false,
          textingPlatformApprovedAt: null,
          textingPlatformApprovedBy: null,
          a2pLastError: null,
          a2pRejectionReason: null,
          a2pRejectedAt: null,
          a2pLastResetOf: plan.rejected,
          a2pLastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
        return plan;
      });
      return { success: true, reset: result.rejected, keptBrand: result.keepBrand };
    } catch (error: unknown) {
      throw mapTextingOnboardingError('resubmitTextingOnboarding', error);
    }
  },
);

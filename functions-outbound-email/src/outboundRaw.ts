/* eslint-disable -- migrated verbatim from functions/src/index.ts; tighten types incrementally */
import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import * as crypto from 'crypto';
import {
  buildEmailUnsubscribeToken,
  buildFacilityFooter,
  enforceAppCheckOrThrow,
  enforceRateLimit,
  getPublicAppUrl,
  getSendgridAsmGroupId,
  getSgMail,
  initializeSendGrid,
  isSuperAdmin,
  releasePlatformOutgoing,
  reservePlatformOutgoing,
  sendFacilityEmailWithCompliance,
  emailMonthlyLimitForAccount,
  writeAuditLog,
} from '@sfc/functions-shared';
import { createOrUpdateMessageLog } from './messageLog';
import { getTenantInfo } from './tenantInfo';
import { SENDGRID_API_KEY, SENDGRID_FROM_EMAIL, SENDGRID_SECRETS } from './secrets';


interface EmailRequest {
  to: string;
  subject: string;
  html?: string; // Optional: will be generated from text if not provided
  text?: string; // Optional: at least one of html or text must be provided
  facilityId: string;
  templateId?: string;
  variables?: Record<string, any>;
  fromName?: string; // Optional: override default From name (e.g., "{FacilityName} via Storage Facility Creator")
  tenantId?: string; // Optional: for message logging and tenant context
  source?: 'manual' | 'bulk' | 'automation'; // Optional: source of the message
}

interface DigestRequest {
  facilityId: string;
  digestId: string;
  to: string;
  subject: string;
  html: string;
  text?: string;
  templateId?: string;
  variables?: Record<string, any>;
}

/**
 * Send individual email via SendGrid
 */
export const sendEmail = functions.runWith({ secrets: SENDGRID_SECRETS }).https.onCall(async (data: EmailRequest, context) => {
  // Log payload at the very start for debugging
  functions.logger.info('📧 [sendEmail] Function invoked', {
    hasData: !!data,
    facilityId: data?.facilityId || 'missing',
    to: data?.to || 'missing',
    subject: data?.subject || 'missing',
    hasHtml: !!(data?.html),
    htmlLength: data?.html?.length || 0,
    hasText: !!(data?.text),
    textLength: data?.text?.length || 0,
    fromName: data?.fromName || 'null',
    templateId: data?.templateId || 'null',
    hasAuth: !!context.auth,
    userId: context.auth?.uid || 'null',
  });

  // Verify authentication
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated to send emails');
  }
  enforceAppCheckOrThrow(context);
  await enforceRateLimit({
    facilityId: data.facilityId,
    key: 'sendEmail',
    limit: 60, // per minute per facility
    windowSeconds: 60,
    userId: context.auth.uid,
  });

  const { to, subject, html, text, facilityId, templateId, variables, fromName, tenantId, source } = data;

  // Validate required fields
  if (!to || !subject || !facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required fields: to, subject, facilityId');
  }

  // Validate that we have either html or text content
  if (!html && !text) {
    throw new functions.https.HttpsError('invalid-argument', 'Email must have either html or text content');
  }

  // Generate message log ID early
  const messageLogId = `email-${Date.now()}-${Math.random().toString(36).substring(2, 9)}`;

  let platformEmailReserved = false;
  let sendGridAcceptedEmail = false;
  try {
    // Get user email for super admin check and message logging
    const userRecord = await admin.auth().getUser(context.auth.uid);
    const userEmail = userRecord.email;
    const isSuperAdminUser = isSuperAdmin(userEmail);
    
    if (isSuperAdminUser) {
      functions.logger.info(`Super admin ${userEmail} sending email - bypassing permission checks`);
    }

    // Verify user has access to the facility (owner or manager)
    const facilityRef = admin.firestore().collection('facilities').doc(facilityId);
    const facilityDoc = await facilityRef.get();
    const facilityData = facilityDoc.data() as Record<string, any> | undefined;

    if (!facilityDoc.exists || !facilityData) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    // Super admins bypass all permission checks
    if (!isSuperAdminUser) {
      const ownerUid = facilityData.ownerUid;
      const managersMap = (facilityData.managers ?? {}) as Record<string, any>;
      const isOwner = ownerUid === context.auth.uid;
      const isManager = managersMap[context.auth.uid ?? ''] === true;

      // Check new permission system (user_roles collection)
      let hasPermission = false;
      // Always check user_roles to support the new permission system
      const userRolesQuery = await admin.firestore()
        .collection('user_roles')
        .where('userId', '==', context.auth.uid)
        .where('facilityId', '==', facilityId)
        .where('isActive', '==', true)
        .limit(1)
        .get();

      if (!userRolesQuery.empty) {
        const userRole = userRolesQuery.docs[0].data();
        const roleType = userRole.roleType as string;
        // Allow owner and manager roles to send emails (legacy `admin` in DB treated like manager in app)
        if (roleType === 'owner' || roleType === 'manager') {
          hasPermission = true;
        }
      }

      if (!isOwner && !isManager && !hasPermission) {
        throw new functions.https.HttpsError(
          'permission-denied',
          'User is not authorized to send email for this facility',
        );
      }
    }

    // Get tenant information for message logging
    const tenantInfo = await getTenantInfo(
      facilityId,
      tenantId || variables?.tenantId,
      to,
      null,
    );

    // Create message log with status "queued"
    const previewText = (text || html || '').replace(/<[^>]*>/g, '').substring(0, 200);
    await createOrUpdateMessageLog(facilityId, messageLogId, {
      tenantId: tenantInfo.tenantId,
      tenantName: tenantInfo.tenantName,
      tenantEmail: tenantInfo.tenantEmail || to,
      tenantPhone: tenantInfo.tenantPhone,
      channel: 'email',
      direction: 'outbound',
      source: source || 'manual',
      templateId: templateId || null,
      subject: subject,
      previewText: previewText,
      bodyHtmlStored: false, // Don't store full body by default
      bodyTextStored: false,
      status: 'queued',
      provider: 'sendgrid',
      providerMessageId: null,
      errorCode: null,
      errorMessage: null,
      sentAt: null,
      createdByUid: context.auth.uid,
      createdByEmail: userEmail || null,
    });

    // Check and increment email usage
    const canSend = await checkAndIncrementEmailUsage(facilityId);
    if (!canSend.success) {
      // Update message log to failed
      await createOrUpdateMessageLog(facilityId, messageLogId, {
        tenantId: tenantInfo.tenantId,
        tenantName: tenantInfo.tenantName,
        tenantEmail: tenantInfo.tenantEmail || to,
        tenantPhone: tenantInfo.tenantPhone,
        channel: 'email',
        direction: 'outbound',
        source: source || 'manual',
        templateId: templateId || null,
        subject: subject,
        previewText: previewText,
        bodyHtmlStored: false,
        bodyTextStored: false,
        status: 'failed',
        provider: 'sendgrid',
        providerMessageId: null,
        errorCode: 'resource-exhausted',
        errorMessage: canSend.message || 'Email quota exceeded',
        sentAt: null,
        createdByUid: context.auth.uid,
        createdByEmail: userEmail || null,
      });
      throw new functions.https.HttpsError('resource-exhausted', canSend.message || 'Email quota exceeded');
    }

    // Validate SendGrid configuration early
    let sendGridApiKey: string;
    let sendGridFromEmail: string;
    try {
      sendGridApiKey = SENDGRID_API_KEY.value();
      if (!sendGridApiKey || sendGridApiKey.trim().length === 0) {
        throw new functions.https.HttpsError(
          'failed-precondition',
          'SendGrid API key not configured. Please set SENDGRID_API_KEY secret in Firebase Functions.',
        );
      }
    } catch (e: any) {
      if (e instanceof functions.https.HttpsError) {
        throw e;
      }
      functions.logger.error('❌ [sendEmail] Failed to retrieve SENDGRID_API_KEY', {
        error: e.message,
        errorType: e.constructor.name,
      });
      throw new functions.https.HttpsError(
        'failed-precondition',
        'SendGrid API key not configured. Please set SENDGRID_API_KEY secret in Firebase Functions.',
        { originalError: e.message },
      );
    }

    try {
      sendGridFromEmail = SENDGRID_FROM_EMAIL.value();
      if (!sendGridFromEmail || sendGridFromEmail.trim().length === 0) {
        throw new functions.https.HttpsError(
          'failed-precondition',
          'SendGrid sender email not configured. Please set SENDGRID_SENDER_EMAIL in Firebase Functions environment.',
        );
      }
    } catch (e: any) {
      if (e instanceof functions.https.HttpsError) {
        throw e;
      }
      functions.logger.error('❌ [sendEmail] Failed to retrieve SENDGRID_SENDER_EMAIL', {
        error: e.message,
        errorType: e.constructor.name,
      });
      throw new functions.https.HttpsError(
        'failed-precondition',
        'SendGrid sender email not configured. Please set SENDGRID_SENDER_EMAIL in Firebase Functions environment.',
        { originalError: e.message },
      );
    }

    functions.logger.info('✅ [sendEmail] SendGrid configuration validated', {
      hasApiKey: !!sendGridApiKey,
      fromEmail: sendGridFromEmail,
    });

    try {
      initializeSendGrid();
      (getSgMail() as any).setApiKey(sendGridApiKey);
      functions.logger.info('✅ [sendEmail] SendGrid API key set successfully');
    } catch (e: any) {
      functions.logger.error('❌ [sendEmail] Failed to set SendGrid API key', {
        error: e.message,
        errorType: e.constructor.name,
        stack: e.stack,
      });
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Failed to configure SendGrid API key. Please verify SENDGRID_API_KEY secret is valid.',
        { originalError: e.message },
      );
    }

    // Extract facility branding information (already fetched above)
    const facilityName = facilityData.name || 'Storage Facility';
    const facilityAddress = facilityData.address || null;
    const facilityPhone = facilityData.phone || null;
    const facilityEmail = facilityData.email || null;

    const isInviteEmail = !!(html && html.includes('accept-invite'));
    const toLower = String(to).trim().toLowerCase();

    if (!isInviteEmail) {
      const suppressId = crypto.createHash('sha256').update(`${facilityId}|${toLower}`).digest('hex');
      const suppressSnap = await admin
        .firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('emailSuppressions')
        .doc(suppressId)
        .get();
      if (suppressSnap.exists) {
        throw new functions.https.HttpsError(
          'failed-precondition',
          'This recipient has unsubscribed from emails from this facility.',
        );
      }
    }

    const baseUrl = getPublicAppUrl();
    const tidForToken = String(tenantId || variables?.tenantId || '').trim();
    const unsubscribeUrl = isInviteEmail
      ? undefined
      : `${baseUrl}/api/email-unsubscribe?token=${encodeURIComponent(
          buildEmailUnsubscribeToken(sendGridApiKey, facilityId, toLower, tidForToken),
        )}`;

    // Build branded footer (includes opt-out link for non-invite mail)
    const footer = buildFacilityFooter(facilityName, facilityAddress, facilityPhone, unsubscribeUrl ? { unsubscribeUrl } : null);

    // Prepare email content for SendGrid with branded footer
    // Ensure html is always provided (SendGrid requires it)
    let htmlContent = html ?? (text ? `<p>${text.replace(/\n/g, '<br>')}</p>` : '<p>No content provided.</p>');
    // Append branded footer to HTML
    htmlContent += footer.html;

    // Prepare text content with branded footer
    let textContent = text || htmlContent.replace(/<[^>]*>/g, '').replace(/&nbsp;/g, ' ').trim();
    // Append branded footer to text
    textContent += footer.text;
    
    // Use facility name as FROM display name (unless fromName is explicitly provided)
    // This allows override for special cases like invitations
    let emailFromName: string;
    
    if (fromName) {
      // Explicit fromName provided (e.g., for invitations)
      emailFromName = fromName;
    } else {
      // Use facility name as default
      emailFromName = facilityName;
    }
    
    // Build SendGrid message object
    const msg: any = {
      to: to,
      from: {
        email: sendGridFromEmail,
        name: emailFromName,
      },
      subject: subject,
      html: htmlContent,
      text: textContent,
    };

    // Optionally set Reply-To to facility email if available
    if (facilityEmail) {
      msg.replyTo = facilityEmail;
    }

    // Disable SendGrid click tracking for invitation emails so the "Accept Invitation"
    // button link is not rewritten to a tracking URL (e.g. url1827.storagefacilitycreator.com)
    // which can fail with DNS_PROBE_FINISHED_NXDOMAIN and make the button unreachable.
    if (html && html.includes('accept-invite')) {
      msg.trackingSettings = {
        clickTracking: { enable: false },
      };
    }

    if (unsubscribeUrl) {
      msg.headers = {
        'List-Unsubscribe': `<${unsubscribeUrl}>`,
        'List-Unsubscribe-Post': 'List-Unsubscribe=One-Click',
      };
    }

    const asmNum = getSendgridAsmGroupId();
    if (asmNum != null) {
      msg.asm = { group_id: asmNum };
    }

    // #region agent log
    functions.logger.info('🔍 [sendEmail:H7] Email message prepared', {
      to,
      fromEmail: sendGridFromEmail,
      fromName: emailFromName,
      facilityId: facilityId,
      hasReplyTo: !!facilityEmail,
      replyTo: facilityEmail || null,
    });
    // #endregion

    // Extract invite URL domain for invitation emails (diagnostic logging)
    let inviteUrlDomain: string | null = null;
    if (html && html.includes('accept-invite')) {
      const urlMatch = html.match(/https?:\/\/[^\s"']+/);
      if (urlMatch) {
        try {
          const url = new URL(urlMatch[0]);
          inviteUrlDomain = url.hostname;
        } catch (e) {
          // Invalid URL, skip domain extraction
        }
      }
    }
    
    // Send email via SendGrid
    functions.logger.info(`Attempting to send email via SendGrid`, {
      to: to,
      fromEmail: sendGridFromEmail,
      subject: subject,
    });
    
    let result;
    let messageId: string | null = null;
    try {
      // #region agent log
      functions.logger.info('🔍 [sendEmail:H7] Calling SendGrid API', {
        to,
        fromEmail: sendGridFromEmail,
        subject,
      });
      // #endregion

      await reservePlatformOutgoing('email');
      platformEmailReserved = true;
      [result] = await (getSgMail() as any).send(msg);
      sendGridAcceptedEmail = true;
      
      // Extract x-message-id from headers (if available)
      messageId = result.headers?.['x-message-id'] || null;
      
      // #region agent log
      functions.logger.info('🔍 [sendEmail:H7] SendGrid API response received', {
        statusCode: result.statusCode,
        to,
      });
      // #endregion
      
      functions.logger.info(`SendGrid API call successful`, {
        statusCode: result.statusCode,
        to: to,
        subject: subject,
        xMessageId: messageId,
      });
    } catch (sgError: any) {
      // #region agent log
      functions.logger.error('❌ [sendEmail:H7] SendGrid API error', {
        error: sgError?.message,
        code: sgError?.code,
        statusCode: sgError?.response?.statusCode,
        responseBody: sgError?.response?.body,
        to: to,
        from: msg.from.email,
        fromName: msg.from.name,
        fromNameSource: fromName ? 'custom' : 'default',
        subject: subject,
        facilityId: facilityId,
        inviteUrlDomain: inviteUrlDomain || null,
        errorType: sgError?.constructor?.name,
        stack: sgError?.stack,
      });
      // #endregion
      
      functions.logger.error(`SendGrid API error`, {
        error: sgError?.message,
        code: sgError?.code,
        response: sgError?.response?.body,
        to: to,
        from: msg.from.email,
        fromName: msg.from.name,
        fromNameSource: fromName ? 'custom' : 'default',
        subject: subject,
        facilityId: facilityId,
        inviteUrlDomain: inviteUrlDomain || null,
      });
      
      // Convert SendGrid errors to appropriate HttpsError
      const statusCode = sgError?.response?.statusCode || sgError?.code;
      const errorMessage = sgError?.message || 'Unknown SendGrid error';
      const responseBody = sgError?.response?.body;

      // Log full error details for debugging
      functions.logger.error('❌ [sendEmail] SendGrid error details', {
        statusCode,
        errorMessage,
        responseBody: typeof responseBody === 'string' ? responseBody.substring(0, 500) : responseBody,
        errorType: sgError?.constructor?.name,
      });

      if (statusCode === 401) {
        // 401 means the API key is invalid, expired, or revoked
        const detailMsg = responseBody?.errors?.[0]?.message || errorMessage;
        throw new functions.https.HttpsError(
          'permission-denied',
          `SendGrid unauthorized: API key is invalid, expired, or revoked. ${detailMsg}. Please verify SENDGRID_API_KEY secret in Firebase Functions is correct and active.`,
          { 
            sendGridError: detailMsg, 
            statusCode,
            hint: 'Check Firebase Functions secrets: firebase functions:secrets:access SENDGRID_API_KEY',
          },
        );
      } else if (statusCode === 403) {
        // Common causes: unverified sender, domain not authenticated, rate limit
        const detailMsg = responseBody?.errors?.[0]?.message || errorMessage;
        throw new functions.https.HttpsError(
          'permission-denied',
          `SendGrid rejected the email: ${detailMsg}. Please verify the sender email is verified in SendGrid.`,
          { sendGridError: errorMessage, statusCode, details: responseBody },
        );
      } else if (statusCode === 400) {
        // Bad request - invalid email format, missing fields, etc.
        const detailMsg = responseBody?.errors?.[0]?.message || errorMessage;
        throw new functions.https.HttpsError(
          'invalid-argument',
          `Invalid email request: ${detailMsg}`,
          { sendGridError: errorMessage, statusCode, details: responseBody },
        );
      } else if (statusCode && statusCode >= 500) {
        throw new functions.https.HttpsError(
          'internal',
          `SendGrid server error (${statusCode}): ${errorMessage}. Please try again later.`,
          { sendGridError: errorMessage, statusCode },
        );
      } else {
        // Unknown error or no status code - convert to internal error with details
        throw new functions.https.HttpsError(
          'internal',
          `SendGrid error: ${errorMessage}. Check logs for details.`,
          { sendGridError: errorMessage, statusCode, originalError: sgError?.toString() },
        );
      }
    }

    // Extract message ID from SendGrid response (already extracted above, reuse it)
    const finalMessageId = messageId || `sg-${Date.now()}`;
    functions.logger.info(`Email sent successfully`, {
      to: to,
      subject: subject,
      statusCode: result.statusCode,
      xMessageId: finalMessageId,
    });

    // Get tenant info again (in case it wasn't retrieved earlier)
    const tenantInfoForLog = await getTenantInfo(
      facilityId,
      tenantId || variables?.tenantId,
      to,
      null,
    );
    const previewTextForLog = (text || html || '').replace(/<[^>]*>/g, '').substring(0, 200);

    // Update message log to "sent"
    await createOrUpdateMessageLog(facilityId, messageLogId, {
      tenantId: tenantInfoForLog.tenantId,
      tenantName: tenantInfoForLog.tenantName,
      tenantEmail: tenantInfoForLog.tenantEmail || to,
      tenantPhone: tenantInfoForLog.tenantPhone,
      channel: 'email',
      direction: 'outbound',
      source: source || 'manual',
      templateId: templateId || null,
      subject: subject,
      previewText: previewTextForLog,
      bodyHtmlStored: false,
      bodyTextStored: false,
      status: 'sent',
      provider: 'sendgrid',
      providerMessageId: finalMessageId,
      errorCode: null,
      errorMessage: null,
      sentAt: admin.firestore.Timestamp.now(),
      createdByUid: context.auth.uid,
      createdByEmail: userEmail || null,
    });

    // Also log to legacy emailLogs collection for backward compatibility
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('emailLogs')
      .add({
        to,
        subject,
        status: 'sent',
        messageId: finalMessageId,
        timestamp: admin.firestore.FieldValue.serverTimestamp(),
        facilityId,
        templateId,
        variables,
        sentBy: context.auth.uid,
      });

    await writeAuditLog(facilityId, {
      action: 'email_sent',
      userId: context.auth.uid,
      messageId: finalMessageId,
      subject,
      to,
      templateId: templateId || null,
    });

    // Also log tracking event (for future tracking integration)
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('emailTracking')
      .add({
        messageId: finalMessageId,
        facilityId,
        tenantId: variables?.tenantId || null,
        to,
        subject,
        eventType: 'sent',
        timestamp: admin.firestore.FieldValue.serverTimestamp(),
        metadata: {
          templateId,
          sentBy: context.auth.uid,
        },
      });

    functions.logger.info(`Email sent successfully to ${to} for facility ${facilityId}`, {
      messageId: messageId,
      facilityId,
      templateId,
    });

    return {
      success: true,
      messageId: messageId,
      messageLogId: messageLogId,
      status: 'sent',
      provider: 'sendgrid',
      providerMessageId: finalMessageId,
      usageWarning: canSend.warning,
    };

  } catch (error: any) {
    if (platformEmailReserved && !sendGridAcceptedEmail) {
      await releasePlatformOutgoing('email').catch((err) =>
        functions.logger.warn('releasePlatformOutgoing email', err),
      );
    }
    // If it's already an HttpsError, re-throw it (don't wrap it)
    if (error instanceof functions.https.HttpsError) {
      functions.logger.error(
        `Failed to send email to ${to} for facility ${facilityId}`,
        { 
          errorCode: error.code,
          errorMessage: error.message,
          errorDetails: error.details,
          facilityId, 
          to, 
          templateId, 
        },
      );

      // Update message log to "failed"
      try {
        const tenantInfo = await getTenantInfo(
          facilityId,
          tenantId || variables?.tenantId,
          to,
          null,
        );
        const userRecord = await admin.auth().getUser(context.auth.uid);
        const userEmail = userRecord.email;
        const previewText = (text || html || '').replace(/<[^>]*>/g, '').substring(0, 200);

        await createOrUpdateMessageLog(facilityId, messageLogId, {
          tenantId: tenantInfo.tenantId,
          tenantName: tenantInfo.tenantName,
          tenantEmail: tenantInfo.tenantEmail || to,
          tenantPhone: tenantInfo.tenantPhone,
          channel: 'email',
          direction: 'outbound',
          source: source || 'manual',
          templateId: templateId || null,
          subject: subject,
          previewText: previewText,
          bodyHtmlStored: false,
          bodyTextStored: false,
          status: 'failed',
          provider: 'sendgrid',
          providerMessageId: null,
          errorCode: error.code,
          errorMessage: error.message || 'Unknown error',
          sentAt: null,
          createdByUid: context.auth.uid,
          createdByEmail: userEmail || null,
        });
      } catch (logError) {
        // Don't fail if logging fails
        functions.logger.warn('Failed to log email failure to messageLogs', { logError });
      }

      // Also log to legacy emailLogs collection
      try {
        await admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('emailLogs')
          .add({
            to,
            subject,
            status: 'failed',
            error: error.message,
            errorCode: error.code,
            timestamp: admin.firestore.FieldValue.serverTimestamp(),
            facilityId,
            templateId,
            variables,
            sentBy: context.auth.uid,
          });
      } catch (logError) {
        // Don't fail if logging fails
        functions.logger.warn('Failed to log email failure to Firestore', { logError });
      }

      throw error;
    }

    // For non-HttpsError exceptions, wrap them
    functions.logger.error(
      `Failed to send email to ${to} for facility ${facilityId}`,
      { 
        error: error?.message, 
        errorType: error?.constructor?.name,
        stack: error?.stack, 
        facilityId, 
        to, 
        templateId, 
      },
    );

    // Update message log to "failed"
    try {
      const tenantInfo = await getTenantInfo(
        facilityId,
        tenantId || variables?.tenantId,
        to,
        null,
      );
      const userRecord = await admin.auth().getUser(context.auth.uid);
      const userEmail = userRecord.email;
      const previewText = (text || html || '').replace(/<[^>]*>/g, '').substring(0, 200);

      await createOrUpdateMessageLog(facilityId, messageLogId, {
        tenantId: tenantInfo.tenantId,
        tenantName: tenantInfo.tenantName,
        tenantEmail: tenantInfo.tenantEmail || to,
        tenantPhone: tenantInfo.tenantPhone,
        channel: 'email',
        direction: 'outbound',
        source: source || 'manual',
        templateId: templateId || null,
        subject: subject,
        previewText: previewText,
        bodyHtmlStored: false,
        bodyTextStored: false,
        status: 'failed',
        provider: 'sendgrid',
        providerMessageId: null,
        errorCode: 'internal',
        errorMessage: error?.message || 'Unknown error',
        sentAt: null,
        createdByUid: context.auth.uid,
        createdByEmail: userEmail || null,
      });
    } catch (logError) {
      // Don't fail if logging fails
      functions.logger.warn('Failed to log email failure to messageLogs', { logError });
    }

    // Also log to legacy emailLogs collection
    try {
      await admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('emailLogs')
        .add({
          to,
          subject,
          status: 'failed',
          error: error?.message || 'Unknown error',
          timestamp: admin.firestore.FieldValue.serverTimestamp(),
          facilityId,
          templateId,
          variables,
          sentBy: context.auth.uid,
        });
    } catch (logError) {
      // Don't fail if logging fails
      functions.logger.warn('Failed to log email failure to Firestore', { logError });
    }

    // Provide a more actionable error message
    const errorMsg = error?.message || 'Unknown error occurred';
    throw new functions.https.HttpsError(
      'internal', 
      `Failed to send email: ${errorMsg}. Please check logs for details.`,
      { originalError: errorMsg, errorType: error?.constructor?.name },
    );
  }
});

/**
 * Send digest email with multiple reminders via SendGrid
 */
export const sendDigest = functions.runWith({ secrets: SENDGRID_SECRETS }).https.onCall(async (data: DigestRequest, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated to send digest emails');
  }
  enforceAppCheckOrThrow(context);
  await enforceRateLimit({
    facilityId: data.facilityId,
    key: 'sendDigest',
    limit: 15, // per minute per facility
    windowSeconds: 60,
    userId: context.auth.uid,
  });

  const { facilityId, digestId, to, subject, html, text, templateId, variables } = data;

  let digestPlatformEmailReserved = false;
  let digestEmailActuallySent = false;
  try {
    // Verify user owns the facility
    const facilityRef = admin.firestore().collection('facilities').doc(facilityId);
    const facilityDoc = await facilityRef.get();
    
    if (!facilityDoc.exists || facilityDoc.data()?.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'User does not own this facility');
    }

    // Check and increment email usage
    const canSend = await checkAndIncrementEmailUsage(facilityId);
    if (!canSend.success) {
      throw new functions.https.HttpsError('resource-exhausted', canSend.message || 'Email quota exceeded');
    }

    const fd = facilityDoc.data() || {};
    const facilityName = (fd.name as string) || 'Storage Facility';
    const tenantIdForDigest = String((variables as Record<string, unknown> | undefined)?.tenantId ?? '').trim();

    await reservePlatformOutgoing('email');
    digestPlatformEmailReserved = true;
    const digestSend = await sendFacilityEmailWithCompliance(
      {
        to: to,
        from: {
          email: SENDGRID_FROM_EMAIL.value(),
          name: facilityName,
        },
        subject: subject,
      },
      html || '',
      text || null,
      {
        facilityId,
        tenantId: tenantIdForDigest || null,
        facilityName,
        facilityAddress: fd.address as string | null,
        facilityPhone: fd.phone as string | null,
      },
    );
    if (!digestSend.sent) {
      await releasePlatformOutgoing('email').catch((err) =>
        functions.logger.warn('releasePlatformOutgoing digest email', err),
      );
      digestPlatformEmailReserved = false;
      throw new functions.https.HttpsError(
        'failed-precondition',
        'This recipient has unsubscribed from emails from this facility.',
      );
    }

    digestEmailActuallySent = true;
    const messageId = digestSend.messageId || `sg-${Date.now()}`;

    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('emailLogs')
      .add({
        to,
        subject,
        status: 'sent',
        messageId: messageId,
        timestamp: admin.firestore.FieldValue.serverTimestamp(),
        facilityId,
        templateId,
        digestId,
        variables,
        sentBy: context.auth.uid,
      });

    functions.logger.info(`Digest email sent successfully to ${to} for facility ${facilityId}`, {
      messageId: messageId,
      facilityId,
      digestId,
    });

    return {
      success: true,
      messageId: messageId,
      usageWarning: canSend.warning,
    };

  } catch (error: any) {
    if (digestPlatformEmailReserved && !digestEmailActuallySent) {
      await releasePlatformOutgoing('email').catch((err) =>
        functions.logger.warn('releasePlatformOutgoing digest email (catch)', err),
      );
    }
    functions.logger.error(`Failed to send digest email to ${to} for facility ${facilityId}`, error);
    if (error instanceof functions.https.HttpsError) {
      throw error;
    }
    throw new functions.https.HttpsError('internal', `Failed to send digest email: ${error.message}`);
  }
});

/**
 * Scheduled function to send daily digest emails at 8am CST
 */
export const sendDailyDigests = functions.runWith({ secrets: SENDGRID_SECRETS }).pubsub
  .schedule('0 8 * * *') // 8am CST daily
  .timeZone('America/Chicago')
  .onRun(async (context) => {
    functions.logger.info('Starting daily digest email job');

    try {
      // Get all facilities that have pending digest emails
      const facilitiesSnapshot = await admin.firestore()
        .collection('facilities')
        .where('active', '==', true)
        .get();

      const digestPromises = facilitiesSnapshot.docs.map(async (facilityDoc) => {
        const facilityId = facilityDoc.id;
        const facilityData = facilityDoc.data();

        // Get pending digest items for this facility
        const digestSnapshot = await admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('digests')
          .where('status', '==', 'pending')
          .where('digestKey', '==', 'daily')
          .get();

        if (digestSnapshot.empty) {
          return; // No pending digests for this facility
        }

        // Group digest items by tenant email
        const digestGroups: Record<string, any[]> = {};
        digestSnapshot.docs.forEach((doc) => {
          const data = doc.data();
          const email = data.tenantEmail;
          if (!digestGroups[email]) {
            digestGroups[email] = [];
          }
          digestGroups[email].push({ id: doc.id, ...data });
        });

        // Send digest email to each tenant
        const sendPromises = Object.entries(digestGroups).map(async ([email, items]) => {
          const digestId = `daily_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
          
          // Generate digest HTML
          const digestHtml = generateDigestHtml(facilityData.name, items);
          const tenantIdForToken = String((items[0] as any)?.tenantId || '').trim();
          const textBase = `Daily reminders from ${facilityData.name}`;
          const fn = facilityData.name || 'Storage Facility';

          const dailySend = await sendFacilityEmailWithCompliance(
            {
              to: email,
              from: {
                email: SENDGRID_FROM_EMAIL.value(),
                name: fn,
              },
              subject: `Daily Reminders - ${facilityData.name}`,
            },
            digestHtml,
            textBase,
            {
              facilityId,
              tenantId: tenantIdForToken || null,
              facilityName: fn,
              facilityAddress: facilityData.address,
              facilityPhone: facilityData.phone,
            },
          );

          if (!dailySend.sent) {
            functions.logger.info(`Skipping daily digest for unsubscribed recipient at ${facilityId}`);
            return;
          }

          const messageId = dailySend.messageId || `sg-${Date.now()}`;

          // Mark digest items as sent
          const batch = admin.firestore().batch();
          items.forEach((item) => {
            batch.update(
              admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('digests')
                .doc(item.id),
              {
                status: 'sent',
                sentAt: admin.firestore.FieldValue.serverTimestamp(),
                messageId: messageId,
                digestId,
              },
            );
          });
          await batch.commit();

          functions.logger.info(`Daily digest sent to ${email} for facility ${facilityId}`);
        });

        await Promise.all(sendPromises);
      });

      await Promise.all(digestPromises);
      functions.logger.info('Daily digest email job completed successfully');

    } catch (error: any) {
      functions.logger.error('Daily digest email job failed', error);
    }
  });

/**
 * Check and increment email usage for a facility
 */
async function checkAndIncrementEmailUsage(facilityId: string): Promise<{success: boolean, message?: string, warning?: string}> {
  const now = new Date();
  const monthKey = `${now.getFullYear()}-${(now.getMonth() + 1).toString().padStart(2, '0')}`;
  
  const usageRef = admin.firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('emailUsage')
    .doc(monthKey);

  // Default cap when usage doc has no limit yet (see `./constants/emailMonthlyLimits.ts`).
  let defaultLimit = emailMonthlyLimitForAccount(false);
  const usageDoc = await usageRef.get();

  if (!usageDoc.exists || !usageDoc.data()?.emailMonthlyLimit) {
    const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
    if (facilityDoc.exists) {
      const ownerUid = facilityDoc.data()?.ownerUid;
      if (ownerUid) {
        const accountSnapshot = await admin.firestore()
          .collection('facilityCreatorAccounts')
          .where('ownerUid', '==', ownerUid)
          .limit(1)
          .get();

        if (!accountSnapshot.empty) {
          const accountData = accountSnapshot.docs[0].data();
          defaultLimit = emailMonthlyLimitForAccount(
            accountData.subscriptionStatus === 'trialing',
          );
        }
      }
    }
  }

  return admin.firestore().runTransaction(async (transaction) => {
    const usageDocSnapshot = await transaction.get(usageRef);
    const currentUsage = usageDocSnapshot.exists ? usageDocSnapshot.data() : {
      emailMonthlyCount: 0,
      emailMonthlyLimit: defaultLimit,
      emailMonth: monthKey,
      lastReset: admin.firestore.FieldValue.serverTimestamp(),
    };

    const newCount = ((currentUsage?.emailMonthlyCount) || 0) + 1;
    const limit = (currentUsage?.emailMonthlyLimit) || defaultLimit;

    // Check if limit exceeded
    if (newCount > limit) {
      return {
        success: false,
        message: `Monthly email limit of ${limit} exceeded. Current usage: ${newCount}`,
      };
    }

    // Update usage count
    transaction.set(usageRef, {
      ...currentUsage,
      emailMonthlyCount: newCount,
      emailMonth: monthKey,
      lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
    });

    // Check for warning threshold (80%)
    const warningThreshold = Math.floor(limit * 0.8);
    const warning = newCount >= warningThreshold ? 
      `Email usage at ${Math.round((newCount / limit) * 100)}% of monthly limit (${newCount}/${limit})` : 
      undefined;

    return {
      success: true,
      warning,
    };
  });
}

/**
 * Generate HTML for digest email
 */
function generateDigestHtml(facilityName: string, items: any[]): string {
  const itemsHtml = items.map(item => `
    <div style="border-left: 4px solid #4CAF50; padding-left: 16px; margin: 16px 0;">
      <h4 style="margin: 0 0 8px 0; color: #333;">${item.title || 'Reminder'}</h4>
      <p style="margin: 0; color: #666;">${item.message}</p>
      ${item.unitNumber ? `<p style="margin: 4px 0; font-size: 14px; color: #888;">Unit: ${item.unitNumber}</p>` : ''}
      ${item.amount ? `<p style="margin: 4px 0; font-size: 14px; color: #888;">Amount: $${item.amount}</p>` : ''}
      ${item.dueDate ? `<p style="margin: 4px 0; font-size: 14px; color: #888;">Due: ${item.dueDate}</p>` : ''}
    </div>
  `).join('');

  return `
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Daily Reminders - ${facilityName}</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; line-height: 1.6; color: #333; background-color: #f4f4f4; margin: 0; padding: 0; }
        .container { max-width: 600px; margin: 20px auto; background-color: #ffffff; padding: 30px; border-radius: 8px; box-shadow: 0 0 10px rgba(0, 0, 0, 0.1); border-top: 5px solid #4CAF50; }
        .header { text-align: center; padding-bottom: 20px; border-bottom: 1px solid #eee; }
        .header h2 { color: #4CAF50; margin: 0; font-size: 24px; }
        .content { padding: 20px 0; }
        .footer { text-align: center; padding-top: 20px; border-top: 1px solid #eee; color: #777; font-size: 12px; }
        @media only screen and (max-width: 600px) { .container { width: 100%; margin: 0; border-radius: 0; box-shadow: none; } }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h2>Daily Reminders from ${facilityName}</h2>
        </div>
        <div class="content">
          <p>Here are your daily reminders:</p>
          ${itemsHtml}
        </div>
        <div class="footer">
          <p>Best regards,<br>${facilityName} Management Team</p>
        </div>
      </div>
    </body>
    </html>
  `;
}

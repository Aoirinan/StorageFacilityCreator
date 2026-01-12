import * as functions from 'firebase-functions';
import * as admin from 'firebase-admin';
import * as sgMail from '@sendgrid/mail';
import Stripe from 'stripe';
import { defineString, defineSecret } from 'firebase-functions/params';

interface TenantPortalRequest {
  email: string;
  accessCode: string;
}

// Define environment parameters for SendGrid
const SENDGRID_API_KEY = defineString('SENDGRID_API_KEY');
const SENDGRID_FROM_EMAIL = defineString('SENDGRID_FROM_EMAIL');
const SENDGRID_FROM_NAME = defineString('SENDGRID_FROM_NAME', { default: 'Storage Facility Creator' });

// Define environment parameters for Stripe
const STRIPE_SECRET_KEY = defineString('STRIPE_SECRET_KEY');
const STRIPE_WEBHOOK_SECRET = defineString('STRIPE_WEBHOOK_SECRET');
// Use process.env for STRIPE_CONNECT_CLIENT_ID to avoid deployment requirement
// It's stored as a secret: ca_TWVomtZkyvI6Ie1ZLDJhjLiWHIwjtAwB

// Define secrets for Twilio
const TWILIO_ACCOUNT_SID = defineSecret('TWILIO_ACCOUNT_SID');
const TWILIO_AUTH_TOKEN = defineSecret('TWILIO_AUTH_TOKEN');
const TWILIO_PHONE_NUMBER = defineSecret('TWILIO_PHONE_NUMBER');

// Super admin email list
// Can be configured via SUPER_ADMIN_EMAILS environment variable (comma-separated)
// Falls back to hardcoded list if not set
// Must also match lib/services/superadmin_service.dart and firestore.rules
const SUPER_ADMIN_EMAILS_HARDCODED = [
  'russell_forsyth_1992@outlook.com',
  'russellforsyth09091992@gmail.com',
  // Add more superadmin emails here
];

// Parse environment variable or use hardcoded list
// Use process.env directly to avoid Firebase params deployment requirement
function getSuperAdminEmails(): string[] {
  const envValue = process.env.SUPER_ADMIN_EMAILS;
  return envValue && envValue.trim()
    ? envValue.split(',').map((e: string) => e.trim()).filter((e: string) => e.length > 0)
    : SUPER_ADMIN_EMAILS_HARDCODED;
}

/**
 * Check if a user is a super admin
 */
function isSuperAdmin(userEmail: string | undefined): boolean {
  if (!userEmail) return false;
  const lowerEmail = userEmail.toLowerCase();
  const adminEmails = getSuperAdminEmails();
  return adminEmails.some((adminEmail: string) => 
    adminEmail.toLowerCase() === lowerEmail
  );
}

// Generate a short numeric access code for gate access / tokens
function generateAccessCode(): string {
  return Math.floor(100000 + Math.random() * 900000).toString();
}

// Initialize Stripe
let stripeClient: Stripe | null = null;

function getStripeClient(): Stripe {
  if (!stripeClient) {
    const secretKey = STRIPE_SECRET_KEY.value();
    if (!secretKey) {
      throw new Error('STRIPE_SECRET_KEY environment variable is not set');
    }
    stripeClient = new Stripe(secretKey, {
      apiVersion: '2023-10-16',
    });
  }
  return stripeClient;
}

// Initialize Firebase Admin
admin.initializeApp();

// Initialize SendGrid
let sendGridInitialized = false;

function initializeSendGrid(): void {
  if (!sendGridInitialized) {
    const apiKey = SENDGRID_API_KEY.value();
    if (!apiKey) {
      throw new Error('SENDGRID_API_KEY environment variable is not set');
    }
    sgMail.setApiKey(apiKey);
    sendGridInitialized = true;
  }
}

interface EmailRequest {
  to: string;
  subject: string;
  html: string;
  text?: string;
  facilityId: string;
  templateId?: string;
  variables?: Record<string, any>;
  fromName?: string; // Optional: override default From name (e.g., "{FacilityName} via Storage Facility Creator")
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
export const sendEmail = functions.https.onCall(async (data: EmailRequest, context) => {
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

  const { to, subject, html, text, facilityId, templateId, variables, fromName } = data;

  // Validate required fields
  if (!to || !subject || !facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required fields: to, subject, facilityId');
  }

  try {
    // Get user email for super admin check
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
        // Allow owner, admin, and manager roles to send emails
        if (roleType === 'owner' || roleType === 'admin' || roleType === 'manager') {
          hasPermission = true;
        }
      }

      if (!isOwner && !isManager && !hasPermission) {
        throw new functions.https.HttpsError(
          'permission-denied',
          'User is not authorized to send email for this facility'
        );
      }
    }

    // Check and increment email usage
    const canSend = await checkAndIncrementEmailUsage(facilityId);
    if (!canSend.success) {
      throw new functions.https.HttpsError('resource-exhausted', canSend.message || 'Email quota exceeded');
    }

    // Initialize SendGrid
    initializeSendGrid();

    // Prepare email content for SendGrid
    // Ensure html is always provided (SendGrid requires it)
    const htmlContent = html ?? (text ? `<p>${text.replace(/\n/g, '<br>')}</p>` : '<p>No content provided.</p>');
    
    // Use custom fromName if provided (for invitations: "{FacilityName} via Storage Facility Creator")
    // Otherwise use default from environment variable
    const emailFromName = fromName || SENDGRID_FROM_NAME.value();
    
    const msg = {
      to: to,
      from: {
        email: SENDGRID_FROM_EMAIL.value(),
        name: emailFromName,
      },
      subject: subject,
      html: htmlContent,
      ...(text && { text: text }),
    };

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
      from: msg.from.email,
      fromName: msg.from.name,
      fromNameSource: fromName ? 'custom' : 'default',
      subject: subject,
      facilityId: facilityId,
      templateId: templateId || null,
      inviteUrlDomain: inviteUrlDomain || null,
      hasTextPart: !!text,
      hasHtmlPart: !!html,
    });
    
    let result;
    try {
      [result] = await sgMail.send(msg);
      functions.logger.info(`SendGrid API call successful`, {
        statusCode: result.statusCode,
        headers: result.headers,
        to: to,
        subject: subject,
        facilityId: facilityId,
      });
    } catch (sgError: any) {
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
      throw sgError;
    }

    // Extract message ID from SendGrid response
    const messageId = result.headers['x-message-id'] || `sg-${Date.now()}`;
    functions.logger.info(`Email sent successfully, messageId: ${messageId}`, {
      to: to,
      messageId: messageId,
      from: msg.from.email,
      fromName: msg.from.name,
      fromNameSource: fromName ? 'custom' : 'default',
      subject: subject,
      facilityId: facilityId,
      inviteUrlDomain: inviteUrlDomain || null,
      sendGridStatusCode: result.statusCode,
    });

    // Log email send in Firestore
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
        variables,
        sentBy: context.auth.uid,
      });

    await writeAuditLog(facilityId, {
      action: 'email_sent',
      userId: context.auth.uid,
      messageId,
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
        messageId: messageId,
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
      usageWarning: canSend.warning,
    };

  } catch (error: any) {
    functions.logger.error(
      `Failed to send email to ${to} for facility ${facilityId}`,
      { error: error?.message, stack: error?.stack, facilityId, to, templateId }
    );

    // Log failed email
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('emailLogs')
      .add({
        to,
        subject,
        status: 'failed',
        error: error.message,
        timestamp: admin.firestore.FieldValue.serverTimestamp(),
        facilityId,
        templateId,
        variables,
        sentBy: context.auth.uid,
      });

    throw new functions.https.HttpsError('internal', `Failed to send email: ${error.message}`);
  }
});

/**
 * Send digest email with multiple reminders via SendGrid
 */
export const sendDigest = functions.https.onCall(async (data: DigestRequest, context) => {
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

    // Initialize SendGrid
    initializeSendGrid();

    // Prepare digest email for SendGrid
    const msg = {
      to: to,
      from: {
        email: SENDGRID_FROM_EMAIL.value(),
        name: SENDGRID_FROM_NAME.value(),
      },
      subject: subject,
      html: html,
      ...(text && { text: text }),
    };

    // Send digest email via SendGrid
    const [result] = await sgMail.send(msg);

    // Log digest send
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('emailLogs')
      // Extract message ID from SendGrid response
      const messageId = result.headers['x-message-id'] || `sg-${Date.now()}`;

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
    functions.logger.error(`Failed to send digest email to ${to} for facility ${facilityId}`, error);
    throw new functions.https.HttpsError('internal', `Failed to send digest email: ${error.message}`);
  }
});

/**
 * Scheduled function to send daily digest emails at 8am CST
 */
export const sendDailyDigests = functions.pubsub
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
          
          // Initialize SendGrid
          initializeSendGrid();

          // Prepare email for SendGrid
          const msg = {
            to: email,
            from: {
              email: SENDGRID_FROM_EMAIL.value(),
              name: SENDGRID_FROM_NAME.value(),
            },
            subject: `Daily Reminders - ${facilityData.name}`,
            html: digestHtml,
            text: `Daily reminders from ${facilityData.name}`,
          };

          // Send digest email via SendGrid
          const [result] = await sgMail.send(msg);

          // Extract message ID from SendGrid response
          const messageId = result.headers['x-message-id'] || `sg-${Date.now()}`;

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
              }
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

  // First, check if we need to determine the limit
  let defaultLimit = 1000; // Default for active subscribers
  const usageDoc = await usageRef.get();
  
  if (!usageDoc.exists || !usageDoc.data()?.emailMonthlyLimit) {
    // Check if facility owner is on trial to set appropriate limit
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
          if (accountData.subscriptionStatus === 'trialing') {
            defaultLimit = 200; // Trial limit
          }
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

export const tenantPortalFetch = functions.https.onCall(async (data: TenantPortalRequest) => {
  enforceAppCheckOrThrow({ app: (data as any)?._appCheckToken ? {} as any : undefined } as any);
  const email = (data.email || '').toString().trim().toLowerCase();
  const accessCode = (data.accessCode || '').toString().trim();

  if (!email || !accessCode) {
    throw new functions.https.HttpsError('invalid-argument', 'Email and access code are required');
  }

  try {
    const tenantSnapshot = await admin
      .firestore()
      .collectionGroup('tenants')
      .where('emailLower', '==', email)
      .where('portalEnabled', '==', true)
      .where('portalAccessCode', '==', accessCode)
      .limit(1)
      .get();

    if (tenantSnapshot.empty) {
      throw new functions.https.HttpsError('not-found', 'Portal access not found. Verify your email and access code.');
    }

    const tenantDoc = tenantSnapshot.docs[0];
    const tenantData = tenantDoc.data() as Record<string, any>;
    const facilityRef = tenantDoc.ref.parent.parent;

    if (!facilityRef) {
      throw new functions.https.HttpsError('failed-precondition', 'Facility reference missing for tenant');
    }

    const facilityDoc = await facilityRef.get();
    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found for tenant');
    }

    const paymentsCollection = facilityRef.collection('payments');
    let paymentsSnapshot;
    try {
      paymentsSnapshot = await paymentsCollection
        .where('tenantId', '==', tenantDoc.id)
        .orderBy('dueDate', 'desc')
        .limit(20)
        .get();
    } catch (error: any) {
      if (error.code === 9 || (error.message ?? '').includes('indexes')) {
        functions.logger.warn('Missing index for portal payment query. Falling back to unordered query.', error);
        paymentsSnapshot = await paymentsCollection
          .where('tenantId', '==', tenantDoc.id)
          .limit(20)
          .get();
      } else {
        throw error;
      }
    }

    let outstandingBalance = 0;
    let nextDueDate: admin.firestore.Timestamp | null = null;
    let nextAmountDue: number | null = null;

    const payments = paymentsSnapshot.docs.map((doc) => {
      const paymentData = doc.data() as Record<string, any>;
      const amountRaw = paymentData.amount ?? 0;
      const amount = typeof amountRaw === 'number' ? amountRaw : Number(amountRaw) || 0;
      const statusRaw = paymentData.status;
      const status = typeof statusRaw === 'string' ? statusRaw : 'pending';
      const dueDateRaw = paymentData.dueDate;
      const dueDate = dueDateRaw instanceof admin.firestore.Timestamp
        ? dueDateRaw
        : admin.firestore.Timestamp.now();
      const paidAtRaw = paymentData.paidAt;
      const paidAt = paidAtRaw instanceof admin.firestore.Timestamp ? paidAtRaw : null;
      const method = paymentData.method ? String(paymentData.method) : null;

      const isPaid = status === 'paid' || status === 'completed';
      if (!isPaid) {
        outstandingBalance += amount;
        if (!nextDueDate || dueDate.toMillis() < nextDueDate.toMillis()) {
          nextDueDate = dueDate;
          nextAmountDue = amount;
        }
      }

      return {
        id: doc.id,
        amount,
        status,
        dueDate,
        paidAt,
        method,
      };
    });

    await tenantDoc.ref.update({
      portalLastAccessAt: admin.firestore.FieldValue.serverTimestamp(),
      portalVisitCount: admin.firestore.FieldValue.increment(1),
    });

    return {
      facility: {
        id: facilityRef.id,
        name: facilityDoc.data()?.name ?? 'Facility',
        phone: facilityDoc.data()?.phone ?? null,
        email: facilityDoc.data()?.email ?? null,
        address: facilityDoc.data()?.address ?? null,
        logoUrl: facilityDoc.data()?.logoUrl ?? null,
      },
      tenant: {
        id: tenantDoc.id,
        name: tenantData.name ?? 'Tenant',
        unitNumber: tenantData.unitNumber ?? '',
        monthlyRate: tenantData.monthlyRate ?? 0,
        paidThrough: tenantData.paidThrough ?? null,
        isDelinquent: outstandingBalance > 0,
        welcomeMessage: tenantData.portalWelcomeMessage ?? null,
        contacts: tenantData.emergencyContacts ?? [],
        vehicles: tenantData.vehicles ?? [],
      },
      payments,
      stats: {
        outstandingBalance,
        nextAmountDue,
        nextDueDate,
      },
    };
  } catch (error: any) {
    functions.logger.error('tenantPortalFetch failed', error);
    if (error instanceof functions.https.HttpsError) {
      throw error;
    }
    throw new functions.https.HttpsError('internal', error.message ?? 'Unable to load tenant portal data');
  }
});

/**
 * Create payment checkout for tenant portal
 * Uses email + accessCode for authentication (no Firebase Auth required)
 */
export const createTenantPortalPaymentCheckout = functions.https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow({ app: (data as any)?._appCheckToken ? {} as any : undefined } as any);
  const email = (data.email || '').toString().trim().toLowerCase();
  const accessCode = (data.accessCode || '').toString().trim();
  const amount = data.amount as number;

  if (!email || !accessCode || !amount || amount <= 0) {
    throw new functions.https.HttpsError('invalid-argument', 'email, accessCode, and amount are required');
  }

  try {
    // Find tenant using email + accessCode (same logic as tenantPortalFetch)
    const tenantSnapshot = await admin
      .firestore()
      .collectionGroup('tenants')
      .where('emailLower', '==', email)
      .where('portalEnabled', '==', true)
      .where('portalAccessCode', '==', accessCode)
      .limit(1)
      .get();

    if (tenantSnapshot.empty) {
      throw new functions.https.HttpsError('not-found', 'Portal access not found');
    }

    const tenantDoc = tenantSnapshot.docs[0];
    const facilityRef = tenantDoc.ref.parent.parent;

    if (!facilityRef) {
      throw new functions.https.HttpsError('failed-precondition', 'Facility reference missing');
    }

    const facilityDoc = await facilityRef.get();
    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityId = facilityRef.id;
    const tenantId = tenantDoc.id;
    const facilityData = facilityDoc.data()!;
    const tenantData = tenantDoc.data()!;

    // Check Stripe Connect setup
    const connectAccountId = facilityData.stripeConnectAccountId as string | undefined;
    const onboardingComplete = facilityData.stripeConnectOnboardingComplete as boolean | undefined;

    if (!connectAccountId || !onboardingComplete) {
      throw new functions.https.HttpsError('failed-precondition', 'Facility owner must complete Stripe Connect onboarding before accepting payments');
    }

    const tenantEmail = tenantData['email'] as string | undefined;
    const tenantName = tenantData['name'] as string | undefined || 'Tenant';

    const stripe = getStripeClient();

    // Create checkout session on connected account
    const session = await stripe.checkout.sessions.create({
      mode: 'payment',
      payment_method_types: ['card'],
      line_items: [
        {
          price_data: {
            currency: 'usd',
            product_data: {
              name: `Payment - ${tenantName}`,
              description: `Payment for ${facilityData['name'] || 'Facility'}`,
            },
            unit_amount: Math.round(amount * 100), // Convert to cents
          },
          quantity: 1,
        },
      ],
      customer_email: tenantEmail,
      success_url: 'https://storage-facility-creator.web.app/portal/payment/success?session_id={CHECKOUT_SESSION_ID}',
      cancel_url: 'https://storage-facility-creator.web.app/portal/payment/cancel',
      metadata: {
        facilityId: facilityId,
        tenantId: tenantId,
        type: 'tenant_portal_payment',
        portalEmail: email,
      },
    }, {
      stripeAccount: connectAccountId, // Create session on connected account
    });

    return {
      checkoutUrl: session.url,
      sessionId: session.id,
    };
  } catch (error: any) {
    if (error instanceof functions.https.HttpsError) {
      throw error;
    }
    functions.logger.error('Error creating tenant portal payment checkout', error);
    throw new functions.https.HttpsError('internal', `Failed to create checkout: ${error.message}`);
  }
});

interface SMSRequest {
  to: string;
  message: string;
  facilityId: string;
  tenantId?: string; // Optional: for per-tenant tracking
  accountId?: string; // Optional: for per-account tracking
  forceSend?: boolean; // Optional: allow manual override for extreme usage
  fallbackToEmail?: boolean; // Optional: if true, send as email when SMS limit exceeded
}

/**
 * Send SMS text message via Twilio with fair-use safeguards
 * Automatically falls back to email if SMS limits are exceeded
 */
export const sendSMS = functions.runWith({
  secrets: [TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_PHONE_NUMBER],
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

  const { to, message, facilityId, tenantId, accountId, forceSend = false, fallbackToEmail = true } = data;

  // Validate required fields
  if (!to || !message || !facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required fields: to, message, facilityId');
  }

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
        'User is not authorized to send SMS for this facility'
      );
    }

    // Get account ID from facility if not provided
    const finalAccountId = accountId || facilityData.facilityCreatorAccountId;

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
        'SMS usage is extremely high. SMS scheduling is disabled. Please contact support if you need to increase your limit.'
      );
    }

    if (usageCheck.shouldFallbackToEmail && !forceSend) {
      // Exceeded limit: fallback to email
      if (fallbackToEmail) {
        return await sendSMSAsEmail(to, message, facilityId, usageCheck);
      }
      throw new functions.https.HttpsError(
        'resource-exhausted',
        usageCheck.warning || 'SMS fair-use limit exceeded. Messages will be sent via email instead.'
      );
    }

    if (!usageCheck.canSendSMS && !forceSend) {
      // Limit exceeded but not in fallback mode
      if (fallbackToEmail) {
        return await sendSMSAsEmail(to, message, facilityId, usageCheck);
      }
      throw new functions.https.HttpsError(
        'resource-exhausted',
        usageCheck.warning || 'SMS quota exceeded'
      );
    }

    // Format phone number (remove non-digits, ensure it starts with +1 for US)
    const phoneNumber = formatPhoneNumber(to);
    if (!phoneNumber) {
      throw new functions.https.HttpsError('invalid-argument', 'Invalid phone number format');
    }

    // Send SMS via Twilio
    // Get credentials from Firebase Functions secrets
    // Trim whitespace (including \r\n) that may be present if secrets were set via echo/file
    const twilioAccountSid = TWILIO_ACCOUNT_SID.value().trim();
    const twilioAuthToken = TWILIO_AUTH_TOKEN.value().trim();
    const twilioPhoneNumber = TWILIO_PHONE_NUMBER.value().trim();

    if (!twilioAccountSid || !twilioAuthToken || !twilioPhoneNumber) {
      functions.logger.warn('Twilio credentials not configured. SMS sending is disabled.');
      throw new functions.https.HttpsError(
        'failed-precondition',
        'SMS service not configured. Please configure Twilio credentials in Firebase Functions environment variables.'
      );
    }

    // Safe debug logging (masked for security)
    functions.logger.info('🔍 [sendSMS] Twilio Credentials Debug:', {
      accountSid: twilioAccountSid, // Full SID is safe to log (it's public)
      accountSidLength: twilioAccountSid.length,
      authTokenMasked: `****${twilioAuthToken.substring(twilioAuthToken.length - 4)}`, // Last 4 chars only
      authTokenLength: twilioAuthToken.length,
      fromNumber: twilioPhoneNumber,
      toNumberMasked: `${phoneNumber.substring(0, 4)}****${phoneNumber.substring(phoneNumber.length - 4)}`, // First 4 + last 4
      messageLength: message.length,
    });

    // Use Twilio REST API to send SMS
    const twilioUrl = `https://api.twilio.com/2010-04-01/Accounts/${twilioAccountSid}/Messages.json`;
    const auth = Buffer.from(`${twilioAccountSid}:${twilioAuthToken}`).toString('base64');

    const formData = new URLSearchParams();
    formData.append('To', phoneNumber);
    formData.append('From', twilioPhoneNumber);
    formData.append('Body', message);

    let response: Response;
    let errorResponse: any = null;

    try {
      response = await fetch(twilioUrl, {
        method: 'POST',
        headers: {
          'Authorization': `Basic ${auth}`,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: formData.toString(),
      });

      if (!response.ok) {
        const errorText = await response.text();
        try {
          errorResponse = JSON.parse(errorText);
        } catch {
          errorResponse = { message: errorText };
        }

        // Log structured Twilio error
        functions.logger.error('❌ [sendSMS] Twilio API Error:', {
          status: response.status,
          statusText: response.statusText,
          errorCode: errorResponse.code,
          errorMessage: errorResponse.message,
          moreInfo: errorResponse.more_info,
          accountSidUsed: twilioAccountSid, // For debugging
        });

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
            }
          );
        } else if (response.status === 400) {
          // Bad request - might be A2P, invalid number, etc.
          throw new functions.https.HttpsError(
            'invalid-argument',
            `Twilio request failed: ${errorResponse.message || 'Invalid request parameters'}`,
            {
              twilioErrorCode: errorResponse.code,
              twilioMoreInfo: errorResponse.more_info,
            }
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
            }
          );
        } else {
          // Other errors
          throw new functions.https.HttpsError(
            'internal',
            `Twilio API error (${response.status}): ${errorResponse.message || 'Unknown error'}`,
            {
              twilioErrorCode: errorResponse.code,
              twilioMoreInfo: errorResponse.more_info,
            }
          );
        }
      }
    } catch (e) {
      // If it's already an HttpsError, rethrow it
      if (e instanceof functions.https.HttpsError) {
        throw e;
      }
      // Network or other errors
      functions.logger.error('❌ [sendSMS] Unexpected error calling Twilio:', e);
      throw new functions.https.HttpsError(
        'internal',
        `Failed to communicate with Twilio: ${e instanceof Error ? e.message : 'Unknown error'}`,
        { originalError: e instanceof Error ? e.toString() : String(e) }
      );
    }

    const result = await response.json();

    // Log full Twilio response for debugging delivery status
    functions.logger.info(`✅ [sendSMS] Twilio API Response:`, {
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
      
      functions.logger.warn(`⚠️ [sendSMS] A2P 10DLC Registration Required:`, {
        messageId: result.sid,
        status: messageStatus,
        errorCode: errorCode,
        errorMessage: errorMessage,
        to: result.to,
      });

      // Log to Firestore with error details
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
        }
      );
    }

    // Check for "queued" status - message accepted but waiting for delivery (often A2P campaign pending)
    if (messageStatus === 'queued') {
      functions.logger.warn(`⚠️ [sendSMS] Message queued (may be waiting for A2P campaign approval):`, {
        messageId: result.sid,
        status: messageStatus,
        to: result.to,
        dateCreated: result.date_created,
      });
      
      // Still log as success since Twilio accepted it, but note the queued status
      // The message will deliver once A2P campaign is approved
    }

    // Log SMS send in Firestore
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('smsLogs')
      .add({
        to: phoneNumber,
        message,
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
      functions.logger.warn(`⚠️ [sendSMS] Twilio message may have delivery issues:`, {
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

    // Prepare status message based on Twilio response status
    let statusMessage: string | undefined;
    if (messageStatus === 'queued') {
      statusMessage = 'Message accepted and queued. It will be delivered once your A2P 10DLC campaign is approved (typically 1-7 business days). Check Twilio Console for campaign status.';
    } else if (messageStatus === 'sent') {
      statusMessage = 'Message sent to carrier. Delivery confirmation pending.';
    } else if (messageStatus === 'delivered') {
      statusMessage = 'Message delivered successfully.';
    }

    return {
      success: true,
      messageId: result.sid,
      twilioStatus: messageStatus,
      statusMessage: statusMessage,
      usageWarning: usageCheck.warning,
      usageState: usageCheck.state,
      fallbackUsed: false,
      usage: usageCheck.usage,
    };

  } catch (error: any) {
    // If it's already an HttpsError (from Twilio auth, invalid args, etc.), rethrow it
    if (error instanceof functions.https.HttpsError) {
      // Still log failed SMS attempt
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
      throw error; // Rethrow the original HttpsError with proper code
    }

    // For unexpected errors, convert to internal error
    functions.logger.error(
      `Failed to send SMS to ${to} for facility ${facilityId}`,
      { error: error?.message, stack: error?.stack, facilityId, to }
    );

    // Log failed SMS
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
  usageCheck: any
): Promise<{
  success: boolean;
  fallbackUsed: boolean;
  messageId?: string;
  usageWarning?: string;
  usageState: string;
}> {
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

    // Send email via SendGrid
    initializeSendGrid();
    const msg = {
      to: emailAddress,
      from: {
        email: SENDGRID_FROM_EMAIL.value(),
        name: SENDGRID_FROM_NAME.value(),
      },
      subject: emailSubject,
      html: emailHtml,
      text: emailText,
    };

    const [result] = await sgMail.send(msg);
    const messageId = result.headers['x-message-id'] || `email-${Date.now()}`;

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
    functions.logger.error(`Failed to send SMS fallback email: ${error.message}`, error);
    return {
      success: false,
      fallbackUsed: true,
      usageState: usageCheck.state,
      usageWarning: 'SMS limit exceeded and email fallback failed',
    };
  }
}

/**
 * Format phone number for Twilio (E.164 format)
 */
function formatPhoneNumber(phone: string): string | null {
  // Remove all non-digit characters
  const digits = phone.replace(/\D/g, '');
  
  // If it starts with 1 and has 11 digits, it's already formatted
  if (digits.length === 11 && digits.startsWith('1')) {
    return `+${digits}`;
  }
  
  // If it has 10 digits, assume US number and add +1
  if (digits.length === 10) {
    return `+1${digits}`;
  }
  
  // If it already starts with +, return as is
  if (phone.startsWith('+')) {
    return phone;
  }
  
  // Invalid format
  return null;
}

/**
 * SMS Usage Limits (configurable via environment variables)
 */
const SMS_LIMIT_PER_TENANT = parseInt(process.env.SMS_LIMIT_PER_TENANT || '4', 10);
const SMS_LIMIT_PER_FACILITY = parseInt(process.env.SMS_LIMIT_PER_FACILITY || '1000', 10);
const SMS_LIMIT_PER_ACCOUNT = parseInt(process.env.SMS_LIMIT_PER_ACCOUNT || '3000', 10);
const SMS_COST_PER_MESSAGE = parseFloat(process.env.SMS_COST_PER_MESSAGE || '0.01'); // conservative high estimate
const SMS_MAX_COST_PER_FACILITY = parseFloat(process.env.SMS_MAX_COST_PER_FACILITY || '40'); // cap spend per facility
const SMS_EXTREME_MULTIPLIER = 3; // Extreme usage = 3x account limit

function capSmsLimit(limit: number): number {
  if (limit <= 0) return 0;
  const maxMessages = Math.floor(SMS_MAX_COST_PER_FACILITY / SMS_COST_PER_MESSAGE);
  return Math.min(limit, maxMessages);
}

/**
 * SMS Usage State
 */
enum SMSUsageState {
  NORMAL = 'normal',
  APPROACHING = 'approaching', // 80-100% of limit
  EXCEEDED = 'exceeded', // Over 100% of limit
  EXTREME = 'extreme', // 3x limit
}

/**
 * Get SMS usage status for a facility (without incrementing)
 */
export const getSMSUsageStatus = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId, tenantId, accountId } = data;

  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }

  try {
    const now = new Date();
    const monthKey = `${now.getFullYear()}-${(now.getMonth() + 1).toString().padStart(2, '0')}`;

    // Get facility to find account ID if not provided
    let finalAccountId = accountId;
    if (!finalAccountId) {
      const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
      if (facilityDoc.exists) {
        finalAccountId = facilityDoc.data()?.facilityCreatorAccountId;
      }
    }

    // Get tenant usage
    let tenantUsage = { count: 0, limit: SMS_LIMIT_PER_TENANT };
    if (tenantId) {
      const tenantUsageDoc = await admin.firestore()
        .collection('tenants')
        .doc(tenantId)
        .collection('smsUsage')
        .doc(monthKey)
        .get();
      
      if (tenantUsageDoc.exists) {
        const data = tenantUsageDoc.data()!;
        tenantUsage = {
          count: data.smsMonthlyCount || 0,
          limit: SMS_LIMIT_PER_TENANT,
        };
      }
    }

    // Get facility usage
    const facilityUsageDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('smsUsage')
      .doc(monthKey)
      .get();
    
    const facilityData = facilityUsageDoc.exists ? facilityUsageDoc.data()! : {};
    const facilityUsage = {
      count: facilityData.smsMonthlyCount || 0,
      limit: capSmsLimit(facilityData.smsMonthlyLimit || SMS_LIMIT_PER_FACILITY),
    };

    // Get account usage
    let accountUsage = { count: 0, limit: SMS_LIMIT_PER_ACCOUNT };
    if (finalAccountId) {
      const accountUsageDoc = await admin.firestore()
        .collection('facilityCreatorAccounts')
        .doc(finalAccountId)
        .collection('smsUsage')
        .doc(monthKey)
        .get();
      
      if (accountUsageDoc.exists) {
        const data = accountUsageDoc.data()!;
        accountUsage = {
          count: data.smsMonthlyCount || 0,
          limit: capSmsLimit(data.smsMonthlyLimit || SMS_LIMIT_PER_ACCOUNT),
        };
      }
    }

    // Determine usage state
    const accountPercentage = finalAccountId ? (accountUsage.count / accountUsage.limit) * 100 : 0;
    const facilityPercentage = (facilityUsage.count / facilityUsage.limit) * 100;
    const tenantPercentage = tenantId ? (tenantUsage.count / tenantUsage.limit) * 100 : 0;

    let state: SMSUsageState = SMSUsageState.NORMAL;
    if (accountUsage.count >= (accountUsage.limit * SMS_EXTREME_MULTIPLIER)) {
      state = SMSUsageState.EXTREME;
    } else if (tenantUsage.count > tenantUsage.limit || facilityUsage.count > facilityUsage.limit || accountUsage.count > accountUsage.limit) {
      state = SMSUsageState.EXCEEDED;
    } else if (accountPercentage >= 80 || facilityPercentage >= 80 || tenantPercentage >= 80) {
      state = SMSUsageState.APPROACHING;
    }

    return {
      state,
      usage: {
        tenant: tenantId ? tenantUsage : undefined,
        facility: facilityUsage,
        account: finalAccountId ? accountUsage : undefined,
      },
      canSendSMS: state === SMSUsageState.NORMAL || state === SMSUsageState.APPROACHING,
      shouldFallbackToEmail: state === SMSUsageState.EXCEEDED || state === SMSUsageState.EXTREME,
    };
  } catch (error: any) {
    functions.logger.error('Error getting SMS usage status', error);
    throw new functions.https.HttpsError('internal', `Failed to get SMS usage status: ${error.message}`);
  }
});

/**
 * Admin function: Override SMS limits for a facility/account
 */
export const overrideSMSLimit = functions.https.onCall(async (data: any, context) => {
  // TODO: Add admin authentication check
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId, accountId, newLimit, limitType } = data; // limitType: 'facility' | 'account'

  if (!facilityId && !accountId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId or accountId is required');
  }

  if (!newLimit || !limitType) {
    throw new functions.https.HttpsError('invalid-argument', 'newLimit and limitType are required');
  }

  try {
    const now = new Date();
    const monthKey = `${now.getFullYear()}-${(now.getMonth() + 1).toString().padStart(2, '0')}`;

    if (limitType === 'facility' && facilityId) {
      const usageRef = admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('smsUsage')
        .doc(monthKey);
      
      await usageRef.set({
        smsMonthlyLimit: capSmsLimit(newLimit),
        smsMonth: monthKey,
        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
        overriddenBy: context.auth.uid,
        overriddenAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });

      return { success: true, message: `Facility SMS limit updated to ${newLimit}` };
    }

    if (limitType === 'account' && accountId) {
      const usageRef = admin.firestore()
        .collection('facilityCreatorAccounts')
        .doc(accountId)
        .collection('smsUsage')
        .doc(monthKey);
      
      await usageRef.set({
        smsMonthlyLimit: capSmsLimit(newLimit),
        smsMonth: monthKey,
        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
        overriddenBy: context.auth.uid,
        overriddenAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });

      return { success: true, message: `Account SMS limit updated to ${newLimit}` };
    }

    throw new functions.https.HttpsError('invalid-argument', 'Invalid limitType or missing ID');
  } catch (error: any) {
    functions.logger.error('Error overriding SMS limit', error);
    throw new functions.https.HttpsError('internal', `Failed to override SMS limit: ${error.message}`);
  }
});

/**
 * Callable function to generate monthly rent charges for a facility
 * Can be called manually or by scheduled function
 */
export const generateMonthlyRentCharges = functions.https.onCall(async (data, context) => {
  try {
    // Verify authentication
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
    }

    const { facilityId, forDate } = data;

    if (!facilityId) {
      throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
    }

    // Verify user has access to this facility
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data();
    const ownerUid = facilityData?.ownerUid;
    const roles = facilityData?.roles || {};

    // Check if user is owner or has manager role
    if (ownerUid !== context.auth.uid && roles[context.auth.uid] !== 'manager' && roles[context.auth.uid] !== 'owner') {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission to generate charges for this facility');
    }

    // Parse target date or use first of current month
    let targetDate: Date;
    if (forDate) {
      targetDate = new Date(forDate);
    } else {
      const now = new Date();
      targetDate = new Date(now.getFullYear(), now.getMonth(), 1);
    }

    // Get all active tenants for the facility
    const tenantsSnapshot = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .where('isActive', '==', true)
      .get();

    const activeTenants = tenantsSnapshot.docs.filter(doc => {
      const data = doc.data();
      return data.unitNumber && data.unitNumber.trim() !== '';
    });

    functions.logger.info(`Generating charges for ${activeTenants.length} active tenants in facility ${facilityId}`);

    let successCount = 0;
    let skippedCount = 0;
    let errorCount = 0;
    const errors: string[] = [];

    const targetMonth = targetDate.getMonth() + 1; // JavaScript months are 0-indexed
    const targetYear = targetDate.getFullYear();

    for (const tenantDoc of activeTenants) {
      try {
        const tenantData = tenantDoc.data();
        const tenantId = tenantDoc.id;
        const monthlyRate = tenantData.monthlyRate || 0;

        if (monthlyRate <= 0) {
          skippedCount++;
          continue;
        }

        // Check if charge already exists for this month
        const ledgerSnapshot = await admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('ledgers')
          .where('tenantId', '==', tenantId)
          .where('type', '==', 'rentCharge')
          .where('status', '==', 'posted')
          .get();

        const existingCharge = ledgerSnapshot.docs.some(doc => {
          const entryData = doc.data();
          const entryDate = entryData.entryDate?.toDate();
          if (!entryDate) return false;

          const entryMonth = entryDate.getMonth() + 1;
          const entryYear = entryDate.getFullYear();

          if (entryMonth !== targetMonth || entryYear !== targetYear) return false;

          const metadata = entryData.metadata || {};
          return metadata.recurringCharge === true &&
                 metadata.chargeType === 'monthlyRent' &&
                 metadata.month === targetMonth &&
                 metadata.year === targetYear;
        });

        if (existingCharge) {
          skippedCount++;
          continue;
        }

        // Generate rent charge
        const monthNames = ['January', 'February', 'March', 'April', 'May', 'June',
          'July', 'August', 'September', 'October', 'November', 'December'];
        const description = `Monthly Rent - ${monthNames[targetDate.getMonth()]} ${targetYear}`;

        const ledgerEntryRef = admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('ledgers')
          .doc();

        await ledgerEntryRef.set({
          tenantId: tenantId,
          facilityId: facilityId,
          type: 'rentCharge',
          amount: monthlyRate,
          description: description,
          entryDate: admin.firestore.Timestamp.fromDate(targetDate),
          dueDate: admin.firestore.Timestamp.fromDate(targetDate),
          status: 'posted',
          metadata: {
            recurringCharge: true,
            chargeType: 'monthlyRent',
            month: targetMonth,
            year: targetYear,
            generatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          createdBy: context.auth.uid,
        });

        // Audit log
        await admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('auditLogs')
          .add({
            action: 'recurringCharge.generated',
            actorUid: context.auth.uid,
            actorEmail: context.auth.token.email,
            targetId: ledgerEntryRef.id,
            entityType: 'ledgerEntry',
            entityId: ledgerEntryRef.id,
            tenantId: tenantId,
            details: {
              amount: monthlyRate,
              chargeType: 'monthlyRent',
              month: targetMonth,
              year: targetYear,
            },
            at: admin.firestore.FieldValue.serverTimestamp(),
          });

        successCount++;
      } catch (error: any) {
        errorCount++;
        const tenantData = tenantDoc.data();
        const errorMsg = `Tenant ${tenantData.name || tenantDoc.id}: ${error.message}`;
        errors.push(errorMsg);
        functions.logger.error(`Error generating charge for tenant ${tenantDoc.id}:`, error);
      }
    }

    functions.logger.info(`Charge generation completed: ${successCount} success, ${skippedCount} skipped, ${errorCount} errors`);

    return {
      success: true,
      totalTenants: activeTenants.length,
      successCount,
      skippedCount,
      errorCount,
      errors,
    };
  } catch (error: any) {
    functions.logger.error('Error generating monthly rent charges:', error);
    throw new functions.https.HttpsError('internal', `Failed to generate charges: ${error.message}`);
  }
});

/**
 * Process payment via Stripe for autopay or manual payments
 */
export const processStripePayment = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  await enforceRateLimit({
    facilityId: data?.facilityId,
    key: 'processStripePayment',
    limit: 40,
    windowSeconds: 60,
    userId: context.auth.uid,
  });

  const { facilityId, tenantId, paymentMethodId, customerId, amount, description } = data;

  if (!facilityId || !tenantId || !paymentMethodId || !amount) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required parameters');
  }

  try {
    // Verify user has access to this facility
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data();
    const ownerUid = facilityData?.ownerUid;
    const roles = facilityData?.roles || {};
    const stripeConnectAccountId = facilityData?.stripeConnectAccountId;

    // Check if user is owner or has manager role
    if (ownerUid !== context.auth.uid && roles[context.auth.uid] !== 'manager' && roles[context.auth.uid] !== 'owner') {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission');
    }

    // Verify tenant exists
    const tenantDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId)
      .get();

    if (!tenantDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Tenant not found');
    }

    const stripe = getStripeClient();

    // Create payment intent
    const paymentIntentParams: Stripe.PaymentIntentCreateParams = {
      amount: Math.round(amount * 100), // Convert to cents
      currency: 'usd',
      payment_method: paymentMethodId,
      customer: customerId,
      confirmation_method: 'automatic',
      confirm: true,
      description: description || `Payment for tenant ${tenantId}`,
      metadata: {
        facilityId,
        tenantId,
        userId: context.auth.uid,
      },
    };

    // If facility has Stripe Connect account, use it
    if (stripeConnectAccountId) {
      paymentIntentParams.on_behalf_of = stripeConnectAccountId;
      paymentIntentParams.transfer_data = {
        destination: stripeConnectAccountId,
      };
    }

    const paymentIntent = await stripe.paymentIntents.create(paymentIntentParams);

    if (paymentIntent.status === 'succeeded') {
      functions.logger.info(`Payment succeeded: ${paymentIntent.id} for tenant ${tenantId}`);
      await writeAuditLog(facilityId, {
        action: 'payment_succeeded',
        userId: context.auth.uid,
        tenantId,
        amount,
        paymentIntentId: paymentIntent.id,
      });
      return {
        success: true,
        transactionId: paymentIntent.id,
        amount: amount,
        status: paymentIntent.status,
      };
    } else if (paymentIntent.status === 'requires_action') {
      // Payment requires additional authentication
      return {
        success: false,
        requiresAction: true,
        clientSecret: paymentIntent.client_secret,
        transactionId: paymentIntent.id,
      };
    } else {
      throw new Error(`Payment failed with status: ${paymentIntent.status}`);
    }
  } catch (error: any) {
    functions.logger.error('Error processing Stripe payment:', error);
    await writeAuditLog(facilityId, {
      action: 'payment_failed',
      userId: context.auth.uid,
      tenantId,
      amount,
      error: error?.message || 'unknown',
    });
    throw new functions.https.HttpsError('internal', `Failed to process payment: ${error.message}`);
  }
});

/**
 * Scheduled function: Generate monthly rent charges on the 1st of each month at 12:00 AM UTC
 * This function runs for all facilities
 */
export const scheduledGenerateMonthlyRentCharges = functions.pubsub
  .schedule('0 0 1 * *') // 1st of each month at 12:00 AM UTC
  .timeZone('UTC')
  .onRun(async (context) => {
    try {
      functions.logger.info('Starting scheduled monthly rent charge generation');

      // Get all active facilities
      const facilitiesSnapshot = await admin.firestore()
        .collection('facilities')
        .where('active', '==', true)
        .get();

      functions.logger.info(`Found ${facilitiesSnapshot.size} active facilities`);

      const results = [];
      const targetDate = new Date();
      targetDate.setDate(1); // First day of current month

      for (const facilityDoc of facilitiesSnapshot.docs) {
        const facilityId = facilityDoc.id;
        try {
          const facilityData = facilityDoc.data();
          // ownerUid available if needed for future permission checks

          // Get all active tenants
          const tenantsSnapshot = await admin.firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('tenants')
            .where('isActive', '==', true)
            .get();

          const activeTenants = tenantsSnapshot.docs.filter(doc => {
            const data = doc.data();
            return data.unitNumber && data.unitNumber.trim() !== '';
          });

          let successCount = 0;
          let skippedCount = 0;
          let errorCount = 0;

          const targetMonth = targetDate.getMonth() + 1;
          const targetYear = targetDate.getFullYear();

          for (const tenantDoc of activeTenants) {
            try {
              const tenantData = tenantDoc.data();
              const tenantId = tenantDoc.id;
              const monthlyRate = tenantData.monthlyRate || 0;

              if (monthlyRate <= 0) {
                skippedCount++;
                continue;
              }

              // Check if charge already exists
              const ledgerSnapshot = await admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('ledgers')
                .where('tenantId', '==', tenantId)
                .where('type', '==', 'rentCharge')
                .where('status', '==', 'posted')
                .get();

              const existingCharge = ledgerSnapshot.docs.some(doc => {
                const entryData = doc.data();
                const entryDate = entryData.entryDate?.toDate();
                if (!entryDate) return false;

                const entryMonth = entryDate.getMonth() + 1;
                const entryYear = entryDate.getFullYear();

                if (entryMonth !== targetMonth || entryYear !== targetYear) return false;

                const metadata = entryData.metadata || {};
                return metadata.recurringCharge === true &&
                       metadata.chargeType === 'monthlyRent' &&
                       metadata.month === targetMonth &&
                       metadata.year === targetYear;
              });

              if (existingCharge) {
                skippedCount++;
                continue;
              }

              // Generate charge
              const monthNames = ['January', 'February', 'March', 'April', 'May', 'June',
                'July', 'August', 'September', 'October', 'November', 'December'];
              const description = `Monthly Rent - ${monthNames[targetDate.getMonth()]} ${targetYear}`;

              const ledgerEntryRef = admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('ledgers')
                .doc();

              await ledgerEntryRef.set({
                tenantId: tenantId,
                facilityId: facilityId,
                type: 'rentCharge',
                amount: monthlyRate,
                description: description,
                entryDate: admin.firestore.Timestamp.fromDate(targetDate),
                dueDate: admin.firestore.Timestamp.fromDate(targetDate),
                status: 'posted',
                metadata: {
                  recurringCharge: true,
                  chargeType: 'monthlyRent',
                  month: targetMonth,
                  year: targetYear,
                  generatedAt: admin.firestore.FieldValue.serverTimestamp(),
                },
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
                createdBy: 'system', // System-generated
              });

              // Audit log
              await admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('auditLogs')
                .add({
                  action: 'recurringCharge.generated',
                  actorUid: 'system',
                  actorEmail: 'system@scheduled-job',
                  targetId: ledgerEntryRef.id,
                  entityType: 'ledgerEntry',
                  entityId: ledgerEntryRef.id,
                  tenantId: tenantId,
                  details: {
                    amount: monthlyRate,
                    chargeType: 'monthlyRent',
                    month: targetMonth,
                    year: targetYear,
                    scheduled: true,
                  },
                  at: admin.firestore.FieldValue.serverTimestamp(),
                });

              successCount++;
            } catch (error: any) {
              errorCount++;
              functions.logger.error(`Error generating charge for tenant ${tenantDoc.id} in facility ${facilityId}:`, error);
            }
          }

          results.push({
            facilityId,
            facilityName: facilityData.name,
            totalTenants: activeTenants.length,
            successCount,
            skippedCount,
            errorCount,
          });

          functions.logger.info(`Facility ${facilityData.name}: ${successCount} success, ${skippedCount} skipped, ${errorCount} errors`);
        } catch (error: any) {
          functions.logger.error(`Error processing facility ${facilityId}:`, error);
          results.push({
            facilityId,
            facilityName: facilityDoc.data()?.name || 'Unknown',
            error: error.message,
          });
        }
      }

      functions.logger.info(`Scheduled charge generation completed for ${results.length} facilities`);
      return { results };
    } catch (error: any) {
      functions.logger.error('Error in scheduled charge generation:', error);
      throw error;
    }
  });

/**
 * Scheduled function: Process autopay payments daily
 * Runs daily at 2:00 AM UTC to process autopay for due payments
 */
/**
 * Scheduled function to process delinquency automation daily
 * Runs at 3:00 AM UTC every day
 */
export const processDelinquencyAutomation = functions.pubsub
  .schedule('0 3 * * *')
  .timeZone('UTC')
  .onRun(async (context) => {
    functions.logger.info('🔄 Starting delinquency automation processing...');

    try {
      // Get all active facilities
      const facilitiesSnapshot = await admin.firestore()
        .collection('facilities')
        .where('active', '==', true)
        .get();

      if (facilitiesSnapshot.empty) {
        functions.logger.info('No active facilities found');
        return null;
      }

      let totalProcessed = 0;
      let totalLateFees = 0;
      let totalNotices = 0;
      let totalLockouts = 0;
      let totalErrors = 0;

      for (const facilityDoc of facilitiesSnapshot.docs) {
        const facilityId = facilityDoc.id;
        functions.logger.info(`Processing delinquency for facility: ${facilityId}`);

        try {
          // Call the delinquency processing function
          // Note: This is a simplified version - in production, you'd want to
          // implement the full logic here or call a callable function
          const result = await processDelinquencyForFacility(facilityId);
          
          if (result.success) {
            totalProcessed += result.processedCount || 0;
            totalLateFees += result.lateFeeAppliedCount || 0;
            totalNotices += result.noticeSentCount || 0;
            totalLockouts += result.lockoutCount || 0;
            totalErrors += result.errorCount || 0;

            functions.logger.info(`✅ Processed facility ${facilityId}:`, {
              processed: result.processedCount,
              lateFees: result.lateFeeAppliedCount,
              notices: result.noticeSentCount,
              lockouts: result.lockoutCount,
            });
          } else {
            totalErrors++;
            functions.logger.error(`❌ Error processing facility ${facilityId}:`, result.error);
          }
        } catch (error: any) {
          totalErrors++;
          functions.logger.error(`❌ Error processing facility ${facilityId}:`, {
            error: error.message,
            stack: error.stack,
          });
        }
      }

      functions.logger.info('✅ Delinquency automation complete:', {
        facilitiesProcessed: facilitiesSnapshot.size,
        totalProcessed,
        totalLateFees,
        totalNotices,
        totalLockouts,
        totalErrors,
      });

      return null;
    } catch (error: any) {
      functions.logger.error('❌ Fatal error in delinquency automation:', {
        error: error.message,
        stack: error.stack,
      });
      throw error;
    }
  });

/**
 * Process delinquency for a single facility
 * This can be called manually or by the scheduled function
 */
async function processDelinquencyForFacility(facilityId: string): Promise<{
  success: boolean;
  processedCount?: number;
  lateFeeAppliedCount?: number;
  noticeSentCount?: number;
  lockoutCount?: number;
  errorCount?: number;
  error?: string;
}> {
  try {
    // Get facility
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      return { success: false, error: 'Facility not found' };
    }

    const facilityData = facilityDoc.data();
    const billingSettings = facilityData?.billingSettings || {};

    // Get delinquency rules
    const rules = {
      gracePeriodDays: billingSettings.gracePeriodDays || 3,
      baseLateFee: billingSettings.baseLateFee || 25.0,
      dailyLateFee: billingSettings.dailyLateFee || 5.0,
      noticeDays: billingSettings.noticeDays || 7,
      finalNoticeDays: billingSettings.finalNoticeDays || 14,
      lienDays: billingSettings.lienDays || 30,
      lockoutDays: billingSettings.lockoutDays || 45,
      enableAutoLateFees: billingSettings.enableAutoLateFees !== false,
      enableAutoNotices: billingSettings.enableAutoNotices !== false,
      enableAutoLockout: billingSettings.enableAutoLockout === true,
    };

    // Get all active tenants
    const tenantsSnapshot = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .where('isActive', '==', true)
      .get();

    let processedCount = 0;
    let lateFeeAppliedCount = 0;
    let noticeSentCount = 0;
    let lockoutCount = 0;
    let errorCount = 0;

    for (const tenantDoc of tenantsSnapshot.docs) {
      try {
        const tenantData = tenantDoc.data();
        const tenantId = tenantDoc.id;

        // Check if tenant is late (simplified check - in production use full logic)
        const paidThrough = tenantData.paidThrough?.toDate();
        const now = new Date();
        const startOfMonth = new Date(now.getFullYear(), now.getMonth(), 1);
        const graceBoundary = new Date(startOfMonth);
        graceBoundary.setDate(graceBoundary.getDate() - rules.gracePeriodDays);

        const isLate = !paidThrough || paidThrough < graceBoundary;
        
        if (!isLate) {
          continue; // Skip non-delinquent tenants
        }

        // Calculate days late
        const daysLate = Math.max(0, Math.floor((now.getTime() - graceBoundary.getTime()) / (1000 * 60 * 60 * 24)));

        // Get ledger balance
        const ledgerSnapshot = await admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .collection('ledger')
          .get();

        let balance = 0;
        for (const entry of ledgerSnapshot.docs) {
          const entryData = entry.data();
          if (entryData.status === 'posted' || entryData.status === 'pending') {
            if (entryData.type === 'payment' || entryData.type === 'credit') {
              balance -= entryData.amount || 0;
            } else {
              balance += entryData.amount || 0;
            }
          }
        }

        if (balance <= 0) {
          continue; // Balance is paid
        }

        // Apply late fee if needed
        if (rules.enableAutoLateFees && daysLate > rules.gracePeriodDays) {
          const lateFee = rules.baseLateFee + ((daysLate - rules.gracePeriodDays) * rules.dailyLateFee);
          
          // Check if late fee already applied this month
          const thisMonth = new Date(now.getFullYear(), now.getMonth(), 1);
          const lateFeeSnapshot = await admin.firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('tenants')
            .doc(tenantId)
            .collection('ledger')
            .where('type', '==', 'lateFee')
            .where('status', '==', 'posted')
            .where('entryDate', '>=', admin.firestore.Timestamp.fromDate(thisMonth))
            .get();

          if (lateFeeSnapshot.empty && lateFee > 0) {
            // Create late fee ledger entry
            await admin.firestore()
              .collection('facilities')
              .doc(facilityId)
              .collection('tenants')
              .doc(tenantId)
              .collection('ledger')
              .add({
                type: 'lateFee',
                amount: lateFee,
                description: `Late Fee - ${daysLate} days overdue`,
                entryDate: admin.firestore.FieldValue.serverTimestamp(),
                dueDate: admin.firestore.FieldValue.serverTimestamp(),
                status: 'posted',
                facilityId,
                tenantId,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
                metadata: {
                  daysOverdue: daysLate,
                  automated: true,
                },
              });

            lateFeeAppliedCount++;
          }
        }

        // Send notices if needed
        if (rules.enableAutoNotices) {
          let shouldSendNotice = false;
          let noticeType = '';
          
          if (daysLate >= rules.finalNoticeDays) {
            shouldSendNotice = true;
            noticeType = 'final';
          } else if (daysLate >= rules.noticeDays) {
            shouldSendNotice = true;
            noticeType = 'late';
          }

          if (shouldSendNotice) {
            try {
              // Get tenant contact info for notices
              const tenantEmail = tenantData?.email;
              const tenantPhone = tenantData?.phone;
              const tenantName = tenantData?.name || 'Tenant';
              
              // Check if notice was already sent today
              const today = new Date();
              today.setHours(0, 0, 0, 0);
              const noticesSnapshot = await admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('tenants')
                .doc(tenantId)
                .collection('notices')
                .where('type', '==', noticeType)
                .where('sentDate', '>=', admin.firestore.Timestamp.fromDate(today))
                .limit(1)
                .get();

              if (noticesSnapshot.empty) {
                // Send email notice
                if (tenantEmail && tenantEmail.trim() !== '') {
                  try {
                    initializeSendGrid();
                    const subject = noticeType === 'final' 
                      ? `Final Notice: Payment Overdue - ${facilityData?.name || 'Storage Facility'}`
                      : `Payment Reminder: Account Past Due - ${facilityData?.name || 'Storage Facility'}`;
                    
                    const emailContent = `
Dear ${tenantName},

This is a ${noticeType === 'final' ? 'FINAL' : ''} notice regarding your overdue payment.

Your account is currently ${daysLate} days overdue with a balance of $${balance.toFixed(2)}.

${noticeType === 'final' ? 'This is your final notice before further action is taken. ' : ''}Please contact us immediately to resolve this matter.

${facilityData?.phone ? `You can reach us at ${facilityData.phone}.` : ''}
${facilityData?.email ? `Or email us at ${facilityData.email}.` : ''}

Thank you,
${facilityData?.name || 'Management Team'}
                    `.trim();

                    // Initialize SendGrid if not already initialized
                    initializeSendGrid();
                    
                    // Send email directly via SendGrid
                    const msg = {
                      to: tenantEmail,
                      from: {
                        email: SENDGRID_FROM_EMAIL.value(),
                        name: SENDGRID_FROM_NAME.value(),
                      },
                      subject: subject,
                      html: emailContent.replace(/\n/g, '<br>'),
                      text: emailContent,
                    };
                    
                    await sgMail.send(msg);

                    // Record notice in Firestore
                    await admin.firestore()
                      .collection('facilities')
                      .doc(facilityId)
                      .collection('tenants')
                      .doc(tenantId)
                      .collection('notices')
                      .add({
                        type: noticeType,
                        sentDate: admin.firestore.FieldValue.serverTimestamp(),
                        daysLate: daysLate,
                        balance: balance,
                        method: 'email',
                        recipient: tenantEmail,
                        createdAt: admin.firestore.FieldValue.serverTimestamp(),
                      });
                  } catch (emailError: any) {
                    functions.logger.error(`Failed to send email notice to ${tenantEmail}:`, emailError);
                  }
                }

                // Send SMS notice if phone available
                if (tenantPhone && tenantPhone.trim() !== '') {
                  try {
                    const smsMessage = noticeType === 'final'
                      ? `FINAL NOTICE: Your account is ${daysLate} days overdue. Balance: $${balance.toFixed(2)}. Contact us immediately.`
                      : `Payment reminder: Your account is ${daysLate} days overdue. Balance: $${balance.toFixed(2)}. Please make a payment.`;
                    
                    // Note: SMS sending would require Twilio integration
                    // For now, we log it - implement actual SMS sending if needed
                    functions.logger.info(`SMS notice would be sent to ${tenantPhone}: ${smsMessage}`);
                  } catch (smsError: any) {
                    functions.logger.error(`Failed to send SMS notice to ${tenantPhone}:`, smsError);
                  }
                }

                noticeSentCount++;
              }
            } catch (noticeError: any) {
              functions.logger.error(`Error sending notice to tenant ${tenantId}:`, noticeError);
            }
          }
        }

        // Update tenant delinquency status
        let delinquencyStatus = '';
        if (daysLate >= rules.lockoutDays) {
          delinquencyStatus = 'lockout';
        } else if (daysLate >= rules.lienDays) {
          delinquencyStatus = 'lien';
        } else if (daysLate >= rules.finalNoticeDays) {
          delinquencyStatus = 'final_notice';
        } else if (daysLate >= rules.noticeDays) {
          delinquencyStatus = 'late';
        }

        if (delinquencyStatus) {
          await tenantDoc.ref.update({
            delinquencyStatus: delinquencyStatus,
            lastLateFeeDate: admin.firestore.FieldValue.serverTimestamp(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          });

          // Set lien eligible date if applicable
          if (daysLate >= rules.lienDays) {
            const lienEligibleDate = new Date(now);
            lienEligibleDate.setDate(lienEligibleDate.getDate() - rules.lienDays);
            await tenantDoc.ref.update({
              lienEligibleDate: admin.firestore.Timestamp.fromDate(lienEligibleDate),
            });
          }
        }

        // Trigger lockout if needed
        if (rules.enableAutoLockout && daysLate >= rules.lockoutDays) {
          // Disable gate access
          const gateAccessSnapshot = await admin.firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('gateAccess')
            .where('tenantId', '==', tenantId)
            .where('isActive', '==', true)
            .get();

          for (const accessDoc of gateAccessSnapshot.docs) {
            await accessDoc.ref.update({
              isActive: false,
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
              notes: `Gate access disabled due to delinquency (${daysLate} days overdue)`,
            });
          }

          lockoutCount++;
        }

        processedCount++;
      } catch (error: any) {
        errorCount++;
        functions.logger.error(`Error processing tenant ${tenantDoc.id}:`, error);
      }
    }

    return {
      success: true,
      processedCount,
      lateFeeAppliedCount,
      noticeSentCount,
      lockoutCount,
      errorCount,
    };
  } catch (error: any) {
    return {
      success: false,
      error: error.message,
    };
  }
}

/**
 * Process refund via Stripe
 * Used for move-out refunds and other refund scenarios
 */
export const processRefund = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  await enforceRateLimit({
    facilityId: data?.facilityId,
    key: 'processRefund',
    limit: 20,
    windowSeconds: 60,
    userId: context.auth.uid,
  });

  const { facilityId, tenantId, amount, refundMethod, referenceId } = data;

  if (!facilityId || !tenantId || !amount || amount <= 0) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required parameters or invalid amount');
  }

  try {
    // Verify user has access to this facility
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data();
    const ownerUid = facilityData?.ownerUid;
    const roles = facilityData?.roles || {};
    const stripeConnectAccountId = facilityData?.stripeConnectAccountId;

    // Check if user is owner or has manager role
    if (ownerUid !== context.auth.uid && roles[context.auth.uid] !== 'manager') {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission to process refunds');
    }

    // If Stripe Connect is set up and refund method is card, process via Stripe
    if (stripeConnectAccountId && refundMethod === 'creditCard' && referenceId) {
      try {
        const stripe = getStripeClient();
        
        // Look up the original payment intent
        const paymentIntent = await stripe.paymentIntents.retrieve(referenceId, {
          expand: ['charges'],
        });

        if (paymentIntent.status !== 'succeeded') {
          throw new Error('Payment intent not succeeded, cannot refund');
        }

        // Get the charge ID - retrieve payment intent with charges expanded
        const expandedPaymentIntent = await stripe.paymentIntents.retrieve(paymentIntent.id, {
          expand: ['charges'],
        });
        const chargeId = (expandedPaymentIntent as any).charges?.data?.[0]?.id;
        if (!chargeId) {
          throw new Error('Charge ID not found in payment intent');
        }

        // Create refund on the connected account
        const refund = await stripe.refunds.create({
          charge: chargeId,
          amount: Math.round(amount * 100), // Convert to cents
        }, {
          stripeAccount: stripeConnectAccountId,
        });

        functions.logger.info(`Stripe refund processed: ${refund.id} for $${amount}`);

        return {
          success: true,
          refundId: refund.id,
          amount: amount,
          method: refundMethod,
          stripeRefundId: refund.id,
          message: 'Refund processed successfully via Stripe',
        };
      } catch (stripeError: any) {
        functions.logger.error('Stripe refund error:', stripeError);
        // Fall through to manual processing
      }
    }

    // For non-Stripe refunds or if Stripe fails, log for manual processing
    functions.logger.info(`Refund requested: $${amount} for tenant ${tenantId}, method: ${refundMethod || 'manual'}`);
    await writeAuditLog(facilityId, {
      action: 'refund_requested',
      userId: context.auth.uid,
      tenantId,
      amount,
      method: refundMethod || 'manual',
      referenceId: referenceId || null,
    });

    return {
      success: true,
      refundId: `refund-${Date.now()}`,
      amount: amount,
      method: refundMethod || 'manual',
      message: 'Refund logged for processing',
    };
  } catch (error: any) {
    functions.logger.error('Error processing refund:', error);
    await writeAuditLog(facilityId, {
      action: 'refund_failed',
      userId: context.auth.uid,
      tenantId,
      amount,
      error: error?.message || 'unknown',
    });
    throw new functions.https.HttpsError('internal', `Failed to process refund: ${error.message}`);
  }
});

/**
 * Process move-out workflow
 * Handles move-out in a transaction-safe way: updates contract, frees unit, calculates charges/refunds
 */
export const processMoveOut = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  await enforceRateLimit({
    facilityId: data?.facilityId,
    key: 'processMoveOut',
    limit: 30,
    windowSeconds: 60,
    userId: context.auth.uid,
  });

  const userId = context.auth.uid; // Store for use in transaction

  const {
    facilityId,
    tenantId,
    contractId,
    unitId,
    moveOutDate,
    moveOutCharges,
    moveOutRefund,
    moveOutNotes,
    processRefund = false,
    refundMethod,
  } = data;

  if (!facilityId || !tenantId || !contractId || !unitId || !moveOutDate) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required parameters');
  }

  try {
    // Verify user has access to this facility
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data();
    const ownerUid = facilityData?.ownerUid;
    const roles = facilityData?.roles || {};

    // Check if user is owner or has manager role
    if (ownerUid !== context.auth.uid && roles[context.auth.uid] !== 'manager') {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission to process move-outs');
    }

    const moveOutTimestamp = admin.firestore.Timestamp.fromDate(new Date(moveOutDate));
    const now = admin.firestore.FieldValue.serverTimestamp();

    // Use Firestore transaction to ensure consistency
    const result = await admin.firestore().runTransaction(async (transaction) => {
      // 1. Get contract
      const contractRef = admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('contracts')
        .doc(contractId);
      const contractDoc = await transaction.get(contractRef);

      if (!contractDoc.exists) {
        throw new Error('Contract not found');
      }

      // 2. Get unit
      const unitRef = admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('units')
        .doc(unitId);
      const unitDoc = await transaction.get(unitRef);

      if (!unitDoc.exists) {
        throw new Error('Unit not found');
      }

      // 3. Get tenant
      const tenantRef = admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .doc(tenantId);
      const tenantDoc = await transaction.get(tenantRef);

      if (!tenantDoc.exists) {
        throw new Error('Tenant not found');
      }

      // 4. Update contract - mark as ended
      transaction.update(contractRef, {
        moveOutStatus: 'completed',
        moveOutDate: moveOutTimestamp,
        moveOutCharges: moveOutCharges || 0,
        moveOutRefund: moveOutRefund || 0,
        moveOutNotes: moveOutNotes || null,
        status: 'cancelled', // Mark contract as cancelled/ended
        isActive: false,
        updatedAt: now,
      });

      // 5. Free the unit
      transaction.update(unitRef, {
        status: 'available',
        tenantId: null,
        tenantName: null,
        moveOutDate: moveOutTimestamp,
        updatedAt: now,
        updatedBy: userId,
      });

      // 6. Update tenant - clear unit assignment
      transaction.update(tenantRef, {
        unitNumber: '',
        isActive: false,
        updatedAt: now,
      });

    // 7. Create ledger entries for move-out charges if any
      if (moveOutCharges && moveOutCharges > 0) {
        const ledgerRef = admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('ledgers')
          .doc();
        
        transaction.set(ledgerRef, {
          tenantId: tenantId,
          facilityId: facilityId,
          type: 'moveOutFee',
          amount: moveOutCharges,
          description: 'Move-out charges',
          referenceId: contractId,
          entryDate: moveOutTimestamp,
          status: 'posted',
          createdAt: now,
          createdBy: userId,
          metadata: {
            moveOutDate: moveOutDate,
          },
        });
      }

    // 8. Create refund ledger entry if applicable
      if (moveOutRefund && moveOutRefund > 0) {
        const refundLedgerRef = admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('ledgers')
          .doc();
        
        transaction.set(refundLedgerRef, {
          tenantId: tenantId,
          facilityId: facilityId,
          type: 'refund',
          amount: -moveOutRefund, // Negative for refunds
          description: 'Move-out refund',
          referenceId: contractId,
          entryDate: moveOutTimestamp,
          status: 'posted',
          createdAt: now,
          createdBy: userId,
          metadata: {
            moveOutDate: moveOutDate,
            refundMethod: refundMethod || 'manual',
          },
        });
      }

      return {
        success: true,
        contractId,
        unitId,
        tenantId,
      };
    });

    // 9. Process refund via Stripe if requested
    let refundResult = null;
    if (processRefund && moveOutRefund && moveOutRefund > 0 && refundMethod === 'creditCard') {
      try {
        // Note: We can't directly call another Cloud Function, so we'll process it here
        // or the client can call processRefund separately after move-out completes
        functions.logger.info(`Move-out refund should be processed separately: $${moveOutRefund}`, {
          facilityId,
          tenantId,
          amount: moveOutRefund,
          refundMethod: 'creditCard',
          referenceId: data.refundReferenceId,
        });
      } catch (refundError: any) {
        functions.logger.error('Error processing move-out refund:', refundError);
        // Don't fail move-out if refund fails - it can be processed manually
      }
    }

    // 10. Send move-out confirmation email (async, don't wait)
    try {
      const tenantData = (await admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .doc(tenantId)
        .get()).data();

      if (tenantData?.email) {
        initializeSendGrid();
        await sgMail.send({
          to: tenantData.email,
          from: {
            email: SENDGRID_FROM_EMAIL.value(),
            name: SENDGRID_FROM_NAME.value(),
          },
          subject: `Move-Out Confirmation - ${facilityData?.name || 'Storage Facility'}`,
          html: `
            <h2>Move-Out Confirmation</h2>
            <p>Dear ${tenantData.name || 'Tenant'},</p>
            <p>This confirms that your move-out has been processed on ${new Date(moveOutDate).toLocaleDateString()}.</p>
            ${moveOutCharges > 0 ? `<p><strong>Final Charges:</strong> $${moveOutCharges.toFixed(2)}</p>` : ''}
            ${moveOutRefund > 0 ? `<p><strong>Refund Amount:</strong> $${moveOutRefund.toFixed(2)}</p>` : ''}
            ${moveOutNotes ? `<p><strong>Notes:</strong> ${moveOutNotes}</p>` : ''}
            <p>Thank you for your business.</p>
          `,
        });
      }
    } catch (emailError: any) {
      functions.logger.error('Error sending move-out confirmation email:', emailError);
      // Don't fail move-out if email fails
    }

    return {
      ...result,
      success: true,
      refundProcessed: (refundResult as any)?.success || false,
    };
  } catch (error: any) {
    functions.logger.error('Error processing move-out:', error);
    await writeAuditLog(data?.facilityId, {
      action: 'moveout_failed',
      userId: userId,
      tenantId: data?.tenantId,
      error: error?.message || 'unknown',
    });
    throw new functions.https.HttpsError('internal', `Failed to process move-out: ${error.message}`);
  }
});

/**
 * Complete public move-in flow (no auth)
 * - Validates reservation token
 * - Creates tenant and contract
 * - Creates ledger entries for move-in charges
 * - Verifies payment intent (optional) and logs payment
 * - Updates unit status and reservation status
 * - Generates gate access code
 */
export const completePublicMoveIn = functions.https.onCall(async (data: any) => {
  // App Check enforced for public move-in flows
  if (!(data as any)?._appCheckToken) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'App Check token required. Please refresh and try again.'
    );
  }
  const {
    reservationId,
    token,
    name,
    email,
    phone,
    address,
    emergencyContactName,
    emergencyContactPhone,
    paymentIntentId,
    totalAmount,
    lineItems = [],
    skipPayment = false,
  } = data || {};

  if (!reservationId || !token || !name || !email || !phone) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required fields');
  }

  const reservationRef = admin.firestore().collection('publicReservations').doc(reservationId);
  const reservationSnap = await reservationRef.get();

  if (!reservationSnap.exists) {
    throw new functions.https.HttpsError('not-found', 'Reservation not found');
  }

  const reservation = reservationSnap.data() as Record<string, any>;

  if (reservation.moveInToken !== token) {
    throw new functions.https.HttpsError('permission-denied', 'Invalid token');
  }

  if (reservation.status !== 'pending' && reservation.status !== 'confirmed') {
    throw new functions.https.HttpsError('failed-precondition', 'Reservation is not active');
  }

  const nowTs = admin.firestore.FieldValue.serverTimestamp();
  const expiresAt = reservation.expiresAt as admin.firestore.Timestamp | undefined;
  if (expiresAt && expiresAt.toDate() < new Date()) {
    await reservationRef.update({ status: 'expired', updatedAt: nowTs });
    throw new functions.https.HttpsError('failed-precondition', 'Reservation has expired');
  }

  // Derive core context
  const facilityId = reservation.facilityId as string | undefined;
  const unitId = reservation.unitId as string | undefined;
  const unitNumber = (reservation.unitNumber as string | undefined) || 'Unassigned';
  const reservationMetadata = (reservation.metadata as Record<string, any> | undefined) || {};
  const moveInDate = (reservation.moveInDate as admin.firestore.Timestamp | undefined)?.toDate() || new Date();

  if (!facilityId) {
    throw new functions.https.HttpsError('failed-precondition', 'Reservation missing facilityId');
  }

  // Optional unit validation
  if (unitId) {
    const unitSnap = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('units')
      .doc(unitId)
      .get();

    if (!unitSnap.exists) {
      throw new functions.https.HttpsError('not-found', 'Reserved unit not found');
    }

    const unitData = unitSnap.data() as Record<string, any>;
    if (unitData.status && unitData.status !== 'available' && unitData.status !== 'reserved') {
      throw new functions.https.HttpsError('failed-precondition', 'Unit is no longer available');
    }
  }

  // Verify payment intent if provided
  if (!skipPayment && paymentIntentId && totalAmount && totalAmount > 0) {
    try {
      const stripe = getStripeClient();
      const stripeAccount = reservationMetadata.stripeConnectAccountId as string | undefined;
      const paymentIntent = await stripe.paymentIntents.retrieve(paymentIntentId, stripeAccount ? {
        stripeAccount,
      } : undefined);

      if (paymentIntent.amount_received < Math.round(totalAmount * 100)) {
        throw new functions.https.HttpsError(
          'failed-precondition',
          'Payment not completed or amount mismatch'
        );
      }

      if (paymentIntent.status !== 'succeeded' && paymentIntent.status !== 'requires_capture') {
        throw new functions.https.HttpsError(
          'failed-precondition',
          `Payment intent not successful: ${paymentIntent.status}`
        );
      }
    } catch (err: any) {
      functions.logger.error('Payment intent validation failed', {
        error: err?.message,
        paymentIntentId,
      });
      throw err instanceof functions.https.HttpsError
        ? err
        : new functions.https.HttpsError('internal', 'Failed to validate payment intent');
    }
  }

  // Helper to derive monthly rate from reservation metadata or line items
  const deriveMonthlyRate = (): number => {
    if (reservationMetadata.monthlyRate) return Number(reservationMetadata.monthlyRate);
    const rentItem = (lineItems as any[]).find(
      (item) => item?.type === 'rent' || item?.type === 'proratedRent'
    );
    if (rentItem?.amount) return Number(rentItem.amount);
    return 0;
  };

  // Perform transactional writes for tenant/contract/unit/reservation/charges
  const transactionResult = await admin.firestore().runTransaction(async (tx) => {
    // Re-check reservation inside transaction
    const freshReservation = await tx.get(reservationRef);
    if (!freshReservation.exists) {
      throw new functions.https.HttpsError('not-found', 'Reservation not found');
    }
    const freshData = freshReservation.data() as Record<string, any>;
    if (freshData.moveInToken !== token) {
      throw new functions.https.HttpsError('permission-denied', 'Invalid token');
    }
    if (freshData.status !== 'pending' && freshData.status !== 'confirmed') {
      throw new functions.https.HttpsError('failed-precondition', 'Reservation is not active');
    }

    // Create tenant
    const tenantRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc();

    const tenantData = {
      facilityId,
      name: name.trim(),
      nameLower: name.trim().toLowerCase(),
      email: email.trim(),
      emailLower: email.trim().toLowerCase(),
      phone: phone.trim(),
      phoneDigits: phone.replace(/[^\d]/g, ''),
      unitNumber,
      monthlyRate: deriveMonthlyRate(),
      notes: '',
      createdAt: nowTs,
      createdBy: 'publicMoveIn',
      isActive: true,
      isOnDNR: false,
      emergencyContacts: emergencyContactName
        ? [{
            name: emergencyContactName,
            phone: emergencyContactPhone || '',
          }]
        : [],
      addresses: address
        ? [{
            street1: address,
            street2: '',
            city: '',
            state: '',
            postalCode: '',
            country: '',
            type: 'mailing',
          }]
        : [],
      portalEnabled: false,
      portalAccessCode: null,
      portalWelcomeMessage: null,
      portalLastAccessAt: null,
      portalVisitCount: 0,
    };

    tx.set(tenantRef, tenantData);

    // Create contract (minimal signed agreement record)
    const facilitySnap = await tx.get(admin.firestore().collection('facilities').doc(facilityId));
    const facilityOwnerUid = (facilitySnap.data() as Record<string, any> | undefined)?.ownerUid || 'publicMoveIn';

    const contractRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('contracts')
      .doc();

    tx.set(contractRef, {
      facilityId,
      facilityOwnerUid,
      tenantId: tenantRef.id,
      title: 'Storage Rental Agreement',
      description: 'Online self-service move-in',
      type: 'storage',
      status: 'signed',
      templateId: null,
      fileUrl: null,
      signedFileUrl: null,
      createdAt: nowTs,
      updatedAt: nowTs,
      createdBy: 'publicMoveIn',
      sentAt: nowTs,
      signedAt: nowTs,
      expiresAt: null,
      sentBy: 'publicMoveIn',
      signedBy: 'publicMoveIn',
      customFields: null,
      notes: null,
      isActive: true,
    });

    // Ledger entries for charges
    (lineItems as any[]).forEach((item) => {
      const ledgerRef = admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('ledgers')
        .doc();

      tx.set(ledgerRef, {
        tenantId: tenantRef.id,
        facilityId,
        type: item?.type || 'moveInCharge',
        amount: Number(item?.amount || 0),
        description: item?.description || 'Move-in charge',
        referenceId: contractRef.id,
        entryDate: moveInDate,
        dueDate: item?.dueDate ? new Date(item.dueDate) : null,
        status: 'posted',
        createdAt: nowTs,
        createdBy: 'publicMoveIn',
        metadata: {
          lineItemId: item?.id || null,
          isProrated: item?.isProrated ?? false,
        },
      });
    });

    // Update unit status
    if (unitId) {
      const unitRef = admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('units')
        .doc(unitId);

      tx.update(unitRef, {
        status: 'occupied',
        tenantId: tenantRef.id,
        tenantName: name,
        moveInDate: moveInDate,
        updatedAt: nowTs,
        updatedBy: 'publicMoveIn',
      });
    }

    // Update reservation status
    tx.update(reservationRef, {
      status: 'completed',
      completedAt: nowTs,
      updatedAt: nowTs,
      tenantId: tenantRef.id,
      contractId: contractRef.id,
      completedBy: 'publicMoveIn',
    });

    return {
      tenantId: tenantRef.id,
      contractId: contractRef.id,
    };
  });

  const { tenantId, contractId } = transactionResult;

  // Create payment ledger entry (outside transaction to avoid blocking)
  if (!skipPayment && paymentIntentId && totalAmount && totalAmount > 0) {
    const ledgerRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('ledgers')
      .doc();

    await ledgerRef.set({
      tenantId,
      facilityId,
      type: 'payment',
      amount: -Number(totalAmount),
      description: 'Move-in payment',
      referenceId: paymentIntentId,
      entryDate: new Date(),
      status: 'posted',
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      createdBy: 'publicMoveIn',
      metadata: {
        paymentIntentId,
      },
    });
  }

  // Create gate access code
  let gateAccessCode: string | null = null;
  try {
    gateAccessCode = generateAccessCode();
    const gateRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('gateAccess')
      .doc();

    await gateRef.set({
      facilityId,
      tenantId,
      tenantName: name,
      accessCode: gateAccessCode,
      isActive: true,
      validFrom: null,
      validUntil: null,
      allowedDays: [],
      allowedStartTime: null,
      allowedEndTime: null,
      notes: 'Auto-generated from public move-in',
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      createdBy: 'publicMoveIn',
    });
  } catch (gateError: any) {
    functions.logger.error('Failed to create gate access', { error: gateError?.message });
  }

  functions.logger.info('Public move-in completed', {
    reservationId,
    facilityId,
    tenantId,
    contractId,
    paymentIntentId,
  });

  return {
    success: true,
    tenantId,
    contractId,
    gateAccessCode,
    reservationId,
  };
});

export const processAutopayPayments = functions.pubsub
  .schedule('0 2 * * *') // Daily at 2:00 AM UTC
  .timeZone('UTC')
  .onRun(async (context) => {
    try {
      functions.logger.info('Starting scheduled autopay processing');

      // Get all facilities
      const facilitiesSnapshot = await admin.firestore()
        .collection('facilities')
        .where('active', '==', true)
        .get();

      functions.logger.info(`Found ${facilitiesSnapshot.size} active facilities`);

      const results = [];

      for (const facilityDoc of facilitiesSnapshot.docs) {
        const facilityId = facilityDoc.id;
        try {
          // Get all tenants with autopay enabled
          const tenantsSnapshot = await admin.firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('tenants')
            .where('isActive', '==', true)
            .get();

          for (const tenantDoc of tenantsSnapshot.docs) {
            try {
              const tenantData = tenantDoc.data();
              const tenantId = tenantDoc.id;

              // Get payment methods for this tenant
              const paymentMethodsSnapshot = await admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('paymentMethods')
                .where('tenantId', '==', tenantId)
                .where('autopayEnabled', '==', true)
                .where('isActive', '==', true)
                .get();

              for (const methodDoc of paymentMethodsSnapshot.docs) {
                try {
                  const methodData = methodDoc.data();
                  const autopaySchedule = methodData.autopaySchedule;
                  
                  if (!autopaySchedule) continue;

                  const nextRun = autopaySchedule.autopayNextRun?.toDate();
                  const now = new Date();

                  // Check if autopay is due
                  if (nextRun && now >= nextRun) {
                    // Get ledger balance
                    const ledgerSnapshot = await admin.firestore()
                      .collection('facilities')
                      .doc(facilityId)
                      .collection('ledgers')
                      .where('tenantId', '==', tenantId)
                      .where('status', '==', 'posted')
                      .get();

                    let balance = 0;
                    for (const entryDoc of ledgerSnapshot.docs) {
                      const entryData = entryDoc.data();
                      balance += entryData.amount || 0;
                    }

                    // Calculate amount to charge
                    let amount = balance;
                    if (autopaySchedule.amount && autopaySchedule.amount > 0) {
                      amount = autopaySchedule.amount;
                    }

                    // Add insurance if configured
                    if (autopaySchedule.includeInsurance) {
                      const facilityData = facilityDoc.data();
                      const defaultInsurance = facilityData?.billingSettings?.['defaultInsuranceAmount'];
                      if (defaultInsurance) {
                        amount += defaultInsurance;
                      }
                    }

                    if (amount > 0 && methodData.stripePaymentMethodId) {
                      // Process payment via Stripe
                      const stripe = getStripeClient();
                      
                      const paymentIntent = await stripe.paymentIntents.create({
                        amount: Math.round(amount * 100),
                        currency: 'usd',
                        payment_method: methodData.stripePaymentMethodId,
                        customer: methodData.stripeCustomerId,
                        confirmation_method: 'automatic',
                        confirm: true,
                        description: `Autopay - ${tenantData.name}`,
                        metadata: {
                          facilityId,
                          tenantId,
                          paymentMethodId: methodDoc.id,
                          autopay: 'true',
                        },
                      });

                      if (paymentIntent.status === 'succeeded') {
                        // Create payment ledger entry
                        const paymentEntryRef = admin.firestore()
                          .collection('facilities')
                          .doc(facilityId)
                          .collection('ledgers')
                          .doc();

                        await paymentEntryRef.set({
                          tenantId: tenantId,
                          facilityId: facilityId,
                          type: 'payment',
                          amount: -amount,
                          description: `Autopay Payment - ${paymentIntent.id}`,
                          referenceId: paymentIntent.id,
                          entryDate: admin.firestore.FieldValue.serverTimestamp(),
                          status: 'posted',
                          metadata: {
                            paymentMethod: 'stripe',
                            autopay: true,
                            paymentIntentId: paymentIntent.id,
                          },
                          createdAt: admin.firestore.FieldValue.serverTimestamp(),
                          createdBy: 'system',
                        });

                        // Update payment method last run
                        await methodDoc.ref.update({
                          'autopayLastRun': admin.firestore.FieldValue.serverTimestamp(),
                          'autopayLastResult': 'success',
                          'autopayNextRun': _calculateNextAutopayRun(autopaySchedule),
                        });

                        // Audit log
                        await admin.firestore()
                          .collection('facilities')
                          .doc(facilityId)
                          .collection('auditLogs')
                          .add({
                            action: 'autopay.processed',
                            actorUid: 'system',
                            actorEmail: 'system@scheduled-job',
                            targetId: paymentEntryRef.id,
                            entityType: 'payment',
                            entityId: paymentEntryRef.id,
                            tenantId: tenantId,
                            details: {
                              amount: amount,
                              paymentIntentId: paymentIntent.id,
                              scheduled: true,
                            },
                            at: admin.firestore.FieldValue.serverTimestamp(),
                          });

                        results.push({
                          facilityId,
                          tenantId,
                          success: true,
                          amount,
                        });

                        functions.logger.info(`Autopay processed: ${tenantData.name} - $${amount}`);
                      }
                    }
                  }
                } catch (error: any) {
                  functions.logger.error(`Error processing autopay for payment method ${methodDoc.id}:`, error);
                  // Update payment method with error
                  await methodDoc.ref.update({
                    'autopayLastRun': admin.firestore.FieldValue.serverTimestamp(),
                    'autopayLastResult': 'failed',
                    'autopayLastError': error.message,
                  });
                }
              }
            } catch (error: any) {
              functions.logger.error(`Error processing autopay for tenant ${tenantDoc.id}:`, error);
            }
          }
        } catch (error: any) {
          functions.logger.error(`Error processing facility ${facilityId}:`, error);
        }
      }

      functions.logger.info(`Scheduled autopay processing completed: ${results.length} payments processed`);
      return { results };
    } catch (error: any) {
      functions.logger.error('Error in scheduled autopay processing:', error);
      throw error;
    }
  });

function _calculateNextAutopayRun(schedule: any): admin.firestore.Timestamp {
  const now = new Date();
  const frequency = schedule.frequency || 'monthly';
  const dayOfMonth = schedule.dayOfMonth || 1;

  if (frequency === 'monthly') {
    const nextMonth = new Date(now.getFullYear(), now.getMonth() + 1, dayOfMonth);
    return admin.firestore.Timestamp.fromDate(nextMonth);
  } else if (frequency === 'weekly') {
    const dayOfWeek = schedule.dayOfWeek || 1;
    const daysUntilNext = (dayOfWeek - now.getDay()) % 7;
    const nextRun = new Date(now);
    nextRun.setDate(nextRun.getDate() + (daysUntilNext === 0 ? 7 : daysUntilNext));
    return admin.firestore.Timestamp.fromDate(nextRun);
  }

  // Default to next month
  return admin.firestore.Timestamp.fromDate(new Date(now.getFullYear(), now.getMonth() + 1, 1));
}

/**
 * Scheduled function: Reset monthly SMS usage counters at UTC month rollover
 * Runs at 00:00 UTC on the 1st of each month
 */
export const resetMonthlySMSUsage = functions.pubsub.schedule('0 0 1 * *').timeZone('UTC').onRun(async (context) => {
  try {
    functions.logger.info('Starting monthly SMS usage reset...');

    const now = new Date();
    const currentMonthKey = `${now.getFullYear()}-${(now.getMonth() + 1).toString().padStart(2, '0')}`;

    // Reset facility usage
    const facilitiesSnapshot = await admin.firestore().collection('facilities').get();
    const facilityResets = facilitiesSnapshot.docs.map(async (facilityDoc) => {
      const usageRef = facilityDoc.ref.collection('smsUsage').doc(currentMonthKey);
      await usageRef.set({
        smsMonthlyCount: 0,
        smsMonthlyLimit: capSmsLimit(SMS_LIMIT_PER_FACILITY),
        smsMonth: currentMonthKey,
        lastReset: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    });

    // Reset account usage
    const accountsSnapshot = await admin.firestore().collection('facilityCreatorAccounts').get();
    const accountResets = accountsSnapshot.docs.map(async (accountDoc) => {
      const usageRef = accountDoc.ref.collection('smsUsage').doc(currentMonthKey);
      await usageRef.set({
        smsMonthlyCount: 0,
        smsMonthlyLimit: capSmsLimit(SMS_LIMIT_PER_ACCOUNT),
        smsMonth: currentMonthKey,
        lastReset: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    });

    await Promise.all([...facilityResets, ...accountResets]);

    functions.logger.info(`Monthly SMS usage reset completed for ${facilitiesSnapshot.size} facilities and ${accountsSnapshot.size} accounts`);
    return null;
  } catch (error: any) {
    functions.logger.error('Error resetting monthly SMS usage', error);
    throw error;
  }
});

/**
 * Scheduled function: Auto-Protect Move-In
 * Runs daily to check new move-ins and auto-enroll tenants in TPP after 14 days if no insurance proof
 * Scheduled to run at 4:00 AM UTC daily
 */
export const autoProtectMoveIn = functions.pubsub
  .schedule('0 4 * * *') // Daily at 4:00 AM UTC
  .timeZone('UTC')
  .onRun(async (context) => {
    functions.logger.info('🔄 Starting Auto-Protect Move-In processing...');

    try {
      initializeSendGrid();

      // Get all active facilities
      const facilitiesSnapshot = await admin.firestore()
        .collection('facilities')
        .where('active', '==', true)
        .get();

      if (facilitiesSnapshot.empty) {
        functions.logger.info('No active facilities found');
        return null;
      }

      let totalProcessed = 0;
      let totalEnrolled = 0;
      const fourteenDaysAgo = new Date();
      fourteenDaysAgo.setDate(fourteenDaysAgo.getDate() - 14);

      for (const facilityDoc of facilitiesSnapshot.docs) {
        const facilityId = facilityDoc.id;
        const facilityData = facilityDoc.data();

        try {
          // Check if Auto-Protect Move-In is enabled for this facility
          const autoProtectEnabled = facilityData?.insuranceSettings?.autoProtectMoveIn;
          if (!autoProtectEnabled) {
            functions.logger.info(`Auto-Protect Move-In disabled for facility ${facilityId}`);
            continue;
          }

          // Get default TPP settings
          const defaultCoverage = facilityData?.insuranceSettings?.defaultCoverageLevel || 'minimum';
          const defaultCoverageAmount = facilityData?.insuranceSettings?.defaultCoverageAmount || 5000;
          const monthlyFee = facilityData?.insuranceSettings?.defaultMonthlyFee || 15;

          // Get all tenants created around 14 days ago (within a 2-day window)
          const startDate = new Date(fourteenDaysAgo);
          startDate.setHours(0, 0, 0, 0);
          const endDate = new Date(fourteenDaysAgo);
          endDate.setDate(endDate.getDate() + 1);
          endDate.setHours(23, 59, 59, 999);

          const tenantsSnapshot = await admin.firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('tenants')
            .where('isActive', '==', true)
            .where('createdAt', '>=', admin.firestore.Timestamp.fromDate(startDate))
            .where('createdAt', '<=', admin.firestore.Timestamp.fromDate(endDate))
            .get();

          for (const tenantDoc of tenantsSnapshot.docs) {
            try {
              const tenantData = tenantDoc.data();
              const tenantId = tenantDoc.id;

              // Check insurance status - only enroll if status is 'none' or 'pendingProof'
              const insuranceStatus = tenantData.insuranceStatus;
              if (insuranceStatus !== 'none' && insuranceStatus !== 'pendingProof') {
                continue; // Tenant already has insurance or is enrolled
              }

              totalProcessed++;

              // Auto-enroll in TPP
              await tenantDoc.ref.update({
                insuranceStatus: 'autoEnrolled',
                tppEnrollmentDate: admin.firestore.FieldValue.serverTimestamp(),
                tppCoverageLevel: defaultCoverage,
                coverageAmount: defaultCoverageAmount,
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
              });

              // Create ledger entry for TPP fee (prorated for remaining days in month)
              const now = new Date();
              const daysInMonth = new Date(now.getFullYear(), now.getMonth() + 1, 0).getDate();
              const remainingDays = daysInMonth - now.getDate() + 1;
              const proratedFee = (monthlyFee / daysInMonth) * remainingDays;

              await admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('ledgers')
                .add({
                  tenantId: tenantId,
                  facilityId: facilityId,
                  type: 'insuranceCharge',
                  amount: proratedFee,
                  description: `Tenant Protection Plan (Auto-Enrolled) - Prorated for ${remainingDays} days`,
                  entryDate: admin.firestore.FieldValue.serverTimestamp(),
                  status: 'posted',
                  metadata: {
                    tppEnrollment: true,
                    autoEnrolled: true,
                    coverageLevel: defaultCoverage,
                    proratedDays: remainingDays,
                  },
                  createdAt: admin.firestore.FieldValue.serverTimestamp(),
                  createdBy: 'system',
                });

              totalEnrolled++;

              // Send email notification to tenant
              try {
                const emailHtml = `
                  <h2>Tenant Protection Plan Enrollment</h2>
                  <p>Dear ${tenantData.name},</p>
                  <p>You have been automatically enrolled in our Tenant Protection Plan (TPP) as you have not provided proof of your own insurance coverage within the 14-day grace period.</p>
                  <p><strong>Coverage Details:</strong></p>
                  <ul>
                    <li>Coverage Amount: $${defaultCoverageAmount.toFixed(2)}</li>
                    <li>Monthly Fee: $${monthlyFee.toFixed(2)}</li>
                    <li>Prorated Fee (this month): $${proratedFee.toFixed(2)}</li>
                  </ul>
                  <p>If you have your own insurance policy, please provide proof to our facility manager to have this enrollment removed.</p>
                  <p>Thank you,<br>${facilityData.name || 'Storage Facility'}</p>
                `;

                await sgMail.send({
                  to: tenantData.email,
                  from: {
                    email: SENDGRID_FROM_EMAIL.value(),
                    name: SENDGRID_FROM_NAME.value(),
                  },
                  subject: 'Tenant Protection Plan Enrollment Notification',
                  html: emailHtml,
                });

                functions.logger.info(`Auto-enrollment email sent to ${tenantData.email}`);
              } catch (emailError: any) {
                functions.logger.error(`Error sending auto-enrollment email: ${emailError.message}`);
              }

              functions.logger.info(`Auto-enrolled tenant ${tenantId} in TPP`);
            } catch (error: any) {
              functions.logger.error(`Error processing tenant ${tenantDoc.id}:`, error);
            }
          }
        } catch (error: any) {
          functions.logger.error(`Error processing facility ${facilityId}:`, error);
        }
      }

      functions.logger.info('✅ Auto-Protect Move-In complete:', {
        totalProcessed,
        totalEnrolled,
      });

      return null;
    } catch (error: any) {
      functions.logger.error('❌ Fatal error in Auto-Protect Move-In:', error);
      throw error;
    }
  });

/**
 * Scheduled function: Auto-Protect Audit
 * Runs monthly to audit existing tenants and notify/enroll them in TPP if no insurance
 * Scheduled to run on the 1st of each month at 5:00 AM UTC
 */
export const autoProtectAudit = functions.pubsub
  .schedule('0 5 1 * *') // 1st of each month at 5:00 AM UTC
  .timeZone('UTC')
  .onRun(async (context) => {
    functions.logger.info('🔄 Starting Auto-Protect Audit processing...');

    try {
      initializeSendGrid();

      // Get all active facilities
      const facilitiesSnapshot = await admin.firestore()
        .collection('facilities')
        .where('active', '==', true)
        .get();

      if (facilitiesSnapshot.empty) {
        functions.logger.info('No active facilities found');
        return null;
      }

      let totalNotified = 0;
      let totalEnrolled = 0;

      for (const facilityDoc of facilitiesSnapshot.docs) {
        const facilityId = facilityDoc.id;
        const facilityData = facilityDoc.data();

        try {
          // Check if Auto-Protect Audit is enabled
          const autoProtectAuditEnabled = facilityData?.insuranceSettings?.autoProtectAudit;
          if (!autoProtectAuditEnabled) {
            functions.logger.info(`Auto-Protect Audit disabled for facility ${facilityId}`);
            continue;
          }

          const defaultCoverage = facilityData?.insuranceSettings?.defaultCoverageLevel || 'minimum';
          const defaultCoverageAmount = facilityData?.insuranceSettings?.defaultCoverageAmount || 5000;
          const monthlyFee = facilityData?.insuranceSettings?.defaultMonthlyFee || 15;
          const gracePeriodDays = facilityData?.insuranceSettings?.auditGracePeriodDays || 45;

          // Get tenants with no insurance or pending proof
          const tenantsSnapshot = await admin.firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('tenants')
            .where('isActive', '==', true)
            .where('insuranceStatus', 'in', ['none', 'pendingProof'])
            .get();

          const now = new Date();

          for (const tenantDoc of tenantsSnapshot.docs) {
            try {
              const tenantData = tenantDoc.data();
              const tenantId = tenantDoc.id;
              const insuranceNotifiedDate = tenantData.insuranceNotifiedDate?.toDate();

              if (!insuranceNotifiedDate) {
                // First notification
                await tenantDoc.ref.update({
                  insuranceNotifiedDate: admin.firestore.FieldValue.serverTimestamp(),
                  updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                });

                // Send first notification email
                try {
                  const emailHtml = `
                    <h2>Insurance Requirement Notice</h2>
                    <p>Dear ${tenantData.name},</p>
                    <p>Our facility now requires all tenants to have insurance coverage for their stored items. You currently do not have proof of insurance on file.</p>
                    <p>You have ${gracePeriodDays} days to provide proof of your own insurance policy. If proof is not provided by ${new Date(now.getTime() + gracePeriodDays * 24 * 60 * 60 * 1000).toLocaleDateString()}, you will be automatically enrolled in our Tenant Protection Plan.</p>
                    <p>Please contact our facility manager to provide your insurance documentation.</p>
                    <p>Thank you,<br>${facilityData.name || 'Storage Facility'}</p>
                  `;

                  await sgMail.send({
                    to: tenantData.email,
                    from: {
                      email: SENDGRID_FROM_EMAIL.value(),
                      name: SENDGRID_FROM_NAME.value(),
                    },
                    subject: 'Insurance Requirement Notice',
                    html: emailHtml,
                  });

                  totalNotified++;
                  functions.logger.info(`First notification sent to ${tenantData.email}`);
                } catch (emailError: any) {
                  functions.logger.error(`Error sending first notification: ${emailError.message}`);
                }
              } else {
                // Check if grace period has passed
                const daysSinceNotification = Math.floor((now.getTime() - insuranceNotifiedDate.getTime()) / (1000 * 60 * 60 * 24));

                if (daysSinceNotification >= gracePeriodDays && tenantData.insuranceStatus !== 'enrolledInTPP' && tenantData.insuranceStatus !== 'autoEnrolled') {
                  // Grace period expired - auto-enroll
                  await tenantDoc.ref.update({
                    insuranceStatus: 'autoEnrolled',
                    tppEnrollmentDate: admin.firestore.FieldValue.serverTimestamp(),
                    tppCoverageLevel: defaultCoverage,
                    coverageAmount: defaultCoverageAmount,
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                  });

                  // Create ledger entry for TPP fee
                  await admin.firestore()
                    .collection('facilities')
                    .doc(facilityId)
                    .collection('ledgers')
                    .add({
                      tenantId: tenantId,
                      facilityId: facilityId,
                      type: 'insuranceCharge',
                      amount: monthlyFee,
                      description: `Tenant Protection Plan (Auto-Enrolled)`,
                      entryDate: admin.firestore.FieldValue.serverTimestamp(),
                      status: 'posted',
                      metadata: {
                        tppEnrollment: true,
                        autoEnrolled: true,
                        coverageLevel: defaultCoverage,
                      },
                      createdAt: admin.firestore.FieldValue.serverTimestamp(),
                      createdBy: 'system',
                    });

                  totalEnrolled++;

                  // Send enrollment notification
                  try {
                    const emailHtml = `
                      <h2>Tenant Protection Plan Auto-Enrollment</h2>
                      <p>Dear ${tenantData.name},</p>
                      <p>You have been automatically enrolled in our Tenant Protection Plan as proof of insurance was not provided within the ${gracePeriodDays}-day grace period.</p>
                      <p><strong>Coverage Details:</strong></p>
                      <ul>
                        <li>Coverage Amount: $${defaultCoverageAmount.toFixed(2)}</li>
                        <li>Monthly Fee: $${monthlyFee.toFixed(2)}</li>
                      </ul>
                      <p>If you have your own insurance policy, please provide proof to have this enrollment removed.</p>
                      <p>Thank you,<br>${facilityData.name || 'Storage Facility'}</p>
                    `;

                    await sgMail.send({
                      to: tenantData.email,
                      from: {
                        email: SENDGRID_FROM_EMAIL.value(),
                        name: SENDGRID_FROM_NAME.value(),
                      },
                      subject: 'Tenant Protection Plan Auto-Enrollment',
                      html: emailHtml,
                    });

                    functions.logger.info(`Auto-enrollment email sent to ${tenantData.email}`);
                  } catch (emailError: any) {
                    functions.logger.error(`Error sending auto-enrollment email: ${emailError.message}`);
                  }
                }
              }
            } catch (error: any) {
              functions.logger.error(`Error processing tenant ${tenantDoc.id}:`, error);
            }
          }
        } catch (error: any) {
          functions.logger.error(`Error processing facility ${facilityId}:`, error);
        }
      }

      functions.logger.info('✅ Auto-Protect Audit complete:', {
        totalNotified,
        totalEnrolled,
      });

      return null;
    } catch (error: any) {
      functions.logger.error('❌ Fatal error in Auto-Protect Audit:', error);
      throw error;
    }
  });

/**
 * Scheduled function: Check Insurance Compliance (daily)
 * Runs daily to check if tenants who were notified have passed the grace period
 * Scheduled to run at 4:30 AM UTC daily (after Auto-Protect Move-In)
 */
export const checkInsuranceCompliance = functions.pubsub
  .schedule('30 4 * * *') // Daily at 4:30 AM UTC
  .timeZone('UTC')
  .onRun(async (context) => {
    functions.logger.info('🔄 Starting Insurance Compliance check...');

    try {
      initializeSendGrid();

      const facilitiesSnapshot = await admin.firestore()
        .collection('facilities')
        .where('active', '==', true)
        .get();

      if (facilitiesSnapshot.empty) {
        return null;
      }

      let totalEnrolled = 0;
      const now = new Date();

      for (const facilityDoc of facilitiesSnapshot.docs) {
        const facilityId = facilityDoc.id;
        const facilityData = facilityDoc.data();

        const autoProtectAuditEnabled = facilityData?.insuranceSettings?.autoProtectAudit;
        if (!autoProtectAuditEnabled) continue;

        const gracePeriodDays = facilityData?.insuranceSettings?.auditGracePeriodDays || 45;
        const defaultCoverage = facilityData?.insuranceSettings?.defaultCoverageLevel || 'minimum';
        const defaultCoverageAmount = facilityData?.insuranceSettings?.defaultCoverageAmount || 5000;
        const monthlyFee = facilityData?.insuranceSettings?.defaultMonthlyFee || 15;

        const cutoffDate = new Date(now);
        cutoffDate.setDate(cutoffDate.getDate() - gracePeriodDays);

        const tenantsSnapshot = await admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .where('isActive', '==', true)
          .where('insuranceNotifiedDate', '<=', admin.firestore.Timestamp.fromDate(cutoffDate))
          .where('insuranceStatus', 'in', ['none', 'pendingProof'])
          .get();

        for (const tenantDoc of tenantsSnapshot.docs) {
          try {
            const tenantData = tenantDoc.data();
            const tenantId = tenantDoc.id;

            // Auto-enroll
            await tenantDoc.ref.update({
              insuranceStatus: 'autoEnrolled',
              tppEnrollmentDate: admin.firestore.FieldValue.serverTimestamp(),
              tppCoverageLevel: defaultCoverage,
              coverageAmount: defaultCoverageAmount,
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });

            await admin.firestore()
              .collection('facilities')
              .doc(facilityId)
              .collection('ledgers')
              .add({
                tenantId: tenantId,
                facilityId: facilityId,
                type: 'insuranceCharge',
                amount: monthlyFee,
                description: `Tenant Protection Plan (Auto-Enrolled)`,
                entryDate: admin.firestore.FieldValue.serverTimestamp(),
                status: 'posted',
                metadata: {
                  tppEnrollment: true,
                  autoEnrolled: true,
                  coverageLevel: defaultCoverage,
                },
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
                createdBy: 'system',
              });

            totalEnrolled++;

            // Send enrollment email (same as in autoProtectAudit)
            try {
              const emailHtml = `
                <h2>Tenant Protection Plan Auto-Enrollment</h2>
                <p>Dear ${tenantData.name},</p>
                <p>You have been automatically enrolled in our Tenant Protection Plan as proof of insurance was not provided within the ${gracePeriodDays}-day grace period.</p>
                <p><strong>Coverage Details:</strong></p>
                <ul>
                  <li>Coverage Amount: $${defaultCoverageAmount.toFixed(2)}</li>
                  <li>Monthly Fee: $${monthlyFee.toFixed(2)}</li>
                </ul>
                <p>Thank you,<br>${facilityData.name || 'Storage Facility'}</p>
              `;

              await sgMail.send({
                to: tenantData.email,
                from: {
                  email: SENDGRID_FROM_EMAIL.value(),
                  name: SENDGRID_FROM_NAME.value(),
                },
                subject: 'Tenant Protection Plan Auto-Enrollment',
                html: emailHtml,
              });
            } catch (emailError: any) {
              functions.logger.error(`Error sending enrollment email: ${emailError.message}`);
            }
          } catch (error: any) {
            functions.logger.error(`Error processing tenant ${tenantDoc.id}:`, error);
          }
        }
      }

      functions.logger.info(`✅ Insurance Compliance check complete: ${totalEnrolled} tenants enrolled`);
      return null;
    } catch (error: any) {
      functions.logger.error('❌ Fatal error in Insurance Compliance check:', error);
      throw error;
    }
  });

/**
 * Callable function: Submit Insurance Claim
 * Allows facility staff to submit an insurance claim for a tenant
 */
export const submitClaim = functions.https.onCall(async (data: any, context) => {
  // Verify authentication
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  try {
    const {
      facilityId,
      tenantId,
      leaseId,
      incidentDate,
      claimType,
      claimAmount,
      deductibleAmount,
      description,
      managerStatement,
      tenantStatement,
      documentUrls,
      adjusterEmail,
    } = data;

    // Validate required fields
    if (!facilityId || !tenantId || !incidentDate || !claimType || !description || claimAmount === undefined || deductibleAmount === undefined) {
      throw new functions.https.HttpsError('invalid-argument', 'Missing required fields');
    }

    // Verify user has access to facility
    const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data();
    const userEmail = context.auth.token.email || '';
    const userId = context.auth.uid;

    // Check if user is owner or manager
    const isOwner = facilityData?.ownerUid === userId;
    const isManager = facilityData?.managers?.[userId] === true || facilityData?.roles?.[userId] === 'manager' || facilityData?.roles?.[userId] === 'owner';
    
    if (!isOwner && !isManager) {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission to submit claims');
    }

    // Verify tenant is enrolled in TPP
    const tenantDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId)
      .get();

    if (!tenantDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Tenant not found');
    }

    const tenantData = tenantDoc.data();
    const insuranceStatus = tenantData?.insuranceStatus;
    
    if (insuranceStatus !== 'enrolledInTPP' && insuranceStatus !== 'autoEnrolled') {
      throw new functions.https.HttpsError('failed-precondition', 'Tenant must be enrolled in TPP to file a claim');
    }

    // Create claim document
    const claimRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('claims')
      .doc();

    const claimData = {
      facilityId,
      tenantId,
      leaseId: leaseId || null,
      incidentDate: admin.firestore.Timestamp.fromDate(new Date(incidentDate)),
      claimType,
      status: 'pending',
      claimAmount: Number(claimAmount),
      deductibleAmount: Number(deductibleAmount),
      description,
      managerStatement: managerStatement || null,
      tenantStatement: tenantStatement || null,
      documentUrls: documentUrls || [],
      adjusterEmail: adjusterEmail || null,
      adjusterNotes: null,
      filedDate: admin.firestore.FieldValue.serverTimestamp(),
      resolvedDate: null,
      createdBy: userId,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    await claimRef.set(claimData);

    // Send email to adjuster (if email provided) or log for manual forwarding
    initializeSendGrid();
    const adjusterEmailToUse = adjusterEmail || facilityData?.insuranceSettings?.defaultAdjusterEmail;
    
    if (adjusterEmailToUse) {
      try {
        const emailHtml = `
          <h2>New Insurance Claim Filed</h2>
          <p><strong>Facility:</strong> ${facilityData?.name || facilityId}</p>
          <p><strong>Tenant:</strong> ${tenantData?.name || tenantId}</p>
          <p><strong>Unit:</strong> ${tenantData?.unitNumber || 'N/A'}</p>
          <p><strong>Incident Date:</strong> ${new Date(incidentDate).toLocaleDateString()}</p>
          <p><strong>Claim Type:</strong> ${claimType}</p>
          <p><strong>Claim Amount:</strong> $${Number(claimAmount).toFixed(2)}</p>
          <p><strong>Deductible:</strong> $${Number(deductibleAmount).toFixed(2)}</p>
          <p><strong>Description:</strong></p>
          <p>${description}</p>
          ${managerStatement ? `<p><strong>Manager Statement:</strong></p><p>${managerStatement}</p>` : ''}
          ${tenantStatement ? `<p><strong>Tenant Statement:</strong></p><p>${tenantStatement}</p>` : ''}
          ${documentUrls && documentUrls.length > 0 ? `<p><strong>Documents:</strong></p><ul>${documentUrls.map((url: string) => `<li><a href="${url}">${url}</a></li>`).join('')}</ul>` : ''}
          <p>Claim ID: ${claimRef.id}</p>
        `;

        await sgMail.send({
          to: adjusterEmailToUse,
          from: {
            email: SENDGRID_FROM_EMAIL.value(),
            name: SENDGRID_FROM_NAME.value(),
          },
          subject: `New Insurance Claim - ${facilityData?.name || 'Storage Facility'}`,
          html: emailHtml,
        });

        functions.logger.info(`Claim notification email sent to ${adjusterEmailToUse}`);
      } catch (emailError: any) {
        functions.logger.error(`Error sending claim email: ${emailError.message}`);
        // Don't fail the claim submission if email fails
      }
    }

    // Audit log
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('auditLogs')
      .add({
        action: 'claim.submitted',
        actorUid: userId,
        actorEmail: userEmail,
        targetId: claimRef.id,
        entityType: 'claim',
        entityId: claimRef.id,
        tenantId: tenantId,
        details: {
          claimType,
          claimAmount,
          incidentDate,
        },
        at: admin.firestore.FieldValue.serverTimestamp(),
      });

    return {
      success: true,
      claimId: claimRef.id,
      message: 'Claim submitted successfully',
    };
  } catch (error: any) {
    functions.logger.error('Error submitting claim:', error);
    if (error instanceof functions.https.HttpsError) {
      throw error;
    }
    throw new functions.https.HttpsError('internal', `Failed to submit claim: ${error.message}`);
  }
});

/**
 * Scheduled function: Payment Reminders
 * Sends payment reminders to tenants 3 days before their due date
 * Runs daily at 9:00 AM UTC
 */
export const processPaymentReminders = functions.pubsub
  .schedule('0 9 * * *') // Daily at 9:00 AM UTC
  .timeZone('UTC')
  .onRun(async (context) => {
    functions.logger.info('🔄 Starting Payment Reminder processing...');

    try {
      initializeSendGrid();

      // Get all active facilities
      const facilitiesSnapshot = await admin.firestore()
        .collection('facilities')
        .where('active', '==', true)
        .get();

      if (facilitiesSnapshot.empty) {
        functions.logger.info('No active facilities found');
        return null;
      }

      let totalRemindersSent = 0;
      const now = new Date();
      const threeDaysFromNow = new Date(now);
      threeDaysFromNow.setDate(threeDaysFromNow.getDate() + 3);

      for (const facilityDoc of facilitiesSnapshot.docs) {
        const facilityId = facilityDoc.id;
        const facilityData = facilityDoc.data();

        try {
          // Check if payment reminders are enabled (default to true if not set)
          const remindersEnabled = facilityData?.billingSettings?.enablePaymentReminders !== false;

          if (!remindersEnabled) {
            functions.logger.info(`Payment reminders disabled for facility ${facilityId}`);
            continue;
          }

          // Get reminder days setting (default to 3)
          const reminderDays = facilityData?.billingSettings?.paymentReminderDays || 3;

          // Calculate target due date
          const targetDueDate = new Date(now);
          targetDueDate.setDate(targetDueDate.getDate() + reminderDays);

          // Get all active tenants
          const tenantsSnapshot = await admin.firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('tenants')
            .where('isActive', '==', true)
            .get();

          for (const tenantDoc of tenantsSnapshot.docs) {
            try {
              const tenantData = tenantDoc.data();
              const tenantId = tenantDoc.id;

              // Calculate next due date based on paidThrough
              const paidThrough = tenantData.paidThrough?.toDate();
              if (!paidThrough) continue; // Skip if never paid

              // Next due date is first day of month after paidThrough
              let nextDueDate: Date;
              if (paidThrough.getMonth() === 11) {
                nextDueDate = new Date(paidThrough.getFullYear() + 1, 0, 1);
              } else {
                nextDueDate = new Date(paidThrough.getFullYear(), paidThrough.getMonth() + 1, 1);
              }

              // Check if due date matches target (within 1 day window for safety)
              const daysUntilDue = Math.floor((nextDueDate.getTime() - now.getTime()) / (1000 * 60 * 60 * 24));
              
              if (daysUntilDue !== reminderDays) {
                continue; // Not the right day to send reminder
              }

              // Get ledger balance to check if already paid
              const ledgerSnapshot = await admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('ledgers')
                .where('tenantId', '==', tenantId)
                .where('status', '==', 'posted')
                .get();

              let balance = 0;
              for (const entryDoc of ledgerSnapshot.docs) {
                const entryData = entryDoc.data();
                balance += entryData.amount || 0;
              }

              // Skip if already paid (negative or zero balance means paid)
              if (balance <= 0) {
                continue;
              }

              // Check if we already sent a reminder for this due date
              // We'll track this by storing lastReminderSentDate on the tenant
              const lastReminderDate = tenantData.lastPaymentReminderDate?.toDate();
              const shouldSendReminder = !lastReminderDate || 
                lastReminderDate.getTime() < (now.getTime() - (24 * 60 * 60 * 1000)); // At least 24 hours since last reminder

              if (!shouldSendReminder) {
                continue;
              }

              // Get monthly rate for the reminder message
              const monthlyRate = tenantData.monthlyRate || 0;

              // Send email reminder
              try {
                const emailHtml = `
                  <h2>Payment Reminder</h2>
                  <p>Dear ${tenantData.name},</p>
                  <p>This is a friendly reminder that your payment of \$${monthlyRate.toFixed(2)} is due in ${reminderDays} days (${nextDueDate.toLocaleDateString()}).</p>
                  <p><strong>Current Balance:</strong> \$${balance.toFixed(2)}</p>
                  <p>Please ensure payment is received by the due date to avoid late fees.</p>
                  <p>Thank you,<br>${facilityData.name || 'Storage Facility'}</p>
                  ${facilityData.phone ? `<p>Phone: ${facilityData.phone}</p>` : ''}
                `;

                await sgMail.send({
                  to: tenantData.email,
                  from: {
                    email: SENDGRID_FROM_EMAIL.value(),
                    name: SENDGRID_FROM_NAME.value(),
                  },
                  subject: `Payment Reminder - Due ${nextDueDate.toLocaleDateString()}`,
                  html: emailHtml,
                });

                // Update tenant with reminder sent date
                await tenantDoc.ref.update({
                  lastPaymentReminderDate: admin.firestore.FieldValue.serverTimestamp(),
                });

                totalRemindersSent++;
                functions.logger.info(`Payment reminder sent to ${tenantData.email} (tenant: ${tenantId})`);
              } catch (emailError: any) {
                functions.logger.error(`Error sending payment reminder to ${tenantData.email}: ${emailError.message}`);
              }
            } catch (error: any) {
              functions.logger.error(`Error processing tenant ${tenantDoc.id} for reminders:`, error);
            }
          }
        } catch (error: any) {
          functions.logger.error(`Error processing facility ${facilityId} for reminders:`, error);
        }
      }

      functions.logger.info(`✅ Payment Reminder processing complete: ${totalRemindersSent} reminders sent`);
      return null;
    } catch (error: any) {
      functions.logger.error('❌ Fatal error in Payment Reminder processing:', error);
      throw error;
    }
  });

/**
 * Check and increment SMS usage for tenant, facility, and account
 * Returns usage state and whether SMS can be sent
 */
async function checkAndIncrementSMSUsage(
  facilityId: string,
  tenantId?: string,
  accountId?: string
): Promise<{
  success: boolean;
  canSendSMS: boolean;
  shouldFallbackToEmail: boolean;
  state: SMSUsageState;
  message?: string;
  warning?: string;
  usage?: {
    tenant?: { count: number; limit: number };
    facility: { count: number; limit: number };
    account?: { count: number; limit: number };
  };
}> {
  const now = new Date();
  const monthKey = `${now.getFullYear()}-${(now.getMonth() + 1).toString().padStart(2, '0')}`;
  
  // Get facility to find account ID if not provided
  if (!accountId) {
    const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
    if (facilityDoc.exists) {
      accountId = facilityDoc.data()?.facilityCreatorAccountId;
    }
  }

  return admin.firestore().runTransaction(async (transaction) => {
    // Check tenant usage (if tenantId provided)
    let tenantUsage = { count: 0, limit: SMS_LIMIT_PER_TENANT };
    if (tenantId) {
      const tenantUsageRef = admin.firestore()
        .collection('tenants')
        .doc(tenantId)
        .collection('smsUsage')
        .doc(monthKey);
      
      const tenantUsageDoc = await transaction.get(tenantUsageRef);
      const tenantData = tenantUsageDoc.exists ? tenantUsageDoc.data() : {
        smsMonthlyCount: 0,
        smsMonth: monthKey,
      };
      
      tenantUsage = {
        count: (tenantData?.smsMonthlyCount || 0) + 1,
        limit: SMS_LIMIT_PER_TENANT,
      };
    }

    // Check facility usage
    const facilityUsageRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('smsUsage')
      .doc(monthKey);
    
    const facilityUsageDoc = await transaction.get(facilityUsageRef);
    const facilityData = facilityUsageDoc.exists ? facilityUsageDoc.data() : {
      smsMonthlyCount: 0,
      smsMonthlyLimit: SMS_LIMIT_PER_FACILITY,
      smsMonth: monthKey,
      lastReset: admin.firestore.FieldValue.serverTimestamp(),
    };
    
    const facilityUsage = {
      count: (facilityData?.smsMonthlyCount || 0) + 1,
      limit: facilityData?.smsMonthlyLimit || SMS_LIMIT_PER_FACILITY,
    };

    // Check account usage (if accountId provided)
    let accountUsage = { count: 0, limit: SMS_LIMIT_PER_ACCOUNT };
    if (accountId) {
      const accountUsageRef = admin.firestore()
        .collection('facilityCreatorAccounts')
        .doc(accountId)
        .collection('smsUsage')
        .doc(monthKey);
      
      const accountUsageDoc = await transaction.get(accountUsageRef);
      const accountData = accountUsageDoc.exists ? accountUsageDoc.data() : {
        smsMonthlyCount: 0,
        smsMonthlyLimit: SMS_LIMIT_PER_ACCOUNT,
        smsMonth: monthKey,
        lastReset: admin.firestore.FieldValue.serverTimestamp(),
      };
      
      accountUsage = {
        count: (accountData?.smsMonthlyCount || 0) + 1,
        limit: accountData?.smsMonthlyLimit || SMS_LIMIT_PER_ACCOUNT,
      };
    }

    // Determine usage state based on account limit (most restrictive)
    const accountPercentage = accountId ? (accountUsage.count / accountUsage.limit) * 100 : 0;
    const facilityPercentage = (facilityUsage.count / facilityUsage.limit) * 100;
    const tenantPercentage = tenantId ? (tenantUsage.count / tenantUsage.limit) * 100 : 0;

    let state: SMSUsageState = SMSUsageState.NORMAL;
    let canSendSMS = true;
    let shouldFallbackToEmail = false;

    // Check if any limit is exceeded
    const tenantExceeded = tenantId && tenantUsage.count > tenantUsage.limit;
    const facilityExceeded = facilityUsage.count > facilityUsage.limit;
    const accountExceeded = accountId && accountUsage.count > accountUsage.limit;
    const extremeUsage = accountId && accountUsage.count >= (accountUsage.limit * SMS_EXTREME_MULTIPLIER);

    if (extremeUsage) {
      state = SMSUsageState.EXTREME;
      canSendSMS = false; // Prevent all SMS scheduling
      shouldFallbackToEmail = true;
    } else if (tenantExceeded || facilityExceeded || accountExceeded) {
      state = SMSUsageState.EXCEEDED;
      canSendSMS = false; // Block automated SMS, but allow manual with confirmation
      shouldFallbackToEmail = true;
    } else if (accountPercentage >= 80 || facilityPercentage >= 80 || tenantPercentage >= 80) {
      state = SMSUsageState.APPROACHING;
      canSendSMS = true;
      shouldFallbackToEmail = false;
    }

    // Update usage counts if within limits or if we're tracking for reporting
    if (state !== SMSUsageState.EXTREME) {
      if (tenantId && !tenantExceeded) {
        const tenantUsageRef = admin.firestore()
          .collection('tenants')
          .doc(tenantId)
          .collection('smsUsage')
          .doc(monthKey);
        transaction.set(tenantUsageRef, {
          smsMonthlyCount: tenantUsage.count,
          smsMonth: monthKey,
          lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      }

      if (!facilityExceeded) {
        transaction.set(facilityUsageRef, {
          ...facilityData,
          smsMonthlyCount: facilityUsage.count,
          smsMonth: monthKey,
          lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      }

      if (accountId && !accountExceeded) {
        const accountUsageRef = admin.firestore()
          .collection('facilityCreatorAccounts')
          .doc(accountId)
          .collection('smsUsage')
          .doc(monthKey);
        // Get existing account data (already fetched earlier in the function)
        const existingAccountDoc = await transaction.get(accountUsageRef);
        const existingAccountData = existingAccountDoc.exists ? existingAccountDoc.data() : {
          smsMonthlyLimit: SMS_LIMIT_PER_ACCOUNT,
          smsMonth: monthKey,
          lastReset: admin.firestore.FieldValue.serverTimestamp(),
        };
        transaction.set(accountUsageRef, {
          ...existingAccountData,
          smsMonthlyCount: accountUsage.count,
          smsMonth: monthKey,
          lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      }
    }

    // Generate warning message
    let warning: string | undefined;
    if (state === SMSUsageState.APPROACHING) {
      const maxPercentage = Math.max(accountPercentage, facilityPercentage, tenantPercentage);
      warning = `You are approaching the monthly SMS fair-use threshold (${Math.round(maxPercentage)}%). Additional messages may be converted to email.`;
    } else if (state === SMSUsageState.EXCEEDED) {
      warning = `SMS fair-use limit exceeded. Messages will be sent via email instead.`;
    } else if (state === SMSUsageState.EXTREME) {
      warning = `SMS usage is extremely high (${Math.round(accountPercentage)}% of limit). SMS scheduling is disabled. Please contact support if you need to increase your limit.`;
    }

    return {
      success: true,
      canSendSMS: canSendSMS && !tenantExceeded && !facilityExceeded && !accountExceeded,
      shouldFallbackToEmail: shouldFallbackToEmail,
      state,
      warning,
      usage: {
        tenant: tenantId ? tenantUsage : undefined,
        facility: facilityUsage,
        account: accountId ? accountUsage : undefined,
      },
    };
  });
}

// ============================================
// STRIPE SUBSCRIPTION FUNCTIONS
// ============================================

/**
 * Create Stripe Checkout session for facility-based subscription
 * Pricing: $25/month base (first facility) + $20/month per additional facility
 */
export const createSubscriptionCheckout = functions.runWith({ timeoutSeconds: 60, memory: '256MB' }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  await enforceRateLimit({
    facilityId: data?.accountId,
    key: 'createSubscriptionCheckout',
    limit: 20,
    windowSeconds: 300,
    userId: context.auth.uid,
  });

  const { accountId, customerEmail, successUrl, cancelUrl } = data;

  if (!accountId || !customerEmail) {
    throw new functions.https.HttpsError('invalid-argument', 'accountId and customerEmail are required');
  }

  try {
    // Verify user owns this account
    const accountDoc = await admin.firestore()
      .collection('facilityCreatorAccounts')
      .doc(accountId)
      .get();

    if (!accountDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Account not found');
    }

    const accountData = accountDoc.data()!;
    if (accountData.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }

    const stripe = getStripeClient();

    // Get or create Stripe customer
    let customerId = accountData.stripeCustomerId as string | undefined;
    if (!customerId) {
      const customer = await stripe.customers.create({
        email: customerEmail,
        metadata: {
          accountId: accountId,
          ownerUid: context.auth.uid,
        },
      });
      customerId = customer.id;

      // Save customer ID to account
      await admin.firestore()
        .collection('facilityCreatorAccounts')
        .doc(accountId)
        .update({
          stripeCustomerId: customerId,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    }

    // Get facility count for this account
    const facilityIds = (accountData.facilityIds as string[]) || [];
    const facilityCount = facilityIds.length;
    const additionalFacilityCount = Math.max(0, facilityCount - 1); // Additional facilities beyond first

    // Get or create prices
    const basePriceId = process.env.STRIPE_BASE_PRICE_ID || await getOrCreateBasePriceId(stripe);
    const addOnPriceId = process.env.STRIPE_ADDON_PRICE_ID || await getOrCreateAddOnPriceId(stripe);

    // Build line items: base price (always 1) + add-on price (quantity = additional facilities)
    const lineItems: Stripe.Checkout.SessionCreateParams.LineItem[] = [
      {
        price: basePriceId,
        quantity: 1, // Base plan is always quantity 1
      },
    ];

    if (additionalFacilityCount > 0) {
      lineItems.push({
        price: addOnPriceId,
        quantity: additionalFacilityCount, // Number of additional facilities
      });
    }

    // Create checkout session
    const session = await stripe.checkout.sessions.create({
      customer: customerId,
      mode: 'subscription',
      line_items: lineItems,
      success_url: successUrl || 'https://storage-facility-creator.web.app/subscription/success?session_id={CHECKOUT_SESSION_ID}',
      cancel_url: cancelUrl || 'https://storage-facility-creator.web.app/subscription/cancel',
      metadata: {
        accountId: accountId,
        ownerUid: context.auth.uid,
        facilityCount: facilityCount.toString(),
      },
      subscription_data: {
        metadata: {
          accountId: accountId,
          facilityCount: facilityCount.toString(),
        },
      },
    });

    const result = {
      checkoutUrl: session.url,
      sessionId: session.id,
    };
    await writeAuditLog(accountId, {
      action: 'subscription_checkout_created',
      userId: context.auth.uid,
      checkoutSessionId: session.id,
      facilityCount,
    });
    return result;
  } catch (error: any) {
    functions.logger.error('Error creating checkout session', error);
    await writeAuditLog(data?.accountId, {
      action: 'subscription_checkout_failed',
      userId: context.auth.uid,
      error: error?.message || 'unknown',
    });
    throw new functions.https.HttpsError('internal', `Failed to create checkout: ${error.message}`);
  }
});

/**
 * Start a 30-day trial for an account
 * Sets subscription status to trialing with 30-day trial period
 */
export const startTrial = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  await enforceRateLimit({
    facilityId: data?.accountId,
    key: 'startTrial',
    limit: 10,
    windowSeconds: 600,
    userId: context.auth.uid,
  });

  const { accountId } = data;

  if (!accountId) {
    throw new functions.https.HttpsError('invalid-argument', 'accountId is required');
  }

  try {
    // Verify user owns this account
    const accountDoc = await admin.firestore()
      .collection('facilityCreatorAccounts')
      .doc(accountId)
      .get();

    if (!accountDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Account not found');
    }

    const accountData = accountDoc.data()!;
    if (accountData.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }

    // Check if already has active subscription or trial
    const currentStatus = accountData.subscriptionStatus as string;
    if (currentStatus === 'active' || currentStatus === 'trialing') {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Account already has an active subscription or trial'
      );
    }

    const now = new Date();
    const trialEnd = new Date(now);
    trialEnd.setDate(trialEnd.getDate() + 30); // 30-day trial

    // Update account to trialing status
    await admin.firestore()
      .collection('facilityCreatorAccounts')
      .doc(accountId)
      .update({
        subscriptionStatus: 'trialing',
        subscriptionTrialEnd: admin.firestore.Timestamp.fromDate(trialEnd),
        subscriptionCurrentPeriodStart: admin.firestore.Timestamp.fromDate(now),
        subscriptionCurrentPeriodEnd: admin.firestore.Timestamp.fromDate(trialEnd),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

    functions.logger.info(`30-day trial started for account ${accountId}`);

    const result = {
      success: true,
      trialEnd: trialEnd.toISOString(),
      message: '30-day trial started successfully',
    };
    await writeAuditLog(accountId, {
      action: 'trial_started',
      userId: context.auth.uid,
      trialEnd: trialEnd.toISOString(),
    });
    return result;
  } catch (error: any) {
    functions.logger.error('Error starting trial', error);
    
    // Provide more detailed error information
    let errorMessage = 'Unknown error occurred';
    if (error instanceof functions.https.HttpsError) {
      // Re-throw HttpsErrors as-is
      throw error;
    } else if (error.message) {
      errorMessage = error.message;
    } else if (typeof error === 'string') {
      errorMessage = error;
    } else {
      errorMessage = JSON.stringify(error);
    }
    
    functions.logger.error(`Trial start error details: ${errorMessage}`, {
      accountId,
      userId: context.auth?.uid,
      errorStack: error.stack,
    });
    
    await writeAuditLog(data?.accountId, {
      action: 'trial_start_failed',
      userId: context.auth.uid,
      error: errorMessage,
    });
    throw new functions.https.HttpsError('internal', `Failed to start trial: ${errorMessage}`);
  }
});

/**
 * Create Stripe Customer Portal session for managing subscription
 */
export const createCustomerPortalSession = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { accountId, returnUrl } = data;

  if (!accountId) {
    throw new functions.https.HttpsError('invalid-argument', 'accountId is required');
  }

  try {
    // Verify user owns this account
    const accountDoc = await admin.firestore()
      .collection('facilityCreatorAccounts')
      .doc(accountId)
      .get();

    if (!accountDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Account not found');
    }

    const accountData = accountDoc.data()!;
    if (accountData.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }

    const customerId = accountData.stripeCustomerId as string | undefined;
    if (!customerId) {
      throw new functions.https.HttpsError('failed-precondition', 'No Stripe customer found. Please subscribe first.');
    }

    const stripe = getStripeClient();

    const session = await stripe.billingPortal.sessions.create({
      customer: customerId,
      return_url: returnUrl || 'https://storagefacilitycreator.com/subscription/manage',
    });

    return {
      portalUrl: session.url,
    };
  } catch (error: any) {
    functions.logger.error('Error creating portal session', error);
    throw new functions.https.HttpsError('internal', `Failed to create portal: ${error.message}`);
  }
});

/**
 * Update subscription quantity based on facility count
 * Called when facilities are added or removed
 */
export const updateSubscriptionQuantity = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { accountId } = data;

  if (!accountId) {
    throw new functions.https.HttpsError('invalid-argument', 'accountId is required');
  }

  try {
    // Verify user owns this account
    const accountDoc = await admin.firestore()
      .collection('facilityCreatorAccounts')
      .doc(accountId)
      .get();

    if (!accountDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Account not found');
    }

    const accountData = accountDoc.data()!;
    if (accountData.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }

    const subscriptionId = accountData.stripeSubscriptionId as string | undefined;
    if (!subscriptionId) {
      // No subscription yet, nothing to update
      return { success: true, message: 'No active subscription to update' };
    }

    const stripe = getStripeClient();
    const subscription = await stripe.subscriptions.retrieve(subscriptionId);

    // Get current facility count
    const facilityIds = (accountData.facilityIds as string[]) || [];
    const facilityCount = facilityIds.length;
    const additionalFacilityCount = Math.max(0, facilityCount - 1);

    // Get price IDs
    const basePriceId = process.env.STRIPE_BASE_PRICE_ID || await getOrCreateBasePriceId(stripe);
    const addOnPriceId = process.env.STRIPE_ADDON_PRICE_ID || await getOrCreateAddOnPriceId(stripe);

    // Find base and add-on items in subscription
    const baseItem = subscription.items.data.find(item => item.price.id === basePriceId);
    const addOnItem = subscription.items.data.find(item => item.price.id === addOnPriceId);

    const updates: Stripe.SubscriptionUpdateParams = {
      items: [],
      proration_behavior: 'always_invoice', // Prorate charges for mid-cycle changes
    };

    // Base item: always quantity 1
    if (baseItem) {
      updates.items!.push({
        id: baseItem.id,
        quantity: 1,
      });
    } else {
      // Base item missing, add it
      updates.items!.push({
        price: basePriceId,
        quantity: 1,
      });
    }

    // Add-on item: quantity = additional facilities
    if (additionalFacilityCount > 0) {
      if (addOnItem) {
        updates.items!.push({
          id: addOnItem.id,
          quantity: additionalFacilityCount,
        });
      } else {
        // Add-on item missing, add it
        updates.items!.push({
          price: addOnPriceId,
          quantity: additionalFacilityCount,
        });
      }
    } else if (addOnItem) {
      // No additional facilities, remove add-on item
      updates.items!.push({
        id: addOnItem.id,
        deleted: true,
      });
    }

    // Update subscription
    await stripe.subscriptions.update(subscriptionId, updates);

    functions.logger.info(`Subscription quantity updated for account ${accountId}: ${facilityCount} facilities (1 base + ${additionalFacilityCount} add-on)`);

    return {
      success: true,
      facilityCount: facilityCount,
      baseQuantity: 1,
      addOnQuantity: additionalFacilityCount,
    };
  } catch (error: any) {
    functions.logger.error('Error updating subscription quantity', error);
    throw new functions.https.HttpsError('internal', `Failed to update subscription: ${error.message}`);
  }
});

/**
 * Get subscription status for an account
 */
export const getSubscriptionStatus = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { accountId } = data;

  if (!accountId) {
    throw new functions.https.HttpsError('invalid-argument', 'accountId is required');
  }

  try {
    const accountDoc = await admin.firestore()
      .collection('facilityCreatorAccounts')
      .doc(accountId)
      .get();

    if (!accountDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Account not found');
    }

    const accountData = accountDoc.data()!;
    if (accountData.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }

    return {
      subscriptionStatus: accountData.subscriptionStatus,
      stripeSubscriptionId: accountData.stripeSubscriptionId,
      stripeCustomerId: accountData.stripeCustomerId,
      currentPeriodEnd: accountData.subscriptionCurrentPeriodEnd,
      cancelAtPeriodEnd: accountData.subscriptionCancelAtPeriodEnd,
    };
  } catch (error: any) {
    functions.logger.error('Error getting subscription status', error);
    throw new functions.https.HttpsError('internal', `Failed to get status: ${error.message}`);
  }
});

/**
 * Stripe webhook handler for subscription events
 */
export const stripeWebhook = functions.https.onRequest(async (req, res) => {
  const sig = req.headers['stripe-signature'] as string;

  if (!sig) {
    functions.logger.error('Missing stripe-signature header');
    res.status(400).send('Missing signature');
    return;
  }

  try {
    const webhookSecret = STRIPE_WEBHOOK_SECRET.value();
    const stripe = getStripeClient();

    let event: Stripe.Event;
    try {
      const rawBody = (req as any).rawBody as Buffer | undefined;
      const payload =
        rawBody ??
        (typeof req.body === 'string'
          ? Buffer.from(req.body)
          : Buffer.from(JSON.stringify(req.body || {})));

      event = stripe.webhooks.constructEvent(payload, sig, webhookSecret);
    } catch (err: any) {
      functions.logger.error('Webhook signature verification failed', err);
      res.status(400).send(`Webhook Error: ${err.message}`);
      return;
    }

    // Idempotency: short-circuit if we've already processed this event
    const alreadyProcessed = await isStripeEventProcessed(event.id);
    if (alreadyProcessed) {
      functions.logger.info(`Stripe webhook event ${event.id} already processed, acking`);
      res.json({ received: true, duplicate: true });
      return;
    }

    // Handle the event
    switch (event.type) {
      case 'checkout.session.completed': {
        const session = event.data.object as Stripe.Checkout.Session;
        await handleCheckoutCompleted(session);
        break;
      }
      case 'customer.subscription.created':
      case 'customer.subscription.updated': {
        const subscription = event.data.object as Stripe.Subscription;
        await handleSubscriptionUpdate(subscription);
        break;
      }
      case 'customer.subscription.deleted': {
        const subscription = event.data.object as Stripe.Subscription;
        await handleSubscriptionDeleted(subscription);
        break;
      }
      case 'invoice.payment_succeeded': {
        const invoice = event.data.object as Stripe.Invoice;
        await handleInvoicePaymentSucceeded(invoice);
        break;
      }
      case 'invoice.payment_failed': {
        const invoice = event.data.object as Stripe.Invoice;
        await handleInvoicePaymentFailed(invoice);
        break;
      }
      case 'account.updated': {
        const account = event.data.object as Stripe.Account;
        await handleConnectAccountUpdated(account);
        break;
      }
      case 'payment_intent.succeeded': {
        const paymentIntent = event.data.object as Stripe.PaymentIntent;
        await handlePaymentIntentSucceeded(paymentIntent);
        break;
      }
      case 'payment_intent.payment_failed': {
        const paymentIntent = event.data.object as Stripe.PaymentIntent;
        await handlePaymentIntentFailed(paymentIntent);
        break;
      }
      default:
        functions.logger.info(`Unhandled event type: ${event.type}`);
    }

    await markStripeEventProcessed(event.id, event.type);
    res.json({ received: true });
  } catch (error: any) {
    functions.logger.error('Webhook error', error);
    res.status(500).send(`Webhook Error: ${error.message}`);
  }
});

// Helper function to get or create the $25/month base price (first facility)
async function getOrCreateBasePriceId(stripe: Stripe): Promise<string> {
  // In production, create this price in Stripe Dashboard and store the ID
  // This is a fallback for development
  try {
    const prices = await stripe.prices.list({
      lookup_keys: ['sfc_base_monthly_25'],
      limit: 1,
    });

    if (prices.data.length > 0) {
      return prices.data[0].id;
    }

    // Create the base product and price if they don't exist
    const product = await stripe.products.create({
      name: 'SFC Base Plan - First Facility',
      description: 'Storage Facility Creator base subscription - includes first facility',
    });

    const price = await stripe.prices.create({
      product: product.id,
      unit_amount: 2500, // $25.00
      currency: 'usd',
      recurring: {
        interval: 'month',
      },
      lookup_key: 'sfc_base_monthly_25',
    });

    return price.id;
  } catch (error: any) {
    functions.logger.error('Error creating base price', error);
    throw error;
  }
}

// Helper function to get or create the $20/month add-on price (additional facilities)
async function getOrCreateAddOnPriceId(stripe: Stripe): Promise<string> {
  // In production, create this price in Stripe Dashboard and store the ID
  // This is a fallback for development
  try {
    const prices = await stripe.prices.list({
      lookup_keys: ['sfc_addon_monthly_20'],
      limit: 1,
    });

    if (prices.data.length > 0) {
      return prices.data[0].id;
    }

    // Create the add-on product and price if they don't exist
    const product = await stripe.products.create({
      name: 'SFC Additional Facility',
      description: 'Additional facility add-on - $20/month per facility',
    });

    const price = await stripe.prices.create({
      product: product.id,
      unit_amount: 2000, // $20.00
      currency: 'usd',
      recurring: {
        interval: 'month',
      },
      lookup_key: 'sfc_addon_monthly_20',
    });

    return price.id;
  } catch (error: any) {
    functions.logger.error('Error creating add-on price', error);
    throw error;
  }
}

// Webhook handlers
async function handleCheckoutCompleted(session: Stripe.Checkout.Session) {
  const accountId = session.metadata?.accountId;
  if (!accountId) {
    functions.logger.error('No accountId in checkout session metadata');
    return;
  }

  const subscriptionId = session.subscription as string;
  if (!subscriptionId) {
    functions.logger.error('No subscription ID in checkout session');
    return;
  }

  await updateAccountFromSubscription(accountId, subscriptionId);
}

async function handleSubscriptionUpdate(subscription: Stripe.Subscription) {
  const accountId = subscription.metadata?.accountId;
  if (!accountId) {
    functions.logger.error('No accountId in subscription metadata');
    return;
  }

  await updateAccountFromSubscription(accountId, subscription.id);
}

async function handleSubscriptionDeleted(subscription: Stripe.Subscription) {
  const accountId = subscription.metadata?.accountId;
  if (!accountId) {
    functions.logger.error('No accountId in subscription metadata');
    return;
  }

  await admin.firestore()
    .collection('facilityCreatorAccounts')
    .doc(accountId)
    .update({
      subscriptionStatus: 'cancelled',
      subscriptionCanceledAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

  functions.logger.info(`Subscription cancelled for account: ${accountId}`);
}

async function handleInvoicePaymentSucceeded(invoice: Stripe.Invoice) {
  const subscriptionId = invoice.subscription as string;
  if (!subscriptionId) {
    return;
  }

  const stripe = getStripeClient();
  const subscription = await stripe.subscriptions.retrieve(subscriptionId);
  const accountId = subscription.metadata?.accountId;

  if (accountId) {
    await updateAccountFromSubscription(accountId, subscriptionId);
    functions.logger.info(`Payment succeeded for account: ${accountId}`);
  }
}

async function handleInvoicePaymentFailed(invoice: Stripe.Invoice) {
  const subscriptionId = invoice.subscription as string;
  if (!subscriptionId) {
    return;
  }

  const stripe = getStripeClient();
  const subscription = await stripe.subscriptions.retrieve(subscriptionId);
  const accountId = subscription.metadata?.accountId;

  if (accountId) {
    // Update account status to past_due
    await admin.firestore()
      .collection('facilityCreatorAccounts')
      .doc(accountId)
      .update({
        subscriptionStatus: 'past_due',
        subscriptionLastPaymentFailed: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

    // Optionally send email notification to facility owner
    // (This would require getting the owner's email from the account)
    functions.logger.info(`Payment failed for account: ${accountId}`);
  }
}

/**
 * Handle successful payment intent (for tenant payments via Stripe Connect)
 */
async function handlePaymentIntentSucceeded(paymentIntent: Stripe.PaymentIntent) {
  try {
    const facilityId = paymentIntent.metadata?.facilityId;
    const tenantId = paymentIntent.metadata?.tenantId;
    const invoiceId = paymentIntent.metadata?.invoiceId;

    if (!facilityId || !tenantId) {
      functions.logger.warn('Payment intent missing facilityId or tenantId metadata');
      return;
    }

    // Update payment record in Firestore
    const paymentsRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('payments');

    // Find payment by externalPaymentId or create new one
    const existingPayments = await paymentsRef
      .where('externalPaymentId', '==', paymentIntent.id)
      .limit(1)
      .get();

    if (!existingPayments.empty) {
      // Update existing payment
      await existingPayments.docs[0].ref.update({
        status: 'completed',
        paidDate: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } else {
      // Create new payment record
      await paymentsRef.add({
        tenantId: tenantId,
        facilityId: facilityId,
        contractId: paymentIntent.metadata?.contractId || '',
        amount: paymentIntent.amount / 100, // Convert from cents
        status: 'completed',
        method: 'stripe',
        externalPaymentId: paymentIntent.id,
        transactionId: paymentIntent.id,
        paidDate: admin.firestore.FieldValue.serverTimestamp(),
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        createdBy: 'system@stripe-webhook',
        isActive: true,
      });
    }

    // If invoiceId provided, mark invoice as paid
    if (invoiceId) {
      const invoiceRef = admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('invoices')
        .doc(invoiceId);

      await invoiceRef.update({
        status: 'paid',
        paidDate: admin.firestore.FieldValue.serverTimestamp(),
        balance: 0,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    // Create ledger entry for payment
    const ledgerRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('ledgers')
      .doc();

    await ledgerRef.set({
      tenantId: tenantId,
      facilityId: facilityId,
      type: 'payment',
      amount: -(paymentIntent.amount / 100), // Negative for payments
      description: `Payment via Stripe - ${paymentIntent.id}`,
      referenceId: existingPayments.empty ? null : existingPayments.docs[0].id,
      entryDate: admin.firestore.FieldValue.serverTimestamp(),
      status: 'posted',
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      createdBy: 'system@stripe-webhook',
      metadata: {
        paymentIntentId: paymentIntent.id,
        invoiceId: invoiceId || null,
      },
    });

    functions.logger.info(`Payment intent succeeded: ${paymentIntent.id} for tenant ${tenantId}`);
  } catch (error: any) {
    functions.logger.error('Error handling payment intent succeeded:', error);
  }
}

/**
 * Handle failed payment intent (for tenant payments via Stripe Connect)
 */
async function handlePaymentIntentFailed(paymentIntent: Stripe.PaymentIntent) {
  try {
    const facilityId = paymentIntent.metadata?.facilityId;
    const tenantId = paymentIntent.metadata?.tenantId;

    if (!facilityId || !tenantId) {
      functions.logger.warn('Payment intent missing facilityId or tenantId metadata');
      return;
    }

    // Update payment record in Firestore
    const paymentsRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('payments');

    const existingPayments = await paymentsRef
      .where('externalPaymentId', '==', paymentIntent.id)
      .limit(1)
      .get();

    if (!existingPayments.empty) {
      await existingPayments.docs[0].ref.update({
        status: 'failed',
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } else {
      // Create failed payment record
      await paymentsRef.add({
        tenantId: tenantId,
        facilityId: facilityId,
        contractId: paymentIntent.metadata?.contractId || '',
        amount: paymentIntent.amount / 100,
        status: 'failed',
        method: 'stripe',
        externalPaymentId: paymentIntent.id,
        transactionId: paymentIntent.id,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        createdBy: 'system@stripe-webhook',
        isActive: true,
        notes: `Payment failed: ${paymentIntent.last_payment_error?.message || 'Unknown error'}`,
      });
    }

    // Optionally send notification to facility manager
    functions.logger.info(`Payment intent failed: ${paymentIntent.id} for tenant ${tenantId}`);
  } catch (error: any) {
    functions.logger.error('Error handling payment intent failed:', error);
  }
}

type RateLimitConfig = {
  facilityId: string | undefined;
  key: string;
  limit: number;
  windowSeconds: number;
  userId?: string | null;
};

async function enforceRateLimit(config: RateLimitConfig): Promise<void> {
  const { facilityId, key, limit, windowSeconds, userId } = config;
  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required for rate limiting');
  }

  const now = Math.floor(Date.now() / 1000);
  const windowStart = Math.floor(now / windowSeconds) * windowSeconds;
  const docId = `${key}_${windowStart}`;
  const ref = admin
    .firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('rateLimits')
    .doc(docId);

  await admin.firestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const current = snap.exists ? (snap.data()?.count as number) || 0 : 0;
    if (current >= limit) {
      throw new functions.https.HttpsError(
        'resource-exhausted',
        `Rate limit exceeded for ${key}. Try again shortly.`
      );
    }
    tx.set(
      ref,
      {
        count: current + 1,
        windowStart: new Date(windowStart * 1000),
        windowSeconds,
        key,
        facilityId,
        lastUserId: userId || null,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  });
}

async function writeAuditLog(
  facilityId: string,
  entry: Record<string, any>
): Promise<void> {
  await admin
    .firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('auditLogs')
    .add({
      ...entry,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      facilityId,
    });
}

function enforceAppCheckOrThrow(context: functions.https.CallableContext) {
  // App Check enforcement is now enabled - client app has been updated with App Check
  // The client app auto-enables App Check for production domain (storagefacilitycreator.com)
  // Ensure reCAPTCHA v3 Secret Key is configured in Firebase Console > App Check
  if (!context.app) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'App Check token required. Please update your app.'
    );
  }
}

async function isStripeEventProcessed(eventId: string): Promise<boolean> {
  if (!eventId) return false;
  const doc = await admin.firestore().collection('stripeWebhookEvents').doc(eventId).get();
  return doc.exists;
}

async function markStripeEventProcessed(eventId: string, eventType: string): Promise<void> {
  if (!eventId) return;
  await admin.firestore().collection('stripeWebhookEvents').doc(eventId).set({
    eventType,
    processedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });
}

// ============================================
// STRIPE CONNECT FUNCTIONS
// ============================================

/**
 * Create a Stripe Connect account for a facility
 * This creates a Standard Connect account that facility owners will complete onboarding for
 */
export const createStripeConnectAccount = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId } = data;

  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }

  try {
    // Verify user has access to this facility
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data()!;
    if (facilityData.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }

    // Check if account already exists
    if (facilityData.stripeConnectAccountId) {
      throw new functions.https.HttpsError('already-exists', 'Stripe Connect account already exists for this facility');
    }

    const stripe = getStripeClient();

    // Get Client ID (available for future use or Express Connect migration)
    const clientId = process.env.STRIPE_CONNECT_CLIENT_ID;
    if (clientId) {
      functions.logger.info(`Using Stripe Connect Client ID for facility ${facilityId}`);
    }

    // Create a Standard Connect account
    const account = await stripe.accounts.create({
      type: 'standard',
      country: 'US', // Default to US, can be made configurable
      email: facilityData.email || context.auth.token.email,
      metadata: {
        facilityId: facilityId,
        ownerUid: context.auth.uid,
      },
    });

    // Store the account ID on the facility
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .update({
        stripeConnectAccountId: account.id,
        stripeConnectOnboardingComplete: false,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

    functions.logger.info(`Created Stripe Connect account ${account.id} for facility ${facilityId}`);

    return {
      accountId: account.id,
    };
  } catch (error: any) {
    functions.logger.error('Error creating Stripe Connect account', error);
    throw new functions.https.HttpsError('internal', `Failed to create account: ${error.message}`);
  }
});

/**
 * Create an account link for Stripe Connect onboarding
 * This returns a URL that the facility owner visits to complete onboarding
 */
export const createStripeConnectAccountLink = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId } = data;

  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }

  try {
    // Verify user has access to this facility
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data()!;
    if (facilityData.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }

    const connectAccountId = facilityData.stripeConnectAccountId as string | undefined;
    if (!connectAccountId) {
      throw new functions.https.HttpsError('failed-precondition', 'Stripe Connect account not created. Call createStripeConnectAccount first.');
    }

    const stripe = getStripeClient();

    // Create account link for onboarding
    const accountLink = await stripe.accountLinks.create({
      account: connectAccountId,
      refresh_url: 'https://storagefacilitycreator.com/stripe-connect/refresh?facility_id=' + facilityId,
      return_url: 'https://storagefacilitycreator.com/stripe-connect/return?facility_id=' + facilityId,
      type: 'account_onboarding',
    });

    return {
      url: accountLink.url,
    };
  } catch (error: any) {
    functions.logger.error('Error creating Stripe Connect account link', error);
    throw new functions.https.HttpsError('internal', `Failed to create account link: ${error.message}`);
  }
});

/**
 * Check Stripe Connect account status
 * Returns the current status of the connected account
 */
export const getStripeConnectAccountStatus = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }

  const { facilityId } = data;

  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }

  try {
    // Verify user has access to this facility
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data()!;
    if (facilityData.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }

    const connectAccountId = facilityData.stripeConnectAccountId as string | undefined;
    if (!connectAccountId) {
      return {
        connected: false,
        onboardingComplete: false,
      };
    }

    const stripe = getStripeClient();

    // Retrieve account details
    const account = await stripe.accounts.retrieve(connectAccountId);

    // Check if onboarding is complete
    const onboardingComplete = account.details_submitted && account.charges_enabled && account.payouts_enabled;

    // Update facility if status changed
    if (onboardingComplete !== facilityData.stripeConnectOnboardingComplete) {
      await admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .update({
          stripeConnectOnboardingComplete: onboardingComplete,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    }

    return {
      connected: true,
      accountId: connectAccountId,
      onboardingComplete: onboardingComplete,
      chargesEnabled: account.charges_enabled,
      payoutsEnabled: account.payouts_enabled,
      detailsSubmitted: account.details_submitted,
      email: account.email,
    };
  } catch (error: any) {
    functions.logger.error('Error getting Stripe Connect account status', error);
    throw new functions.https.HttpsError('internal', `Failed to get status: ${error.message}`);
  }
});

/**
 * Create a payment checkout session for tenant rent payment
 * Routes payment to the facility owner's Stripe Connect account (0% platform fee)
 */
export const createTenantPaymentCheckout = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }

  const { facilityId, tenantId, amount, description } = data;

  if (!facilityId || !tenantId || !amount) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId, tenantId, and amount are required');
  }

  try {
    // Verify user has access to this facility
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data()!;
    const connectAccountId = facilityData.stripeConnectAccountId as string | undefined;
    const onboardingComplete = facilityData.stripeConnectOnboardingComplete as boolean | undefined;

    if (!connectAccountId || !onboardingComplete) {
      throw new functions.https.HttpsError('failed-precondition', 'Facility owner must complete Stripe Connect onboarding before accepting payments');
    }

    // Get tenant info
    const tenantDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId)
      .get();

    if (!tenantDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Tenant not found');
    }

    const tenantData = tenantDoc.data()!;
    const tenantEmail = tenantData['email'] as string | undefined;
    const tenantName = tenantData['name'] as string | undefined || 'Tenant';

    const stripe = getStripeClient();

    // Create checkout session directly on the connected account
    // For Standard accounts, payments go directly to the connected account (0% platform fee)
    const session = await stripe.checkout.sessions.create({
      mode: 'payment',
      payment_method_types: ['card'],
      line_items: [
        {
          price_data: {
            currency: 'usd',
            product_data: {
              name: description || `Rent Payment - ${tenantName}`,
              description: `Payment for ${facilityData['name'] || 'Facility'}`,
            },
            unit_amount: Math.round(amount * 100), // Convert to cents
          },
          quantity: 1,
        },
      ],
      customer_email: tenantEmail,
      success_url: 'https://storagefacilitycreator.com/payment/success?session_id={CHECKOUT_SESSION_ID}',
      cancel_url: 'https://storagefacilitycreator.com/payment/cancel',
      metadata: {
        facilityId: facilityId,
        tenantId: tenantId,
        type: 'tenant_rent_payment',
      },
    }, {
      stripeAccount: connectAccountId, // Create session on connected account - all funds go to facility owner
    });

    return {
      checkoutUrl: session.url,
      sessionId: session.id,
    };
  } catch (error: any) {
    functions.logger.error('Error creating tenant payment checkout', error);
    throw new functions.https.HttpsError('internal', `Failed to create checkout: ${error.message}`);
  }
});


/**
 * Create a payment checkout session for public payment links
 * No authentication required - uses token-based validation
 */
export const createPublicPaymentCheckout = functions.https.onCall(async (data: any, context) => {
  // Note: No auth check - public access via token
  const { token } = data;

  if (!token) {
    throw new functions.https.HttpsError('invalid-argument', 'token is required');
  }

  try {
    // Get payment link from Firestore
    const linkDoc = await admin.firestore()
      .collection('publicPaymentLinks')
      .doc(token)
      .get();

    if (!linkDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Payment link not found');
    }

    const linkData = linkDoc.data()!;
    const facilityId = linkData.facilityId as string;
    const tenantId = linkData.tenantId as string;
    const amount = linkData.amount as number;
    const description = linkData.description as string || 'Payment';
    const status = linkData.status as string;
    const expiresAt = linkData.expiresAt as admin.firestore.Timestamp;

    // Validate link is active
    if (status !== 'pending') {
      throw new functions.https.HttpsError('failed-precondition', 'Payment link is no longer active');
    }

    // Check if expired
    if (expiresAt && expiresAt.toDate() < new Date()) {
      throw new functions.https.HttpsError('failed-precondition', 'Payment link has expired');
    }

    // Get facility info
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data()!;
    const connectAccountId = facilityData.stripeConnectAccountId as string | undefined;
    const onboardingComplete = facilityData.stripeConnectOnboardingComplete as boolean | undefined;

    if (!connectAccountId || !onboardingComplete) {
      throw new functions.https.HttpsError('failed-precondition', 'Facility owner must complete Stripe Connect onboarding before accepting payments');
    }

    // Get tenant info
    const tenantDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId)
      .get();

    if (!tenantDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Tenant not found');
    }

    const tenantData = tenantDoc.data()!;
    const tenantEmail = tenantData['email'] as string | undefined;

    const stripe = getStripeClient();

    // Create checkout session directly on the connected account
    // For Standard accounts, payments go directly to the connected account (0% platform fee)
    const session = await stripe.checkout.sessions.create({
      mode: 'payment',
      payment_method_types: ['card'],
      line_items: [
        {
          price_data: {
            currency: 'usd',
            product_data: {
              name: description || `Payment for ${facilityData['name'] || 'Facility'}`,
              description: `Payment for ${facilityData['name'] || 'Facility'}`,
            },
            unit_amount: Math.round(amount * 100), // Convert to cents
          },
          quantity: 1,
        },
      ],
      customer_email: tenantEmail,
      success_url: 'https://storage-facility-creator.web.app/pay?token=' + token + '&status=success&session_id={CHECKOUT_SESSION_ID}',
      cancel_url: 'https://storage-facility-creator.web.app/pay?token=' + token + '&status=cancel',
      metadata: {
        facilityId: facilityId,
        tenantId: tenantId,
        type: 'public_payment_link',
        paymentLinkToken: token,
      },
    }, {
      stripeAccount: connectAccountId, // Create session on connected account - all funds go to facility owner
    });

    return {
      checkoutUrl: session.url,
      sessionId: session.id,
    };
  } catch (error: any) {
    if (error instanceof functions.https.HttpsError) {
      throw error;
    }
    functions.logger.error('Error creating public payment checkout', error);
    throw new functions.https.HttpsError('internal', `Failed to create checkout: ${error.message}`);
  }
});

/**
 * Handle Stripe Connect account updates
 * Updates facility when connected account status changes
 */
async function handleConnectAccountUpdated(account: Stripe.Account) {
  try {
    const facilityId = account.metadata?.facilityId;
    if (!facilityId) {
      functions.logger.warn('Connect account updated but no facilityId in metadata');
      return;
    }

    const onboardingComplete = account.details_submitted && account.charges_enabled && account.payouts_enabled;

    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .update({
        stripeConnectOnboardingComplete: onboardingComplete,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

    functions.logger.info(`Updated Connect account status for facility ${facilityId}: onboardingComplete=${onboardingComplete}`);
  } catch (error: any) {
    functions.logger.error('Error handling Connect account update', error);
  }
}

/**
 * Lookup user by email for invite purposes
 * Returns minimal user data (uid, email, name) for security
 */
export const lookupUserByEmail = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  
  const { email } = data;
  if (!email) {
    throw new functions.https.HttpsError('invalid-argument', 'Email is required');
  }
  
  try {
    const emailLower = email.toLowerCase().trim();
    
    // Find user by emailLower field
    const usersSnapshot = await admin.firestore()
      .collection('users')
      .where('emailLower', '==', emailLower)
      .limit(1)
      .get();
    
    if (usersSnapshot.empty) {
      // Fallback to email field (case-insensitive)
      const fallbackSnapshot = await admin.firestore()
        .collection('users')
        .where('email', '==', emailLower)
        .limit(1)
        .get();
      
      if (fallbackSnapshot.empty) {
        return { found: false };
      }
      
      const userData = fallbackSnapshot.docs[0].data();
      return {
        found: true,
        uid: fallbackSnapshot.docs[0].id,
        email: userData.email || emailLower,
        name: userData.name || null,
      };
    }
    
    const userData = usersSnapshot.docs[0].data();
    
    // Return minimal data for invites (email, name, uid)
    return {
      found: true,
      uid: usersSnapshot.docs[0].id,
      email: userData.email || emailLower,
      name: userData.name || null,
    };
  } catch (error: any) {
    functions.logger.error('Error looking up user by email', { error: error.message, email });
    throw new functions.https.HttpsError('internal', 'Failed to lookup user');
  }
});

// Export migration functions (Phase 2)
import { runAllMigrations } from './migrations/phase2_migrations';

// Cloud Function to run migrations (for manual execution)
export const runPhase2Migrations = functions.https.onCall(async (data: any, context) => {
  // Only allow super admins to run migrations
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }

  const userEmail = context.auth.token.email;
  const superAdminEmails = [
    'russell_forsyth_1992@outlook.com',
    'russellforsyth09091992@gmail.com',
  ];

  if (!superAdminEmails.includes(userEmail?.toLowerCase() || '')) {
    throw new functions.https.HttpsError('permission-denied', 'Only super admins can run migrations');
  }

  try {
    await runAllMigrations();
    return { success: true, message: 'All migrations completed' };
  } catch (error: any) {
    functions.logger.error('Migration error:', error);
    throw new functions.https.HttpsError('internal', `Migration failed: ${error.message}`);
  }
});

async function updateAccountFromSubscription(accountId: string, subscriptionId: string) {
  try {
    const stripe = getStripeClient();
    const subscription = await stripe.subscriptions.retrieve(subscriptionId);

    let status: string = 'active';
    switch (subscription.status) {
      case 'active':
        status = 'active';
        break;
      case 'past_due':
        status = 'pastDue';
        break;
      case 'canceled':
        status = 'cancelled';
        break;
      case 'trialing':
        status = 'trialing';
        break;
      case 'incomplete':
        status = 'incomplete';
        break;
      case 'incomplete_expired':
        status = 'incompleteExpired';
        break;
      case 'unpaid':
        status = 'unpaid';
        break;
      default:
        status = 'active';
    }

    await admin.firestore()
      .collection('facilityCreatorAccounts')
      .doc(accountId)
      .update({
        subscriptionStatus: status,
        stripeSubscriptionId: subscriptionId,
        subscriptionCurrentPeriodStart: subscription.current_period_start
          ? admin.firestore.Timestamp.fromMillis(subscription.current_period_start * 1000)
          : null,
        subscriptionCurrentPeriodEnd: subscription.current_period_end
          ? admin.firestore.Timestamp.fromMillis(subscription.current_period_end * 1000)
          : null,
        subscriptionCancelAtPeriodEnd: subscription.cancel_at_period_end,
        subscriptionCanceledAt: subscription.canceled_at
          ? admin.firestore.Timestamp.fromMillis(subscription.canceled_at * 1000)
          : null,
        subscriptionTrialEnd: subscription.trial_end
          ? admin.firestore.Timestamp.fromMillis(subscription.trial_end * 1000)
          : null,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

    functions.logger.info(`Account ${accountId} updated from subscription ${subscriptionId}`);
  } catch (error: any) {
    functions.logger.error(`Error updating account from subscription: ${error.message}`, error);
  }
}

/**
 * Phase 12: Two-Way SMS Messaging
 * Handle incoming SMS messages from tenants via Twilio webhook
 */
export const handleIncomingSMS = functions.runWith({
  secrets: [TWILIO_AUTH_TOKEN],
}).https.onRequest(async (req, res) => {
  // Set CORS headers for Twilio
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.set('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    res.status(200).send('');
    return;
  }

  // Only accept POST requests
  if (req.method !== 'POST') {
    res.status(405).send('Method Not Allowed');
    return;
  }

  try {
    // Note: Twilio signature verification requires twilio package or manual crypto implementation
    // For now, we'll rely on the webhook URL being secret and Firebase security rules
    // TODO: Implement proper Twilio signature verification when twilio package is added
    
    // Extract phone number and message from Twilio webhook
    const from = req.body.From as string;
    const to = req.body.To as string;
    const body = (req.body.Body as string || '').trim();
    const bodyUpper = body.toUpperCase();
    const messageSid = req.body.MessageSid as string;

    functions.logger.info(`Incoming SMS from ${from} to ${to}: ${body.substring(0, 50)}`);

    // Handle STOP/UNSTOP keywords
    if (bodyUpper === 'STOP' || bodyUpper === 'STOPALL' || bodyUpper === 'UNSUBSCRIBE' || 
        bodyUpper === 'CANCEL' || bodyUpper === 'END' || bodyUpper === 'QUIT') {
      // Handle opt-out
      await handleSMSOptOut(from);
      res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
      return;
    }

    if (bodyUpper === 'START' || bodyUpper === 'YES' || bodyUpper === 'UNSTOP') {
      // Handle opt-in
      await handleSMSOptIn(from);
      res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
      return;
    }

    // Normalize phone number and find tenant
    const normalizedFrom = formatPhoneNumber(from);
    if (!normalizedFrom) {
      functions.logger.warn(`Invalid phone number format: ${from}`);
      res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
      return;
    }

    // Find tenant by phone number (try multiple formats)
    const tenant = await findTenantByPhoneNumber(normalizedFrom);
    
    if (!tenant) {
      // No tenant found - log but don't error (could be spam)
      functions.logger.warn(`Incoming SMS from unknown number: ${from}`);
      res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
      return;
    }

    // Get or create conversation
    const conversationId = await getOrCreateSMSConversation(tenant.facilityId, tenant.id, normalizedFrom);

    // Store incoming message
    await storeIncomingSMSMessage(conversationId, tenant.facilityId, tenant.id, normalizedFrom, body, messageSid);

    // Create contact log entry
    await createContactLogForSMSReply(tenant.facilityId, tenant.id, body, normalizedFrom, messageSid);

    // Send notification to facility staff (optional - can be done via Firebase Cloud Messaging)
    functions.logger.info(`Stored incoming SMS from tenant ${tenant.id} in facility ${tenant.facilityId}`);

    res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');

  } catch (error: any) {
    functions.logger.error(`Error handling incoming SMS: ${error.message}`, error);
    // Always return 200 to Twilio to prevent retries for errors we can't recover from
    res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
  }
});

/**
 * Helper: Find tenant by phone number (try multiple formats)
 */
async function findTenantByPhoneNumber(phoneNumber: string): Promise<{ facilityId: string; id: string; phone: string } | null> {
  try {
    // Try different phone number formats
    const phoneVariations = [
      phoneNumber, // Original normalized format
      phoneNumber.replace('+', ''), // Without +
      phoneNumber.replace(/^\+1/, ''), // Without +1
      phoneNumber.replace(/^\+1/, '1'), // With 1 but no +
    ];

    for (const phoneVar of phoneVariations) {
      // Use collection group query to search across all facilities
      const tenantsQuery = await admin.firestore()
        .collectionGroup('tenants')
        .where('phone', '==', phoneVar)
        .where('isActive', '==', true)
        .limit(1)
        .get();

      if (!tenantsQuery.empty) {
        const tenantDoc = tenantsQuery.docs[0];
        const tenantData = tenantDoc.data();
        const facilityId = tenantDoc.ref.parent.parent?.id;
        
        if (facilityId) {
          return {
            facilityId,
            id: tenantDoc.id,
            phone: tenantData.phone,
          };
        }
      }
    }

    return null;
  } catch (error: any) {
    functions.logger.error(`Error finding tenant by phone: ${error.message}`, error);
    return null;
  }
}

/**
 * Helper: Get or create SMS conversation
 */
async function getOrCreateSMSConversation(
  facilityId: string,
  tenantId: string,
  phoneNumber: string
): Promise<string> {
  try {
    // Check if conversation already exists
    const conversationsRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('smsConversations');
    
    const existingQuery = await conversationsRef
      .where('tenantId', '==', tenantId)
      .where('phoneNumber', '==', phoneNumber)
      .limit(1)
      .get();

    if (!existingQuery.empty) {
      return existingQuery.docs[0].id;
    }

    // Create new conversation
    const conversationRef = await conversationsRef.add({
      tenantId,
      phoneNumber,
      lastMessage: '',
      lastMessageAt: admin.firestore.FieldValue.serverTimestamp(),
      lastMessageDirection: 'incoming',
      unreadCount: 0,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return conversationRef.id;
  } catch (error: any) {
    functions.logger.error(`Error creating SMS conversation: ${error.message}`, error);
    throw error;
  }
}

/**
 * Helper: Store incoming SMS message
 */
async function storeIncomingSMSMessage(
  conversationId: string,
  facilityId: string,
  tenantId: string,
  phoneNumber: string,
  messageBody: string,
  messageSid: string
): Promise<void> {
  try {
    const now = admin.firestore.FieldValue.serverTimestamp();
    
    // Store message in messages subcollection
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('smsConversations')
      .doc(conversationId)
      .collection('messages')
      .add({
        direction: 'incoming',
        phoneNumber,
        body: messageBody,
        status: 'received',
        messageSid,
        timestamp: now,
        read: false,
      });

    // Update conversation
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('smsConversations')
      .doc(conversationId)
      .update({
        lastMessage: messageBody.substring(0, 100), // Truncate long messages
        lastMessageAt: now,
        lastMessageDirection: 'incoming',
        unreadCount: admin.firestore.FieldValue.increment(1),
        updatedAt: now,
      });

  } catch (error: any) {
    functions.logger.error(`Error storing incoming SMS message: ${error.message}`, error);
    throw error;
  }
}

/**
 * Helper: Create contact log for SMS reply
 */
async function createContactLogForSMSReply(
  facilityId: string,
  tenantId: string,
  messageBody: string,
  phoneNumber: string,
  messageSid: string
): Promise<void> {
  try {
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId)
      .collection('contactLogs')
      .add({
        type: 'sms_reply',
        subject: 'SMS Reply from Tenant',
        message: messageBody,
        contactMethod: phoneNumber,
        direction: 'incoming',
        timestamp: admin.firestore.FieldValue.serverTimestamp(),
        metadata: {
          messageSid,
        },
      });
  } catch (error: any) {
    // Don't fail the webhook if contact log creation fails
    functions.logger.warn(`Failed to create contact log for SMS reply: ${error.message}`);
  }
}

/**
 * Helper: Handle SMS opt-out
 */
async function handleSMSOptOut(phoneNumber: string): Promise<void> {
  try {
    const normalizedPhone = formatPhoneNumber(phoneNumber);
    if (!normalizedPhone) return;

    const tenant = await findTenantByPhoneNumber(normalizedPhone);
    if (!tenant) return;

    // Update tenant's SMS opt-out status
    await admin.firestore()
      .collection('facilities')
      .doc(tenant.facilityId)
      .collection('tenants')
      .doc(tenant.id)
      .update({
        smsOptOut: true,
        smsOptOutDate: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

    functions.logger.info(`Tenant ${tenant.id} opted out of SMS`);
  } catch (error: any) {
    functions.logger.error(`Error handling SMS opt-out: ${error.message}`, error);
  }
}

/**
 * Helper: Handle SMS opt-in
 */
async function handleSMSOptIn(phoneNumber: string): Promise<void> {
  try {
    const normalizedPhone = formatPhoneNumber(phoneNumber);
    if (!normalizedPhone) return;

    const tenant = await findTenantByPhoneNumber(normalizedPhone);
    if (!tenant) return;

    // Update tenant's SMS opt-in status
    await admin.firestore()
      .collection('facilities')
      .doc(tenant.facilityId)
      .collection('tenants')
      .doc(tenant.id)
      .update({
        smsOptOut: false,
        smsOptInDate: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

    functions.logger.info(`Tenant ${tenant.id} opted in to SMS`);
  } catch (error: any) {
    functions.logger.error(`Error handling SMS opt-in: ${error.message}`, error);
  }
}
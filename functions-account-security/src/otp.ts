import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { enforceAppCheckOrThrow } from '@sfc/functions-shared';
import { getSgMail, initializeSendGrid } from '@sfc/functions-shared';
import { appendPlatformSecurityEmailFooter } from './emailOtpFooter';
import { getOtpCooldownRemainingSeconds, isValidOtpCodeFormat, OTP_COOLDOWN_SECONDS } from './otpHelpers';
import { SENDGRID_FROM_EMAIL, SENDGRID_FROM_NAME, SENDGRID_SECRETS } from './secrets';

/**
 * Generate and send OTP code via email
 *
 * Rate limiting: Max 1 OTP per 45 seconds per user. lastOTPSentAt is updated only
 * after a successful email send, so failed sends do not rate-limit the user.
 */
export const generateOTP = functions.runWith({ secrets: SENDGRID_SECRETS }).https.onCall(
  async (data: { purpose?: string }, context) => {
    try {
      if (!context.auth) {
        throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
      }
      enforceAppCheckOrThrow(context);

      const userId = context.auth.uid;
      const userEmail = context.auth.token.email;
      const purpose = data.purpose || 'sensitive_action';

      if (!userEmail) {
        throw new functions.https.HttpsError('invalid-argument', 'User email is required');
      }

      const userDoc = await admin.firestore().collection('users').doc(userId).get();
      if (!userDoc.exists) {
        throw new functions.https.HttpsError('not-found', 'User not found');
      }

      const userData = userDoc.data()!;
      const lastOTPSentAt = userData.lastOTPSentAt as admin.firestore.Timestamp | null;

      const remainingSeconds = getOtpCooldownRemainingSeconds(lastOTPSentAt, Date.now());
      if (remainingSeconds > 0) {
        throw new functions.https.HttpsError(
          'resource-exhausted',
          `Please wait ${remainingSeconds} seconds before requesting another OTP code. You can request a new code in ${remainingSeconds} second${remainingSeconds !== 1 ? 's' : ''}.`,
        );
      }

      const otpCode = Math.floor(100000 + Math.random() * 900000).toString();
      const expiresAt = new Date(Date.now() + 10 * 60 * 1000);

      const otpId = `otp-${Date.now()}-${Math.random().toString(36).substring(2, 9)}`;
      await admin
        .firestore()
        .collection('users')
        .doc(userId)
        .collection('otpCodes')
        .doc(otpId)
        .set({
          code: otpCode,
          purpose: purpose,
          expiresAt: admin.firestore.Timestamp.fromDate(expiresAt),
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          used: false,
        });

      initializeSendGrid();

      const emailSubject = 'Your Verification Code';
      const emailHtml = `
        <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
          <h2 style="color: #333;">Verification Code</h2>
          <p>Your verification code is:</p>
          <div style="background-color: #f5f5f5; padding: 20px; text-align: center; margin: 20px 0; border-radius: 5px;">
            <h1 style="color: #0066cc; font-size: 32px; margin: 0; letter-spacing: 5px;">${otpCode}</h1>
          </div>
          <p>This code will expire in 10 minutes.</p>
          <p style="color: #666; font-size: 12px;">If you didn't request this code, please ignore this email.</p>
        </div>
      `;
      const emailText = `Your verification code is: ${otpCode}\n\nThis code will expire in 10 minutes.\n\nIf you didn't request this code, please ignore this email.`;

      const { html: otpHtml, text: otpText } = appendPlatformSecurityEmailFooter(emailHtml, emailText);
      const msg = {
        to: userEmail,
        from: {
          email: SENDGRID_FROM_EMAIL.value(),
          name: SENDGRID_FROM_NAME.value(),
        },
        subject: emailSubject,
        html: otpHtml,
        text: otpText,
      };

      await (getSgMail() as any).send(msg);

      await admin.firestore().collection('users').doc(userId).update({
        lastOTPSentAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      functions.logger.info(`OTP generated and sent to user ${userId} (${userEmail})`);

      return {
        success: true,
        message: 'OTP code sent to your email',
        expiresIn: 600,
      };
    } catch (error: any) {
      functions.logger.error('Error generating OTP:', error);
      if (error instanceof functions.https.HttpsError) {
        throw error;
      }
      throw new functions.https.HttpsError('internal', `Failed to generate OTP: ${error.message}`);
    }
  },
);

export const verifyOTP = functions.https.onCall(async (data: { code: string; purpose?: string }, context) => {
  try {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
    }
    enforceAppCheckOrThrow(context);

    const userId = context.auth.uid;
    const { code, purpose } = data;

    if (!isValidOtpCodeFormat(code)) {
      throw new functions.https.HttpsError('invalid-argument', 'OTP code must be a 6-digit number');
    }

    let otpQuery: admin.firestore.QuerySnapshot | { empty: boolean; docs: admin.firestore.QueryDocumentSnapshot[] };
    try {
      otpQuery = await admin
        .firestore()
        .collection('users')
        .doc(userId)
        .collection('otpCodes')
        .where('used', '==', false)
        .where('purpose', '==', purpose || 'sensitive_action')
        .orderBy('createdAt', 'desc')
        .limit(1)
        .get();
    } catch (queryError: any) {
      if (queryError.message && queryError.message.includes('index')) {
        functions.logger.warn('Composite index missing, using fallback query');
        const fallback = await admin
          .firestore()
          .collection('users')
          .doc(userId)
          .collection('otpCodes')
          .where('used', '==', false)
          .where('purpose', '==', purpose || 'sensitive_action')
          .get();

        if (!fallback.empty) {
          const sortedDocs = fallback.docs.sort((a, b) => {
            const aTime = (a.data().createdAt as admin.firestore.Timestamp)?.toMillis() || 0;
            const bTime = (b.data().createdAt as admin.firestore.Timestamp)?.toMillis() || 0;
            return bTime - aTime;
          });
          otpQuery = {
            empty: sortedDocs.length === 0,
            docs: sortedDocs.slice(0, 1),
          };
        } else {
          otpQuery = fallback;
        }
      } else {
        throw queryError;
      }
    }

    if (otpQuery.empty) {
      throw new functions.https.HttpsError('not-found', 'No valid OTP code found. Please request a new code.');
    }

    const otpDoc = otpQuery.docs[0];
    const otpData = otpDoc.data();

    if (!otpData.expiresAt) {
      functions.logger.error('OTP document missing expiresAt field', { userId, otpId: otpDoc.id });
      throw new functions.https.HttpsError('internal', 'OTP data is invalid. Please request a new code.');
    }

    const expiresAt = (otpData.expiresAt as admin.firestore.Timestamp).toDate();

    if (expiresAt < new Date()) {
      await otpDoc.ref.update({ used: true });
      throw new functions.https.HttpsError('deadline-exceeded', 'OTP code has expired. Please request a new code.');
    }

    const storedCode = String(otpData.code || '');
    const providedCode = String(code || '');

    if (storedCode !== providedCode) {
      functions.logger.warn('OTP code mismatch', {
        userId,
        storedCode: storedCode.substring(0, 2) + '****',
        providedCodeLength: providedCode.length,
      });
      throw new functions.https.HttpsError('permission-denied', 'Invalid OTP code. Please try again.');
    }

    await otpDoc.ref.update({ used: true });

    const oneHourAgo = admin.firestore.Timestamp.fromDate(new Date(Date.now() - 60 * 60 * 1000));
    const oldOtpsQuery = await admin
      .firestore()
      .collection('users')
      .doc(userId)
      .collection('otpCodes')
      .where('createdAt', '<', oneHourAgo)
      .get();

    const batch = admin.firestore().batch();
    oldOtpsQuery.docs.forEach((doc) => {
      batch.delete(doc.ref);
    });
    if (!oldOtpsQuery.empty) {
      await batch.commit();
    }

    functions.logger.info(`OTP verified successfully for user ${userId}`);

    return {
      success: true,
      message: 'OTP code verified successfully',
    };
  } catch (error: any) {
    functions.logger.error('Error verifying OTP:', error);
    if (error instanceof functions.https.HttpsError) {
      throw error;
    }
    throw new functions.https.HttpsError('internal', `Failed to verify OTP: ${error.message}`);
  }
});

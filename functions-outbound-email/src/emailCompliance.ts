import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import * as crypto from 'crypto';
import {
  enforceAppCheckOrThrow,
  enforceRateLimit,
  escapeHtml,
  getFacilityDataForUserOrThrow,
  initializeSendGrid,
  parseEmailUnsubscribeToken,
  sendFacilityEmailWithCompliance,
} from '@sfc/functions-shared';
import { SENDGRID_API_KEY, SENDGRID_FROM_EMAIL, SENDGRID_FROM_NAME, SENDGRID_SECRETS } from './secrets';

/**
 * Callable function: Submit Insurance Claim
 * Allows facility staff to submit an insurance claim for a tenant
 */
export const submitClaim = functions.runWith({ secrets: SENDGRID_SECRETS }).https.onCall(async (data: any, context) => {
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

    if (!facilityId || !tenantId || !incidentDate || !claimType || !description || claimAmount === undefined || deductibleAmount === undefined) {
      throw new functions.https.HttpsError('invalid-argument', 'Missing required fields');
    }

    const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data() as Record<string, unknown> | undefined;
    const userEmail = context.auth.token.email || '';
    const userId = context.auth.uid;

    const isOwner = facilityData?.ownerUid === userId;
    const isManager =
      (facilityData?.managers as Record<string, boolean> | undefined)?.[userId] === true ||
      (facilityData?.roles as Record<string, string> | undefined)?.[userId] === 'manager' ||
      (facilityData?.roles as Record<string, string> | undefined)?.[userId] === 'owner';

    if (!isOwner && !isManager) {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission to submit claims');
    }

    const tenantDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId)
      .get();

    if (!tenantDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Tenant not found');
    }

    const tenantData = tenantDoc.data() as Record<string, unknown> | undefined;
    const insuranceStatus = tenantData?.insuranceStatus;

    if (insuranceStatus !== 'enrolledInTPP' && insuranceStatus !== 'autoEnrolled') {
      throw new functions.https.HttpsError('failed-precondition', 'Tenant must be enrolled in TPP to file a claim');
    }

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

    initializeSendGrid();
    const insuranceSettings = facilityData?.insuranceSettings as Record<string, unknown> | undefined;
    const adjusterEmailToUse = adjusterEmail || (insuranceSettings?.defaultAdjusterEmail as string | undefined);

    if (adjusterEmailToUse) {
      try {
        const emailHtml = `
          <h2>New Insurance Claim Filed</h2>
          <p><strong>Facility:</strong> ${String(facilityData?.name || facilityId)}</p>
          <p><strong>Tenant:</strong> ${String(tenantData?.name || tenantId)}</p>
          <p><strong>Unit:</strong> ${String(tenantData?.unitNumber || 'N/A')}</p>
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

        const claimSend = await sendFacilityEmailWithCompliance(
          {
            to: adjusterEmailToUse,
            from: {
              email: SENDGRID_FROM_EMAIL.value(),
              name: String(facilityData?.name || SENDGRID_FROM_NAME.value()),
            },
            subject: `New Insurance Claim - ${String(facilityData?.name || 'Storage Facility')}`,
          },
          emailHtml,
          null,
          {
            facilityId,
            tenantId,
            facilityName: String(facilityData?.name || 'Storage Facility'),
            facilityAddress: facilityData?.address != null ? String(facilityData.address) : undefined,
            facilityPhone: facilityData?.phone != null ? String(facilityData.phone) : undefined,
          },
        );
        if (claimSend.sent) {
          functions.logger.info(`Claim notification email sent to ${adjusterEmailToUse}`);
        } else {
          functions.logger.info(`Claim notification skipped (unsubscribed): ${adjusterEmailToUse}`);
        }
      } catch (emailError: unknown) {
        const msg = emailError instanceof Error ? emailError.message : String(emailError);
        functions.logger.error(`Error sending claim email: ${msg}`);
      }
    }

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
  } catch (error: unknown) {
    functions.logger.error('Error submitting claim:', error);
    if (error instanceof functions.https.HttpsError) {
      throw error;
    }
    const msg = error instanceof Error ? error.message : String(error);
    throw new functions.https.HttpsError('internal', `Failed to submit claim: ${msg}`);
  }
});

/**
 * One-click / link unsubscribe for facility marketing-style emails (SendGrid List-Unsubscribe target).
 */
export const emailUnsubscribeHttp = functions.runWith({ secrets: SENDGRID_SECRETS }).https.onRequest(async (req, res) => {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.set('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') {
    res.status(204).send('');
    return;
  }

  const sendGridApiKey = SENDGRID_API_KEY.value();
  const token =
    (typeof req.query.token === 'string' && req.query.token) ||
    (typeof (req.body as { token?: string })?.token === 'string' && (req.body as { token?: string }).token) ||
    '';

  const parsed = token ? parseEmailUnsubscribeToken(sendGridApiKey, token) : null;

  const htmlOk =
    '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Unsubscribed</title></head><body style="font-family:system-ui,sans-serif;max-width:520px;margin:48px auto;padding:16px;">' +
    '<h1>Preferences updated</h1>' +
    '<p>You will no longer receive non-essential emails from this facility sent through Storage Facility Creator.</p>' +
    '<p style="color:#666;font-size:14px;">Time-sensitive or legally required messages may still be sent.</p>' +
    '</body></html>';
  const htmlInvalid =
    '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Link invalid</title></head><body style="font-family:system-ui,sans-serif;max-width:520px;margin:48px auto;padding:16px;">' +
    '<h1>Link invalid or expired</h1>' +
    '<p>This unsubscribe link is invalid or has expired. Contact the facility directly to update your email preferences.</p>' +
    '</body></html>';

  if (!parsed) {
    res.set('Content-Type', 'text/html; charset=utf-8');
    res.status(400).send(htmlInvalid);
    return;
  }

  const suppressId = crypto.createHash('sha256').update(`${parsed.facilityId}|${parsed.emailLower}`).digest('hex');
  await admin
    .firestore()
    .collection('facilities')
    .doc(parsed.facilityId)
    .collection('emailSuppressions')
    .doc(suppressId)
    .set(
      {
        emailLower: parsed.emailLower,
        tenantId: parsed.tenantId || null,
        unsubscribedAt: admin.firestore.FieldValue.serverTimestamp(),
        source: 'list_unsubscribe',
      },
      { merge: true },
    );

  res.set('Content-Type', 'text/html; charset=utf-8');
  res.status(200).send(htmlOk);
});

/**
 * Staff: list addresses that unsubscribed from non-essential facility emails (emailSuppressions subcollection).
 */
export const listFacilityEmailSuppressions = functions.https.onCall(async (data: { facilityId?: string }, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);
  const facilityId = data?.facilityId;
  if (!facilityId || typeof facilityId !== 'string') {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }
  await getFacilityDataForUserOrThrow(context.auth.uid, facilityId);
  await enforceRateLimit({
    facilityId,
    key: 'listFacilityEmailSuppressions',
    limit: 60,
    windowSeconds: 60,
    userId: context.auth.uid,
  });

  const snap = await admin
    .firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('emailSuppressions')
    .orderBy('unsubscribedAt', 'desc')
    .limit(500)
    .get();

  const suppressions = snap.docs.map((d) => {
    const x = d.data() as Record<string, unknown>;
    const ts = x.unsubscribedAt as admin.firestore.Timestamp | undefined;
    let unsubscribedAt: string | null = null;
    if (ts && typeof ts.toDate === 'function') {
      unsubscribedAt = ts.toDate().toISOString();
    }
    return {
      suppressId: d.id,
      emailLower: String(x.emailLower ?? ''),
      tenantId: x.tenantId != null ? String(x.tenantId) : null,
      unsubscribedAt,
      source: x.source != null ? String(x.source) : null,
    };
  });

  return { suppressions };
});

/**
 * Staff: remove an email suppression (re-allow facility emails). Optionally sends a confirmation email after removal.
 */
export const removeFacilityEmailSuppression = functions.runWith({ secrets: SENDGRID_SECRETS }).https.onCall(
  async (
    data: { facilityId?: string; suppressId?: string; emailLower?: string; sendConfirmation?: boolean },
    context,
  ) => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }
    enforceAppCheckOrThrow(context);
    const facilityId = data?.facilityId;
    if (!facilityId || typeof facilityId !== 'string') {
      throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
    }
    const sendConfirmation = data?.sendConfirmation !== false;

    let suppressId = typeof data?.suppressId === 'string' ? data.suppressId.trim() : '';
    if (!suppressId && typeof data?.emailLower === 'string' && data.emailLower.trim()) {
      const el = data.emailLower.trim().toLowerCase();
      suppressId = crypto.createHash('sha256').update(`${facilityId}|${el}`).digest('hex');
    }
    if (!suppressId) {
      throw new functions.https.HttpsError('invalid-argument', 'suppressId or emailLower is required');
    }

    const facilityData = (await getFacilityDataForUserOrThrow(
      context.auth.uid,
      facilityId,
    )) as Record<string, unknown>;
    await enforceRateLimit({
      facilityId,
      key: 'removeFacilityEmailSuppression',
      limit: 30,
      windowSeconds: 60,
      userId: context.auth.uid,
    });

    const ref = admin.firestore().collection('facilities').doc(facilityId).collection('emailSuppressions').doc(suppressId);
    const doc = await ref.get();
    if (!doc.exists) {
      throw new functions.https.HttpsError('not-found', 'No unsubscribe record found for this recipient');
    }
    const row = doc.data() as Record<string, unknown>;
    const emailLower = String(row.emailLower ?? '').trim().toLowerCase();
    const tenantId = row.tenantId != null ? String(row.tenantId) : null;
    const priorSource = row.source != null ? String(row.source) : null;

    await ref.delete();

    let confirmationSent = false;
    if (sendConfirmation && emailLower.includes('@')) {
      try {
        let sendGridFromEmail: string;
        try {
          sendGridFromEmail = SENDGRID_FROM_EMAIL.value();
        } catch {
          sendGridFromEmail = '';
        }
        if (!sendGridFromEmail?.trim()) {
          functions.logger.warn('removeFacilityEmailSuppression: SENDGRID_SENDER_EMAIL not set; skip confirmation');
        } else {
          initializeSendGrid();
          const facilityName = String(facilityData.name ?? 'Storage Facility');
          const facilityAddress =
            facilityData.address != null && facilityData.address !== '' ? String(facilityData.address) : undefined;
          const facilityPhone =
            facilityData.phone != null && facilityData.phone !== '' ? String(facilityData.phone) : undefined;

          const htmlBody =
            '<p>You are set to receive non-essential emails from <strong>' +
            escapeHtml(facilityName) +
            '</strong> again. These messages are sent through Storage Facility Creator.</p>' +
            '<p style="font-size:14px;color:#444;">If you did not ask to receive these emails again, contact the facility directly.</p>';

          const result = await sendFacilityEmailWithCompliance(
            {
              to: emailLower,
              from: { email: sendGridFromEmail.trim(), name: facilityName },
              subject: `Email preferences updated - ${facilityName}`,
            },
            htmlBody,
            null,
            {
              facilityId,
              tenantId: tenantId || null,
              facilityName,
              facilityAddress,
              facilityPhone,
            },
          );
          confirmationSent = result.sent;
        }
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        functions.logger.error('removeFacilityEmailSuppression: confirmation email failed', {
          error: msg,
          facilityId,
          emailLower,
        });
      }
    }

    let actorEmail = '';
    try {
      const u = await admin.auth().getUser(context.auth!.uid);
      actorEmail = u.email || '';
    } catch (_) {
      /* ignore */
    }
    let actorRole = 'staff';
    if (facilityData.ownerUid === context.auth.uid) {
      actorRole = 'owner';
    } else {
      const roles = (facilityData.roles as Record<string, string> | undefined) || {};
      const r = roles[context.auth.uid!];
      if (r) actorRole = r;
      else if ((facilityData.managers as Record<string, boolean> | undefined)?.[context.auth.uid!] === true) {
        actorRole = 'manager';
      }
    }

    await admin
      .firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('auditLogs')
      .add({
        eventType: 'communication.emailSuppressionRemoved',
        action: 'communication.emailSuppressionRemoved',
        actorUid: context.auth.uid,
        actorEmail,
        actorRole,
        userId: context.auth.uid,
        userEmail: actorEmail,
        targetType: 'emailSuppression',
        targetId: suppressId,
        entityType: 'emailSuppression',
        entityId: suppressId,
        facilityId,
        tenantId: tenantId || null,
        metadata: {
          emailLower,
          confirmationSent,
          priorSource,
          sendConfirmationRequested: sendConfirmation,
        },
        changes: {},
        timestamp: admin.firestore.FieldValue.serverTimestamp(),
      });

    return { ok: true, confirmationSent };
  },
);

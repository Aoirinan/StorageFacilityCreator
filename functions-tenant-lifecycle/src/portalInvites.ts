import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import {
  buildTenantPortalInviteEmail,
  enforceAppCheckOrThrow,
  generatePortalAccessCode,
  getFacilityDataForUserOrThrow,
  getPublicAppUrl,
  initializeSendGrid,
  sendFacilityEmailWithCompliance,
} from '@sfc/functions-shared';
import { SENDGRID_FROM_EMAIL, SENDGRID_FROM_NAME, SENDGRID_SECRETS } from './secrets';

const MAX_INVITES_PER_CALL = 200;

interface SendTenantPortalInvitesData {
  facilityId?: string;
  /** Specific tenants, or omit with allActive=true to invite every active tenant. */
  tenantIds?: string[];
  allActive?: boolean;
}

export interface PortalInviteSummary {
  requested: number;
  sent: number;
  /** Dropped by the pre-launch customer contact gate (appConfig/outbound). */
  blockedPrelaunch: number;
  skippedNoEmail: number;
  unsubscribed: number;
  failed: number;
  codesGenerated: number;
}

/**
 * Email selected tenants (or every active tenant) their portal link and
 * access code, enabling the portal and minting a code where one is missing.
 *
 * Goes through the shared facility-email helper, so the pre-launch customer
 * contact gate applies: before launch this reports blockedPrelaunch instead
 * of sending, except to super-admin and allowlisted test addresses.
 */
export const sendTenantPortalInvites = functions
  .runWith({ secrets: SENDGRID_SECRETS, timeoutSeconds: 300, memory: '512MB' })
  .https.onCall(async (data: SendTenantPortalInvitesData, context): Promise<PortalInviteSummary> => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }
    enforceAppCheckOrThrow(context);

    const facilityId = (data?.facilityId || '').toString().trim();
    if (!facilityId) {
      throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
    }
    const facility = await getFacilityDataForUserOrThrow(context.auth.uid, facilityId);

    const db = admin.firestore();
    const tenantsRef = db.collection('facilities').doc(facilityId).collection('tenants');

    let tenantDocs: admin.firestore.DocumentSnapshot[] = [];
    if (data?.allActive) {
      const snap = await tenantsRef.where('isActive', '==', true).limit(MAX_INVITES_PER_CALL).get();
      tenantDocs = snap.docs;
    } else {
      const ids = Array.isArray(data?.tenantIds)
        ? data!.tenantIds!.map((id) => String(id).trim()).filter(Boolean).slice(0, MAX_INVITES_PER_CALL)
        : [];
      if (ids.length === 0) {
        throw new functions.https.HttpsError('invalid-argument', 'tenantIds or allActive is required');
      }
      tenantDocs = (await Promise.all(ids.map((id) => tenantsRef.doc(id).get()))).filter((d) => d.exists);
    }

    const facilityName = ((facility.name as string | undefined) || 'Your storage facility').trim();
    const facilityPhone = (facility.phone as string | undefined) || null;
    const stripeStatus = (facility.stripeStatus as Record<string, unknown> | undefined) || {};
    const autopayAvailable =
      !!(facility.stripeConnectAccountId as string | undefined) &&
      (stripeStatus.state === 'ENABLED' || facility.stripeConnectOnboardingComplete === true);
    const portalUrl = `${getPublicAppUrl()}/#/tenant-portal`;

    const summary: PortalInviteSummary = {
      requested: tenantDocs.length,
      sent: 0,
      blockedPrelaunch: 0,
      skippedNoEmail: 0,
      unsubscribed: 0,
      failed: 0,
      codesGenerated: 0,
    };

    initializeSendGrid();

    for (const doc of tenantDocs) {
      const t = (doc.data() || {}) as Record<string, unknown>;
      const email = ((t.email as string | undefined) || '').trim();
      if (!email || email.toLowerCase().endsWith('@example.com')) {
        summary.skippedNoEmail += 1;
        continue;
      }

      let accessCode = ((t.portalAccessCode as string | undefined) || '').trim();
      const updates: Record<string, unknown> = {};
      if (!accessCode) {
        accessCode = generatePortalAccessCode();
        updates.portalAccessCode = accessCode;
        summary.codesGenerated += 1;
      }
      if (t.portalEnabled !== true) updates.portalEnabled = true;
      if (Object.keys(updates).length) {
        updates.updatedAt = admin.firestore.FieldValue.serverTimestamp();
        await doc.ref.update(updates);
      }

      const content = buildTenantPortalInviteEmail({
        facilityName,
        tenantName: (t.name as string | undefined) || '',
        unitNumber: (t.unitNumber as string | undefined) || null,
        email,
        accessCode,
        portalUrl,
        facilityPhone,
        autopayAvailable,
      });

      try {
        const result = await sendFacilityEmailWithCompliance(
          {
            to: email,
            from: { email: SENDGRID_FROM_EMAIL.value(), name: facilityName || SENDGRID_FROM_NAME.value() },
            subject: content.subject,
          },
          content.html,
          content.text,
          {
            facilityId,
            tenantId: doc.id,
            facilityName,
            facilityAddress: (facility.address as string | undefined) || null,
            facilityPhone,
          },
        );
        if (result.sent) {
          summary.sent += 1;
          await doc.ref.update({
            portalInviteSentAt: admin.firestore.FieldValue.serverTimestamp(),
            portalInviteCount: admin.firestore.FieldValue.increment(1),
          });
        } else if (result.blocked === 'prelaunch') {
          summary.blockedPrelaunch += 1;
        } else {
          summary.unsubscribed += 1;
        }
      } catch (error) {
        summary.failed += 1;
        functions.logger.error('Portal invite failed', {
          facilityId,
          tenantId: doc.id,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }

    functions.logger.info('Portal invites processed', { facilityId, by: context.auth.uid, ...summary });
    return summary;
  });

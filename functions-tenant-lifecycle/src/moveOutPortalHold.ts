import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import * as crypto from 'crypto';
import { sendFacilityEmailWithCompliance } from '@sfc/functions-shared';
import { SENDGRID_FROM_EMAIL, SENDGRID_FROM_NAME, SENDGRID_SECRETS } from './secrets';
import { enforceAppCheckOrThrow, enforceRateLimit, writeAuditLog } from './guardrails';
/**
 * Process move-out workflow
 * Handles move-out in a transaction-safe way: updates contract, frees unit, calculates charges/refunds
 */
export const processMoveOut = functions.runWith({ secrets: SENDGRID_SECRETS }).https.onCall(async (data: any, context) => {
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
    const refundResult = null;
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
        const moveOutHtml = `
            <h2>Move-Out Confirmation</h2>
            <p>Dear ${tenantData.name || 'Tenant'},</p>
            <p>This confirms that your move-out has been processed on ${new Date(moveOutDate).toLocaleDateString()}.</p>
            ${moveOutCharges > 0 ? `<p><strong>Final Charges:</strong> $${moveOutCharges.toFixed(2)}</p>` : ''}
            ${moveOutRefund > 0 ? `<p><strong>Refund Amount:</strong> $${moveOutRefund.toFixed(2)}</p>` : ''}
            ${moveOutNotes ? `<p><strong>Notes:</strong> ${moveOutNotes}</p>` : ''}
            <p>Thank you for your business.</p>
          `;
        await sendFacilityEmailWithCompliance(
          {
            to: tenantData.email,
            from: {
              email: SENDGRID_FROM_EMAIL.value(),
              name: facilityData?.name || SENDGRID_FROM_NAME.value(),
            },
            subject: `Move-Out Confirmation - ${facilityData?.name || 'Storage Facility'}`,
          },
          moveOutHtml,
          null,
          {
            facilityId,
            tenantId,
            facilityName: facilityData?.name || 'Storage Facility',
            facilityAddress: facilityData?.address,
            facilityPhone: facilityData?.phone,
          },
        );
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
 * Creates a reservation hold for a logged-in tenant-portal user renting an additional unit.
 * Authenticates via tenant portal email + access code and stamps trusted linking metadata.
 */
export const createTenantPortalAdditionalUnitHold = functions.https.onCall(async (data: any) => {
  const email = (data?.email || '').toString().trim().toLowerCase();
  const accessCode = (data?.accessCode || '').toString().trim();
  const facilityId = (data?.facilityId || '').toString().trim();
  const unitId = (data?.unitId || '').toString().trim();
  const unitNumber = (data?.unitNumber || '').toString().trim();
  const moveInDate = data?.moveInDate;
  const holdMinutesRaw = Number(data?.holdMinutes);
  const holdMinutes = Math.max(1, Math.min(Number.isFinite(holdMinutesRaw) ? holdMinutesRaw : 10, 60));

  if (!email || !accessCode || !facilityId || !unitId) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      'email, accessCode, facilityId, and unitId are required',
    );
  }

  // Authenticate against tenant portal credentials.
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

  const sourceTenantDoc = tenantSnapshot.docs[0];
  const sourceTenantData = sourceTenantDoc.data() as Record<string, any>;
  const sourceFacilityRef = sourceTenantDoc.ref.parent.parent;
  if (!sourceFacilityRef || sourceFacilityRef.id !== facilityId) {
    throw new functions.https.HttpsError(
      'permission-denied',
      'Unit facility does not match this portal account',
    );
  }

  const now = new Date();
  const expiresAt = new Date(now.getTime() + holdMinutes * 60 * 1000);
  const moveInToken = crypto.randomBytes(24).toString('hex');
  const portalAccountId = (sourceTenantData.portalAccountId || '').toString().trim() || sourceTenantDoc.id;

  const unitRef = admin.firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('units')
    .doc(unitId);
  const holdRef = admin.firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('mapEngine')
    .doc('activeHolds')
    .collection('items')
    .doc(unitId);
  const reservationRef = admin.firestore().collection('publicReservations').doc();

  await admin.firestore().runTransaction(async (tx) => {
    const unitSnap = await tx.get(unitRef);
    if (!unitSnap.exists) {
      throw new functions.https.HttpsError('not-found', 'Unit not found');
    }
    const unitData = unitSnap.data() as Record<string, any>;
    const unitStatus = String(unitData.status || '').toLowerCase();
    if (unitStatus !== 'available' && unitStatus !== 'reserved') {
      throw new functions.https.HttpsError('failed-precondition', 'Unit is not currently available');
    }

    const holdSnap = await tx.get(holdRef);
    if (holdSnap.exists) {
      const holdData = holdSnap.data() as Record<string, any>;
      const holdExpiresAt = holdData.expiresAt as admin.firestore.Timestamp | undefined;
      if (holdExpiresAt && holdExpiresAt.toDate() > now) {
        throw new functions.https.HttpsError('already-exists', 'Unit is currently in checkout');
      }
    }

    tx.set(reservationRef, {
      facilityId,
      unitId,
      unitNumber: unitNumber || unitData.unitNumber || '',
      email,
      phone: sourceTenantData.phone ? String(sourceTenantData.phone).trim() : null,
      name: sourceTenantData.name ? String(sourceTenantData.name).trim() : null,
      status: 'pending',
      reservedAt: admin.firestore.FieldValue.serverTimestamp(),
      expiresAt: admin.firestore.Timestamp.fromDate(expiresAt),
      moveInDate: moveInDate ? admin.firestore.Timestamp.fromDate(new Date(moveInDate)) : null,
      moveInToken,
      metadata: {
        holdType: 'checkout',
        holdMinutes,
        source: 'tenant_portal_additional_unit',
        portalTenantId: sourceTenantDoc.id,
        portalAccountId,
      },
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    tx.set(holdRef, {
      facilityId,
      unitId,
      reservationId: reservationRef.id,
      status: 'pending',
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      expiresAt: admin.firestore.Timestamp.fromDate(expiresAt),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    if (!sourceTenantData.portalAccountId) {
      tx.update(sourceTenantDoc.ref, {
        portalAccountId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  });

  return {
    success: true,
    reservationId: reservationRef.id,
    moveInToken,
    expiresAt: expiresAt.toISOString(),
  };
});


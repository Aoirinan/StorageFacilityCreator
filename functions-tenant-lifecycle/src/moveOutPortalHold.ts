import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import * as crypto from 'crypto';
import {
  sendFacilityEmailWithCompliance,
  authenticatePortalTenantForFacility,
  extractCallableClientIp,
  enabledOnlineUnitTypes,
  isUnitOfferedOnline,
  isUnitTypeOfferedOnline,
} from '@sfc/functions-shared';
import { SENDGRID_FROM_EMAIL, SENDGRID_FROM_NAME, SENDGRID_SECRETS } from './secrets';
import { enforceAppCheckOrThrow, enforceRateLimit, writeAuditLog } from './guardrails';
import { tenantFieldsAfterMoveOut } from './moveOutTenantFields';
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
      // Already moved out (a retry after a dropped connection, which
      // re-enables the screen's button): nothing is written again. A second
      // run took the unit's rent off the tenant again (250 to 150 to 50) and
      // posted the move-out charges twice.
      const contract = contractDoc.data() || {};
      if (contract.moveOutStatus === 'completed') {
        return { success: true, alreadyCompleted: true, contractId, unitId, tenantId };
      }
      if (contract.isActive === false) {
        throw new functions.https.HttpsError(
          'failed-precondition',
          'This contract is archived or has already ended, so nothing was moved out. ' +
            'To free the unit, use Units > unit > Unassign Tenant.',
        );
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
      const unitData = unitDoc.data() || {};

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

      // Another tenant's unit is not this tenant's to free (the screen
      // falls back to the facility's first unit when the tenant's unit
      // number matches none): it freed that tenant's unit and took its rent
      // off this one.
      const holder = typeof unitData.tenantId === 'string' ? unitData.tenantId : '';
      if (holder && holder !== tenantId && String(unitData.status ?? '') !== 'available') {
        throw new functions.https.HttpsError(
          'failed-precondition',
          `Unit ${String(unitData.unitNumber ?? '').trim()} is assigned to ` +
            `${String(unitData.tenantName ?? '').trim() || 'another tenant'}, not this tenant, so nothing was moved out.`,
        );
      }

      // 3b. Does this tenant still hold another unit?
      //
      // Moving out of one unit was unconditionally marking the whole tenant
      // inactive. A tenant renting two units who vacates one would be
      // deactivated entirely — and the autopay worker skips inactive tenants,
      // so rent on the unit they still occupy would silently stop being
      // collected. Their units, not their contracts, decide it, as in the
      // app: a unit given by Edit Tenant or Units > Assign Tenant has no
      // contract of its own. Read before any write.
      const linkedUnitsSnap = await transaction.get(
        admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('units')
          .where('tenantId', '==', tenantId),
      );
      const settled = tenantFieldsAfterMoveOut({
        tenantId,
        tenant: tenantDoc.data() || {},
        unitId,
        unit: unitData,
        linkedUnits: linkedUnitsSnap.docs.map((d) => ({ id: d.id, data: d.data() })),
      });
      // Their last unit: their gate codes go off with them, as the app's
      // move-out does, or an inactive tenant kept a working code.
      const gateAccessSnap = settled.endsTenancy
        ? await transaction.get(
          admin.firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('gateAccess')
            .where('tenantId', '==', tenantId),
        )
        : null;

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

      // 6. Update tenant — only end the tenancy if this was their last unit;
      // otherwise this unit's rent comes off their rate (tenantFieldsAfterMoveOut).
      transaction.update(tenantRef, {
        ...settled.fields,
        updatedAt: now,
      });
      for (const gate of gateAccessSnap?.docs ?? []) {
        if (gate.data().isActive === false) continue;
        transaction.update(gate.ref, { isActive: false, updatedAt: now, updatedBy: userId });
      }

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
        alreadyCompleted: false,
        contractId,
        unitId,
        tenantId,
        rentNotice: settled.rentNotice,
        rentWarning: settled.rentWarning,
      };
    });

    if (result.alreadyCompleted) {
      return {
        ...result,
        refundProcessed: false,
        message: 'This move-out was already completed, so nothing was charged or changed again.',
      };
    }

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
    // Refusals written for the owner keep their code and words.
    if (error instanceof functions.https.HttpsError && error.code === 'failed-precondition') throw error;
    throw new functions.https.HttpsError('internal', `Failed to process move-out: ${error.message}`);
  }
});

/** The unit types the facility opened to online rental (settings/public); empty means all. */
async function readEnabledOnlineUnitTypes(facilityId: string): Promise<string[]> {
  const settingsSnap = await admin.firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('settings')
    .doc('public')
    .get();
  return enabledOnlineUnitTypes(settingsSnap.data());
}

/**
 * Whether a portal tenant may rent [unit] online, apart from its status,
 * which each caller checks: the owner offers it online, its type is one the
 * owner opened to online rental (as on the public map), and it is not
 * deactivated. The list and the hold both use this, so a unit the list
 * leaves out cannot be held by sending its id.
 */
function isOfferedToPortalTenant(unit: Record<string, unknown>, enabledTypes: string[]): boolean {
  return unit.isActive !== false && isUnitOfferedOnline(unit) && isUnitTypeOfferedOnline(unit, enabledTypes);
}

/**
 * Lists units available for online/additional rental for a tenant portal session.
 * Direct Firestore reads are blocked for portal users; this callable validates email + access code
 * then reads inventory with the Admin SDK (same trust boundary as createTenantPortalAdditionalUnitHold).
 *
 * Only units the owner offers online (isOfferedToPortalTenant): the portal
 * rents through the same online move-in and checkout as the public rental
 * page, so a unit left off the public website, archived or kept for internal
 * use is not offered here either.
 */
export const tenantPortalListAvailableUnits = functions.https.onCall(async (data: any, context) => {
  const email = (data?.email || '').toString().trim().toLowerCase();
  const accessCode = (data?.accessCode || '').toString().trim();
  const facilityId = (data?.facilityId || '').toString().trim();
  const clientIp = extractCallableClientIp(context.rawRequest);

  if (!facilityId) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      'email, accessCode, and facilityId are required',
    );
  }

  await authenticatePortalTenantForFacility(email, accessCode, facilityId, clientIp);

  const enabledTypes = await readEnabledOnlineUnitTypes(facilityId);
  const unitsSnap = await admin
    .firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('units')
    .get();

  const units: Array<{
    id: string;
    unitNumber: string;
    unitType: string;
    monthlyRate: number;
  }> = [];

  unitsSnap.forEach((doc) => {
    const d = doc.data() as Record<string, any>;
    if (!isOfferedToPortalTenant(d, enabledTypes)) {
      return;
    }
    const st = String(d.status || '').toLowerCase();
    if (st !== 'available') {
      return;
    }
    const rawRate = d.monthlyRate;
    const monthlyRate =
      typeof rawRate === 'number'
        ? rawRate
        : typeof rawRate === 'string'
          ? Number.parseFloat(rawRate) || 0
          : 0;
    units.push({
      id: doc.id,
      unitNumber: String(d.unitNumber ?? ''),
      unitType: String(d.unitType ?? 'standard'),
      monthlyRate,
    });
  });

  units.sort((a, b) => {
    const byRate = a.monthlyRate - b.monthlyRate;
    if (byRate !== 0) {
      return byRate;
    }
    return a.unitNumber.localeCompare(b.unitNumber, undefined, { numeric: true });
  });

  return { units };
});

/**
 * Creates a reservation hold for a logged-in tenant-portal user renting an additional unit.
 * Authenticates via tenant portal email + access code and stamps trusted linking metadata.
 */
export const createTenantPortalAdditionalUnitHold = functions.https.onCall(async (data: any, context) => {
  const email = (data?.email || '').toString().trim().toLowerCase();
  const accessCode = (data?.accessCode || '').toString().trim();
  const facilityId = (data?.facilityId || '').toString().trim();
  const unitId = (data?.unitId || '').toString().trim();
  const unitNumber = (data?.unitNumber || '').toString().trim();
  const moveInDate = data?.moveInDate;
  const holdMinutesRaw = Number(data?.holdMinutes);
  const holdMinutes = Math.max(1, Math.min(Number.isFinite(holdMinutesRaw) ? holdMinutesRaw : 10, 60));
  const clientIp = extractCallableClientIp(context.rawRequest);

  if (!facilityId || !unitId) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      'email, accessCode, facilityId, and unitId are required',
    );
  }

  const session = await authenticatePortalTenantForFacility(email, accessCode, facilityId, clientIp);
  const sourceTenantDoc = session.tenantDoc;
  const sourceTenantData = session.tenantData as Record<string, any>;
  const enabledTypes = await readEnabledOnlineUnitTypes(facilityId);

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
    // The list above leaves these units out, but a unit id can be sent
    // directly: every unit's id is in the public map doc. Same test as the
    // list, which the hold did not share: it took deactivated units and
    // unit types the owner had not opened to online rental.
    if ((unitStatus !== 'available' && unitStatus !== 'reserved') || !isOfferedToPortalTenant(unitData, enabledTypes)) {
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


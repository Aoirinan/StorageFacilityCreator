import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

export type PersistOffSessionChargeParams = {
  facilityId: string;
  tenantId: string;
  amountNum: number;
  amountCents: number;
  paymentIntentId: string;
  paymentIntentStatus: string;
  customerId: string;
  connectAccountId: string;
  description: string | undefined;
  actorUid: string;
};

/**
 * Writes tenant payment, facility payment, ledger, and tenantCharges after a succeeded off-session PI.
 * Returns a user-facing warning if Firestore fails (charge already succeeded in Stripe).
 */
export async function persistOffSessionChargeRecords(
  params: PersistOffSessionChargeParams,
): Promise<{ recordingWarning?: string }> {
  const {
    facilityId,
    tenantId,
    amountNum,
    amountCents,
    paymentIntentId,
    paymentIntentStatus,
    customerId,
    connectAccountId,
    description,
    actorUid,
  } = params;

  const now = admin.firestore.FieldValue.serverTimestamp();

  try {
    const tenantPaymentsRef = admin.firestore()
      .collection('facilities').doc(facilityId)
      .collection('tenants').doc(tenantId)
      .collection('payments');
    const paymentDocRef = tenantPaymentsRef.doc();
    await paymentDocRef.set({
      facilityId,
      tenantId,
      type: 'one_time',
      amountCents,
      currency: 'usd',
      stripeObjectId: paymentIntentId,
      status: 'succeeded',
      chargeType: 'tenant_one_time_card_on_file',
      description: description || `One-time payment`,
      createdAt: now,
      updatedAt: now,
      failureCode: null,
      failureMessage: null,
    });

    const facilityPaymentsRef = admin.firestore().collection('facilities').doc(facilityId).collection('payments');
    const facilityPaymentRef = await facilityPaymentsRef.add({
      tenantId,
      facilityId,
      contractId: '',
      amount: amountNum,
      status: 'completed',
      method: 'stripe',
      paidAt: now,
      paidDate: now,
      externalPaymentId: paymentIntentId,
      transactionId: paymentIntentId,
      createdAt: now,
      updatedAt: now,
      createdBy: actorUid,
      isActive: true,
    });

    const ledgerRef = admin.firestore().collection('facilities').doc(facilityId).collection('ledgers').doc();
    await ledgerRef.set({
      tenantId,
      facilityId,
      type: 'payment',
      amount: -amountNum,
      description: `Payment via Stripe - ${paymentIntentId}`,
      referenceId: facilityPaymentRef.id,
      entryDate: now,
      status: 'posted',
      createdAt: now,
      createdBy: actorUid,
      metadata: { paymentIntentId },
    });

    const chargeRef = admin.firestore().collection('tenantCharges').doc();
    await chargeRef.set({
      facilityId,
      tenantId,
      stripePaymentIntentId: paymentIntentId,
      stripeCustomerId: customerId,
      stripeConnectedAccountId: connectAccountId,
      amount: amountNum,
      currency: 'usd',
      status: paymentIntentStatus,
      description: description || `One-time payment for tenant ${tenantId}`,
      metadata: {
        chargeType: 'tenant_one_time_card_on_file',
        userId: actorUid,
        paymentDocId: paymentDocRef.id,
      },
      createdAt: now,
      updatedAt: now,
    });

    functions.logger.info(`Off-session charge recorded: ${paymentIntentId} for tenant ${tenantId}`);
    return {};
  } catch (persistErr: any) {
    functions.logger.error('chargeTenantOffSession: Stripe succeeded but Firestore persist failed', {
      facilityId,
      tenantId,
      paymentIntentId,
      error: persistErr?.message,
      stack: persistErr?.stack,
    });
    return {
      recordingWarning:
        'Your card was charged successfully, but saving the receipt in the app failed. ' +
        `Give support this payment ID: ${paymentIntentId}`,
    };
  }
}

import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import { writeAuditLog } from '@sfc/functions-shared';

export async function recordSucceededStripePaymentAndAudit(options: {
  facilityId: string;
  tenantId: string;
  amount: number;
  paymentIntent: Stripe.PaymentIntent;
  stripeConnectAccountId: string | undefined;
  idempotencyKey: string | undefined;
  actorUid: string;
}): Promise<{
  success: true;
  transactionId: string;
  amount: number;
  status: string;
  paymentId: string;
}> {
  const { facilityId, tenantId, amount, paymentIntent, stripeConnectAccountId, idempotencyKey, actorUid } = options;

  const paymentRef = admin.firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('payments')
    .doc();

  await paymentRef.set({
    tenantId,
    facilityId,
    amount,
    status: 'paid',
    method: 'stripe',
    paidAt: admin.firestore.FieldValue.serverTimestamp(),
    paidDate: admin.firestore.FieldValue.serverTimestamp(),
    transactionId: paymentIntent.id,
    externalPaymentId: paymentIntent.id,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    createdBy: actorUid,
    isActive: true,
    metadata: {
      idempotencyKey,
      stripeConnectAccountId: stripeConnectAccountId || null,
    },
  });

  if (idempotencyKey) {
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('idempotencyKeys')
      .doc(idempotencyKey)
      .set({
        paymentId: paymentRef.id,
        paymentIntentId: paymentIntent.id,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        facilityId,
        tenantId,
        amount,
      });
  }

  await writeAuditLog(facilityId, {
    eventType: 'payment.charged',
    actorUid,
    targetType: 'payment',
    targetId: paymentIntent.id,
    tenantId,
    after: {
      amount,
      status: 'succeeded',
      paymentIntentId: paymentIntent.id,
      paymentId: paymentRef.id,
    },
    metadata: {
      method: 'stripe',
      stripeConnectAccountId: stripeConnectAccountId || null,
      ...(idempotencyKey ? { idempotencyKey } : {}),
    },
  });

  return {
    success: true,
    transactionId: paymentIntent.id,
    amount: amount,
    status: paymentIntent.status,
    paymentId: paymentRef.id,
  };
}

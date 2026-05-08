import * as admin from 'firebase-admin';

export async function isStripeEventProcessed(eventId: string): Promise<boolean> {
  if (!eventId) return false;
  const doc = await admin.firestore().collection('stripeWebhookEvents').doc(eventId).get();
  return doc.exists;
}

export async function markStripeEventProcessed(
  eventId: string,
  eventType: string,
  account?: string,
  facilityId?: string,
  tenantId?: string,
): Promise<void> {
  if (!eventId) return;
  await admin.firestore().collection('stripeWebhookEvents').doc(eventId).set(
    {
      eventType,
      account: account || null,
      facilityId: facilityId || null,
      tenantId: tenantId || null,
      processedAt: admin.firestore.FieldValue.serverTimestamp(),
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
}

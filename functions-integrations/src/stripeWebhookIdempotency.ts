import * as admin from 'firebase-admin';
import {
  buildStripeEventProcessedFields,
  shouldCheckStripeEventIdempotency,
  STRIPE_WEBHOOK_EVENTS_COLLECTION,
  isStripeEventAlreadyProcessed,
} from './stripeWebhookIdempotencyHelpers';

export async function isStripeEventProcessed(eventId: string): Promise<boolean> {
  if (!shouldCheckStripeEventIdempotency(eventId)) return false;
  const doc = await admin.firestore().collection(STRIPE_WEBHOOK_EVENTS_COLLECTION).doc(eventId).get();
  return isStripeEventAlreadyProcessed(doc.exists);
}

export async function markStripeEventProcessed(
  eventId: string,
  eventType: string,
  account?: string,
  facilityId?: string,
  tenantId?: string,
): Promise<void> {
  if (!shouldCheckStripeEventIdempotency(eventId)) return;
  const fields = buildStripeEventProcessedFields(eventType, account, facilityId, tenantId);
  await admin.firestore().collection(STRIPE_WEBHOOK_EVENTS_COLLECTION).doc(eventId).set(
    {
      ...fields,
      processedAt: admin.firestore.FieldValue.serverTimestamp(),
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
}

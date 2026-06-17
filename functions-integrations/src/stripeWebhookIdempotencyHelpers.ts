export const STRIPE_WEBHOOK_EVENTS_COLLECTION = 'stripeWebhookEvents';

export function shouldCheckStripeEventIdempotency(eventId: string): boolean {
  return eventId.length > 0;
}

export function isStripeEventAlreadyProcessed(docExists: boolean): boolean {
  return docExists;
}

export function buildStripeEventProcessedFields(
  eventType: string,
  account?: string,
  facilityId?: string,
  tenantId?: string,
): {
  eventType: string;
  account: string | null;
  facilityId: string | null;
  tenantId: string | null;
} {
  return {
    eventType,
    account: account || null,
    facilityId: facilityId || null,
    tenantId: tenantId || null,
  };
}

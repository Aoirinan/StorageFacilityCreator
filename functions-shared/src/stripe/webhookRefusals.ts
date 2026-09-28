/**
 * Where the Stripe webhook records refused money events from connected
 * accounts (functions-integrations connectedAccountGuard.ts), one row per
 * account and Stripe object, with the facility, tenant, amount and what a
 * super admin should do. Shared so the platform and facility purges delete
 * the rows too: each carries a facilityId, a tenantId and an amount.
 */
export const STRIPE_WEBHOOK_REFUSALS_COLLECTION = 'stripeWebhookRefusals';

/**
 * Stripe Connect status state: DISCONNECTED | ONBOARDING_INCOMPLETE | ENABLED | ACTION_REQUIRED
 * Used to gate tenant payment UI; only ENABLED allows Stripe Elements / card entry.
 */
export type StripeConnectState = 'DISCONNECTED' | 'ONBOARDING_INCOMPLETE' | 'ENABLED' | 'ACTION_REQUIRED';

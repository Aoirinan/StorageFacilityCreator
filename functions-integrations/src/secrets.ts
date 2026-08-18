import { defineSecret, defineString } from 'firebase-functions/params';

import type { QuickBooksConfig } from './accounting/quickbooks';

/** Platform Stripe secrets (same names as default functions / admin). */
export const STRIPE_SECRET_KEY = defineSecret('STRIPE_SECRET_KEY');
export const STRIPE_WEBHOOK_SECRET = defineSecret('STRIPE_WEBHOOK_SECRET');
/**
 * Signing secret for a second webhook destination, used for connected-account
 * events. Stripe fixes "Events from" when a destination is created, so
 * receiving Connect events needs a separate destination, which signs with its
 * own secret. Optional: unset simply means no second destination yet.
 */
export const STRIPE_WEBHOOK_SECRET_CONNECT = defineSecret('STRIPE_WEBHOOK_SECRET_CONNECT');
export const STRIPE_PUBLISHABLE_KEY = defineSecret('STRIPE_PUBLISHABLE_KEY');
/** Stripe Connect OAuth client id (`ca_…`); optional for `createStripeConnectAccount` logging / future OAuth. */
export const STRIPE_CONNECT_CLIENT_ID = defineSecret('STRIPE_CONNECT_CLIENT_ID');

export const STRIPE_SECRETS = [STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, STRIPE_PUBLISHABLE_KEY];
/** Include the optional Connect destination secret where webhooks are verified. */
export const STRIPE_WEBHOOK_SECRETS = [...STRIPE_SECRETS, STRIPE_WEBHOOK_SECRET_CONNECT];

/** Platform Stripe secrets + Connect client id (no webhook secret required). */
export const STRIPE_SECRETS_WITH_CONNECT = [
  STRIPE_SECRET_KEY,
  STRIPE_PUBLISHABLE_KEY,
  STRIPE_CONNECT_CLIENT_ID,
];

export const QUICKBOOKS_CLIENT_ID = defineSecret('QUICKBOOKS_CLIENT_ID');
export const QUICKBOOKS_CLIENT_SECRET = defineSecret('QUICKBOOKS_CLIENT_SECRET');
/** Intuit OAuth redirect URL; empty until set in Firebase params / `.env` for local discovery. */
export const QUICKBOOKS_REDIRECT_URI = defineString('QUICKBOOKS_REDIRECT_URI', { default: '' });
export const QUICKBOOKS_ENV = defineString('QUICKBOOKS_ENV', { default: 'sandbox' });

export const QUICKBOOKS_SECRETS = [QUICKBOOKS_CLIENT_ID, QUICKBOOKS_CLIENT_SECRET];

/** Egress for Intuit OAuth + QBO API must match Cloud NAT static IP (Intuit "where hosted"). */
export const QUICKBOOKS_VPC_CONNECTOR = {
  vpcConnector: 'sfc-serverless-connector',
  vpcConnectorEgressSettings: 'ALL_TRAFFIC' as const,
};

export function getQuickBooksConfig(): QuickBooksConfig {
  const envRaw = (QUICKBOOKS_ENV.value() || 'sandbox').trim().toLowerCase();
  const clientId = (QUICKBOOKS_CLIENT_ID.value() ?? '').trim();
  const clientSecret = (QUICKBOOKS_CLIENT_SECRET.value() ?? '').trim();
  return {
    clientId,
    clientSecret,
    redirectUri: (QUICKBOOKS_REDIRECT_URI.value() || '').trim(),
    environment: envRaw === 'production' ? 'production' : 'sandbox',
  };
}

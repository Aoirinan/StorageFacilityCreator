import { defineSecret, defineString } from 'firebase-functions/params';

import type { QuickBooksConfig } from './accounting/quickbooks';

/** Platform Stripe secrets (same names as default functions / admin). */
export const STRIPE_SECRET_KEY = defineSecret('STRIPE_SECRET_KEY');
export const STRIPE_WEBHOOK_SECRET = defineSecret('STRIPE_WEBHOOK_SECRET');
export const STRIPE_PUBLISHABLE_KEY = defineSecret('STRIPE_PUBLISHABLE_KEY');
export const STRIPE_SECRETS = [STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, STRIPE_PUBLISHABLE_KEY];

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

import * as functions from 'firebase-functions/v1';
import type Stripe from 'stripe';

import { requireStripeKeysProvider } from './keysRegistry';

/**
 * Validates that Stripe secret and publishable keys are same mode (both test or both live).
 */
export function validateStripeKeyMode(secretKey: string, publishableKey: string): void {
  const skLive = secretKey.startsWith('sk_live_');
  const skTest = secretKey.startsWith('sk_test_');
  const pkLive = publishableKey.startsWith('pk_live_');
  const pkTest = publishableKey.startsWith('pk_test_');
  if (skLive && pkLive) {
    functions.logger.info('Stripe mode: LIVE');
    return;
  }
  if (skTest && pkTest) {
    functions.logger.info('Stripe mode: TEST');
    return;
  }
  throw new Error(
    'Stripe key mode mismatch: platform keys must both be test or both be live. Check STRIPE_SECRET_KEY and STRIPE_PUBLISHABLE_KEY in Firebase secrets.',
  );
}

export function rejectClientSuppliedStripeKeys(data: Record<string, unknown>): void {
  const forbidden = [
    'stripeSecretKey',
    'stripePublishableKey',
    'secretKey',
    'apiKey',
    'STRIPE_SECRET_KEY',
    'STRIPE_PUBLISHABLE_KEY',
  ];
  for (const key of forbidden) {
    if (data && typeof data[key] === 'string' && (data[key] as string).trim() !== '') {
      functions.logger.warn('Rejected client-supplied Stripe key parameter', { key });
      throw new functions.https.HttpsError(
        'invalid-argument',
        'Stripe keys must not be sent from the client. Use backend configuration only.',
      );
    }
  }
}

let cachedPlatformPublishableKey: string | null = null;
let stripeClient: Stripe | null = null;

export function getPlatformPublishableKey(): string {
  if (cachedPlatformPublishableKey) return cachedPlatformPublishableKey;
  const { getSecretKey, getPublishableKey } = requireStripeKeysProvider();
  const secretKey = getSecretKey();
  const publishableKey = getPublishableKey();
  if (!secretKey) throw new Error('STRIPE_SECRET_KEY is not set');
  if (!publishableKey || !publishableKey.trim()) throw new Error('STRIPE_PUBLISHABLE_KEY is not set');
  validateStripeKeyMode(secretKey, publishableKey);
  cachedPlatformPublishableKey = publishableKey.trim();
  return cachedPlatformPublishableKey;
}

export function getStripeClient(): Stripe {
  if (!stripeClient) {
    const { getSecretKey, getPublishableKey } = requireStripeKeysProvider();
    const secretKey = getSecretKey();
    if (!secretKey) {
      throw new Error('STRIPE_SECRET_KEY is not set');
    }
    try {
      const publishableKey = getPublishableKey();
      if (publishableKey && publishableKey.trim()) {
        validateStripeKeyMode(secretKey, publishableKey);
      }
    } catch {
      functions.logger.warn('Stripe mode check skipped (publishable key not set)');
    }
    const StripeSdk = require('stripe').default as typeof import('stripe').default;
    stripeClient = new StripeSdk(secretKey, {
      apiVersion: '2026-02-25.clover',
    });
  }
  return stripeClient;
}

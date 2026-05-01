export type StripeKeysProvider = {
  getSecretKey: () => string;
  getPublishableKey: () => string;
};

let stripeKeysProvider: StripeKeysProvider | null = null;

/** Call once from each codebase entrypoint (with defineSecret().value() accessors). */
export function registerStripeKeysProvider(provider: StripeKeysProvider): void {
  stripeKeysProvider = provider;
}

export function requireStripeKeysProvider(): StripeKeysProvider {
  if (!stripeKeysProvider) {
    throw new Error(
      'Stripe keys not configured: call registerStripeKeysProvider({ getSecretKey, getPublishableKey }) from your functions entrypoint before using shared Stripe helpers.',
    );
  }
  return stripeKeysProvider;
}

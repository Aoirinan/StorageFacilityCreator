/**
 * Verifying Stripe webhooks against more than one signing secret.
 *
 * A Stripe webhook destination signs with its own secret, and "Events from:
 * your account" versus "Events from: connected accounts" cannot be changed on
 * an existing destination — a second destination is required, which brings a
 * second secret.
 *
 * With a single configured secret that produces a uniquely misleading failure:
 * connected-account events finally start arriving and every one is rejected as
 * an invalid signature, so it looks like delivery is still broken when in fact
 * only verification is. Accepting any configured secret removes that trap.
 */

/** Split a config value that may hold several secrets, comma or whitespace separated. */
export function parseWebhookSecrets(...values: Array<string | undefined | null>): string[] {
  const out: string[] = [];
  for (const value of values) {
    if (typeof value !== 'string') continue;
    for (const part of value.split(/[\s,]+/)) {
      const trimmed = part.trim();
      // Ignore anything that is not a signing secret, so a placeholder or an
      // empty env var cannot silently become a "valid" candidate.
      if (trimmed.startsWith('whsec_') && !out.includes(trimmed)) {
        out.push(trimmed);
      }
    }
  }
  return out;
}

export interface WebhookVerifyResult<TEvent> {
  event: TEvent;
  /** Index of the secret that verified, for logging which destination signed. */
  secretIndex: number;
}

/**
 * Try each secret in turn, returning the first that verifies.
 *
 * Throws the last error when none match, so the caller still surfaces a real
 * Stripe error message rather than a generic one.
 */
export function verifyWithAnySecret<TEvent>(
  construct: (secret: string) => TEvent,
  secrets: readonly string[],
): WebhookVerifyResult<TEvent> {
  if (secrets.length === 0) {
    throw new Error('No Stripe webhook signing secret is configured.');
  }
  let lastError: unknown;
  for (let i = 0; i < secrets.length; i += 1) {
    try {
      return { event: construct(secrets[i]), secretIndex: i };
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError instanceof Error
    ? lastError
    : new Error('Stripe webhook signature verification failed.');
}

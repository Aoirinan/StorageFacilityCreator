import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import { isSuperAdmin } from '../auth/superAdmin';

/**
 * Pre-launch gate for anything that reaches a customer.
 *
 * Rule from the owner (2026-09-14): no email or text goes to a customer, owner
 * or tenant, until the platform build is finished. Rather than remembering
 * that in sixteen call sites, the shared tenant-email helper asks this gate
 * before sending. Super-admin addresses always pass, so the team can keep
 * testing every flow against their own inboxes, and `allowedTestRecipients`
 * lets a specific test address or phone through.
 *
 * Config lives in Firestore at appConfig/outbound so launch is a field flip,
 * not a deploy:
 *   customerEmailsEnabled: boolean   (default false)
 *   allowedTestRecipients: string[]  (emails or E.164 phones, default [])
 */
export interface OutboundGateConfig {
  customerEmailsEnabled: boolean;
  allowedTestRecipients: string[];
}

export const DEFAULT_OUTBOUND_GATE: OutboundGateConfig = {
  customerEmailsEnabled: false,
  allowedTestRecipients: [],
};

function normalizeRecipient(value: string): string {
  return value.trim().toLowerCase();
}

/** Pure decision: may this recipient be contacted under this config? */
export function isCustomerRecipientAllowed(
  recipient: string,
  config: OutboundGateConfig,
  superAdminCheck: (email: string) => boolean = isSuperAdmin,
): boolean {
  if (config.customerEmailsEnabled) return true;
  const normalized = normalizeRecipient(recipient);
  if (!normalized) return false;
  if (superAdminCheck(normalized)) return true;
  return config.allowedTestRecipients.some((r) => normalizeRecipient(r) === normalized);
}

const CACHE_TTL_MS = 60_000;
let cached: { config: OutboundGateConfig; at: number } | null = null;

export async function getOutboundGateConfig(): Promise<OutboundGateConfig> {
  const now = Date.now();
  if (cached && now - cached.at < CACHE_TTL_MS) return cached.config;
  let config = DEFAULT_OUTBOUND_GATE;
  try {
    const snap = await admin.firestore().collection('appConfig').doc('outbound').get();
    if (snap.exists) {
      const data = snap.data() || {};
      const list = Array.isArray(data.allowedTestRecipients) ? data.allowedTestRecipients : [];
      config = {
        customerEmailsEnabled: data.customerEmailsEnabled === true,
        allowedTestRecipients: list.filter((x: unknown): x is string => typeof x === 'string'),
      };
    }
  } catch (error) {
    // Fail closed: a config read error must not turn into customer email.
    functions.logger.warn('Could not read appConfig/outbound; customer sends stay off', {
      error: error instanceof Error ? error.message : String(error),
    });
  }
  cached = { config, at: now };
  return config;
}

/** For tests and for flipping the flag within a warm instance. */
export function resetOutboundGateCache(): void {
  cached = null;
}

export async function isCustomerEmailAllowed(to: string): Promise<boolean> {
  return isCustomerRecipientAllowed(to, await getOutboundGateConfig());
}

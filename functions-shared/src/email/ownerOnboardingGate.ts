import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import { isSuperAdmin } from '../auth/superAdmin';

/**
 * Pre-launch gate for automated owner onboarding mail.
 *
 * Same rule as the tenant gate in customerOutboundGate.ts: no automated
 * message reaches a real customer until the build is finished. Onboarding mail
 * gets its own flag rather than borrowing `appConfig/outbound` so that owner
 * onboarding can be switched on and tested without also unmuting every
 * tenant-facing email, and so that launch order stays a deliberate choice.
 *
 * Super-admin addresses always pass, so the team can sign up test accounts and
 * watch the real thing arrive. `allowedTestRecipients` lets one named address
 * through, which is how a specific owner gets the real email before the flag
 * is flipped for everyone.
 *
 * Config lives in Firestore at appConfig/onboarding so launch is a field flip,
 * not a deploy:
 *   ownerEmailsEnabled: boolean      (default false)
 *   allowedTestRecipients: string[]  (default [])
 */
export interface OwnerOnboardingGateConfig {
  ownerEmailsEnabled: boolean;
  allowedTestRecipients: string[];
}

export const DEFAULT_OWNER_ONBOARDING_GATE: OwnerOnboardingGateConfig = {
  ownerEmailsEnabled: false,
  allowedTestRecipients: [],
};

function normalizeRecipient(value: string): string {
  return value.trim().toLowerCase();
}

/** Pure decision: may this owner be sent automated onboarding mail? */
export function isOwnerOnboardingRecipientAllowed(
  recipient: string,
  config: OwnerOnboardingGateConfig,
  superAdminCheck: (email: string) => boolean = isSuperAdmin,
): boolean {
  const normalized = normalizeRecipient(recipient);
  if (!normalized) return false;
  if (config.ownerEmailsEnabled) return true;
  if (superAdminCheck(normalized)) return true;
  return config.allowedTestRecipients.some((r) => normalizeRecipient(r) === normalized);
}

const CACHE_TTL_MS = 60_000;
let cached: { config: OwnerOnboardingGateConfig; at: number } | null = null;

export async function getOwnerOnboardingGateConfig(): Promise<OwnerOnboardingGateConfig> {
  const now = Date.now();
  if (cached && now - cached.at < CACHE_TTL_MS) return cached.config;
  let config = DEFAULT_OWNER_ONBOARDING_GATE;
  try {
    const snap = await admin.firestore().collection('appConfig').doc('onboarding').get();
    if (snap.exists) {
      const data = snap.data() || {};
      const list = Array.isArray(data.allowedTestRecipients) ? data.allowedTestRecipients : [];
      config = {
        ownerEmailsEnabled: data.ownerEmailsEnabled === true,
        allowedTestRecipients: list.filter((x: unknown): x is string => typeof x === 'string'),
      };
    }
  } catch (error) {
    // Fail closed: a config read error must not turn into customer email.
    functions.logger.warn('Could not read appConfig/onboarding; owner onboarding mail stays off', {
      error: error instanceof Error ? error.message : String(error),
    });
  }
  cached = { config, at: now };
  return config;
}

/** For tests and for flipping the flag within a warm instance. */
export function resetOwnerOnboardingGateCache(): void {
  cached = null;
}

export async function isOwnerOnboardingEmailAllowed(to: string): Promise<boolean> {
  return isOwnerOnboardingRecipientAllowed(to, await getOwnerOnboardingGateConfig());
}

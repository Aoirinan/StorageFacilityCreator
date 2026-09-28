import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import { isSuperAdmin } from '../auth/superAdmin';

/**
 * Gate for anything that reaches a customer (tenant email and tenant texts).
 *
 * Rule from the owner (2026-09-14): no email or text goes to a customer, owner
 * or tenant, until the platform build is finished. Rather than remembering
 * that in sixteen call sites, every send path asks this gate before sending.
 * Super-admin addresses always pass, so the team can keep testing every flow
 * against their own inboxes, and `allowedTestRecipients` lets a specific test
 * address or phone through.
 *
 * Decision from the owner (2026-09-27): customer contact opens for every
 * facility except the ones listed in `blockedFacilityIds` (his own facility,
 * Keepsake, stays blocked until he says otherwise). So the gate is now
 * facility-aware: every caller says which facility the message is for.
 *
 * Config lives in Firestore at appConfig/outbound so launch is a field flip,
 * not a deploy:
 *   customerEmailsEnabled: boolean   (default false; governs email AND sms)
 *   allowedTestRecipients: string[]  (emails or E.164 phones, default [])
 *   blockedFacilityIds:    string[]  (facility ids that stay closed, default [])
 *
 * Order of the rules:
 *   1. super admins and allowedTestRecipients always pass;
 *   2. a facility in blockedFacilityIds is blocked;
 *   3. a send with no facility id while blockedFacilityIds is non-empty is
 *      blocked (fail closed: we cannot prove it is not for a blocked facility);
 *   4. otherwise customerEmailsEnabled decides.
 */
export interface OutboundGateConfig {
  customerEmailsEnabled: boolean;
  allowedTestRecipients: string[];
  blockedFacilityIds: string[];
}

export type OutboundChannel = 'email' | 'sms';

/** Who the message is from and how it travels. Every caller must say. */
export interface OutboundTarget {
  facilityId: string | null | undefined;
  channel: OutboundChannel;
}

export type OutboundGateReason =
  | 'test_recipient'
  | 'facility_blocked'
  | 'missing_facility'
  | 'launch_flag_off'
  | 'open';

export interface OutboundGateDecision {
  allowed: boolean;
  reason: OutboundGateReason;
}

export const DEFAULT_OUTBOUND_GATE: OutboundGateConfig = {
  customerEmailsEnabled: false,
  allowedTestRecipients: [],
  blockedFacilityIds: [],
};

function normalizeRecipient(value: string): string {
  return String(value ?? '').trim().toLowerCase();
}

/** Pure decision, with the reason, for logs and tests. */
export function decideCustomerRecipient(
  recipient: string,
  target: OutboundTarget,
  config: OutboundGateConfig,
  superAdminCheck: (email: string) => boolean = isSuperAdmin,
): OutboundGateDecision {
  const normalized = normalizeRecipient(recipient);
  if (normalized) {
    if (superAdminCheck(normalized)) return { allowed: true, reason: 'test_recipient' };
    if (config.allowedTestRecipients.some((r) => normalizeRecipient(r) === normalized)) {
      return { allowed: true, reason: 'test_recipient' };
    }
  }

  const facilityId = String(target?.facilityId ?? '').trim();
  const blocked = config.blockedFacilityIds ?? [];
  if (facilityId && blocked.includes(facilityId)) {
    return { allowed: false, reason: 'facility_blocked' };
  }
  if (!facilityId && blocked.length > 0) {
    return { allowed: false, reason: 'missing_facility' };
  }

  if (config.customerEmailsEnabled) return { allowed: true, reason: 'open' };
  return { allowed: false, reason: 'launch_flag_off' };
}

/** Pure decision: may this recipient be contacted for this facility under this config? */
export function isCustomerRecipientAllowed(
  recipient: string,
  target: OutboundTarget,
  config: OutboundGateConfig,
  superAdminCheck: (email: string) => boolean = isSuperAdmin,
): boolean {
  const decision = decideCustomerRecipient(recipient, target, config, superAdminCheck);
  if (decision.reason === 'missing_facility') {
    functions.logger.warn('Customer send with no facility id blocked (blockedFacilityIds is set; failing closed)', {
      channel: target?.channel ?? null,
    });
  }
  return decision.allowed;
}

function stringList(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.filter((x: unknown): x is string => typeof x === 'string');
}

/** Reads a raw appConfig/outbound document into a config, defaulting closed. */
export function parseOutboundGateConfig(data: Record<string, unknown> | undefined): OutboundGateConfig {
  const d = data ?? {};
  return {
    customerEmailsEnabled: d.customerEmailsEnabled === true,
    allowedTestRecipients: stringList(d.allowedTestRecipients),
    blockedFacilityIds: stringList(d.blockedFacilityIds)
      .map((id) => id.trim())
      .filter((id) => id.length > 0),
  };
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
      config = parseOutboundGateConfig(snap.data());
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

/** Async form for any channel: reads the config, then decides. */
export async function isCustomerContactAllowed(
  recipient: string,
  target: OutboundTarget,
): Promise<boolean> {
  return isCustomerRecipientAllowed(recipient, target, await getOutboundGateConfig());
}

/** Email form of [isCustomerContactAllowed]. */
export async function isCustomerEmailAllowed(
  to: string,
  target: { facilityId: string | null | undefined },
): Promise<boolean> {
  return isCustomerContactAllowed(to, { facilityId: target?.facilityId, channel: 'email' });
}

import type { Firestore } from 'firebase-admin/firestore';
import * as functions from 'firebase-functions/v1';

import {
  STAYS_CURRENT_DOC_ID,
  STAY_TOP_LEVEL_COLLECTIONS,
  StaysServerConfigDoc,
} from '@sfc/functions-shared/stays/contracts';

import { staysError } from './errors';

/**
 * staysServerConfig/current, the platform gate (spec §3.2, §6.3 step 4):
 * a kill switch and a facility allowlist that only a super admin sets, in the
 * console. It fails closed: a missing doc or a read error allows nothing.
 */
export interface StaysGate {
  killSwitch: boolean;
  enabledGlobal: boolean;
  allowlistFacilityIds: ReadonlySet<string>;
  extraIcalHosts: readonly string[];
  /** Facilities allowed to turn on calendar sending (a missing field allows none). */
  exportAllowlist: ReadonlySet<string>;
  paymentsAllowlistFacilityIds: ReadonlySet<string>;
  guestMessagingAllowlistFacilityIds: ReadonlySet<string>;
  /** Where the answer came from: the doc, no doc, or a failed read. */
  source: 'doc' | 'missing' | 'error';
}

const CACHE_MS = 60_000;

let cached: { gate: StaysGate; at: number } | null = null;

function stringList(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((v): v is string => typeof v === 'string' && v.length > 0) : [];
}

/** Reads the doc defensively: only an explicit `true` turns anything on. */
export function parseServerConfig(data: Partial<Record<keyof StaysServerConfigDoc, unknown>> | undefined): StaysGate {
  if (!data) return closedGate('missing');
  return {
    killSwitch: data.killSwitch === true,
    enabledGlobal: data.enabledGlobal === true,
    allowlistFacilityIds: new Set(stringList(data.allowlistFacilityIds)),
    extraIcalHosts: stringList(data.extraIcalHosts).map((h) => h.toLowerCase()),
    exportAllowlist: new Set(stringList(data.exportAllowlist)),
    paymentsAllowlistFacilityIds: new Set(stringList(data.paymentsAllowlistFacilityIds)),
    guestMessagingAllowlistFacilityIds: new Set(stringList(data.guestMessagingAllowlistFacilityIds)),
    source: 'doc',
  };
}

export function closedGate(source: 'missing' | 'error'): StaysGate {
  return {
    killSwitch: false,
    enabledGlobal: false,
    allowlistFacilityIds: new Set(),
    extraIcalHosts: [],
    exportAllowlist: new Set(),
    paymentsAllowlistFacilityIds: new Set(),
    guestMessagingAllowlistFacilityIds: new Set(),
    source,
  };
}

/**
 * The gate, cached for 60 seconds per instance. A failed read is not cached,
 * so the next call tries again, but it still allows nothing.
 */
export async function loadStaysGate(db: Firestore, nowMs: number): Promise<StaysGate> {
  if (cached && nowMs - cached.at >= 0 && nowMs - cached.at < CACHE_MS) {
    return cached.gate;
  }
  try {
    const snap = await db
      .collection(STAY_TOP_LEVEL_COLLECTIONS.serverConfig)
      .doc(STAYS_CURRENT_DOC_ID)
      .get();
    const gate = parseServerConfig(snap.exists ? snap.data() : undefined);
    cached = { gate, at: nowMs };
    return gate;
  } catch (error) {
    functions.logger.error('stays: could not read staysServerConfig/current; failing closed', {
      error: error instanceof Error ? error.message : String(error),
    });
    return closedGate('error');
  }
}

/** For tests: forget the cached gate. */
export function resetStaysGateCacheForTests(): void {
  cached = null;
}

export interface StaysAvailability {
  allowed: boolean;
  paused: boolean;
}

/** What staysGetAvailability returns, and what every other gate check is built on. */
export function evaluateStaysGate(gate: StaysGate, facilityId: string): StaysAvailability {
  if (gate.killSwitch) return { allowed: false, paused: true };
  return { allowed: gate.enabledGlobal || gate.allowlistFacilityIds.has(facilityId), paused: false };
}

/**
 * Whether this facility may turn on sending its SFC calendar: Stays is
 * allowed for it and a super admin put it on exportAllowlist (after the
 * shadow week, spec §11.4 Stage B).
 */
export function exportAllowedFor(gate: StaysGate, facilityId: string): boolean {
  return evaluateStaysGate(gate, facilityId).allowed && gate.exportAllowlist.has(facilityId);
}

/** Throws stays_paused or module_not_available unless the facility may use Stays right now. */
export function assertStaysAllowed(gate: StaysGate, facilityId: string): void {
  const { allowed, paused } = evaluateStaysGate(gate, facilityId);
  if (paused) {
    throw staysError('failed-precondition', 'stays_paused', 'Stays is paused for maintenance. Try again later.');
  }
  if (!allowed) {
    throw staysError('failed-precondition', 'module_not_available', 'Stays is not available for this facility yet.');
  }
}

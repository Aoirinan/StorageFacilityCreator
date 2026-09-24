/**
 * Set-up for the booking-engine tests (WP1): a facility with Stays on,
 * listings as staysSaveListing stores them, request ids, and a caller that
 * runs a callable handler as a given user with the fake deps.
 */
import * as functions from 'firebase-functions/v1';

import type { RateLimitConfig } from '@sfc/functions-shared/rateLimits/facilityRateLimit';
import type { StayListingDoc, StayListingInput } from '@sfc/functions-shared/stays/contracts';
import { Timestamp } from 'firebase-admin/firestore';

import { resetStaysGateCacheForTests } from '../../common/serverConfig';
import { staysErrorReason } from '../../common/errors';
import type { StaysDeps } from '../../common/guards';
import { FakeFirestore } from './fakeFirestore';
import { FAC, NOW, OWNER, callableContext, fakeDeps, seedControls, seedFacility, seedGate } from './staysFixtures';

export const P = `facilities/${FAC}`;

let counter = 0;

/** A fresh 32-hex request id, as the app mints one per form. */
export function rid(): string {
  counter++;
  return counter.toString(16).padStart(32, '0');
}

export function listingInput(patch: Partial<StayListingInput> = {}): StayListingInput {
  return {
    name: 'Airbnb A',
    shortCode: 'A1',
    kind: 'vacation_rental',
    group: 'Airbnbs',
    sortOrder: 1,
    active: true,
    archived: false,
    address: null,
    capacity: { maxGuests: 4, bedrooms: 2, beds: 2, bathrooms: 1, petsAllowed: false },
    rv: null,
    times: { checkIn: null, checkOut: null },
    stayRules: { minNights: 1, maxNights: 28 },
    ratesCents: {
      nightly: 10_000,
      weekendNightly: null,
      weeklyNightly: null,
      cleaningFee: 5_000,
      petFee: 0,
      extraGuestFee: 0,
      extraGuestAfter: 0,
    },
    seasonalRates: [],
    taxLines: [],
    turnover: {
      mode: 'full',
      afterOwnerBlocks: false,
      checklistTemplate: [{ id: 'beds', label: 'Make beds' }],
      defaultAssigneeUid: null,
      defaultAssigneeName: null,
    },
    accessCodeMode: 'none',
    airbnb: { listingNameAliases: [], listingUrl: null, calendarUrl: null },
    notes: '',
    ...patch,
  };
}

/** An RV site: $45 a night, no cleaning fee, a quick site check. */
export function rvInput(n: number, patch: Partial<StayListingInput> = {}): StayListingInput {
  return listingInput({
    name: `RV ${n}`,
    shortCode: `RV${n}`,
    kind: 'rv_site',
    group: 'RV park',
    sortOrder: 100 + n,
    capacity: { maxGuests: 0, bedrooms: 0, beds: 0, bathrooms: 0, petsAllowed: true },
    rv: { hookup: 'full', amps: [30, 50], maxLengthFt: 40, pullThrough: false, surface: null },
    ratesCents: { nightly: 4_500, weekendNightly: null, weeklyNightly: null, cleaningFee: 0, petFee: 0, extraGuestFee: 0, extraGuestAfter: 0 },
    turnover: {
      mode: 'quick_check',
      afterOwnerBlocks: false,
      checklistTemplate: [{ id: 'hookups', label: 'Hookups off' }],
      defaultAssigneeUid: null,
      defaultAssigneeName: null,
    },
    ...patch,
  });
}

export function seedListing(fake: FakeFirestore, id: string, input: StayListingInput = listingInput(), version = 1): void {
  const ts = Timestamp.fromMillis(NOW - 86_400_000);
  const doc: StayListingDoc = { ...input, facilityId: FAC, version, createdAt: ts, createdBy: OWNER, updatedAt: ts, updatedBy: OWNER };
  fake.seed(`${P}/stayListings/${id}`, doc as unknown as Record<string, unknown>);
}

export interface Env {
  fake: FakeFirestore;
  handle: ReturnType<typeof fakeDeps>;
  deps: StaysDeps;
}

/** A facility, the gate open for it, and confirmed controls (patchable; null leaves them out). */
export function setupEnv(
  all: FakeFirestore[],
  opts: { controls?: Record<string, unknown> | null; gate?: Record<string, unknown>; nowMs?: number } = {},
): Env {
  resetStaysGateCacheForTests();
  const fake = new FakeFirestore();
  fake.clock = () => opts.nowMs ?? NOW;
  all.push(fake);
  seedFacility(fake);
  seedGate(fake, opts.gate ?? {});
  if (opts.controls !== null) seedControls(fake, opts.controls ?? {});
  const handle = fakeDeps(fake, opts.nowMs ?? NOW);
  return { fake, handle, deps: handle.deps };
}

export type Handler<R> = (data: unknown, context: functions.https.CallableContext, deps: StaysDeps) => Promise<R>;

/** Calls a handler as `uid`. */
export function as<R>(env: Env, handler: Handler<R>, uid: string, data: Record<string, unknown>): Promise<R> {
  return handler({ facilityId: FAC, ...data }, callableContext(uid), env.deps);
}

/** The Stays reason a call failed with, or null when it succeeded. */
export async function reasonOf(p: Promise<unknown>): Promise<string | null> {
  try {
    await p;
    return null;
  } catch (error) {
    return staysErrorReason(error) ?? `untyped: ${error instanceof Error ? error.message : String(error)}`;
  }
}

/** The error a call failed with (asserting it failed). */
export async function errorOf(p: Promise<unknown>): Promise<functions.https.HttpsError> {
  try {
    await p;
  } catch (error) {
    return error as functions.https.HttpsError;
  }
  throw new Error('expected the call to fail');
}

/**
 * The rate limits one call asked for, in order, as [key, limit, window
 * seconds]; a per-user key (`{key}_u_{uid}`) is shown as `{key}_u`. The call
 * itself may fail afterwards: the limits are taken before a handler's own checks.
 */
export async function rateLimitsOf(env: Env, handler: Handler<unknown>, uid: string, data: Record<string, unknown>): Promise<[string, number, number][]> {
  const seen: RateLimitConfig[] = [];
  const deps: StaysDeps = {
    ...env.deps,
    enforceRateLimit: async (config) => {
      seen.push(config);
      await env.deps.enforceRateLimit(config);
    },
  };
  await handler({ facilityId: FAC, ...data }, callableContext(uid), deps).catch(() => undefined);
  return seen.map((c) => [c.key.replace(/_u_.+$/, '_u'), c.limit, c.windowSeconds]);
}

export function nightsOf(fake: FakeFirestore, listingId: string, month: string): Record<string, { s: string; h: boolean }> {
  return (fake.read(`${P}/stayNightLocks/${listingId}_${month}`)?.nights ?? {}) as Record<string, { s: string; h: boolean }>;
}

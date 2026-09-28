/**
 * Shared set-up for the functions-stays tests: a facility with each role, the
 * platform gate, confirmed controls, stay docs, a callable context and fake
 * deps (rate limiter and audit recorder backed by memory).
 */
import * as functions from 'firebase-functions/v1';
import { Timestamp } from 'firebase-admin/firestore';

import type { RateLimitConfig } from '@sfc/functions-shared/rateLimits/facilityRateLimit';
import type { StayControlsDoc, StayDoc } from '@sfc/functions-shared/stays/contracts';

import type { StaysAuditEntry } from '../../common/audit';
import type { StaysDeps } from '../../common/guards';
import { FakeFirestore } from './fakeFirestore';

export const FAC = 'fac-caprock';
export const OWNER = 'uid-owner';
export const MANAGER = 'uid-manager';
export const EMPLOYEE = 'uid-employee';
export const VIEWER = 'uid-viewer';
export const OUTSIDER = 'uid-outsider';
export const TZ = 'America/Denver';

/** 2026-10-01 12:00 in Denver (MDT). */
export const NOW = Date.parse('2026-10-01T18:00:00Z');

export function seedFacility(fake: FakeFirestore, extra: Record<string, unknown> = {}): void {
  fake.seed(`facilities/${FAC}`, {
    name: 'Caprock Storage & RV Park',
    ownerUid: OWNER,
    timeZone: TZ,
    roles: { [OWNER]: 'owner', [MANAGER]: 'manager', [EMPLOYEE]: 'employee', [VIEWER]: 'viewer' },
    ...extra,
  });
}

export function seedGate(fake: FakeFirestore, config: Record<string, unknown> = {}): void {
  fake.seed('staysServerConfig/current', {
    killSwitch: false,
    enabledGlobal: false,
    allowlistFacilityIds: [FAC],
    extraIcalHosts: [],
    ...config,
  });
}

export function seedControls(fake: FakeFirestore, patch: Partial<StayControlsDoc> = {}): void {
  fake.seed(`facilities/${FAC}/stayControls/current`, {
    facilityId: FAC,
    moduleEnabled: true,
    timeZone: TZ,
    timeZoneConfirmedAt: Timestamp.fromMillis(NOW - 86_400_000),
    timeZoneConfirmedBy: OWNER,
    version: 1,
    ...patch,
  });
}

/** Controls as the writer and callables see them once loaded. */
export function controlsOn(patch: Partial<StayControlsDoc> = {}): StayControlsDoc {
  return {
    facilityId: FAC,
    moduleEnabled: true,
    timeZone: TZ,
    timeZoneConfirmedAt: Timestamp.fromMillis(NOW - 86_400_000),
    timeZoneConfirmedBy: OWNER,
    icalSyncEnabled: false,
    icalExportEnabled: false,
    turnoverTasksEnabled: false,
    dailyBriefEnabled: false,
    dailyBriefLocalHour: 7,
    lodgingTaxEnabled: false,
    employeesCanBook: false,
    employeesCanRecordCash: false,
    defaultCheckInTime: '15:00',
    defaultCheckOutTime: '11:00',
    shortLeadWarningHours: 72,
    paymentMethods: ['cash', 'check', 'card_external', 'venmo', 'other'],
    parkRules: '',
    quietHours: '',
    guestMessagingEnabled: false,
    directPaymentsEnabled: false,
    templatesSeededAt: null,
    createdAt: null,
    createdBy: null,
    updatedAt: null,
    updatedBy: null,
    version: 1,
    ...patch,
  };
}

let createdAtCounter = 0;

/** A full stay doc; createdAtMs increases with each call unless given. */
export function makeStay(listingId: string, checkIn: string, checkOut: string, patch: Partial<StayDoc> = {}): StayDoc {
  const ts = Timestamp.fromMillis(NOW);
  createdAtCounter++;
  const nights = Math.round((Date.parse(`${checkOut}T00:00:00Z`) - Date.parse(`${checkIn}T00:00:00Z`)) / 86_400_000);
  return {
    facilityId: FAC,
    listingId,
    listingName: listingId.toUpperCase(),
    listingGroup: 'Airbnbs',
    listingKind: 'vacation_rental',
    kind: 'reservation',
    source: 'direct',
    origin: 'sfc',
    status: 'confirmed',
    arrivalState: 'upcoming',
    checkIn,
    checkOut,
    nights,
    checkInTime: '15:00',
    checkOutTime: '11:00',
    guestDisplayName: 'Jane D.',
    adults: 2,
    children: 0,
    pets: 0,
    rvLengthFt: null,
    paymentStatus: 'none',
    external: null,
    sync: null,
    conflict: null,
    staffNotes: '',
    cleanerNotes: '',
    tags: [],
    messageMarks: {},
    turnoverTaskId: null,
    checkedInAt: null,
    checkedOutAt: null,
    cancelledAt: null,
    cancelledBy: null,
    cancelReason: null,
    requestId: null,
    version: 1,
    createdAtMs: NOW + createdAtCounter,
    createdAt: ts,
    createdBy: OWNER,
    updatedAt: ts,
    updatedBy: OWNER,
    ...patch,
  };
}

export function callableContext(uid: string | null, opts: { appCheck?: boolean } = {}): functions.https.CallableContext {
  return {
    ...(uid ? { auth: { uid, token: {} } } : {}),
    ...(opts.appCheck === false ? {} : { app: { appId: 'test-app', token: {} } }),
    rawRequest: {},
  } as unknown as functions.https.CallableContext;
}

export interface FakeDepsHandle {
  deps: StaysDeps;
  audits: { facilityId: string; entry: StaysAuditEntry }[];
  rateLimitKeys: string[];
  setNow(ms: number): void;
}

/** Deps on the fake: a counting rate limiter (the shared helper's semantics) and an audit recorder. */
export function fakeDeps(fake: FakeFirestore, nowMs = NOW): FakeDepsHandle {
  let now = nowMs;
  const counts = new Map<string, number>();
  const handle: FakeDepsHandle = {
    audits: [],
    rateLimitKeys: [],
    setNow: (ms) => {
      now = ms;
    },
    deps: {
      db: () => fake.firestore(),
      now: () => now,
      enforceRateLimit: async (config: RateLimitConfig) => {
        const windowStart = Math.floor(now / 1000 / config.windowSeconds) * config.windowSeconds;
        const key = `${config.facilityId}/${config.key}_${windowStart}`;
        handle.rateLimitKeys.push(config.key);
        const current = counts.get(key) ?? 0;
        if (current >= config.limit) {
          throw new functions.https.HttpsError('resource-exhausted', `Rate limit exceeded for ${config.key}.`);
        }
        counts.set(key, current + 1);
      },
      writeAudit: async (facilityId, entry) => {
        handle.audits.push({ facilityId, entry });
      },
    },
  };
  return handle;
}

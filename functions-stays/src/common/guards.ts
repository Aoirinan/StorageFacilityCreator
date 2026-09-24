import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import type { Firestore } from 'firebase-admin/firestore';

import { enforceAppCheckOrThrow } from '@sfc/functions-shared/auth/appCheck';
import { RateLimitConfig, enforceRateLimit } from '@sfc/functions-shared/rateLimits/facilityRateLimit';
import { StayControlsDoc, StayRole, StaysCallableName } from '@sfc/functions-shared/stays/contracts';
import { isValidYmd } from '@sfc/functions-shared/stays/dates';
import { isValidDocId, isValidRequestId } from '@sfc/functions-shared/stays/ids';

import { StaysAuditEntry, StaysAuditWriter, defaultAuditWriter } from './audit';
import { assertModuleEnabled, loadControls } from './controls';
import { staysError } from './errors';
import { StaysGate, assertStaysAllowed, loadStaysGate } from './serverConfig';

/**
 * The guard pipeline every Stays callable runs, in order (spec §6.3):
 *  1. signed in                      → unauthenticated
 *  2. App Check                      → app_check_required
 *  3. ids (facilityId + the callable's own checks) → invalid_argument
 *  4. staysServerConfig gate         → stays_paused / module_not_available
 *  5. the caller's role here         → role_not_allowed (never canAccessFacility)
 *  6. stayControls, module enabled   → module_disabled
 *  7. role allowed for this callable → role_not_allowed
 *  8. rate limits, facility and user → rate_limited
 * The callable then runs its transaction (step 9) and writes its audit
 * record (step 10) with auditStays().
 */

/** What the guards and the callables reach the outside world through; tests pass fakes. */
export interface StaysDeps {
  db: () => Firestore;
  now: () => number;
  enforceRateLimit: (config: RateLimitConfig) => Promise<void>;
  writeAudit: StaysAuditWriter;
}

export function defaultStaysDeps(): StaysDeps {
  return {
    db: () => admin.firestore(),
    now: () => Date.now(),
    enforceRateLimit,
    writeAudit: defaultAuditWriter,
  };
}

/** Runtime settings (spec §6.1): v1 API, default region, no minInstances, no VPC connector, no secrets. */
export const STAYS_RUNTIME = {
  callable: { memory: '256MB', timeoutSeconds: 60, maxInstances: 10 },
  csvImport: { memory: '512MB', timeoutSeconds: 300, maxInstances: 10 },
  worker: { memory: '256MB', timeoutSeconds: 300, maxInstances: 5, failurePolicy: false },
  trigger: { memory: '256MB', timeoutSeconds: 60, maxInstances: 10 },
  export: { memory: '256MB', timeoutSeconds: 30, maxInstances: 5 },
} as const satisfies Record<string, functions.RuntimeOptions>;

/**
 * Wraps a Stays callable: runtime settings, and no internal error text ever
 * reaches the app (anything that is not already an HttpsError becomes a
 * generic `internal`).
 */
export function staysCallable<Res>(
  name: StaysCallableName,
  handler: (data: unknown, context: functions.https.CallableContext) => Promise<Res>,
  runtime: functions.RuntimeOptions = STAYS_RUNTIME.callable,
): functions.HttpsFunction & functions.Runnable<unknown> {
  return functions.runWith(runtime).https.onCall(async (data: unknown, context) => {
    try {
      return await handler(data, context);
    } catch (error) {
      if (error instanceof functions.https.HttpsError) throw error;
      functions.logger.error(`${name} failed`, {
        message: error instanceof Error ? error.message : String(error),
      });
      throw staysError('internal', 'internal', 'Something went wrong on our side. Try again.');
    }
  });
}

// ---------------------------------------------------------------------------
// Role resolution (step 5)
// ---------------------------------------------------------------------------

const ROLE_RANK: Record<StayRole, number> = { owner: 4, manager: 3, employee: 2, viewer: 1 };

function higher(a: StayRole | null, b: StayRole | null): StayRole | null {
  if (!a) return b;
  if (!b) return a;
  return ROLE_RANK[a] >= ROLE_RANK[b] ? a : b;
}

/** The `managers` map entry forms assertOwnerOrManager (functions-automation processExportJob.ts) accepts. */
function isManagerEntry(entry: unknown): boolean {
  if (entry === true) return true;
  if (typeof entry !== 'object' || entry === null) return false;
  const e = entry as Record<string, unknown>;
  return e.active === true || e.isActive === true || e.role === 'manager' || e.roleType === 'manager';
}

/**
 * The caller's role from the facility doc: ownerUid, the `managers` map and
 * the `roles` map. Only `ownerUid` makes an owner; a roles entry of 'owner'
 * counts as manager, so owner-only settings stay with the account that owns
 * the facility.
 */
export function roleFromFacilityDoc(data: Record<string, unknown>, uid: string): StayRole | null {
  if (data.ownerUid === uid) return 'owner';
  const roles = (data.roles as Record<string, unknown> | undefined) ?? {};
  const managers = (data.managers as Record<string, unknown> | undefined) ?? {};
  const role = roles[uid];
  if (isManagerEntry(managers[uid]) || role === 'owner' || role === 'manager' || role === 'admin') return 'manager';
  if (role === 'employee') return 'employee';
  if (role === 'viewer') return 'viewer';
  return null;
}

/** A user_roles row's roleType. 'owner' rows count as manager for the same reason as above. */
export function roleFromUserRoleType(roleType: unknown): StayRole | null {
  switch (String(roleType ?? '').toLowerCase()) {
    case 'owner':
    case 'manager':
    case 'admin':
      return 'manager';
    case 'employee':
    case 'staff':
      return 'employee';
    case 'viewer':
      return 'viewer';
    default:
      return null;
  }
}

export interface FacilityAccess {
  role: StayRole | null;
  facilityExists: boolean;
  /** facilities/{id}.timeZone, for the mismatch warning only; never used as a fallback. */
  facilityTimeZone: string | null;
}

/**
 * Step 5: ownerUid, the roles map, the managers map and active user_roles
 * rows; the highest wins. Deliberately not canAccessFacility, which also
 * lets tenant-portal occupants through.
 */
export async function loadFacilityAccess(db: Firestore, facilityId: string, uid: string, nowMs: number): Promise<FacilityAccess> {
  const snap = await db.collection('facilities').doc(facilityId).get();
  if (!snap.exists) return { role: null, facilityExists: false, facilityTimeZone: null };
  const data = (snap.data() ?? {}) as Record<string, unknown>;
  let role = roleFromFacilityDoc(data, uid);
  if (role !== 'owner' && role !== 'manager') {
    const rows = await db
      .collection('user_roles')
      .where('userId', '==', uid)
      .where('facilityId', '==', facilityId)
      .where('isActive', '==', true)
      .get();
    for (const row of rows.docs) {
      const expiresAt = row.get('expiresAt') as { toMillis?: () => number } | null | undefined;
      if (expiresAt && typeof expiresAt.toMillis === 'function' && expiresAt.toMillis() <= nowMs) continue;
      role = higher(role, roleFromUserRoleType(row.get('roleType')));
    }
  }
  return {
    role,
    facilityExists: true,
    facilityTimeZone: typeof data.timeZone === 'string' ? data.timeZone : null,
  };
}

export function isOwnerOrManager(role: StayRole): boolean {
  return role === 'owner' || role === 'manager';
}

// ---------------------------------------------------------------------------
// Input checks (step 3)
// ---------------------------------------------------------------------------

export function asRecord(data: unknown): Record<string, unknown> {
  if (typeof data !== 'object' || data === null || Array.isArray(data)) {
    throw staysError('invalid-argument', 'invalid_argument', 'Expected an object.');
  }
  return data as Record<string, unknown>;
}

export function requireDocId(data: Record<string, unknown>, field: string): string {
  const value = data[field];
  if (!isValidDocId(value)) {
    throw staysError('invalid-argument', 'invalid_argument', `${field} is missing or invalid.`, { field });
  }
  return value;
}

export function optionalDocId(data: Record<string, unknown>, field: string): string | null {
  return data[field] === undefined || data[field] === null ? null : requireDocId(data, field);
}

export function requireYmd(data: Record<string, unknown>, field: string): string {
  const value = data[field];
  if (!isValidYmd(value)) {
    throw staysError('invalid-argument', 'invalid_dates', `${field} must be a YYYY-MM-DD date.`, { field });
  }
  return value;
}

export function requireRequestId(data: Record<string, unknown>, field = 'requestId'): string {
  const value = data[field];
  if (!isValidRequestId(value)) {
    throw staysError('invalid-argument', 'invalid_argument', `${field} must be 32 lowercase hex characters.`, { field });
  }
  return value;
}

// ---------------------------------------------------------------------------
// The pipeline
// ---------------------------------------------------------------------------

export interface StaysRateLimit {
  /** e.g. 'stays_create'. The per-user key is `${key}_u_${uid}`. */
  key: string;
  windowSeconds: number;
  perFacility?: number;
  perUser?: number;
}

export interface StaysGuardOptions {
  callable: StaysCallableName;
  /** Roles that may call it at all; per-setting employee checks come after (assertEmployeeSetting). */
  roles: readonly StayRole[];
  /** False only for staysGetAvailability and staysSetControls. */
  requireModuleEnabled?: boolean;
  /** The callable's own id and date checks (step 3). */
  validate?: (data: Record<string, unknown>) => void;
  rateLimit?: StaysRateLimit;
}

export interface StaysCallContext {
  uid: string;
  facilityId: string;
  role: StayRole;
  controls: StayControlsDoc;
  gate: StaysGate;
  facilityTimeZone: string | null;
  data: Record<string, unknown>;
  db: Firestore;
  deps: StaysDeps;
  nowMs: number;
}

export async function runStaysGuards(
  rawData: unknown,
  context: functions.https.CallableContext,
  options: StaysGuardOptions,
  deps: StaysDeps = defaultStaysDeps(),
): Promise<StaysCallContext> {
  // 1. Signed in.
  const uid = context.auth?.uid;
  if (!uid) {
    throw staysError('unauthenticated', 'unauthenticated', 'Sign in to use Stays.');
  }

  // 2. App Check.
  try {
    enforceAppCheckOrThrow(context);
  } catch (error) {
    const message = error instanceof Error ? error.message : 'App Check token required.';
    throw staysError('failed-precondition', 'app_check_required', message);
  }

  // 3. Ids.
  const data = asRecord(rawData);
  const facilityId = requireDocId(data, 'facilityId');
  options.validate?.(data);

  const db = deps.db();
  const nowMs = deps.now();

  // 4. Platform gate (fails closed).
  const gate = await loadStaysGate(db, nowMs);
  assertStaysAllowed(gate, facilityId);

  // 5. Role at this facility.
  const access = await loadFacilityAccess(db, facilityId, uid, nowMs);
  if (!access.role) {
    throw staysError('permission-denied', 'role_not_allowed', 'You do not have access to this facility.');
  }
  const role = access.role;

  // 6. Controls and the module switch.
  const controls = await loadControls(db, facilityId);
  if (options.requireModuleEnabled !== false) assertModuleEnabled(controls);

  // 7. Role for this callable.
  if (!options.roles.includes(role)) {
    throw staysError('permission-denied', 'role_not_allowed', 'Your role cannot do this in Stays.', { role });
  }

  // 8. Rate limits: facility-wide, then per user.
  const limit = options.rateLimit;
  if (limit) {
    try {
      if (limit.perFacility !== undefined) {
        await deps.enforceRateLimit({
          facilityId,
          key: limit.key,
          limit: limit.perFacility,
          windowSeconds: limit.windowSeconds,
          userId: uid,
        });
      }
      if (limit.perUser !== undefined) {
        await deps.enforceRateLimit({
          facilityId,
          key: `${limit.key}_u_${uid}`,
          limit: limit.perUser,
          windowSeconds: limit.windowSeconds,
          userId: uid,
        });
      }
    } catch (error) {
      if (error instanceof functions.https.HttpsError && error.code === 'resource-exhausted') {
        throw staysError('resource-exhausted', 'rate_limited', 'Too many requests. Wait a moment and try again.');
      }
      throw error;
    }
  }

  return { uid, facilityId, role, controls, gate, facilityTimeZone: access.facilityTimeZone, data, db, deps, nowMs };
}

/**
 * Employee walk-up booking and cash depend on owner switches that default
 * off; owners and managers are never limited by them.
 */
export function assertEmployeeSetting(ctx: StaysCallContext, setting: 'employeesCanBook' | 'employeesCanRecordCash'): void {
  if (ctx.role === 'employee' && ctx.controls[setting] !== true) {
    throw staysError(
      'permission-denied',
      'employee_setting_off',
      setting === 'employeesCanBook'
        ? 'The owner has not allowed employees to book stays.'
        : 'The owner has not allowed employees to record payments.',
      { setting },
    );
  }
}

/** Step 10. Never throws: the booking has already committed. */
export async function auditStays(ctx: StaysCallContext, entry: Omit<StaysAuditEntry, 'actorUid'>): Promise<void> {
  try {
    await ctx.deps.writeAudit(ctx.facilityId, { ...entry, actorUid: ctx.uid });
  } catch (error) {
    functions.logger.warn('stays: audit write failed', {
      eventType: entry.eventType,
      message: error instanceof Error ? error.message : String(error),
    });
  }
}

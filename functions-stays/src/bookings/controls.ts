import * as functions from 'firebase-functions/v1';
import { Timestamp } from 'firebase-admin/firestore';

import { enforceAppCheckOrThrow } from '@sfc/functions-shared/auth/appCheck';
import {
  MANUAL_PAYMENT_METHODS,
  STAYS_CALLABLES,
  STAYS_LIMITS,
  STAY_COLLECTIONS,
  StayControlsChanges,
  StayControlsDoc,
  StayListingDoc,
  StayRole,
  StaysGetAvailabilityResponse,
  StaysSetControlsResponse,
  StaysWarning,
} from '@sfc/functions-shared/stays/contracts';
import { canonicalIanaZone, isValidHourMinute, sameTimeZone } from '@sfc/functions-shared/stays/dates';

import { controlsRef, normalizeControls } from '../common/controls';
import { staysError } from '../common/errors';
import {
  StaysDeps,
  auditStays,
  asRecord,
  defaultStaysDeps,
  loadFacilityAccess,
  requireDocId,
  runStaysGuards,
  staysCallable,
} from '../common/guards';
import { StaysGate, evaluateStaysGate, exportAllowedFor, loadStaysGate } from '../common/serverConfig';
import { ReconcileTurnoversResult, reconcileTurnovers } from '../tasks/onStayWrite';
import { SEEDED_TEMPLATES, defaultChecklistFor, seededTemplateDoc } from './seedDefaults';
import { facilityCol, invalid, toWire } from './shared';

const ANY_ROLE: readonly StayRole[] = ['owner', 'manager', 'employee', 'viewer'];
const OWNER_OR_MANAGER: readonly StayRole[] = ['owner', 'manager'];

// ---------------------------------------------------------------------------
// staysGetAvailability: may this facility use Stays right now?
// ---------------------------------------------------------------------------

/**
 * Anyone with a role at the facility may ask. It answers from the platform
 * gate instead of refusing, so the app can show "paused" or hide the setup
 * prompt; a gate that cannot be read answers "not available".
 */
export async function handleGetAvailability(
  rawData: unknown,
  context: functions.https.CallableContext,
  deps: StaysDeps = defaultStaysDeps(),
): Promise<StaysGetAvailabilityResponse> {
  const uid = context.auth?.uid;
  if (!uid) throw staysError('unauthenticated', 'unauthenticated', 'Sign in to use Stays.');
  try {
    enforceAppCheckOrThrow(context);
  } catch (error) {
    throw staysError('failed-precondition', 'app_check_required', error instanceof Error ? error.message : 'App Check token required.');
  }
  const data = asRecord(rawData);
  const facilityId = requireDocId(data, 'facilityId');
  const db = deps.db();
  const access = await loadFacilityAccess(db, facilityId, uid);
  // Outsiders learn nothing about the facility, not even whether Stays is on offer.
  if (!access.role || !ANY_ROLE.includes(access.role)) {
    throw staysError('permission-denied', 'role_not_allowed', 'You do not have access to this facility.');
  }
  try {
    await deps.enforceRateLimit({ facilityId, key: `stays_availability_u_${uid}`, limit: 30, windowSeconds: 60, userId: uid });
  } catch (error) {
    if (error instanceof functions.https.HttpsError && error.code === 'resource-exhausted') {
      throw staysError('resource-exhausted', 'rate_limited', 'Too many requests. Wait a moment and try again.');
    }
    throw error;
  }
  const gate = await loadStaysGate(db, deps.now());
  return { ...evaluateStaysGate(gate, facilityId), exportAllowed: exportAllowedFor(gate, facilityId) };
}

export const staysGetAvailability = staysCallable(STAYS_CALLABLES.getAvailability, (data, context) =>
  handleGetAvailability(data, context),
);

// ---------------------------------------------------------------------------
// staysSetControls
// ---------------------------------------------------------------------------

const BOOLEAN_KEYS = [
  'moduleEnabled',
  'icalSyncEnabled',
  'icalExportEnabled',
  'turnoverTasksEnabled',
  'dailyBriefEnabled',
  'lodgingTaxEnabled',
  'employeesCanBook',
  'employeesCanRecordCash',
] as const;

/** Reserved for later automation and card payments: owner-only, and v1 refuses to turn them on. */
const RESERVED_KEYS = ['guestMessagingEnabled', 'directPaymentsEnabled'] as const;

const CHANGE_KEYS: ReadonlySet<string> = new Set<keyof StayControlsChanges>([
  ...BOOLEAN_KEYS,
  ...RESERVED_KEYS,
  'timeZone',
  'dailyBriefLocalHour',
  'defaultCheckInTime',
  'defaultCheckOutTime',
  'shortLeadWarningHours',
  'paymentMethods',
  'parkRules',
  'quietHours',
]);

function parseChanges(raw: unknown): StayControlsChanges {
  const changes = asRecord(raw ?? {});
  const out: StayControlsChanges = {};
  for (const [key, value] of Object.entries(changes)) {
    if (!CHANGE_KEYS.has(key)) throw invalid(`changes.${key}`, `${key} is not a Stays setting.`);
    if (value === undefined) continue;
    const field = `changes.${key}`;
    if ((BOOLEAN_KEYS as readonly string[]).includes(key) || (RESERVED_KEYS as readonly string[]).includes(key)) {
      if (typeof value !== 'boolean') throw invalid(field, `${key} must be true or false.`);
      (out as Record<string, unknown>)[key] = value;
      continue;
    }
    switch (key) {
      case 'timeZone': {
        const zone = canonicalIanaZone(value);
        if (!zone) throw invalid(field, 'Choose a time zone such as America/Denver.');
        out.timeZone = zone;
        break;
      }
      case 'dailyBriefLocalHour':
        if (!Number.isInteger(value) || (value as number) < 0 || (value as number) > 23) {
          throw invalid(field, 'The daily brief hour is 0 to 23.');
        }
        out.dailyBriefLocalHour = value as number;
        break;
      case 'defaultCheckInTime':
      case 'defaultCheckOutTime':
        if (!isValidHourMinute(value)) throw invalid(field, 'Use a 24-hour time like 15:00.');
        out[key] = value;
        break;
      case 'shortLeadWarningHours':
        if (!Number.isInteger(value) || (value as number) < 0 || (value as number) > 720) {
          throw invalid(field, 'The short-notice window is 0 to 720 hours.');
        }
        out.shortLeadWarningHours = value as number;
        break;
      case 'paymentMethods': {
        if (!Array.isArray(value) || value.length === 0) throw invalid(field, 'Pick at least one payment method.');
        const methods = value.map((m) => {
          if (!(MANUAL_PAYMENT_METHODS as readonly unknown[]).includes(m)) {
            throw invalid(field, `${String(m)} is not a payment method Stays records.`);
          }
          return m as (typeof MANUAL_PAYMENT_METHODS)[number];
        });
        if (new Set(methods).size !== methods.length) throw invalid(field, 'A payment method is listed twice.');
        out.paymentMethods = methods;
        break;
      }
      case 'parkRules':
      case 'quietHours': {
        const max = key === 'parkRules' ? 4000 : 200;
        if (typeof value !== 'string' || value.length > max) throw invalid(field, `${key} is text of at most ${max} characters.`);
        out[key] = value;
        break;
      }
    }
  }
  return out;
}

/**
 * The reserved switches: only the owner may change one, and v1 refuses to
 * turn either on. A value sent unchanged is not a change, so a settings
 * screen that saves every field works for a manager too.
 */
function assertReservedKeys(changes: StayControlsChanges, stored: StayControlsDoc, role: StayRole): void {
  for (const key of RESERVED_KEYS) {
    if (changes[key] === undefined || changes[key] === (stored[key] === true)) continue;
    if (role !== 'owner') {
      throw staysError('permission-denied', 'role_not_allowed', 'Only the owner can change automation and payment settings.', {
        role,
        field: key,
      });
    }
    if (changes[key] === true) {
      throw staysError(
        'failed-precondition',
        'not_available_yet',
        key === 'guestMessagingEnabled'
          ? 'Automatic guest messages are not available yet. Copy, print or open messages in your own mail or text app.'
          : 'Card payments for stays are not available yet. Record card payments taken on your own terminal as "Card elsewhere".',
        { field: key },
      );
    }
  }
}

/**
 * Turning on calendar sending needs the platform's say-so: the facility must
 * be on staysServerConfig.exportAllowlist, which a super admin sets after the
 * shadow week (spec §11.4 Stage B). Turning it off is always allowed, and a
 * value sent unchanged is not a change.
 */
function assertExportAllowed(changes: StayControlsChanges, stored: StayControlsDoc, gate: StaysGate, facilityId: string): void {
  if (changes.icalExportEnabled !== true || stored.icalExportEnabled === true) return;
  if (!exportAllowedFor(gate, facilityId)) {
    throw staysError(
      'failed-precondition',
      'not_available_yet',
      'Calendar sending is turned on by support after the first week of checking. Contact support to turn it on.',
      { field: 'icalExportEnabled' },
    );
  }
}

/** Turnover tasks are being made: Stays on, turnovers on, and a confirmed zone to time them in. */
function turnoversRunning(c: Pick<StayControlsDoc, 'moduleEnabled' | 'turnoverTasksEnabled' | 'timeZone' | 'timeZoneConfirmedAt'>): boolean {
  return c.moduleEnabled === true && c.turnoverTasksEnabled === true && !!canonicalIanaZone(c.timeZone) && !!c.timeZoneConfirmedAt;
}

export interface SetControlsResult extends StaysSetControlsResponse {
  /** Template keys seeded by this call (the first time the module was turned on). */
  seededTemplateKeys: string[];
  /** The turnover catch-up this call ran (turnovers just started, or their zone moved), or null. */
  turnovers: ReconcileTurnoversResult | null;
}

function mismatchWarning(zone: string | null, facilityZone: string | null): StaysWarning | null {
  if (!zone || sameTimeZone(zone, facilityZone)) return null;
  return {
    code: 'facility_timezone_mismatch',
    message: facilityZone
      ? `Stays uses ${zone}, but the facility is set to ${facilityZone}. If the facility setting is wrong, fix it in Facility settings.`
      : `The facility has no time zone set; Stays will use ${zone}.`,
    details: { staysTimeZone: zone, facilityTimeZone: facilityZone },
  };
}

export async function handleSetControls(
  rawData: unknown,
  context: functions.https.CallableContext,
  deps: StaysDeps = defaultStaysDeps(),
): Promise<SetControlsResult> {
  const ctx = await runStaysGuards(
    rawData,
    context,
    {
      callable: STAYS_CALLABLES.setControls,
      roles: OWNER_OR_MANAGER,
      requireModuleEnabled: false,
      rateLimit: { key: 'stays_controls', windowSeconds: 60, perFacility: 20 },
    },
    deps,
  );
  const changes = parseChanges(ctx.data.changes);
  const confirmTimeZone = ctx.data.confirmTimeZone === true;
  if (ctx.data.confirmTimeZone !== undefined && typeof ctx.data.confirmTimeZone !== 'boolean') {
    throw invalid('confirmTimeZone', 'confirmTimeZone must be true or false.');
  }
  const expectedVersion = ctx.data.expectedVersion;
  if (expectedVersion !== undefined && (!Number.isInteger(expectedVersion) || (expectedVersion as number) < 0)) {
    throw invalid('expectedVersion', 'expectedVersion must be a whole number.');
  }

  const now = Timestamp.fromMillis(ctx.nowMs);
  const ref = controlsRef(ctx.db, ctx.facilityId);
  const templatesCol = facilityCol(ctx.db, ctx.facilityId, STAY_COLLECTIONS.messageTemplates);
  const listingsCol = facilityCol(ctx.db, ctx.facilityId, STAY_COLLECTIONS.listings);

  const result = await ctx.db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const stored = normalizeControls(ctx.facilityId, snap.exists ? (snap.data() as Record<string, unknown>) : undefined);
    if (expectedVersion !== undefined && stored.version !== expectedVersion) {
      throw staysError('aborted', 'version_mismatch', 'These settings changed since you opened them. Reload and try again.', {
        version: stored.version,
      });
    }
    assertReservedKeys(changes, stored, ctx.role);
    assertExportAllowed(changes, stored, ctx.gate, ctx.facilityId);

    const next: StayControlsDoc = { ...stored, ...changes };
    // A zone counts only once someone confirms it; changing it undoes the
    // confirmation unless this same call confirms the new one.
    const zoneChanged = changes.timeZone !== undefined && changes.timeZone !== stored.timeZone;
    if (zoneChanged) {
      next.timeZoneConfirmedAt = null;
      next.timeZoneConfirmedBy = null;
    }
    if (confirmTimeZone) {
      if (!next.timeZone) {
        throw staysError('failed-precondition', 'timezone_unconfirmed', 'Choose the time zone before confirming it.');
      }
      next.timeZoneConfirmedAt = now;
      next.timeZoneConfirmedBy = ctx.uid;
    }
    if (next.moduleEnabled && (!next.timeZone || !next.timeZoneConfirmedAt)) {
      throw staysError(
        'failed-precondition',
        'timezone_unconfirmed',
        zoneChanged && stored.moduleEnabled
          ? 'Confirm the new time zone: every booking date is read in it.'
          : "Confirm the facility's time zone before turning Stays on.",
      );
    }

    // First turn-on: seed the message templates and fill empty checklists, once.
    const seededTemplateKeys: string[] = [];
    const listingFills: { id: string; doc: StayListingDoc }[] = [];
    const seedNow = next.moduleEnabled && !stored.templatesSeededAt;
    if (seedNow) {
      const existing = await tx.get(templatesCol.limit(STAYS_LIMITS.templatesPerFacility * 2));
      const taken = new Set(existing.docs.map((d) => d.id));
      let room = STAYS_LIMITS.templatesPerFacility - existing.size;
      for (const t of SEEDED_TEMPLATES) {
        if (taken.has(t.key) || room <= 0) continue;
        seededTemplateKeys.push(t.key);
        room--;
      }
      const listings = await tx.get(listingsCol.limit(500));
      for (const d of listings.docs) {
        const doc = d.data() as StayListingDoc;
        const mode = doc.turnover?.mode;
        if ((mode === 'full' || mode === 'quick_check') && (doc.turnover.checklistTemplate ?? []).length === 0) {
          listingFills.push({ id: d.id, doc });
        }
      }
      next.templatesSeededAt = now;
    }

    next.facilityId = ctx.facilityId;
    next.version = stored.version + 1;
    next.updatedAt = now;
    next.updatedBy = ctx.uid;
    if (!snap.exists || !stored.createdAt) {
      next.createdAt = now;
      next.createdBy = ctx.uid;
    }
    tx.set(ref, next);
    for (const key of seededTemplateKeys) {
      const template = SEEDED_TEMPLATES.find((t) => t.key === key)!;
      tx.set(templatesCol.doc(key), seededTemplateDoc(ctx.facilityId, template, ctx.uid, now));
    }
    for (const { id, doc } of listingFills) {
      tx.update(listingsCol.doc(id), {
        'turnover.checklistTemplate': defaultChecklistFor(doc.kind, doc.turnover.mode),
        version: (Number.isInteger(doc.version) ? doc.version : 0) + 1,
        updatedAt: now,
        updatedBy: ctx.uid,
      });
    }
    return {
      controls: next,
      seededTemplateKeys,
      filledChecklists: listingFills.length,
      // Turnovers just started, or their zone moved: every task due from today on is (re)planned.
      catchUpTurnovers: turnoversRunning(next) && (!turnoversRunning(stored) || stored.timeZone !== next.timeZone),
    };
  });

  // The trigger plans a turnover only when a booking changes, so bookings made
  // (or imported from a feed) before turnovers were on get theirs here. After
  // the commit: a failure leaves the settings saved, and the nightly
  // catch-up (reconcileTurnovers) tries again.
  let turnovers: ReconcileTurnoversResult | null = null;
  if (result.catchUpTurnovers) {
    try {
      turnovers = await reconcileTurnovers(ctx.db, ctx.facilityId, ctx.nowMs);
    } catch (error) {
      functions.logger.error('stays: turnover catch-up after a settings change failed', {
        facilityId: ctx.facilityId,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  const warnings: StaysWarning[] = [];
  const mismatch = mismatchWarning(result.controls.timeZone, ctx.facilityTimeZone);
  if (mismatch) warnings.push(mismatch);

  await auditStays(ctx, {
    eventType: 'stays.controls.updated',
    targetType: 'stayControls',
    targetId: 'current',
    metadata: {
      changed: Object.keys(changes).sort(),
      confirmedTimeZone: confirmTimeZone,
      version: result.controls.version,
      seededTemplates: result.seededTemplateKeys.length,
      filledChecklists: result.filledChecklists,
      turnoversPlanned: turnovers ? turnovers.created + turnovers.updated : null,
    },
  });

  return { controls: toWire(result.controls), warnings, seededTemplateKeys: result.seededTemplateKeys, turnovers };
}

export const staysSetControls = staysCallable(STAYS_CALLABLES.setControls, async (data, context) => {
  const { controls, warnings } = await handleSetControls(data, context);
  return { controls, warnings } satisfies StaysSetControlsResponse;
});

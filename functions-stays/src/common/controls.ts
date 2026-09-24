import type { DocumentReference, Firestore } from 'firebase-admin/firestore';

import {
  DEFAULT_PAYMENT_METHODS,
  MANUAL_PAYMENT_METHODS,
  STAYS_CURRENT_DOC_ID,
  STAY_COLLECTIONS,
  StayControlsDoc,
  StayManualPaymentMethod,
} from '@sfc/functions-shared/stays/contracts';
import { isValidHourMinute, isValidIanaZone } from '@sfc/functions-shared/stays/dates';

import { staysError } from './errors';

/**
 * stayControls/current (spec §3.3): per-facility module and automation
 * toggles, plus the confirmed zone. Only staysSetControls writes it, and
 * every toggle defaults to off.
 */
export function controlsRef(db: Firestore, facilityId: string): DocumentReference {
  return db
    .collection('facilities')
    .doc(facilityId)
    .collection(STAY_COLLECTIONS.controls)
    .doc(STAYS_CURRENT_DOC_ID);
}

export function defaultControls(facilityId: string): StayControlsDoc {
  return {
    facilityId,
    moduleEnabled: false,
    timeZone: null,
    timeZoneConfirmedAt: null,
    timeZoneConfirmedBy: null,
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
    paymentMethods: [...DEFAULT_PAYMENT_METHODS],
    parkRules: '',
    quietHours: '',
    guestMessagingEnabled: false,
    directPaymentsEnabled: false,
    templatesSeededAt: null,
    createdAt: null,
    createdBy: null,
    updatedAt: null,
    updatedBy: null,
    version: 0,
  };
}

function intIn(value: unknown, min: number, max: number, fallback: number): number {
  return Number.isInteger(value) && (value as number) >= min && (value as number) <= max ? (value as number) : fallback;
}

function str(value: unknown, max: number): string {
  return typeof value === 'string' ? value.slice(0, max) : '';
}

/**
 * Reads a stored doc defensively. Every automation boolean counts only when
 * it is exactly `true`; a bad zone reads as no zone, never as a default one.
 */
export function normalizeControls(facilityId: string, data: Record<string, unknown> | undefined): StayControlsDoc {
  const d = defaultControls(facilityId);
  if (!data) return d;
  const methods = Array.isArray(data.paymentMethods)
    ? (data.paymentMethods as unknown[]).filter((m): m is StayManualPaymentMethod =>
        (MANUAL_PAYMENT_METHODS as readonly unknown[]).includes(m),
      )
    : d.paymentMethods;
  const timeZone = isValidIanaZone(data.timeZone) ? (data.timeZone as string) : null;
  return {
    ...d,
    moduleEnabled: data.moduleEnabled === true,
    timeZone,
    timeZoneConfirmedAt: timeZone ? ((data.timeZoneConfirmedAt as StayControlsDoc['timeZoneConfirmedAt']) ?? null) : null,
    timeZoneConfirmedBy: timeZone && typeof data.timeZoneConfirmedBy === 'string' ? data.timeZoneConfirmedBy : null,
    icalSyncEnabled: data.icalSyncEnabled === true,
    icalExportEnabled: data.icalExportEnabled === true,
    turnoverTasksEnabled: data.turnoverTasksEnabled === true,
    dailyBriefEnabled: data.dailyBriefEnabled === true,
    dailyBriefLocalHour: intIn(data.dailyBriefLocalHour, 0, 23, d.dailyBriefLocalHour),
    lodgingTaxEnabled: data.lodgingTaxEnabled === true,
    employeesCanBook: data.employeesCanBook === true,
    employeesCanRecordCash: data.employeesCanRecordCash === true,
    defaultCheckInTime: isValidHourMinute(data.defaultCheckInTime) ? data.defaultCheckInTime : d.defaultCheckInTime,
    defaultCheckOutTime: isValidHourMinute(data.defaultCheckOutTime) ? data.defaultCheckOutTime : d.defaultCheckOutTime,
    shortLeadWarningHours: intIn(data.shortLeadWarningHours, 0, 720, d.shortLeadWarningHours),
    paymentMethods: methods,
    parkRules: str(data.parkRules, 4000),
    quietHours: str(data.quietHours, 200),
    guestMessagingEnabled: data.guestMessagingEnabled === true,
    directPaymentsEnabled: data.directPaymentsEnabled === true,
    templatesSeededAt: (data.templatesSeededAt as StayControlsDoc['templatesSeededAt']) ?? null,
    createdAt: (data.createdAt as StayControlsDoc['createdAt']) ?? null,
    createdBy: typeof data.createdBy === 'string' ? data.createdBy : null,
    updatedAt: (data.updatedAt as StayControlsDoc['updatedAt']) ?? null,
    updatedBy: typeof data.updatedBy === 'string' ? data.updatedBy : null,
    version: intIn(data.version, 0, Number.MAX_SAFE_INTEGER, 0),
  };
}

/** The facility's controls; a missing doc is all defaults (module off). A failed read throws. */
export async function loadControls(db: Firestore, facilityId: string): Promise<StayControlsDoc> {
  const snap = await controlsRef(db, facilityId).get();
  return normalizeControls(facilityId, snap.exists ? (snap.data() as Record<string, unknown>) : undefined);
}

export function assertModuleEnabled(controls: StayControlsDoc): void {
  if (controls.moduleEnabled !== true) {
    throw staysError('failed-precondition', 'module_disabled', 'Stays is not turned on for this facility.');
  }
}

/**
 * The confirmed facility zone. Nothing falls back to a default zone: an
 * unconfirmed one stops the call.
 */
export function confirmedTimeZone(controls: StayControlsDoc): string {
  if (!controls.timeZone || !controls.timeZoneConfirmedAt || !isValidIanaZone(controls.timeZone)) {
    throw staysError(
      'failed-precondition',
      'timezone_unconfirmed',
      "Confirm the facility's time zone in Stays settings first.",
    );
  }
  return controls.timeZone;
}

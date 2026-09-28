/**
 * Deterministic document ids for Stays (spec §3.3, §6.11).
 *
 * Every money write and every notification is keyed by one of these, so a
 * retried call lands on the same doc and a create() of it reports
 * ALREADY_EXISTS instead of writing a second row.
 */
import { createHash, randomBytes } from 'crypto';

import type { StayNotificationType, Ymd, YearMonth } from './contracts';

export function sha256Hex(text: string): string {
  return createHash('sha256').update(text, 'utf8').digest('hex');
}

/** The app mints these: 128 random bits as 32 lowercase hex characters. */
export function isValidRequestId(value: unknown): value is string {
  return typeof value === 'string' && /^[a-f0-9]{32}$/.test(value);
}

/**
 * A Firestore document id a caller may name: 1–128 characters, no slash, and
 * none of the ids Firestore reserves ('.', '..', '__…__').
 */
export function isValidDocId(value: unknown): value is string {
  return (
    typeof value === 'string' &&
    /^[^/]{1,128}$/.test(value) &&
    value !== '.' &&
    value !== '..' &&
    !/^__.*__$/.test(value)
  );
}

/** An Airbnb confirmation code, e.g. 'HMABC12345'. */
export function normalizeAirbnbCode(code: unknown): string | null {
  if (typeof code !== 'string') return null;
  const upper = code.trim().toUpperCase();
  return /^[A-Z0-9]{6,14}$/.test(upper) ? upper : null;
}

/**
 * Any Airbnb reservation with a confirmation code, whether it came from the
 * feed, the CSV or a manual entry, so all three converge on one doc.
 */
export function stayIdForAirbnb(code: string): string {
  const normalized = normalizeAirbnbCode(code);
  if (!normalized) {
    throw new Error('stayIdForAirbnb: not an Airbnb confirmation code');
  }
  return `airbnb_${normalized}`;
}

/**
 * Other feed events. The channel id is deliberately not part of it: removing
 * and re-adding a feed must find the same stays rather than duplicate them.
 */
export function stayIdForFeed(listingId: string, provider: string, uid: string): string {
  return `ical_${sha256Hex(`${listingId}|${provider}|${uid}`).slice(0, 40)}`;
}

/** Stays and blocks SFC creates. */
export function stayIdManual(requestId: string): string {
  if (!isValidRequestId(requestId)) {
    throw new Error('stayIdManual: requestId must be 32 lowercase hex characters');
  }
  return `man_${requestId}`;
}

export function lockBucketId(listingId: string, month: YearMonth): string {
  return `${listingId}_${month}`;
}

export function incomeIdManual(requestId: string): string {
  if (!isValidRequestId(requestId)) {
    throw new Error('incomeIdManual: requestId must be 32 lowercase hex characters');
  }
  return `man_${requestId}`;
}

/**
 * One Airbnb CSV row. The listing title is never part of it, so renaming a
 * listing cannot import a row twice; `occurrence` counts identical rows over
 * the whole file.
 */
export function incomeIdAirbnb(
  facilityId: string,
  codeOrReference: string,
  type: string,
  dateYmd: Ymd,
  amountCents: number,
  occurrence: number,
): string {
  if (!Number.isInteger(amountCents) || !Number.isInteger(occurrence) || occurrence < 0) {
    throw new Error('incomeIdAirbnb: amountCents and occurrence must be integers');
  }
  const key = [facilityId, codeOrReference, type, dateYmd, String(amountCents), String(occurrence)].join('|');
  return `abnb_${sha256Hex(key).slice(0, 40)}`;
}

export function expenseId(requestId: string): string {
  if (!isValidRequestId(requestId)) {
    throw new Error('expenseId: requestId must be 32 lowercase hex characters');
  }
  return `exp_${requestId}`;
}

export function taskIdTurnover(stayId: string): string {
  return `turnover_${stayId}`;
}

export function listingIdBulk(requestId: string, n: number): string {
  if (!isValidRequestId(requestId) || !Number.isInteger(n) || n < 0) {
    throw new Error('listingIdBulk: bad requestId or site number');
  }
  return `lst_${requestId}_${n}`;
}

export function guestProfileIdFor(requestId: string): string {
  if (!isValidRequestId(requestId)) {
    throw new Error('guestProfileIdFor: requestId must be 32 lowercase hex characters');
  }
  return `gp_${requestId}`;
}

/** `lst_…`, `ch_…`, `xl_…`: an id nobody retries against. */
export function randomId(prefix: string): string {
  return `${prefix}_${randomBytes(10).toString('hex')}`;
}

/** staySyncJobs/{slot}_{facilityId}. */
export function jobId(slot: string, facilityId: string): string {
  return `${slot}_${facilityId}`;
}

/** staySyncLog/{runId}. */
export function syncLogIdScheduled(slot: string, channelId: string): string {
  return `${slot}_${channelId}`;
}

export function syncLogIdManual(nowMs: number, channelId: string): string {
  return `manual_${nowMs}_${channelId}`;
}

/** stayImportBatches/{sha256(csvText)}. */
export function importBatchId(csvText: string): string {
  return sha256Hex(csvText);
}

/** The raw export token: 24 random bytes, 48 lowercase hex. */
export function newExportToken(): string {
  return randomBytes(24).toString('hex');
}

export function isValidExportToken(value: unknown): value is string {
  return typeof value === 'string' && /^[a-f0-9]{48}$/.test(value);
}

/** stayCalendarExportTokens/{sha256hex(token)}: the endpoint never stores or logs the raw token. */
export function exportTokenHash(token: string): string {
  return sha256Hex(token);
}

export type NotificationIdInput =
  | { kind: 'stay'; type: StayNotificationType; stayId: string; version: number }
  | { kind: 'conflict'; stayId: string; conflictStayIds: string[] }
  | { kind: 'feed'; channelId: string; status: string; ymd: Ymd }
  | { kind: 'brief'; ymd: Ymd }
  | { kind: 'turnover_done'; taskId: string }
  | { kind: 'turnover_issue'; taskId: string; note: string }
  | { kind: 'unassigned'; taskId: string; dueDate: Ymd };

/**
 * facilities/{fid}/Notifications ids (spec §6.11). Written with create(), so
 * the id is also the "already told them" marker.
 */
export function notificationId(input: NotificationIdInput): string {
  switch (input.kind) {
    case 'stay':
      return `stay_${input.type.replace(/^STAY_/, '').toLowerCase()}_${input.stayId}_${input.version}`;
    case 'conflict': {
      const others = [...input.conflictStayIds].sort().join('|');
      return `stay_conflict_${input.stayId}_${sha256Hex(others).slice(0, 12)}`;
    }
    case 'feed':
      return `stay_feed_${input.channelId}_${input.status}_${input.ymd}`;
    case 'brief':
      return `stay_brief_${input.ymd}`;
    case 'turnover_done':
      return `stay_turnover_done_${input.taskId}`;
    case 'turnover_issue':
      return `stay_turnover_issue_${input.taskId}_${sha256Hex(input.note).slice(0, 12)}`;
    case 'unassigned':
      return `stay_unassigned_${input.taskId}_${input.dueDate}`;
  }
}

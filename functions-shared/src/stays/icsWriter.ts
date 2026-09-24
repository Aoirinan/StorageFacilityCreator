/**
 * The iCal export (spec §1.1 G, §6.9): busy blocks only, for a channel to
 * import. Each VEVENT says "Not available" and nothing else, so no guest
 * name, source, note or amount can leave through it; the UID is a hash of
 * the stay id, so it is stable across fetches without revealing the id.
 *
 * What goes in is decided by staysForExport: never imported channel blocks
 * (the endpoint does not even read them), never the target channel's own
 * bookings, and only as much as the link's scope allows. That is what keeps
 * two channels from bouncing each other's blocks back and forth.
 */
import type { ExportScope, ExportTargetProvider, StayKind, StaySource, StayStatus, Ymd } from './contracts';
import { OTA_SOURCES, SFC_BOOKING_SOURCES } from './contracts';
import { isActiveStatus } from './nightLocks';
import { sha256Hex } from './ids';

export const ICS_PRODID = '-//Storage Facility Creator//Stays//EN';
export const ICS_UID_DOMAIN = 'stays.storagefacilitycreator.com';
export const ICS_BUSY_SUMMARY = 'Not available';

export interface IcsExportEvent {
  stayId: string;
  checkIn: Ymd;
  /** Exclusive. */
  checkOut: Ymd;
  /** SEQUENCE: bumps when the stay changes, so channels update it. */
  version: number;
}

export interface BuildIcsInput {
  calName: string;
  events: readonly IcsExportEvent[];
  /** DTSTAMP; defaults to now. */
  now?: number;
}

/** TEXT escaping (RFC 5545 §3.3.11). */
export function escapeText(value: string): string {
  return value.replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\r\n|\r|\n/g, '\\n');
}

/** Folds a content line at 75 octets, never inside a UTF-8 character; continuations start with one space. */
export function foldLine(line: string): string {
  if (Buffer.byteLength(line, 'utf8') <= 75) return line;
  const out: string[] = [];
  let current = '';
  let bytes = 0;
  let limit = 75;
  for (const ch of line) {
    const size = Buffer.byteLength(ch, 'utf8');
    if (bytes + size > limit) {
      out.push(current);
      current = ' ';
      bytes = 1;
      limit = 75;
    }
    current += ch;
    bytes += size;
  }
  out.push(current);
  return out.join('\r\n');
}

function ymdToIcsDate(ymd: Ymd): string {
  return ymd.replace(/-/g, '');
}

function icsTimestamp(ms: number): string {
  return new Date(ms).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z');
}

/** A stable UID for a stay that does not reveal its id. */
export function exportUid(stayId: string): string {
  return `${sha256Hex(stayId).slice(0, 32)}@${ICS_UID_DOMAIN}`;
}

/** The whole calendar: CRLF line ends, folded lines, one busy VEVENT per stay. */
export function buildIcs(input: BuildIcsInput): string {
  const stamp = icsTimestamp(input.now ?? Date.now());
  const lines: string[] = [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    `PRODID:${ICS_PRODID}`,
    'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH',
    `X-WR-CALNAME:${escapeText(input.calName)}`,
  ];
  const events = [...input.events].sort((a, b) =>
    a.checkIn < b.checkIn ? -1 : a.checkIn > b.checkIn ? 1 : a.stayId < b.stayId ? -1 : a.stayId > b.stayId ? 1 : 0,
  );
  for (const e of events) {
    lines.push(
      'BEGIN:VEVENT',
      `UID:${exportUid(e.stayId)}`,
      `DTSTAMP:${stamp}`,
      `DTSTART;VALUE=DATE:${ymdToIcsDate(e.checkIn)}`,
      `DTEND;VALUE=DATE:${ymdToIcsDate(e.checkOut)}`,
      `SEQUENCE:${Number.isInteger(e.version) && e.version >= 0 ? e.version : 0}`,
      `SUMMARY:${ICS_BUSY_SUMMARY}`,
      'TRANSP:OPAQUE',
      'END:VEVENT',
    );
  }
  lines.push('END:VCALENDAR');
  return lines.map(foldLine).join('\r\n') + '\r\n';
}

/** The fields of a stay the export rules look at. */
export interface ExportableStay {
  stayId: string;
  status: StayStatus;
  kind: StayKind;
  source: StaySource;
  checkIn: Ymd;
  checkOut: Ymd;
  version: number;
}

export interface ExportFilter {
  scope: ExportScope;
  targetProvider: ExportTargetProvider;
  /** Stays ending before today are left out. */
  todayYmd: Ymd;
  /** Stays starting after this (today + 540) are left out. */
  lastCheckInYmd: Ymd;
}

/**
 * Whether a stay's kind and source are in a link's scope (ignoring dates):
 * blocks_only → owner and maintenance blocks; sfc → plus direct, phone and
 * walk-up bookings; all → plus other channels' bookings. The target
 * channel's own bookings are always left out.
 */
export function inExportScope(stay: Pick<ExportableStay, 'kind' | 'source'>, scope: ExportScope, targetProvider: ExportTargetProvider): boolean {
  if ((stay.source as string) === (targetProvider as string)) return false;
  if (stay.kind === 'owner_block' || stay.kind === 'maintenance_block') return true;
  if (stay.kind !== 'reservation') return false;
  if (scope === 'blocks_only') return false;
  if ((SFC_BOOKING_SOURCES as readonly string[]).includes(stay.source)) return true;
  return scope === 'all' && (OTA_SOURCES as readonly string[]).includes(stay.source);
}

/** The stays an export link sends: active, in scope, from today to today+540. */
export function staysForExport<T extends ExportableStay>(stays: readonly T[], filter: ExportFilter): T[] {
  return stays.filter(
    (s) =>
      isActiveStatus(s.status) &&
      s.checkOut >= filter.todayYmd &&
      s.checkIn <= filter.lastCheckInYmd &&
      s.checkIn < s.checkOut &&
      inExportScope(s, filter.scope, filter.targetProvider),
  );
}

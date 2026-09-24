/**
 * iCal import for Stays (spec §6.8 "Parsing" and "Classification").
 *
 * A feed is untrusted text from a channel. Only dates, UIDs, the event status
 * and a few Airbnb constants are kept; any other SUMMARY or DESCRIPTION text
 * is dropped as possibly personal (a guest name in a VRBO summary, a phone
 * number in a Google description). Parsing is all-or-nothing: a feed that
 * breaks a cap throws instead of returning part of itself, because a partial
 * parse would read as bookings missing from the feed.
 */
import type { ChannelProvider, Ymd } from './contracts';
import { STAYS_LIMITS } from './contracts';
import { addDays, facilityToday, isValidIanaZone, isValidYmd, localDateTimeToUtc } from './dates';

/**
 * Caps. The line cap is set by the event cap, not the other way round: 3000
 * events of ~10 lines each already need 30,000 lines, and the 2 MB byte cap
 * on the fetch is the real bound on work. A longer logical line is cut to
 * 8 KB (only free text is ever that long).
 */
export const ICS_LIMITS = {
  maxLines: 100_000,
  maxLineChars: 8 * 1024,
  maxEvents: STAYS_LIMITS.feedMaxEvents,
} as const;

/** Airbnb's own sites; reservation links are trusted only on these. */
export const AIRBNB_HOSTS: readonly string[] = [
  'www.airbnb.com',
  'airbnb.com',
  'www.airbnb.ca',
  'www.airbnb.co.uk',
  'www.airbnb.com.au',
  'www.airbnb.ie',
  'www.airbnb.co.nz',
];

/** The only SUMMARY values kept on a stay (spec §3.3 `external.summary`). */
export const AIRBNB_SUMMARY_CONSTANTS: readonly string[] = ['Reserved', 'Airbnb (Not available)'];

export type IcsParseErrorCode = 'invalid_feed' | 'too_large';

export class IcsParseError extends Error {
  constructor(
    readonly code: IcsParseErrorCode,
    message: string,
  ) {
    super(message);
    this.name = 'IcsParseError';
  }
}

export interface IcsEvent {
  uid: string | null;
  /** Untrusted: use only through classifyEvent and extractAirbnbRefs. */
  summary: string | null;
  /** Untrusted: use only through classifyEvent and extractAirbnbRefs. */
  description: string | null;
  /** Facility-local first night. */
  checkIn: Ymd;
  /** Facility-local, exclusive. */
  checkOut: Ymd;
}

export type IcsWarningCode = 'events_skipped' | 'recurring_events_skipped' | 'unknown_time_zone' | 'long_lines_cut';

export interface ParseIcsResult {
  events: IcsEvent[];
  /** Every VEVENT in the feed, including the skipped ones. */
  eventCount: number;
  cancelled: number;
  /** Timed events that start and end on the same local day: they hold no night. */
  withinOneDay: number;
  skippedRecurring: number;
  skippedInvalid: number;
  warnings: IcsWarningCode[];
}

// ---------------------------------------------------------------------------
// Lines
// ---------------------------------------------------------------------------

/** RFC 5545 §3.1: a line starting with a space or tab continues the previous one. */
function unfold(text: string): { lines: string[]; cut: boolean } {
  const raw = text.replace(/^\uFEFF/, '').split(/\r\n|\n|\r/);
  const lines: string[] = [];
  let cut = false;
  for (const line of raw) {
    if ((line.startsWith(' ') || line.startsWith('\t')) && lines.length > 0) {
      const prev = lines[lines.length - 1];
      if (prev.length < ICS_LIMITS.maxLineChars) {
        lines[lines.length - 1] = prev + line.slice(1);
      } else {
        cut = true;
      }
      continue;
    }
    if (line.length === 0) continue;
    lines.push(line);
    if (lines.length > ICS_LIMITS.maxLines) {
      throw new IcsParseError('too_large', 'The calendar has too many lines.');
    }
  }
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].length > ICS_LIMITS.maxLineChars) {
      lines[i] = lines[i].slice(0, ICS_LIMITS.maxLineChars);
      cut = true;
    }
  }
  return { lines, cut };
}

interface ContentLine {
  name: string;
  params: Record<string, string>;
  value: string;
}

/** NAME;PARAM=VALUE;PARAM="quoted:value":value */
function parseContentLine(line: string): ContentLine | null {
  let i = 0;
  while (i < line.length && line[i] !== ';' && line[i] !== ':') i++;
  const name = line.slice(0, i).trim().toUpperCase();
  if (!name) return null;
  const params: Record<string, string> = {};
  while (i < line.length && line[i] === ';') {
    i++;
    const eq = line.indexOf('=', i);
    if (eq < 0) return null;
    const key = line.slice(i, eq).trim().toUpperCase();
    i = eq + 1;
    let value = '';
    if (line[i] === '"') {
      const close = line.indexOf('"', i + 1);
      if (close < 0) return null;
      value = line.slice(i + 1, close);
      i = close + 1;
      // A list of values: keep the first.
      while (i < line.length && line[i] !== ';' && line[i] !== ':') i++;
    } else {
      const start = i;
      while (i < line.length && line[i] !== ';' && line[i] !== ':') i++;
      value = line.slice(start, i).split(',')[0];
    }
    params[key] = value;
  }
  if (line[i] !== ':') return null;
  return { name, params, value: line.slice(i + 1) };
}

/** TEXT values: \n \N \, \; \\ (RFC 5545 §3.3.11). */
export function unescapeText(value: string): string {
  return value.replace(/\\([\\;,nN])/g, (_, c: string) => (c === 'n' || c === 'N' ? '\n' : c));
}

// ---------------------------------------------------------------------------
// Dates
// ---------------------------------------------------------------------------

interface IcsDate {
  /** The facility-local date. */
  ymd: Ymd;
  /** The instant, for DATE-TIME values with Z or a known TZID. */
  ms: number | null;
  isDate: boolean;
}

const DATE_RE = /^(\d{4})(\d{2})(\d{2})$/;
const DATE_TIME_RE = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)$/;

function toIcsDate(prop: ContentLine, tz: string, warnings: Set<IcsWarningCode>): IcsDate | null {
  const value = prop.value.trim();
  const d = DATE_RE.exec(value);
  if (d || prop.params.VALUE?.toUpperCase() === 'DATE') {
    if (!d) return null;
    const ymd = `${d[1]}-${d[2]}-${d[3]}`;
    return isValidYmd(ymd) ? { ymd, ms: null, isDate: true } : null;
  }
  const t = DATE_TIME_RE.exec(value);
  if (!t) return null;
  const ymd = `${t[1]}-${t[2]}-${t[3]}`;
  const hh = Number(t[4]);
  const mi = Number(t[5]);
  const ss = Number(t[6]);
  if (!isValidYmd(ymd) || hh > 23 || mi > 59 || ss > 60) return null;
  let ms: number | null = null;
  if (t[7] === 'Z') {
    ms = Date.UTC(Number(t[1]), Number(t[2]) - 1, Number(t[3]), hh, mi, ss);
  } else if (prop.params.TZID) {
    const zone = prop.params.TZID.replace(/^\/mozilla\.org\/[^/]+\//, '');
    if (isValidIanaZone(zone)) {
      ms = localDateTimeToUtc(ymd, `${t[4]}:${t[5]}`, zone).getTime() + ss * 1000;
    } else {
      // A Windows zone name or similar: read the wall time as facility time.
      warnings.add('unknown_time_zone');
    }
  }
  if (ms === null) {
    // Floating time: the facility's own wall clock.
    return { ymd, ms: null, isDate: false };
  }
  return { ymd: facilityToday(tz, ms), ms, isDate: false };
}

/** P1D, P2W, PT36H, P1DT12H: milliseconds, or null. */
function parseDurationMs(value: string): number | null {
  const m = /^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/.exec(value.trim());
  if (!m || value.trim() === 'P' || /T$/.test(value.trim())) return null;
  if (m[1] === '-') return null;
  const [w, d, h, mi, s] = [m[2], m[3], m[4], m[5], m[6]].map((x) => Number(x ?? 0));
  return ((((w * 7 + d) * 24 + h) * 60 + mi) * 60 + s) * 1000;
}


// ---------------------------------------------------------------------------
// Parse
// ---------------------------------------------------------------------------

interface RawEvent {
  props: Map<string, ContentLine>;
  recurring: boolean;
}

/**
 * Parses a feed into facility-local stays: RFC 5545 unfolding, CRLF or LF,
 * BOM stripped, TEXT unescaped. DATE values are taken as-is; DATE-TIME
 * values with Z or TZID become facility-local dates, and the checkout is the
 * local date the event ends on (exclusive, so an end at local 00:00 frees
 * that day). A missing DTEND on a DATE start means one night.
 * STATUS:CANCELLED events are left out, recurring events are skipped and
 * counted, a timed event inside one day is counted and left out (it holds
 * no night), and any other event whose end is not after its start is
 * skipped with a warning. Throws IcsParseError when the text is not a
 * calendar or breaks a cap.
 */
export function parseIcs(text: string, tz: string): ParseIcsResult {
  if (!isValidIanaZone(tz)) throw new Error('parseIcs: a confirmed facility time zone is required');
  const { lines, cut } = unfold(text);
  if (lines.length === 0 || lines[0].trim().toUpperCase() !== 'BEGIN:VCALENDAR') {
    throw new IcsParseError('invalid_feed', 'That is not a calendar.');
  }
  const warnings = new Set<IcsWarningCode>();
  if (cut) warnings.add('long_lines_cut');

  const raw: RawEvent[] = [];
  const stack: string[] = [];
  let current: RawEvent | null = null;
  let sawEnd = false;
  for (const line of lines) {
    const prop = parseContentLine(line);
    if (!prop) continue;
    if (prop.name === 'BEGIN') {
      const component = prop.value.trim().toUpperCase();
      stack.push(component);
      if (component === 'VEVENT' && stack.length === 2 && stack[0] === 'VCALENDAR') {
        if (raw.length >= ICS_LIMITS.maxEvents) {
          throw new IcsParseError('too_large', 'The calendar has too many events.');
        }
        current = { props: new Map(), recurring: false };
        raw.push(current);
      }
      continue;
    }
    if (prop.name === 'END') {
      const component = prop.value.trim().toUpperCase();
      const open = stack.pop();
      if (open !== component) throw new IcsParseError('invalid_feed', 'The calendar is malformed.');
      if (component === 'VEVENT' && stack.length === 1) current = null;
      if (component === 'VCALENDAR' && stack.length === 0) sawEnd = true;
      continue;
    }
    // Only the event's own properties: an alarm's DESCRIPTION is not the event's.
    if (!current || stack.length !== 2) continue;
    if (prop.name === 'RRULE' || prop.name === 'RDATE' || prop.name === 'RECURRENCE-ID') {
      current.recurring = true;
      continue;
    }
    if (!current.props.has(prop.name)) current.props.set(prop.name, prop);
  }
  if (!sawEnd || stack.length !== 0) throw new IcsParseError('invalid_feed', 'The calendar is cut off.');

  const result: ParseIcsResult = {
    events: [],
    eventCount: raw.length,
    cancelled: 0,
    withinOneDay: 0,
    skippedRecurring: 0,
    skippedInvalid: 0,
    warnings: [],
  };
  for (const ev of raw) {
    const status = ev.props.get('STATUS')?.value.trim().toUpperCase() ?? null;
    if (status === 'CANCELLED') {
      result.cancelled++;
      continue;
    }
    if (ev.recurring) {
      result.skippedRecurring++;
      continue;
    }
    const startProp = ev.props.get('DTSTART');
    const start = startProp ? toIcsDate(startProp, tz, warnings) : null;
    if (!start) {
      result.skippedInvalid++;
      continue;
    }
    let checkOut: Ymd | null = null;
    const endProp = ev.props.get('DTEND');
    const durationProp = ev.props.get('DURATION');
    // The checkout is the facility-local date the event ends on, and it is
    // exclusive. For DATE values that is DTEND as written. For a DATE-TIME
    // end it is the local date of that instant: a stay ending 11:00 on the
    // 6th frees the night of the 6th, and an end exactly at local 00:00 frees
    // that day too. A timed event inside one day (a cleaning 10:00-14:00)
    // holds no night and is left out.
    if (endProp) {
      checkOut = toIcsDate(endProp, tz, warnings)?.ymd ?? null;
    } else if (durationProp) {
      const ms = parseDurationMs(durationProp.value);
      if (ms !== null && start.isDate) {
        checkOut = addDays(start.ymd, Math.max(1, Math.round(ms / 86_400_000)));
      } else if (ms !== null && start.ms !== null) {
        checkOut = facilityToday(tz, start.ms + ms);
      } else if (ms !== null) {
        checkOut = addDays(start.ymd, Math.floor(ms / 86_400_000));
      }
    } else {
      // No DTEND: a DATE start is one night; a timed start is a moment, which holds none.
      checkOut = start.isDate ? addDays(start.ymd, 1) : start.ymd;
    }
    if (checkOut && checkOut === start.ymd && !start.isDate) {
      result.withinOneDay++;
      continue;
    }
    if (!checkOut || checkOut <= start.ymd) {
      result.skippedInvalid++;
      continue;
    }
    const uid = ev.props.get('UID')?.value.trim() || null;
    const summary = ev.props.get('SUMMARY');
    const description = ev.props.get('DESCRIPTION');
    result.events.push({
      uid: uid ? uid.slice(0, 512) : null,
      summary: summary ? unescapeText(summary.value).trim() : null,
      description: description ? unescapeText(description.value) : null,
      checkIn: start.ymd,
      checkOut,
    });
  }
  if (result.skippedInvalid > 0) warnings.add('events_skipped');
  if (result.skippedRecurring > 0) warnings.add('recurring_events_skipped');
  result.warnings = [...warnings].sort();
  return result;
}

// ---------------------------------------------------------------------------
// Classification
// ---------------------------------------------------------------------------

export type IcsEventClass = 'reservation' | 'block';

const BLOCK_WORDS = /blocked|not available|unavailable|closed/i;
/** A Booking.com reservation reference in a description: "Reservation number: 1234567890". */
const BOOKING_REFERENCE = /\b(?:reservation|booking)\s*(?:id|number|no\.?|#|ref(?:erence)?)\s*[:#]?\s*\d{6,}/i;

/**
 * Airbnb: SUMMARY "Reserved", or a reservation link in DESCRIPTION, is a
 * booking; anything else ("Airbnb (Not available)") is a block. Booking.com:
 * "CLOSED - Not available" is a block unless a reservation reference is
 * present. VRBO, Hipcamp, Google and others: a block when the SUMMARY says
 * blocked / not available / unavailable / closed, otherwise a booking.
 */
export function classifyEvent(provider: ChannelProvider | string, summary: string | null, description: string | null): IcsEventClass {
  const s = (summary ?? '').trim();
  if (provider === 'airbnb') {
    if (/^reserved$/i.test(s) || extractAirbnbRefs(description).confirmationCode) return 'reservation';
    return 'block';
  }
  if (provider === 'booking') {
    if (BOOKING_REFERENCE.test(description ?? '')) return 'reservation';
    return BLOCK_WORDS.test(s) || s === '' ? 'block' : 'reservation';
  }
  return BLOCK_WORDS.test(s) ? 'block' : 'reservation';
}

export interface AirbnbRefs {
  confirmationCode: string | null;
  /** https://{airbnb host}/hosting/reservations/details/{CODE}, nothing else. */
  reservationUrl: string | null;
  phoneLast4: string | null;
}

const RESERVATION_PATH = /^\/hosting\/reservations\/details\/([A-Z0-9]{6,14})\/?$/;
const URL_IN_TEXT = /https?:\/\/[^\s<>"'\\]+/g;
const PHONE_LAST4 = /Phone Number \(Last 4 Digits\):\s*(\d{4})\b/i;

/**
 * The confirmation code and reservation link from an Airbnb DESCRIPTION,
 * only from an https link on an Airbnb host with the reservation path; and
 * the "Phone Number (Last 4 Digits)" line. Everything else in the text is
 * ignored.
 */
export function extractAirbnbRefs(description: string | null | undefined): AirbnbRefs {
  const refs: AirbnbRefs = { confirmationCode: null, reservationUrl: null, phoneLast4: null };
  if (!description) return refs;
  for (const match of description.matchAll(URL_IN_TEXT)) {
    let u: URL;
    try {
      u = new URL(match[0]);
    } catch {
      continue;
    }
    const host = u.hostname.toLowerCase();
    if (u.protocol !== 'https:' || u.username || u.password || (u.port !== '' && u.port !== '443')) continue;
    if (!AIRBNB_HOSTS.includes(host)) continue;
    const path = RESERVATION_PATH.exec(u.pathname);
    if (!path) continue;
    refs.confirmationCode = path[1];
    refs.reservationUrl = `https://${host}/hosting/reservations/details/${path[1]}`;
    break;
  }
  const phone = PHONE_LAST4.exec(description);
  if (phone) refs.phoneLast4 = phone[1];
  return refs;
}

/** A SUMMARY worth keeping: only Airbnb's own constants. */
export function keptSummary(provider: ChannelProvider | string, summary: string | null): string | null {
  if (provider !== 'airbnb' || !summary) return null;
  return AIRBNB_SUMMARY_CONSTANTS.find((c) => c.toLowerCase() === summary.trim().toLowerCase()) ?? null;
}

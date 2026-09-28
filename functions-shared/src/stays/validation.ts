/**
 * Listing input validation for Stays (spec §3.3, §6.2).
 *
 * Firestore rules cannot check the elements of a list, so listings are
 * written only by staysSaveListing / staysBulkCreateRvSites, which run every
 * value through here first, and quoteStay re-checks the money-bearing lists
 * when it reads a stored listing. Bad values are rejected with the field
 * named, never coerced: a string is not a number, 1.5 nights is not 1, and an
 * unknown enum is not the default. Only whitespace around text is trimmed and
 * a blank optional text becomes null.
 */
import {
  ACCESS_CODE_MODES,
  RV_AMPS,
  RV_HOOKUPS,
  STAYS_LIMITS,
  STAY_LISTING_KINDS,
  TAX_APPLIES_TO,
  TURNOVER_MODES,
  type HourMinute,
  type StayChecklistTemplateItem,
  type StayListingAirbnb,
  type StayListingCapacity,
  type StayListingInput,
  type StayListingRates,
  type StayListingRules,
  type StayListingRv,
  type StayListingTimes,
  type StayListingTurnover,
  type StaySeasonalRate,
  type StayTaxLine,
  type TaxAppliesTo,
} from './contracts';
import { isValidHourMinute, isValidYmd } from './dates';

/** A value a person entered that Stays will not store; `field` is its dotted path. */
export class StayValidationError extends Error {
  constructor(
    readonly field: string,
    message: string,
  ) {
    super(message);
    this.name = 'StayValidationError';
  }
}

/** The most any one rate or fee may be: $100,000, in cents. */
export const MAX_RATE_CENTS = 10_000_000;
export const MAX_SEASONAL_RATES = 10;
export const MAX_TAX_LINES = 10;
export const MAX_CHECKLIST_ITEMS = 50;
export const MAX_AIRBNB_ALIASES = 10;

/** Hosts an Airbnb listing or calendar page may be on (https only). */
export const AIRBNB_WEB_HOSTS: ReadonlySet<string> = new Set([
  'www.airbnb.com',
  'airbnb.com',
  'www.airbnb.ca',
  'www.airbnb.co.uk',
  'www.airbnb.com.au',
  'www.airbnb.ie',
  'www.airbnb.co.nz',
]);

function fail(field: string, message: string): never {
  throw new StayValidationError(field, message);
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function record(value: unknown, field: string): Record<string, unknown> {
  if (!isPlainObject(value)) fail(field, `${field} is missing or not an object.`);
  return value;
}

function list(value: unknown, field: string, max: number): unknown[] {
  if (!Array.isArray(value)) fail(field, `${field} must be a list.`);
  if (value.length > max) fail(field, `${field} can have at most ${max} entries.`);
  return value;
}

const CONTROL_CHARS = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/;
const LINE_BREAKS = /[\r\n\t]/;

interface TextOptions {
  min?: number;
  max: number;
  /** Names, codes and labels: no line breaks or tabs. */
  singleLine?: boolean;
}

/** Text, trimmed. */
export function validateText(value: unknown, field: string, opts: TextOptions): string {
  if (typeof value !== 'string') fail(field, `${field} must be text.`);
  const text = value.trim();
  const min = opts.min ?? 0;
  if (text.length < min) fail(field, min === 1 ? `${field} is required.` : `${field} needs at least ${min} characters.`);
  if (text.length > opts.max) fail(field, `${field} can be at most ${opts.max} characters.`);
  if (CONTROL_CHARS.test(text)) fail(field, `${field} contains characters that cannot be stored.`);
  if (opts.singleLine && LINE_BREAKS.test(text)) fail(field, `${field} must be on one line.`);
  return text;
}

/** Optional text: absent, null or blank is null. */
export function validateOptionalText(value: unknown, field: string, opts: TextOptions): string | null {
  if (value === undefined || value === null) return null;
  if (typeof value === 'string' && value.trim() === '') return null;
  return validateText(value, field, opts);
}

export function validateInt(value: unknown, field: string, min: number, max: number): number {
  if (typeof value !== 'number' || !Number.isInteger(value)) fail(field, `${field} must be a whole number.`);
  if (value < min || value > max) fail(field, `${field} must be between ${min} and ${max}.`);
  return value;
}

export function validateOptionalInt(value: unknown, field: string, min: number, max: number): number | null {
  if (value === undefined || value === null) return null;
  return validateInt(value, field, min, max);
}

export function validateBool(value: unknown, field: string): boolean {
  if (typeof value !== 'boolean') fail(field, `${field} must be true or false.`);
  return value;
}

export function validateEnum<T extends string>(value: unknown, field: string, allowed: readonly T[]): T {
  if (typeof value !== 'string' || !(allowed as readonly string[]).includes(value)) {
    fail(field, `${field} must be one of: ${allowed.join(', ')}.`);
  }
  return value as T;
}

function validateCents(value: unknown, field: string): number {
  return validateInt(value, field, 0, MAX_RATE_CENTS);
}

function validateOptionalCents(value: unknown, field: string): number | null {
  return validateOptionalInt(value, field, 0, MAX_RATE_CENTS);
}

/** 'HH:mm', 24-hour. */
export function validateTime(value: unknown, field = 'time'): HourMinute {
  if (!isValidHourMinute(value)) fail(field, `${field} must be a 24-hour time like 15:00.`);
  return value;
}

export function validateOptionalTime(value: unknown, field: string): HourMinute | null {
  if (value === undefined || value === null) return null;
  return validateTime(value, field);
}

/** A calendar day written 'MM-DD'; 02-29 is allowed (it happens in leap years). */
export function isValidMmdd(value: unknown): value is string {
  return typeof value === 'string' && /^\d{2}-\d{2}$/.test(value) && isValidYmd(`2024-${value}`);
}

/**
 * Whether a night on `mmdd` falls in a season running from `start` to `end`,
 * both days included. A season whose end comes before its start wraps the
 * year end (e.g. 12-15 to 01-05).
 */
export function mmddInSeason(mmdd: string, start: string, end: string): boolean {
  return start <= end ? mmdd >= start && mmdd <= end : mmdd >= start || mmdd <= end;
}

const ID_RE = /^[A-Za-z0-9_-]{1,40}$/;

function validateItemId(value: unknown, field: string): string {
  if (typeof value !== 'string' || !ID_RE.test(value)) {
    fail(field, `${field} must be 1–40 letters, digits, '-' or '_'.`);
  }
  return value;
}

export function validateSeasonalRates(value: unknown, field = 'seasonalRates'): StaySeasonalRate[] {
  const items = list(value ?? [], field, MAX_SEASONAL_RATES);
  const seen = new Set<string>();
  const seasons = items.map((raw, i) => {
    const f = `${field}[${i}]`;
    const r = record(raw, f);
    const id = validateItemId(r.id, `${f}.id`);
    if (seen.has(id)) fail(`${f}.id`, `Two seasons share the id ${id}.`);
    seen.add(id);
    if (!isValidMmdd(r.startMmdd)) fail(`${f}.startMmdd`, 'A season starts on a day written MM-DD.');
    if (!isValidMmdd(r.endMmdd)) fail(`${f}.endMmdd`, 'A season ends on a day written MM-DD.');
    return {
      id,
      name: validateText(r.name, `${f}.name`, { min: 1, max: 60, singleLine: true }),
      startMmdd: r.startMmdd,
      endMmdd: r.endMmdd,
      nightlyCents: validateCents(r.nightlyCents, `${f}.nightlyCents`),
      weekendNightlyCents: validateOptionalCents(r.weekendNightlyCents, `${f}.weekendNightlyCents`),
    };
  });
  // Overlapping seasons would make a night's rate depend on list order.
  for (let day = 0; day < 366; day++) {
    const mmdd = new Date(Date.UTC(2024, 0, 1 + day)).toISOString().slice(5, 10);
    const hits = seasons.filter((s) => mmddInSeason(mmdd, s.startMmdd, s.endMmdd));
    if (hits.length > 1) {
      fail(field, `The seasons "${hits[0].name}" and "${hits[1].name}" overlap on ${mmdd}.`);
    }
  }
  return seasons;
}

export function validateTaxLines(value: unknown, field = 'taxLines'): StayTaxLine[] {
  const items = list(value ?? [], field, MAX_TAX_LINES);
  const codes = new Set<string>();
  return items.map((raw, i) => {
    const f = `${field}[${i}]`;
    const r = record(raw, f);
    if (typeof r.code !== 'string' || !/^[A-Za-z0-9_-]{1,24}$/.test(r.code)) {
      fail(`${f}.code`, 'A tax code is 1–24 letters, digits, "-" or "_".');
    }
    if (codes.has(r.code)) fail(`${f}.code`, `Two tax lines share the code ${r.code}.`);
    codes.add(r.code);
    const applies = list(r.appliesTo, `${f}.appliesTo`, TAX_APPLIES_TO.length);
    if (applies.length === 0) fail(`${f}.appliesTo`, 'A tax line must apply to at least one charge.');
    const appliesTo: TaxAppliesTo[] = [];
    applies.forEach((a, j) => {
      const v = validateEnum(a, `${f}.appliesTo[${j}]`, TAX_APPLIES_TO);
      if (appliesTo.includes(v)) fail(`${f}.appliesTo`, `${v} is listed twice.`);
      appliesTo.push(v);
    });
    if (r.remittedBy !== undefined && r.remittedBy !== 'owner') {
      fail(`${f}.remittedBy`, 'Only taxes the owner remits can be set up here.');
    }
    return {
      code: r.code,
      label: validateText(r.label, `${f}.label`, { min: 1, max: 60, singleLine: true }),
      rateBps: validateInt(r.rateBps, `${f}.rateBps`, 0, STAYS_LIMITS.taxRateMaxBps),
      appliesTo,
      remittedBy: 'owner' as const,
    };
  });
}

export function validateChecklist(value: unknown, field = 'checklistTemplate'): StayChecklistTemplateItem[] {
  const items = list(value ?? [], field, MAX_CHECKLIST_ITEMS);
  const ids = new Set<string>();
  return items.map((raw, i) => {
    const f = `${field}[${i}]`;
    const r = record(raw, f);
    const id = validateItemId(r.id, `${f}.id`);
    if (ids.has(id)) fail(`${f}.id`, `Two checklist items share the id ${id}.`);
    ids.add(id);
    return { id, label: validateText(r.label, `${f}.label`, { min: 1, max: 120, singleLine: true }) };
  });
}

export function validateRates(value: unknown, field = 'ratesCents'): StayListingRates {
  const r = record(value, field);
  const extraGuestFee = validateCents(r.extraGuestFee, `${field}.extraGuestFee`);
  const extraGuestAfter = validateInt(r.extraGuestAfter, `${field}.extraGuestAfter`, 0, 50);
  if (extraGuestFee > 0 && extraGuestAfter < 1) {
    fail(`${field}.extraGuestAfter`, 'Say after how many guests the extra-guest fee starts (1 or more).');
  }
  return {
    nightly: validateCents(r.nightly, `${field}.nightly`),
    weekendNightly: validateOptionalCents(r.weekendNightly, `${field}.weekendNightly`),
    weeklyNightly: validateOptionalCents(r.weeklyNightly, `${field}.weeklyNightly`),
    cleaningFee: validateCents(r.cleaningFee, `${field}.cleaningFee`),
    petFee: validateCents(r.petFee, `${field}.petFee`),
    extraGuestFee,
    extraGuestAfter,
  };
}

function validateCapacity(value: unknown, field: string): StayListingCapacity {
  const r = record(value, field);
  const bathrooms = r.bathrooms;
  if (typeof bathrooms !== 'number' || !Number.isFinite(bathrooms) || bathrooms < 0 || bathrooms > 50 || !Number.isInteger(bathrooms * 2)) {
    fail(`${field}.bathrooms`, 'Bathrooms is a number from 0 to 50, in halves (e.g. 1.5).');
  }
  return {
    maxGuests: validateInt(r.maxGuests, `${field}.maxGuests`, 0, 50),
    bedrooms: validateInt(r.bedrooms, `${field}.bedrooms`, 0, 50),
    beds: validateInt(r.beds, `${field}.beds`, 0, 100),
    bathrooms,
    petsAllowed: validateBool(r.petsAllowed, `${field}.petsAllowed`),
  };
}

export function validateRv(value: unknown, field = 'rv'): StayListingRv | null {
  if (value === null || value === undefined) return null;
  const r = record(value, field);
  const amps = list(r.amps ?? [], `${field}.amps`, RV_AMPS.length).map((a, i) => {
    if (typeof a !== 'number' || !(RV_AMPS as readonly number[]).includes(a)) {
      fail(`${field}.amps[${i}]`, 'Amps are 15, 20, 30 or 50.');
    }
    return a;
  });
  const ampNumbers = [...new Set(amps)].sort((a, b) => a - b);
  if (ampNumbers.length !== amps.length) fail(`${field}.amps`, 'An amp rating is listed twice.');
  return {
    hookup: validateEnum(r.hookup, `${field}.hookup`, RV_HOOKUPS),
    amps: ampNumbers,
    maxLengthFt: validateOptionalInt(r.maxLengthFt, `${field}.maxLengthFt`, 1, 100),
    pullThrough: validateBool(r.pullThrough, `${field}.pullThrough`),
    surface: validateOptionalText(r.surface, `${field}.surface`, { max: 40, singleLine: true }),
  };
}

function validateTimes(value: unknown, field: string): StayListingTimes {
  const r = record(value, field);
  return {
    checkIn: validateOptionalTime(r.checkIn, `${field}.checkIn`),
    checkOut: validateOptionalTime(r.checkOut, `${field}.checkOut`),
  };
}

function validateStayRules(value: unknown, field: string): StayListingRules {
  const r = record(value, field);
  const minNights = validateInt(r.minNights, `${field}.minNights`, 1, 30);
  const maxNights = validateInt(r.maxNights, `${field}.maxNights`, 1, STAYS_LIMITS.manualStayMaxNights);
  if (minNights > maxNights) fail(`${field}.minNights`, 'The minimum stay is longer than the maximum.');
  return { minNights, maxNights };
}

function validateTurnover(value: unknown, field: string): StayListingTurnover {
  const r = record(value, field);
  const uid = r.defaultAssigneeUid;
  if (uid !== undefined && uid !== null && (typeof uid !== 'string' || !/^[^/]{1,128}$/.test(uid))) {
    fail(`${field}.defaultAssigneeUid`, 'The default cleaner is not a valid user.');
  }
  return {
    mode: validateEnum(r.mode, `${field}.mode`, TURNOVER_MODES),
    afterOwnerBlocks: validateBool(r.afterOwnerBlocks, `${field}.afterOwnerBlocks`),
    checklistTemplate: validateChecklist(r.checklistTemplate, `${field}.checklistTemplate`),
    defaultAssigneeUid: typeof uid === 'string' ? uid : null,
    defaultAssigneeName: validateOptionalText(r.defaultAssigneeName, `${field}.defaultAssigneeName`, {
      max: 80,
      singleLine: true,
    }),
  };
}

/** An https page on an Airbnb host, e.g. https://www.airbnb.com/rooms/123. */
export function isAirbnbWebUrl(value: unknown): value is string {
  if (typeof value !== 'string' || value.length > 2000) return false;
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  return (
    url.protocol === 'https:' &&
    url.username === '' &&
    url.password === '' &&
    (url.port === '' || url.port === '443') &&
    AIRBNB_WEB_HOSTS.has(url.hostname.toLowerCase())
  );
}

/**
 * An Airbnb iCal export link carries a bearer token. It belongs in a
 * channel's server-only secret, never on the listing doc, which viewers read.
 */
function looksLikeIcalExport(url: string): boolean {
  const u = new URL(url);
  return /\/ical\//i.test(u.pathname) || /\.ics$/i.test(u.pathname) || u.searchParams.has('s') || u.searchParams.has('t');
}

function validateAirbnb(value: unknown, field: string): StayListingAirbnb {
  const r = record(value, field);
  const seen = new Set<string>();
  const listingNameAliases = list(r.listingNameAliases ?? [], `${field}.listingNameAliases`, MAX_AIRBNB_ALIASES).map(
    (a, i) => {
      const alias = validateText(a, `${field}.listingNameAliases[${i}]`, { min: 1, max: 120, singleLine: true });
      const key = alias.toLowerCase();
      if (seen.has(key)) fail(`${field}.listingNameAliases`, `"${alias}" is listed twice.`);
      seen.add(key);
      return alias;
    },
  );
  const urlField = (key: 'listingUrl' | 'calendarUrl'): string | null => {
    const raw = validateOptionalText(r[key], `${field}.${key}`, { max: 2000, singleLine: true });
    if (raw === null) return null;
    if (!isAirbnbWebUrl(raw)) fail(`${field}.${key}`, 'Use an https link on airbnb.com (or a country Airbnb site).');
    if (looksLikeIcalExport(raw)) {
      fail(
        `${field}.${key}`,
        'That looks like the private calendar export link. Paste it under Channels instead, where it is kept secret.',
      );
    }
    return raw;
  };
  return { listingNameAliases, listingUrl: urlField('listingUrl'), calendarUrl: urlField('calendarUrl') };
}

/**
 * Everything staysSaveListing stores from `listing`, validated. Keys this
 * does not know are ignored, never stored.
 */
export function validateListingInput(value: unknown): StayListingInput {
  const r = record(value, 'listing');
  const kind = validateEnum(r.kind, 'kind', STAY_LISTING_KINDS);
  return {
    name: validateText(r.name, 'name', { min: 1, max: 80, singleLine: true }),
    shortCode: validateText(r.shortCode, 'shortCode', { min: 1, max: 8, singleLine: true }),
    kind,
    group: validateText(r.group ?? '', 'group', { max: 40, singleLine: true }),
    sortOrder: validateInt(r.sortOrder, 'sortOrder', -100_000, 100_000),
    active: validateBool(r.active, 'active'),
    archived: validateBool(r.archived, 'archived'),
    address: validateOptionalText(r.address, 'address', { max: 200 }),
    capacity: validateCapacity(r.capacity, 'capacity'),
    rv: validateRv(r.rv, 'rv'),
    times: validateTimes(r.times, 'times'),
    stayRules: validateStayRules(r.stayRules, 'stayRules'),
    ratesCents: validateRates(r.ratesCents, 'ratesCents'),
    seasonalRates: validateSeasonalRates(r.seasonalRates, 'seasonalRates'),
    taxLines: validateTaxLines(r.taxLines, 'taxLines'),
    turnover: validateTurnover(r.turnover, 'turnover'),
    accessCodeMode: validateEnum(r.accessCodeMode, 'accessCodeMode', ACCESS_CODE_MODES),
    airbnb: validateAirbnb(r.airbnb, 'airbnb'),
    notes: validateText(r.notes ?? '', 'notes', { max: 2000 }),
  };
}

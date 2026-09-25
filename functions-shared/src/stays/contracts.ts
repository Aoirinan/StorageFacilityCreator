/**
 * Stays (short-term rentals): every document shape, enum, callable name and
 * request/response type the Stays functions and the app share.
 *
 * WP0 owns this file and it is frozen after merge; a change goes through a
 * small WP0 follow-up. The Dart mirror is
 * lib/models/stays/stays_callable_models.dart, and
 * test/stays_contract_parity_test.dart fails when the callable names, error
 * reasons or notification types drift apart.
 *
 * Conventions (spec §3.1):
 * - Nights and dates are 'YYYY-MM-DD' strings in the facility's confirmed
 *   zone (stayControls.timeZone); `checkOut` is exclusive.
 * - Money is integer cents; tax rates are integer basis points.
 * - Stay money lives only in stayIncome, stayFolios and stayExpenses, and
 *   no stay document ever carries a tenantId.
 */
import type { Timestamp } from 'firebase-admin/firestore';

export type StayTimestamp = Timestamp;
/** 'YYYY-MM-DD' in the facility's confirmed zone. */
export type Ymd = string;
/** 'YYYY-MM'. */
export type YearMonth = string;
/** 'HH:mm', 24-hour, facility-local. */
export type HourMinute = string;
/** 'YYYY-MM-DD HH:mm', facility-local, written by the server for display. */
export type LocalDateTime = string;

/**
 * A document as a callable returns it: timestamps become ISO-8601 strings
 * (the callable protocol cannot carry Firestore Timestamps).
 */
export type Wire<T> = T extends StayTimestamp
  ? string
  : T extends Array<infer U>
    ? Wire<U>[]
    : T extends object
      ? { [K in keyof T]: Wire<T[K]> }
      : T;

// ---------------------------------------------------------------------------
// Enums. Lower_snake wire strings; the Dart models map unknown strings to
// `unknown` and render them neutrally.
// ---------------------------------------------------------------------------

export const STAY_ROLES = ['owner', 'manager', 'employee', 'viewer'] as const;
export type StayRole = (typeof STAY_ROLES)[number];

export const STAY_LISTING_KINDS = [
  'vacation_rental',
  'house',
  'cabin',
  'room',
  'rv_site',
  'tent_site',
  'garage',
  'other',
] as const;
export type StayListingKind = (typeof STAY_LISTING_KINDS)[number];

export const RV_HOOKUPS = ['full', 'water_electric', 'electric', 'dry'] as const;
export type RvHookup = (typeof RV_HOOKUPS)[number];

export const RV_AMPS = [15, 20, 30, 50] as const;
export type RvAmps = (typeof RV_AMPS)[number];

export const STAY_KINDS = ['reservation', 'owner_block', 'maintenance_block'] as const;
export type StayKind = (typeof STAY_KINDS)[number];

export const STAY_SOURCES = [
  'airbnb',
  'vrbo',
  'booking',
  'hipcamp',
  'other_channel',
  'direct',
  'phone',
  'walk_up',
  'owner',
] as const;
export type StaySource = (typeof STAY_SOURCES)[number];

/** Sources SFC itself books (the `sfc` export scope sends these). */
export const SFC_BOOKING_SOURCES = ['direct', 'phone', 'walk_up'] as const;
/** Sources that are another channel's bookings. */
export const OTA_SOURCES = ['airbnb', 'vrbo', 'booking', 'hipcamp', 'other_channel'] as const;

export const STAY_ORIGINS = ['sfc', 'feed', 'csv'] as const;
export type StayOrigin = (typeof STAY_ORIGINS)[number];

export const STAY_STATUSES = ['confirmed', 'conflict', 'cancelled', 'removed_from_feed'] as const;
export type StayStatus = (typeof STAY_STATUSES)[number];

/** Statuses that hold nights (spec §3.4 invariant 1). */
export const ACTIVE_STAY_STATUSES: readonly StayStatus[] = ['confirmed', 'conflict'];

export const STAY_ARRIVAL_STATES = ['upcoming', 'checked_in', 'checked_out', 'no_show'] as const;
export type StayArrivalState = (typeof STAY_ARRIVAL_STATES)[number];

export const STAY_PAYMENT_STATUSES = [
  'none',
  'due',
  'partial',
  'paid',
  'channel_collected',
  'refunded',
] as const;
export type StayPaymentStatus = (typeof STAY_PAYMENT_STATUSES)[number];

export const CHANNEL_PROVIDERS = ['airbnb', 'vrbo', 'booking', 'google', 'hipcamp', 'other'] as const;
export type ChannelProvider = (typeof CHANNEL_PROVIDERS)[number];

export const CHANNEL_SYNC_STATUSES = [
  'ok',
  'not_modified',
  'http_error',
  'gone',
  'invalid_feed',
  'blocked_host',
  'timeout',
  'too_large',
  'suspicious',
] as const;
export type ChannelSyncStatus = (typeof CHANNEL_SYNC_STATUSES)[number];

/**
 * Who imports an export link. Hipcamp has its own target so a Hipcamp link can
 * leave out Hipcamp's own bookings while an 'other' link (any other site)
 * still sends every channel's.
 */
export const EXPORT_TARGET_PROVIDERS = ['airbnb', 'vrbo', 'booking', 'google', 'hipcamp', 'other'] as const;
export type ExportTargetProvider = (typeof EXPORT_TARGET_PROVIDERS)[number];

export const EXPORT_SCOPES = ['blocks_only', 'sfc', 'all'] as const;
export type ExportScope = (typeof EXPORT_SCOPES)[number];

export const TASK_CATEGORIES = ['turnover', 'site_check', 'maintenance', 'restock', 'general'] as const;
export type StayTaskCategory = (typeof TASK_CATEGORIES)[number];

export const TASK_STATUSES = ['todo', 'in_progress', 'done', 'skipped', 'cancelled'] as const;
export type StayTaskStatus = (typeof TASK_STATUSES)[number];

export const TASK_PRIORITIES = ['normal', 'high'] as const;
export type StayTaskPriority = (typeof TASK_PRIORITIES)[number];

export const TURNOVER_MODES = ['full', 'quick_check', 'none'] as const;
export type TurnoverMode = (typeof TURNOVER_MODES)[number];

export const ACCESS_CODE_MODES = ['none', 'static', 'per_stay', 'phone_last4'] as const;
export type AccessCodeMode = (typeof ACCESS_CODE_MODES)[number];

export const STAY_ACCESS_SOURCES = ['manual', 'phone_last4', 'static'] as const;
export type StayAccessSource = (typeof STAY_ACCESS_SOURCES)[number];

export const INCOME_SOURCES = ['manual', 'airbnb_csv'] as const; // 'stripe' reserved for later
export type StayIncomeSource = (typeof INCOME_SOURCES)[number];

export const INCOME_METHODS = ['cash', 'check', 'card_external', 'venmo', 'bank', 'airbnb', 'other'] as const;
export type StayIncomeMethod = (typeof INCOME_METHODS)[number];

/** Methods a person records by hand (never 'airbnb', which only the CSV import writes). */
export const MANUAL_PAYMENT_METHODS = ['cash', 'check', 'card_external', 'venmo', 'bank', 'other'] as const;
export type StayManualPaymentMethod = (typeof MANUAL_PAYMENT_METHODS)[number];

export const DEFAULT_PAYMENT_METHODS: readonly StayManualPaymentMethod[] = [
  'cash',
  'check',
  'card_external',
  'venmo',
  'other',
];

export const INCOME_KINDS = [
  'stay_payment',
  'refund_given',
  'channel_booking',
  'adjustment',
  'resolution',
  'cancellation_fee',
  'channel_tax',
  'payout',
  'other',
] as const;
export type StayIncomeKind = (typeof INCOME_KINDS)[number];

export const EXPENSE_CATEGORIES = [
  'cleaning',
  'supplies',
  'laundry',
  'utilities',
  'repairs',
  'channel',
  'other',
] as const;
export type StayExpenseCategory = (typeof EXPENSE_CATEGORIES)[number];

export const MONEY_ENTRY_STATUSES = ['posted', 'voided'] as const;
export type StayMoneyEntryStatus = (typeof MONEY_ENTRY_STATUSES)[number];

export const IMPORT_BATCH_KINDS = ['airbnb_earnings', 'airbnb_reservations'] as const;
export type StayImportBatchKind = (typeof IMPORT_BATCH_KINDS)[number];

export const IMPORT_BATCH_STATUSES = ['previewed', 'committed'] as const;
export type StayImportBatchStatus = (typeof IMPORT_BATCH_STATUSES)[number];

export const TEMPLATE_CHANNEL_HINTS = ['airbnb_paste', 'email', 'sms', 'print'] as const;
export type TemplateChannelHint = (typeof TEMPLATE_CHANNEL_HINTS)[number];

export const FOLIO_LINE_CODES = ['lodging', 'cleaning', 'pet', 'extra_guest', 'adjustment'] as const;
export type FolioLineCode = (typeof FOLIO_LINE_CODES)[number];

export const TAX_APPLIES_TO = ['lodging', 'cleaning', 'pet', 'extra_guest'] as const;
export type TaxAppliesTo = (typeof TAX_APPLIES_TO)[number];

export const CONSENT_METHODS = ['verbal', 'written', 'booking_form'] as const;
export type ConsentMethod = (typeof CONSENT_METHODS)[number];

export const SYNC_TRIGGERS = ['scheduled', 'manual', 'save', 'drift'] as const;
export type SyncTrigger = (typeof SYNC_TRIGGERS)[number];

export const SYNC_JOB_STATUSES = ['pending', 'processing', 'completed', 'failed'] as const;
export type SyncJobStatus = (typeof SYNC_JOB_STATUSES)[number];

export const REVIEW_ACTIONS = ['acknowledge_conflict', 'restore', 'clear_review'] as const;
export type StayReviewAction = (typeof REVIEW_ACTIONS)[number];

/** `createdBy`/`updatedBy` for writes no person made. */
export const STAYS_SYSTEM_ACTORS = [
  'system:stays-sync',
  'system:stays-trigger',
  'system:stays-csv',
  'system:stays-writer',
] as const;
export type StaysSystemActor = (typeof STAYS_SYSTEM_ACTORS)[number];

// ---------------------------------------------------------------------------
// Limits (spec §6.10). Shared so the app can say them too.
// ---------------------------------------------------------------------------

export const STAYS_LIMITS = {
  activeListingsPerFacility: 60,
  channelsPerListing: 4,
  channelsPerFacility: 20,
  exportLinksPerListing: 4,
  manualStayMinNights: 1,
  manualStayMaxNights: 180,
  importedStayMaxNights: 365,
  lockHorizonPastDays: 60,
  lockHorizonFutureDays: 540,
  stayMutationsPerTransaction: 150,
  /**
   * Lock buckets (months) one write may touch per listing. The horizon's 600
   * nights touch up to 21 months (on about two days in three), and a
   * whole-horizon write such as a feed's full block set must fit, so this is
   * at least that; staysNightLocks.test.ts checks it for every day of 8 years.
   */
  bucketsPerListingPerTransaction: 22,
  feedTimeoutMs: 10_000,
  feedMaxBytes: 2_000_000,
  feedMaxRedirects: 3,
  feedMaxEvents: 3000,
  csvMaxBytes: 1_000_000,
  csvMaxRows: 5000,
  taskPhotos: 10,
  taskPhotoMaxBytes: 10 * 1024 * 1024,
  templatesPerFacility: 30,
  templateBodyMaxChars: 4000,
  exportFetchesPerMinutePerToken: 30,
  exportFetchesPerMinutePerIp: 300,
  taxRateMaxBps: 3000,
} as const;

// ---------------------------------------------------------------------------
// Documents (spec §3.3). All paths are under facilities/{facilityId}/ unless
// marked TOP-LEVEL.
// ---------------------------------------------------------------------------

/** Fields every stay document carries. */
export interface StayCommonFields {
  facilityId: string;
  createdAt: StayTimestamp;
  createdBy: string;
  updatedAt: StayTimestamp;
  updatedBy: string;
}

/** stayControls/current. Written only by staysSetControls. */
export interface StayControlsDoc {
  facilityId: string;
  moduleEnabled: boolean;
  timeZone: string | null;
  timeZoneConfirmedAt: StayTimestamp | null;
  timeZoneConfirmedBy: string | null;
  /** Import feeds. */
  icalSyncEnabled: boolean;
  /** Serve export links. */
  icalExportEnabled: boolean;
  turnoverTasksEnabled: boolean;
  /** In-app only; the wizard proposes ON. */
  dailyBriefEnabled: boolean;
  dailyBriefLocalHour: number;
  lodgingTaxEnabled: boolean;
  employeesCanBook: boolean;
  employeesCanRecordCash: boolean;
  defaultCheckInTime: HourMinute;
  defaultCheckOutTime: HourMinute;
  shortLeadWarningHours: number;
  paymentMethods: StayManualPaymentMethod[];
  /** ≤4000; used in templates. */
  parkRules: string;
  /** ≤200; used in templates. */
  quietHours: string;
  /** RESERVED, owner-only; v1 rejects true. */
  guestMessagingEnabled: boolean;
  /** RESERVED, owner-only; v1 rejects true. */
  directPaymentsEnabled: boolean;
  templatesSeededAt: StayTimestamp | null;
  createdAt: StayTimestamp | null;
  createdBy: string | null;
  updatedAt: StayTimestamp | null;
  updatedBy: string | null;
  version: number;
}

export interface StayListingCapacity {
  maxGuests: number;
  bedrooms: number;
  beds: number;
  bathrooms: number;
  petsAllowed: boolean;
}

export interface StayListingRv {
  hookup: RvHookup;
  /** Subset of [15, 20, 30, 50]. */
  amps: number[];
  maxLengthFt: number | null;
  pullThrough: boolean;
  surface: string | null;
}

export interface StayListingTimes {
  /** null → controls default. */
  checkIn: HourMinute | null;
  checkOut: HourMinute | null;
}

export interface StayListingRules {
  /** 1..30 */
  minNights: number;
  /** 1..180 */
  maxNights: number;
}

export interface StayListingRates {
  nightly: number;
  weekendNightly: number | null;
  weeklyNightly: number | null;
  cleaningFee: number;
  petFee: number;
  extraGuestFee: number;
  extraGuestAfter: number;
}

export interface StaySeasonalRate {
  id: string;
  name: string;
  /** 'MM-DD'; a season may wrap the year end. */
  startMmdd: string;
  endMmdd: string;
  nightlyCents: number;
  weekendNightlyCents: number | null;
}

export interface StayTaxLine {
  code: string;
  label: string;
  /** 0–3000 */
  rateBps: number;
  appliesTo: TaxAppliesTo[];
  remittedBy: 'owner';
}

export interface StayChecklistTemplateItem {
  id: string;
  label: string;
}

export interface StayListingTurnover {
  mode: TurnoverMode;
  afterOwnerBlocks: boolean;
  /** ≤50 */
  checklistTemplate: StayChecklistTemplateItem[];
  defaultAssigneeUid: string | null;
  defaultAssigneeName: string | null;
}

export interface StayListingAirbnb {
  /** ≤10, for matching CSV rows. */
  listingNameAliases: string[];
  /** https airbnb hosts only. */
  listingUrl: string | null;
  calendarUrl: string | null;
}

/** The fields a person edits (staysSaveListing's `listing`). */
export interface StayListingInput {
  /** 1–80 */
  name: string;
  /** 1–8, e.g. 'A1', 'RV3'. */
  shortCode: string;
  kind: StayListingKind;
  /** ≤40, e.g. 'Airbnbs', 'RV park'. */
  group: string;
  sortOrder: number;
  active: boolean;
  archived: boolean;
  /** ≤200, for off-site Airbnbs. */
  address: string | null;
  capacity: StayListingCapacity;
  rv: StayListingRv | null;
  times: StayListingTimes;
  stayRules: StayListingRules;
  ratesCents: StayListingRates;
  /** ≤10 */
  seasonalRates: StaySeasonalRate[];
  /** ≤10 */
  taxLines: StayTaxLine[];
  turnover: StayListingTurnover;
  accessCodeMode: AccessCodeMode;
  airbnb: StayListingAirbnb;
  /** ≤2000 */
  notes: string;
}

/**
 * stayListings/{listingId}: ids are `lst_{random}`, or `lst_{requestId}_{n}`
 * for bulk RV sites. List fields cannot be checked in rules, so only
 * staysSaveListing and staysBulkCreateRvSites write these.
 */
export interface StayListingDoc extends StayListingInput, StayCommonFields {
  version: number;
}

/** stayListingAccess/{listingId}: staff read, owner/manager write (whitelisted keys). */
export interface StayListingAccessDoc {
  facilityId: string;
  listingId: string;
  wifiName: string;
  wifiPassword: string;
  staticDoorCode: string;
  lockboxCode: string;
  gateCode: string;
  parkingNotes: string;
  trashNotes: string;
  checkoutInstructions: string;
  directionsUrl: string;
  houseRules: string;
  updatedAt: StayTimestamp;
  updatedBy: string;
}

export interface StayExternalRef {
  provider: ChannelProvider;
  uid: string | null;
  uidHistory: string[];
  confirmationCode: string | null;
  /** Kept only when https on an allowlisted Airbnb host with the reservation path. */
  reservationUrl: string | null;
  /** Kept only for known Airbnb constants; other text is dropped as untrusted. */
  summary: string | null;
}

export interface StaySyncState {
  channelId: string;
  firstSeenAt: StayTimestamp;
  lastSeenAt: StayTimestamp;
  missCount: number;
  firstMissAt: StayTimestamp | null;
  lastMissAt: StayTimestamp | null;
  needsReview: boolean;
  agedOutAt: StayTimestamp | null;
  detached: boolean;
}

export interface StayConflict {
  stayIds: string[];
  nights: Ymd[];
  detectedAt: StayTimestamp;
  acknowledgedAt: StayTimestamp | null;
  acknowledgedBy: string | null;
  note: string | null;
}

/**
 * stays/{stayId}: bookings and blocks, with no personal data or money
 * amounts. Ids: `airbnb_{CODE}`, `ical_{sha256(listingId|provider|uid)[0:40]}`
 * or `man_{requestId}` (see ids.ts). Viewers read the whole doc, so
 * staffNotes and cleanerNotes are visible to them: the app labels those
 * fields as such, and private details belong in stayPrivate.privateNotes.
 */
export interface StayDoc extends StayCommonFields {
  listingId: string;
  listingName: string;
  listingGroup: string;
  listingKind: StayListingKind;
  kind: StayKind;
  source: StaySource;
  /** Who created it first. */
  origin: StayOrigin;
  /** Server-owned. */
  status: StayStatus;
  /** Staff-editable through the rules' narrow transitions. */
  arrivalState: StayArrivalState;
  checkIn: Ymd;
  /** Exclusive. */
  checkOut: Ymd;
  nights: number;
  checkInTime: HourMinute;
  checkOutTime: HourMinute;
  /** ≤60, e.g. 'Jane D.' */
  guestDisplayName: string;
  adults: number;
  children: number;
  pets: number;
  rvLengthFt: number | null;
  /** No amounts here; those live in stayFolios. */
  paymentStatus: StayPaymentStatus;
  external: StayExternalRef | null;
  sync: StaySyncState | null;
  conflict: StayConflict | null;
  staffNotes: string;
  cleanerNotes: string;
  tags: string[];
  /** templateKey → when it was copied or opened. */
  messageMarks: Record<string, StayTimestamp>;
  turnoverTaskId: string | null;
  checkedInAt: StayTimestamp | null;
  checkedOutAt: StayTimestamp | null;
  cancelledAt: StayTimestamp | null;
  /** A uid, or 'feed'. */
  cancelledBy: string | null;
  cancelReason: string | null;
  requestId: string | null;
  version: number;
  /**
   * Lock precedence: the first writer wins. The writer owns it: an existing
   * stay keeps its stored value whatever the caller sends, and a new stay
   * must carry a positive time (callers pass their nowMs).
   */
  createdAtMs: number;
}

/**
 * The stay fields staff change directly under the rules (53-stays.rules
 * quickKeys, less the updatedAt/updatedBy stamp). They do not bump
 * `version`, so the writer keeps the stored values of these unless a
 * mutation names them in `owns`: a check-in or note saved while a callable
 * or sync was in flight is never undone by it. The staff notes are readable
 * by viewers too, like the rest of the stay doc.
 */
export const STAY_STAFF_FIELDS = [
  'guestDisplayName',
  'adults',
  'children',
  'pets',
  'rvLengthFt',
  'staffNotes',
  'cleanerNotes',
  'tags',
  'messageMarks',
  'arrivalState',
  'checkedInAt',
  'checkedOutAt',
] as const;
export type StayStaffField = (typeof STAY_STAFF_FIELDS)[number];

/** stayPrivate/{stayId}: owner/manager only. */
export interface StayPrivateDoc {
  facilityId: string;
  stayId: string;
  guestProfileId: string | null;
  /** ≤120 */
  fullName: string | null;
  phoneLast4: string | null;
  /** ≤2000 */
  privateNotes: string;
  updatedAt: StayTimestamp;
  updatedBy: string;
}

/** stayAccess/{stayId}: staff read, owner/manager write. */
export interface StayAccessDoc {
  facilityId: string;
  stayId: string;
  doorCode: string | null;
  gateCode: string | null;
  accessNotes: string;
  source: StayAccessSource;
  updatedAt: StayTimestamp;
  updatedBy: string;
}

export interface StayFolioLine {
  code: FolioLineCode;
  label: string;
  qty: number;
  unitCents: number;
  amountCents: number;
}

export interface StayFolioTaxLine {
  code: string;
  label: string;
  rateBps: number;
  amountCents: number;
  remittedBy: 'owner';
}

export interface StayFolioAdjustment {
  cents: number;
  reason: string;
  by: string;
}

/** From the Airbnb CSV match, summed. */
export interface StayFolioAirbnb {
  grossCents: number;
  hostFeeCents: number;
  cleaningFeeCents: number;
  taxRemittedCents: number;
  netCents: number;
  rowCount: number;
  /** True when only the Reservations CSV's expected earnings are known. */
  expectedOnly?: boolean;
}

/** stayFolios/{stayId}: owner/manager read, callables write. */
export interface StayFolioDoc {
  facilityId: string;
  stayId: string;
  currency: 'usd';
  lines: StayFolioLine[];
  taxLines: StayFolioTaxLine[];
  subtotalCents: number;
  taxCents: number;
  totalCents: number;
  paidCents: number;
  balanceCents: number;
  quoteVersion: number;
  quotedAt: StayTimestamp;
  adjustment: StayFolioAdjustment | null;
  airbnb: StayFolioAirbnb | null;
  updatedAt: StayTimestamp;
}

/**
 * One night in a lock bucket. `s` is the stayId, or `blk:{channelId}` for a
 * soft channel block; `h` is true for a hard claim.
 */
export interface NightClaim {
  s: string;
  h: boolean;
  /** The stay's source, or the channel's provider. */
  src: string;
  /** The stay's kind, or 'channel_block'. */
  k: StayKind | 'channel_block';
  /** Set (true) only on echoed channel blocks. */
  e?: true;
}

/**
 * stayNightLocks/{listingId}_{YYYY-MM}: a cache, rebuilt from stays and
 * channel blocks inside every stayWriter transaction.
 */
export interface StayNightLockBucketDoc {
  facilityId: string;
  listingId: string;
  month: YearMonth;
  nights: Record<Ymd, NightClaim>;
  digest: string;
  rebuiltAt: StayTimestamp;
}

export interface StayChannelSyncLease {
  runId: string;
  expiresAt: StayTimestamp;
}

export interface StayChannelSyncHealth {
  lastAttemptAt: StayTimestamp | null;
  lastSuccessAt: StayTimestamp | null;
  lastChangedAt: StayTimestamp | null;
  lastStatus: ChannelSyncStatus | null;
  lastHttpStatus: number | null;
  lastErrorCode: string | null;
  consecutiveFailures: number;
  etag: string | null;
  lastModified: string | null;
  contentSha256: string | null;
  eventCount: number;
  futureReservationCount: number;
  blockCount: number;
  firstSyncCompletedAt: StayTimestamp | null;
  suspiciousSince: StayTimestamp | null;
  lease: StayChannelSyncLease | null;
}

/** stayChannels/{channelId}: feed metadata and sync health. */
export interface StayChannelDoc {
  facilityId: string;
  listingId: string;
  provider: ChannelProvider;
  label: string;
  active: boolean;
  importBlocks: boolean;
  urlHost: string;
  /** sha256(url)[0:12] */
  urlFingerprint: string;
  sync: StayChannelSyncHealth;
  createdAt: StayTimestamp;
  createdBy: string;
  updatedAt: StayTimestamp;
}

/** stayChannels/{channelId}/secret/current: the import URL, a bearer secret. No client access. */
export interface StayChannelSecretDoc {
  url: string;
  updatedAt: StayTimestamp;
}

export interface ChannelBlockRange {
  checkIn: Ymd;
  /** Exclusive. */
  checkOut: Ymd;
  echo: boolean;
}

/** stayChannelBlocks/{channelId}: the set of imported soft-block ranges per feed. */
export interface StayChannelBlocksDoc {
  facilityId: string;
  listingId: string;
  provider: ChannelProvider;
  /** ≤500, merged and clamped. */
  ranges: ChannelBlockRange[];
  syncedAt: StayTimestamp;
}

export interface StayExportLinkStats {
  lastFetchedAt: StayTimestamp | null;
  lastFetcher: ExportTargetProvider | null;
  lastStatus: number | null;
  statsWrittenAt: StayTimestamp | null;
}

/** stayExportLinks/{linkId}: export link metadata and fetch telemetry. */
export interface StayExportLinkDoc {
  facilityId: string;
  listingId: string;
  targetProvider: ExportTargetProvider;
  label: string;
  scope: ExportScope;
  active: boolean;
  stats: StayExportLinkStats;
  createdAt: StayTimestamp;
  createdBy: string;
  rotatedAt: StayTimestamp | null;
  revokedAt: StayTimestamp | null;
}

/** stayExportLinks/{linkId}/secret/current. No client access. */
export interface StayExportLinkSecretDoc {
  token: string;
}

/** TOP-LEVEL stayCalendarExportTokens/{sha256hex(token)}. No client access. */
export interface StayCalendarExportTokenDoc {
  facilityId: string;
  listingId: string;
  linkId: string;
  active: boolean;
  createdAt: StayTimestamp;
}

/** staySyncLog/{runId}: per-run sync results, kept 30 days. */
export interface StaySyncLogDoc {
  facilityId: string;
  channelId: string;
  listingId: string;
  trigger: SyncTrigger;
  status: ChannelSyncStatus;
  httpStatus: number | null;
  created: number;
  dateChanged: number;
  restored: number;
  missesAdvanced: number;
  removed: number;
  needsReview: number;
  conflicts: number;
  blocks: number;
  durationMs: number;
  finishedAt: StayTimestamp;
  expireAt: StayTimestamp;
}

export interface StayTaskChecklistItem {
  id: string;
  label: string;
  done: boolean;
  doneAt: StayTimestamp | null;
  doneBy: string | null;
}

/** stayTasks/{taskId}: `turnover_{stayId}` for automatic turnovers, an auto id for manual tasks. */
export interface StayTaskDoc {
  facilityId: string;
  category: StayTaskCategory;
  listingId: string | null;
  stayId: string | null;
  nextStayId: string | null;
  /** ≤120 */
  title: string;
  /** ≤2000 */
  notes: string;
  dueStartAt: StayTimestamp;
  dueStartLocal: LocalDateTime;
  dueByAt: StayTimestamp | null;
  dueByLocal: LocalDateTime | null;
  dueDate: Ymd;
  sameDayTurn: boolean;
  priority: StayTaskPriority;
  status: StayTaskStatus;
  needsAttention: boolean;
  assigneeUid: string | null;
  assigneeName: string | null;
  /** ≤50 */
  checklist: StayTaskChecklistItem[];
  /** ≤20 */
  suppliesLow: string[];
  /** ≤2000 */
  issueNote: string;
  /** ≤10 */
  photoPaths: string[];
  startedAt: StayTimestamp | null;
  completedAt: StayTimestamp | null;
  completedBy: string | null;
  plannedDigest: string | null;
  createdBy: string;
  createdAt: StayTimestamp;
  updatedAt: StayTimestamp;
  updatedBy: string;
}

export interface StayIncomeExternalRef {
  confirmationCode: string | null;
  referenceCode: string | null;
}

/**
 * stayIncome/{entryId}: the append-only money journal. Ids: `man_{requestId}`,
 * `abnb_{sha256(facilityId|codeOrReference|type|dateYmd|amountCents|occurrence)[0:40]}`;
 * `stripe_*` ids are reserved for later. netCents = grossCents −
 * channelFeeCents − taxPassThroughCents; pass-through tax is never income.
 */
export interface StayIncomeDoc {
  facilityId: string;
  listingId: string | null;
  stayId: string | null;
  /** ≤60; this doc is owner/manager-only. */
  guestName: string | null;
  source: StayIncomeSource;
  method: StayIncomeMethod;
  kind: StayIncomeKind;
  /** False for payout and channel_tax rows. */
  countsAsIncome: boolean;
  grossCents: number;
  channelFeeCents: number;
  cleaningFeeCents: number;
  taxPassThroughCents: number;
  taxRemittedByChannelCents: number;
  netCents: number;
  receivedDate: Ymd;
  receivedMonth: YearMonth;
  receivedAt: StayTimestamp;
  stayStart: Ymd | null;
  stayEnd: Ymd | null;
  nights: number | null;
  externalRef: StayIncomeExternalRef;
  /** ≤500 */
  memo: string;
  importBatchId: string | null;
  requestId: string | null;
  status: StayMoneyEntryStatus;
  voidedAt: StayTimestamp | null;
  voidedBy: string | null;
  voidReason: string | null;
  createdAt: StayTimestamp;
  createdBy: string;
}

/** stayExpenses/{exp_{requestId}}. */
export interface StayExpenseDoc {
  facilityId: string;
  listingId: string | null;
  category: StayExpenseCategory;
  /** > 0 */
  amountCents: number;
  spentDate: Ymd;
  spentMonth: YearMonth;
  /** ≤80 */
  vendor: string;
  /** ≤500 */
  memo: string;
  /** Under facilities/{fid}/stayExpenseReceipts/{expenseId}/… */
  receiptPath: string | null;
  status: StayMoneyEntryStatus;
  voidedAt: StayTimestamp | null;
  voidedBy: string | null;
  voidReason: string | null;
  createdAt: StayTimestamp;
  createdBy: string;
}

export interface StayImportTotals {
  grossCents: number;
  channelFeeCents: number;
  netCents: number;
  taxCents: number;
  payoutCents: number;
}

/** stayImportBatches/{sha256(csvText)}. */
export interface StayImportBatchDoc {
  facilityId: string;
  kind: StayImportBatchKind;
  fileName: string;
  rowCount: number;
  created: number;
  skippedDuplicate: number;
  needsReview: number;
  rejected: number;
  matchedStays: number;
  createdStays: number;
  unmatchedListings: string[];
  totals: StayImportTotals;
  dateRange: { from: Ymd | null; to: Ymd | null };
  status: StayImportBatchStatus;
  committedAt: StayTimestamp | null;
  committedBy: string | null;
  createdAt: StayTimestamp;
  createdBy: string;
}

export interface StayGuestVehicle {
  plate: string | null;
  state: string | null;
  make: string | null;
  rvType: string | null;
  rvLengthFt: number | null;
}

/** Captured now, used by nothing in v1. */
export interface StayGuestConsent {
  email: boolean;
  sms: boolean;
  method: ConsentMethod;
  recordedAt: StayTimestamp;
  recordedBy: string;
}

/** stayGuestProfiles/{profileId} (`gp_{requestId}` or an auto id): personal data, owner/manager only. */
export interface StayGuestProfileDoc {
  facilityId: string;
  /** ≤120 */
  name: string;
  nameLower: string;
  phoneE164: string | null;
  email: string | null;
  vehicle: StayGuestVehicle | null;
  /** ≤2000 */
  notes: string;
  doNotRent: boolean;
  doNotRentReason: string | null;
  consent: StayGuestConsent | null;
  /** Server-maintained. */
  stayCount: number;
  lastStayAt: StayTimestamp | null;
  createdAt: StayTimestamp;
  createdBy: string;
  updatedAt: StayTimestamp;
  updatedBy: string;
}

/** stayMessageTemplates/{templateId}: copy-first templates. No `autoSend` key in v1. */
export interface StayMessageTemplateDoc {
  facilityId: string;
  key: string;
  /** ≤80 */
  name: string;
  /** ≤4000 */
  body: string;
  channelHint: TemplateChannelHint;
  /** ≤60; empty means every listing. */
  listingIds: string[];
  kind: 'copy';
  seeded: boolean;
  createdAt: StayTimestamp;
  createdBy: string;
  updatedAt: StayTimestamp;
  updatedBy: string;
}

/**
 * TOP-LEVEL staysServerConfig/current: kill switch and allowlists. Server
 * only on purpose (appConfig/* is readable by every signed-in user). A
 * missing doc or a read error means disabled.
 */
export interface StaysServerConfigDoc {
  killSwitch: boolean;
  enabledGlobal: boolean;
  allowlistFacilityIds: string[];
  extraIcalHosts: string[];
  /** Later. */
  paymentsAllowlistFacilityIds: string[];
  /** Later. */
  guestMessagingAllowlistFacilityIds: string[];
}

/** TOP-LEVEL staySyncJobs/{slot}_{facilityId}. */
export interface StaySyncJobDoc {
  facilityId: string;
  /** 'YYYY-MM-DDTHH:mm' (UTC, floored to 30 minutes) or 'manual_…'. */
  runDate: string;
  status: SyncJobStatus;
  createdAt: StayTimestamp;
  finishedAt: StayTimestamp | null;
  summary: Record<string, unknown> | null;
}

// ---------------------------------------------------------------------------
// Notifications (spec §6.11): facilities/{fid}/Notifications, in-app only,
// written with create() under a deterministic id (ids.ts notificationId).
// ---------------------------------------------------------------------------

export const STAY_NOTIFICATION_TYPES = [
  'STAY_BOOKING_IMPORTED',
  'STAY_BOOKING_CHANGED',
  'STAY_BOOKING_REMOVED',
  'STAY_BOOKING_NEEDS_REVIEW',
  'STAY_CONFLICT',
  'STAY_FEED_FIRST_SYNC',
  'STAY_FEED_FAILING',
  'STAY_FEED_SUSPICIOUS',
  'STAY_TURNOVER_DONE',
  'STAY_TURNOVER_ISSUE',
  'STAY_TURNOVER_UNASSIGNED',
  'STAY_DAILY_BRIEF',
] as const;
export type StayNotificationType = (typeof STAY_NOTIFICATION_TYPES)[number];

export interface StayNotificationMetadata {
  stayId?: string;
  listingId?: string;
  taskId?: string;
  channelId?: string;
  /** In-app route the notification opens. */
  route: string;
}

export interface StayNotificationDoc {
  facilityId: string;
  type: StayNotificationType;
  message: string;
  createdAt: StayTimestamp;
  readAt: null;
  metadata: StayNotificationMetadata;
}

// ---------------------------------------------------------------------------
// Audit event types (spec §6.11), written through writeAuditLog.
// ---------------------------------------------------------------------------

export const STAYS_AUDIT_EVENT_TYPES = [
  'stays.controls.updated',
  'stays.listing.saved',
  'stays.stay.created',
  'stays.stay.modified',
  'stays.stay.cancelled',
  'stays.stay.reviewed',
  'stays.income.created',
  'stays.income.voided',
  'stays.expense.created',
  'stays.expense.voided',
  'stays.channel.saved',
  'stays.channel.removed',
  'stays.channel.synced_manually',
  'stays.export_link.created',
  'stays.export_link.url_viewed',
  'stays.export_link.scope_changed',
  'stays.export_link.revoked',
  'stays.export_link.rotated',
  'stays.csv.imported',
] as const;
export type StaysAuditEventType = (typeof STAYS_AUDIT_EVENT_TYPES)[number];

// ---------------------------------------------------------------------------
// Errors (spec §6.3). Every Stays HttpsError carries details.reason; the app
// maps it to StaysCallableException(reason, details).
// ---------------------------------------------------------------------------

export const STAYS_ERROR_REASONS = [
  // Gates and roles
  'stays_paused',
  'module_not_available',
  'module_disabled',
  'role_not_allowed',
  'employee_setting_off',
  // Booking
  'invalid_dates',
  'min_nights',
  'max_nights',
  'listing_inactive',
  'hard_conflict',
  'soft_block',
  'short_lead_ack_required',
  'do_not_rent',
  // Ownership and concurrency
  'feed_owned_dates',
  'version_mismatch',
  'contention',
  'duplicate_reservation',
  // Setup
  'timezone_unconfirmed',
  'not_available_yet',
  // Feeds and files
  'feed_host_not_allowed',
  'feed_fetch_failed',
  'feed_invalid',
  'feed_too_large',
  'csv_invalid',
  'csv_too_large',
  'rate_limited',
  // General (WP0 additions so every error still names a reason)
  'unauthenticated',
  'app_check_required',
  'invalid_argument',
  'not_found',
  'limit_reached',
  'internal',
] as const;
export type StaysErrorReason = (typeof STAYS_ERROR_REASONS)[number];

/** details of a `hard_conflict` error. */
export interface HardConflictNight {
  date: Ymd;
  stayId: string;
  /** e.g. "Jane D. · Oct 3–6" or "Owner block"; never personal data beyond the display name. */
  label: string;
}

export const STAYS_WARNING_CODES = [
  'facility_timezone_mismatch',
  'short_lead',
  'soft_nights',
  'fresh_sync_failed',
  'fresh_sync_skipped',
  'over_capacity',
  'pets_not_allowed',
  'rv_too_long',
  'do_not_rent',
  'orphan_gap',
  'feed_empty',
  'feed_suspicious',
  'events_skipped',
  'recurring_events_skipped',
  'far_future_clamped',
  'repaste_required',
] as const;
export type StaysWarningCode = (typeof STAYS_WARNING_CODES)[number];

export interface StaysWarning {
  code: StaysWarningCode;
  message: string;
  details?: Record<string, unknown>;
}

// ---------------------------------------------------------------------------
// Callables (spec §6.5), codebase `stays`.
// ---------------------------------------------------------------------------

export const STAYS_CALLABLES = {
  getAvailability: 'staysGetAvailability',
  setControls: 'staysSetControls',
  saveListing: 'staysSaveListing',
  bulkCreateRvSites: 'staysBulkCreateRvSites',
  quote: 'staysQuote',
  createStay: 'staysCreateStay',
  modifyStay: 'staysModifyStay',
  cancelStay: 'staysCancelStay',
  reviewStay: 'staysReviewStay',
  recordPayment: 'staysRecordPayment',
  voidIncome: 'staysVoidIncome',
  searchGuests: 'staysSearchGuests',
  upsertChannel: 'staysUpsertChannel',
  removeChannel: 'staysRemoveChannel',
  syncNow: 'staysSyncNow',
  createExportLink: 'staysCreateExportLink',
  getExportUrl: 'staysGetExportUrl',
  updateExportLink: 'staysUpdateExportLink',
  revokeExportLink: 'staysRevokeExportLink',
  importAirbnbCsv: 'staysImportAirbnbCsv',
  recordExpense: 'staysRecordExpense',
  voidExpense: 'staysVoidExpense',
} as const;
export type StaysCallableKey = keyof typeof STAYS_CALLABLES;
export type StaysCallableName = (typeof STAYS_CALLABLES)[StaysCallableKey];
export const STAYS_CALLABLE_NAMES: readonly StaysCallableName[] = Object.values(STAYS_CALLABLES);

/** Triggers, the scheduler, the worker and the export endpoint. */
export const STAYS_BACKGROUND_FUNCTIONS = {
  onStayWrite: 'staysOnStayWrite',
  onTaskWrite: 'staysOnTaskWrite',
  scheduledSync: 'staysScheduledSync',
  processSyncJob: 'staysProcessSyncJob',
  icalExport: 'staysIcalExport',
} as const;

// --- Shared request pieces --------------------------------------------------

export interface FacilityScopedRequest {
  facilityId: string;
}

export interface StayGuestInput {
  /** ≤60, e.g. 'Jane D.' */
  displayName: string;
  adults: number;
  children: number;
  pets: number;
  rvLengthFt: number | null;
}

export interface StayGuestProfileCreateInput {
  name: string;
  phone?: string | null;
  email?: string | null;
  vehicle?: Partial<StayGuestVehicle> | null;
  notes?: string | null;
}

export type StayGuestProfileRef = { profileId: string } | { create: StayGuestProfileCreateInput };

export interface StayPaymentInput {
  method: StayManualPaymentMethod;
  amountCents: number;
  receivedDate: Ymd;
}

export interface StayAdjustmentInput {
  cents: number;
  reason: string;
}

export interface StayQuote {
  currency: 'usd';
  nights: number;
  lines: StayFolioLine[];
  taxLines: StayFolioTaxLine[];
  subtotalCents: number;
  taxCents: number;
  totalCents: number;
}

// --- staysGetAvailability ---------------------------------------------------

export type StaysGetAvailabilityRequest = FacilityScopedRequest;
export interface StaysGetAvailabilityResponse {
  allowed: boolean;
  paused: boolean;
}

// --- staysSetControls -------------------------------------------------------

export type StayControlsChanges = Partial<
  Pick<
    StayControlsDoc,
    | 'moduleEnabled'
    | 'timeZone'
    | 'icalSyncEnabled'
    | 'icalExportEnabled'
    | 'turnoverTasksEnabled'
    | 'dailyBriefEnabled'
    | 'dailyBriefLocalHour'
    | 'lodgingTaxEnabled'
    | 'employeesCanBook'
    | 'employeesCanRecordCash'
    | 'defaultCheckInTime'
    | 'defaultCheckOutTime'
    | 'shortLeadWarningHours'
    | 'paymentMethods'
    | 'parkRules'
    | 'quietHours'
    | 'guestMessagingEnabled'
    | 'directPaymentsEnabled'
  >
>;

export interface StaysSetControlsRequest extends FacilityScopedRequest {
  changes: StayControlsChanges;
  /** Confirms `changes.timeZone` (or the stored zone). moduleEnabled:true needs a confirmed zone. */
  confirmTimeZone?: boolean;
  expectedVersion?: number;
}
export interface StaysSetControlsResponse {
  controls: Wire<StayControlsDoc>;
  warnings: StaysWarning[];
}

// --- staysSaveListing / staysBulkCreateRvSites ------------------------------

export interface StaysSaveListingRequest extends FacilityScopedRequest {
  requestId: string;
  listingId?: string;
  expectedVersion?: number;
  listing: StayListingInput;
}
export interface StaysSaveListingResponse {
  listingId: string;
  version: number;
}

export interface StaysBulkRvSiteInput {
  n: number;
  hookup: RvHookup;
  amps: number[];
  maxLengthFt: number | null;
  pullThrough: boolean;
}
export interface StaysBulkCreateRvSitesRequest extends FacilityScopedRequest {
  requestId: string;
  /** e.g. 'RV ' → 'RV 1' … 'RV N'. */
  prefix: string;
  from: number;
  to: number;
  group: string;
  defaults: Partial<StayListingInput>;
  perSite: StaysBulkRvSiteInput[];
}
export interface StaysBulkCreateRvSitesResponse {
  listingIds: string[];
}

// --- staysQuote -------------------------------------------------------------

export interface StaysQuoteRequest extends FacilityScopedRequest {
  listingId: string;
  checkIn: Ymd;
  checkOut: Ymd;
  adults: number;
  children: number;
  pets: number;
  excludeStayId?: string;
  adjustmentCents?: number;
}
export interface StaysQuoteResponse {
  available: boolean;
  hardConflicts: HardConflictNight[];
  softNights: Ymd[];
  shortLead: boolean;
  quote: StayQuote;
  warnings: StaysWarning[];
}

// --- staysCreateStay --------------------------------------------------------

export interface StaysCreateStayRequest extends FacilityScopedRequest {
  requestId: string;
  listingId: string;
  checkIn: Ymd;
  checkOut: Ymd;
  kind: StayKind;
  source: StaySource;
  /** Required for OTA sources; Airbnb stays become `airbnb_{CODE}`. */
  confirmationCode?: string;
  guest: StayGuestInput;
  guestProfile?: StayGuestProfileRef;
  checkInNow?: boolean;
  times?: { checkIn?: HourMinute; checkOut?: HourMinute };
  payment?: StayPaymentInput;
  adjustment?: StayAdjustmentInput;
  overrideSoftBlocks?: boolean;
  acknowledgeShortLead?: boolean;
  acknowledgeDoNotRent?: boolean;
  notes?: string;
}
export interface StaysCreateStayResponse {
  stayId: string;
  /** false when this requestId was already applied (a retry). */
  created: boolean;
  status: StayStatus;
  folio?: Wire<StayFolioDoc> | null;
  incomeEntryId?: string | null;
  warnings: StaysWarning[];
}

// --- staysModifyStay --------------------------------------------------------

export interface StaysModifyStayChanges {
  checkIn?: Ymd;
  checkOut?: Ymd;
  listingId?: string;
  checkInTime?: HourMinute;
  checkOutTime?: HourMinute;
  guest?: Partial<StayGuestInput>;
}
export interface StaysModifyStayRequest extends FacilityScopedRequest {
  stayId: string;
  expectedVersion: number;
  changes: StaysModifyStayChanges;
  overrideSoftBlocks?: boolean;
  acknowledgeShortLead?: boolean;
  payment?: StayPaymentInput;
  /** Required with `payment`: the income row is `man_{requestId}`. */
  requestId?: string;
}
export interface StaysModifyStayResponse {
  stay: Wire<StayDoc>;
  folio?: Wire<StayFolioDoc> | null;
}

// --- staysCancelStay / staysReviewStay --------------------------------------

export interface StaysCancelStayRequest extends FacilityScopedRequest {
  stayId: string;
  expectedVersion: number;
  reason: string;
  noShow?: boolean;
}
export interface StaysCancelStayResponse {
  stay: Wire<StayDoc>;
}

export interface StaysReviewStayRequest extends FacilityScopedRequest {
  stayId: string;
  action: StayReviewAction;
  note: string;
  expectedVersion?: number;
}
export interface StaysReviewStayResponse {
  stay: Wire<StayDoc>;
}

// --- staysRecordPayment / staysVoidIncome -----------------------------------

export interface StaysRecordPaymentRequest extends FacilityScopedRequest {
  requestId: string;
  stayId: string;
  method: StayManualPaymentMethod;
  /** Negative for a refund given back (owner/manager only). */
  amountCents: number;
  receivedDate: Ymd;
  memo?: string;
}
export interface StaysRecordPaymentResponse {
  entryId: string;
  created: boolean;
  paymentStatus: StayPaymentStatus;
  folio: Wire<StayFolioDoc> | null;
}

export interface StaysVoidIncomeRequest extends FacilityScopedRequest {
  entryId: string;
  reason: string;
}
export interface StaysVoidIncomeResponse {
  entryId: string;
  status: 'voided';
  folio: Wire<StayFolioDoc> | null;
}

// --- staysSearchGuests ------------------------------------------------------

export interface StaysSearchGuestsRequest extends FacilityScopedRequest {
  query: string;
}
export interface StayGuestSearchResult {
  profileId: string;
  name: string;
  rvLengthFt: number | null;
  lastStayAt: string | null;
  stayCount: number;
  doNotRent: boolean;
  /** Owner/manager only. */
  phoneE164?: string | null;
  /** Owner/manager only. */
  email?: string | null;
}
export type StaysSearchGuestsResponse = StayGuestSearchResult[];

// --- Channels ---------------------------------------------------------------

export interface StaysChannelSyncResult {
  channelId: string;
  status: ChannelSyncStatus;
  httpStatus: number | null;
  created: number;
  dateChanged: number;
  restored: number;
  missesAdvanced: number;
  removed: number;
  needsReview: number;
  conflicts: number;
  blocks: number;
  durationMs: number;
  /** Set when the channel's lease was held by another run. */
  skipped?: boolean;
}

export interface StaysUpsertChannelRequest extends FacilityScopedRequest {
  listingId: string;
  provider: ChannelProvider;
  label: string;
  url: string;
  importBlocks: boolean;
  dryRun: boolean;
  channelId?: string;
}
export interface StaysUpsertChannelPreview {
  dryRun: true;
  status: ChannelSyncStatus;
  reservations: number;
  blocks: number;
  firstDate: Ymd | null;
  lastDate: Ymd | null;
  nextArrival: Ymd | null;
  warnings: StaysWarning[];
}
export interface StaysUpsertChannelCommitted {
  dryRun: false;
  channelId: string;
  urlHost: string;
  urlFingerprint: string;
  firstSync: StaysChannelSyncResult;
}
export type StaysUpsertChannelResponse = StaysUpsertChannelPreview | StaysUpsertChannelCommitted;

export interface StaysRemoveChannelRequest extends FacilityScopedRequest {
  channelId: string;
}
export interface StaysRemoveChannelResponse {
  channelId: string;
  detachedStays: number;
}

export interface StaysSyncNowRequest extends FacilityScopedRequest {
  channelId?: string;
}
export interface StaysSyncNowResponse {
  results: StaysChannelSyncResult[];
}

// --- Export links -----------------------------------------------------------

export interface StaysCreateExportLinkRequest extends FacilityScopedRequest {
  listingId: string;
  targetProvider: ExportTargetProvider;
  label: string;
  /** Defaults to 'blocks_only'. */
  scope?: ExportScope;
  /** Optional (null is the same as leaving it out); the link becomes `xl_{requestId}`, so a double tap or retry returns the link it made. */
  requestId?: string | null;
}
export interface StaysCreateExportLinkResponse {
  linkId: string;
  url: string;
}

export interface StaysGetExportUrlRequest extends FacilityScopedRequest {
  linkId: string;
}
export interface StaysGetExportUrlResponse {
  url: string;
}

export interface StaysUpdateExportLinkRequest extends FacilityScopedRequest {
  linkId: string;
  scope?: ExportScope;
  label?: string;
}
export interface StaysUpdateExportLinkResponse {
  linkId: string;
  scope: ExportScope;
  label: string;
}

export interface StaysRevokeExportLinkRequest extends FacilityScopedRequest {
  linkId: string;
  rotate?: boolean;
}
export interface StaysRevokeExportLinkResponse {
  linkId: string;
  revoked: true;
  /** Present when rotating: the new link, to re-paste into the channel. */
  rotated?: StaysCreateExportLinkResponse;
  warnings: StaysWarning[];
}

// --- Airbnb CSV import ------------------------------------------------------

export interface StaysImportAirbnbCsvRequest extends FacilityScopedRequest {
  kind: 'earnings' | 'reservations';
  fileName: string;
  /** ≤1 MB, ≤5000 rows. */
  csvText: string;
  dryRun: boolean;
  /** Canonical field → header text in this file. */
  mappingOverrides?: Record<string, string>;
  /** Airbnb listing name → listingId; saved as an alias on commit. */
  listingAliasMap?: Record<string, string>;
}
export interface StaysImportSample {
  row: number;
  reason: string;
}
export interface StaysImportAirbnbCsvResponse {
  batchId: string;
  kind: 'earnings' | 'reservations';
  dryRun: boolean;
  /** Set when this exact file was committed before. */
  alreadyImportedAt: string | null;
  mapping: { detected: Record<string, string>; missingRequired: string[] };
  rowCount: number;
  created: number;
  skippedDuplicate: number;
  needsReview: number;
  rejected: number;
  /** ≤20 */
  samples: StaysImportSample[];
  totals: StayImportTotals;
  dateRange: { from: Ymd | null; to: Ymd | null };
  matchedListings: { name: string; listingId: string }[];
  unmatchedListings: string[];
  matchedStays: number;
  createdStays: number;
}

// --- Expenses ---------------------------------------------------------------

export interface StaysRecordExpenseRequest extends FacilityScopedRequest {
  requestId: string;
  listingId?: string | null;
  category: StayExpenseCategory;
  amountCents: number;
  spentDate: Ymd;
  vendor?: string;
  memo?: string;
  receiptPath?: string | null;
}
export interface StaysRecordExpenseResponse {
  expenseId: string;
  created: boolean;
}

export interface StaysVoidExpenseRequest extends FacilityScopedRequest {
  expenseId: string;
  reason: string;
}
export interface StaysVoidExpenseResponse {
  expenseId: string;
  status: 'voided';
}

/** Request and response type per callable name. */
export interface StaysCallableContracts {
  staysGetAvailability: { request: StaysGetAvailabilityRequest; response: StaysGetAvailabilityResponse };
  staysSetControls: { request: StaysSetControlsRequest; response: StaysSetControlsResponse };
  staysSaveListing: { request: StaysSaveListingRequest; response: StaysSaveListingResponse };
  staysBulkCreateRvSites: { request: StaysBulkCreateRvSitesRequest; response: StaysBulkCreateRvSitesResponse };
  staysQuote: { request: StaysQuoteRequest; response: StaysQuoteResponse };
  staysCreateStay: { request: StaysCreateStayRequest; response: StaysCreateStayResponse };
  staysModifyStay: { request: StaysModifyStayRequest; response: StaysModifyStayResponse };
  staysCancelStay: { request: StaysCancelStayRequest; response: StaysCancelStayResponse };
  staysReviewStay: { request: StaysReviewStayRequest; response: StaysReviewStayResponse };
  staysRecordPayment: { request: StaysRecordPaymentRequest; response: StaysRecordPaymentResponse };
  staysVoidIncome: { request: StaysVoidIncomeRequest; response: StaysVoidIncomeResponse };
  staysSearchGuests: { request: StaysSearchGuestsRequest; response: StaysSearchGuestsResponse };
  staysUpsertChannel: { request: StaysUpsertChannelRequest; response: StaysUpsertChannelResponse };
  staysRemoveChannel: { request: StaysRemoveChannelRequest; response: StaysRemoveChannelResponse };
  staysSyncNow: { request: StaysSyncNowRequest; response: StaysSyncNowResponse };
  staysCreateExportLink: { request: StaysCreateExportLinkRequest; response: StaysCreateExportLinkResponse };
  staysGetExportUrl: { request: StaysGetExportUrlRequest; response: StaysGetExportUrlResponse };
  staysUpdateExportLink: { request: StaysUpdateExportLinkRequest; response: StaysUpdateExportLinkResponse };
  staysRevokeExportLink: { request: StaysRevokeExportLinkRequest; response: StaysRevokeExportLinkResponse };
  staysImportAirbnbCsv: { request: StaysImportAirbnbCsvRequest; response: StaysImportAirbnbCsvResponse };
  staysRecordExpense: { request: StaysRecordExpenseRequest; response: StaysRecordExpenseResponse };
  staysVoidExpense: { request: StaysVoidExpenseRequest; response: StaysVoidExpenseResponse };
}

// ---------------------------------------------------------------------------
// Collection names. Stays code opens collections through these, and
// scripts/check_stays_isolation.cjs keeps it away from the storage ones.
// ---------------------------------------------------------------------------

/** Under facilities/{facilityId}/. */
export const STAY_COLLECTIONS = {
  controls: 'stayControls',
  listings: 'stayListings',
  listingAccess: 'stayListingAccess',
  channels: 'stayChannels',
  channelBlocks: 'stayChannelBlocks',
  exportLinks: 'stayExportLinks',
  syncLog: 'staySyncLog',
  stays: 'stays',
  private: 'stayPrivate',
  access: 'stayAccess',
  folios: 'stayFolios',
  nightLocks: 'stayNightLocks',
  tasks: 'stayTasks',
  income: 'stayIncome',
  expenses: 'stayExpenses',
  importBatches: 'stayImportBatches',
  guestProfiles: 'stayGuestProfiles',
  messageTemplates: 'stayMessageTemplates',
  /** Existing collection; stays writes only STAY_* types with deterministic ids. */
  notifications: 'Notifications',
} as const;

/** TOP-LEVEL. */
export const STAY_TOP_LEVEL_COLLECTIONS = {
  serverConfig: 'staysServerConfig',
  syncJobs: 'staySyncJobs',
  exportTokens: 'stayCalendarExportTokens',
} as const;

/** The single doc id used by stayControls and staysServerConfig, and by the secret subcollections. */
export const STAYS_CURRENT_DOC_ID = 'current';
/** Subcollection that holds bearer secrets (channel URLs, export tokens). */
export const STAYS_SECRET_SUBCOLLECTION = 'secret';

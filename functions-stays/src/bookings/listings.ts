import * as functions from 'firebase-functions/v1';
import { Timestamp } from 'firebase-admin/firestore';

import {
  STAYS_CALLABLES,
  STAYS_LIMITS,
  STAY_COLLECTIONS,
  StayDoc,
  StayListingDoc,
  StayListingInput,
  StayRole,
  StaysBulkCreateRvSitesResponse,
  StaysSaveListingResponse,
} from '@sfc/functions-shared/stays/contracts';
import { addDays, canonicalIanaZone, facilityToday } from '@sfc/functions-shared/stays/dates';
import { listingIdBulk } from '@sfc/functions-shared/stays/ids';
import { StayValidationError, validateListingInput, validateRv } from '@sfc/functions-shared/stays/validation';

import { staysError, staysErrorReason } from '../common/errors';
import {
  StaysCallContext,
  StaysDeps,
  auditStays,
  defaultStaysDeps,
  optionalDocId,
  requireRequestId,
  runStaysGuards,
  staysCallable,
} from '../common/guards';
import { applyStayMutations } from '../common/stayWriter';
import { defaultChecklistFor } from './seedDefaults';
import { facilityCol, invalid, validated } from './shared';

const OWNER_OR_MANAGER: readonly StayRole[] = ['owner', 'manager'];

/** Counts toward the 60-listing cap and takes bookings. */
function isLive(doc: Pick<StayListingDoc, 'active' | 'archived'>): boolean {
  return doc.active === true && doc.archived !== true;
}

function sameText(a: string, b: string): boolean {
  return a.trim().toLowerCase() === b.trim().toLowerCase();
}

/**
 * Names and short codes are how she tells listings apart (the tape chart, the
 * Airbnb CSV match), so two unarchived listings may not share either.
 */
function assertDistinct(
  input: Pick<StayListingInput, 'name' | 'shortCode' | 'archived'>,
  others: { id: string; doc: StayListingDoc }[],
  fieldPrefix = '',
): void {
  if (input.archived) return;
  for (const { doc } of others) {
    if (doc.archived === true) continue;
    if (sameText(doc.name ?? '', input.name)) {
      throw invalid(`${fieldPrefix}name`, `There is already a listing called "${doc.name}". Give this one a different name.`);
    }
    if (sameText(doc.shortCode ?? '', input.shortCode)) {
      throw invalid(`${fieldPrefix}shortCode`, `"${doc.shortCode}" is already the short code of ${doc.name}.`);
    }
  }
}

function assertListingCap(liveOthers: number, adding: number): void {
  if (liveOthers + adding > STAYS_LIMITS.activeListingsPerFacility) {
    throw staysError(
      'resource-exhausted',
      'limit_reached',
      `A facility can have up to ${STAYS_LIMITS.activeListingsPerFacility} active listings. Archive one you no longer rent first.`,
      { limit: STAYS_LIMITS.activeListingsPerFacility },
    );
  }
}

// ---------------------------------------------------------------------------
// staysSaveListing
// ---------------------------------------------------------------------------

export interface SaveListingResult extends StaysSaveListingResponse {
  created: boolean;
  /** Stays whose denormalized listing name, group or kind were brought up to date. */
  staysUpdated: number;
}

export async function handleSaveListing(
  rawData: unknown,
  context: functions.https.CallableContext,
  deps: StaysDeps = defaultStaysDeps(),
): Promise<SaveListingResult> {
  const ctx = await runStaysGuards(
    rawData,
    context,
    {
      callable: STAYS_CALLABLES.saveListing,
      roles: OWNER_OR_MANAGER,
      // The setup wizard adds listings before the module is turned on.
      requireModuleEnabled: false,
      validate: (d) => {
        requireRequestId(d);
        optionalDocId(d, 'listingId');
      },
      rateLimit: { key: 'stays_listing', windowSeconds: 60, perFacility: 60 },
    },
    deps,
  );
  const requestId = requireRequestId(ctx.data);
  const listingId = optionalDocId(ctx.data, 'listingId');
  const input = validated(() => validateListingInput(ctx.data.listing));
  const expectedVersion = ctx.data.expectedVersion;
  if (listingId && (!Number.isInteger(expectedVersion) || (expectedVersion as number) < 1)) {
    throw invalid('expectedVersion', 'expectedVersion is required to change a listing: send the version you opened.');
  }
  const now = Timestamp.fromMillis(ctx.nowMs);
  const col = facilityCol(ctx.db, ctx.facilityId, STAY_COLLECTIONS.listings);
  const id = listingId ?? `lst_${requestId}`;

  const saved = await ctx.db.runTransaction(async (tx) => {
    const all = await tx.get(col.limit(500));
    const docs = all.docs.map((d) => ({ id: d.id, doc: d.data() as StayListingDoc }));
    const existing = docs.find((d) => d.id === id)?.doc ?? null;
    if (!listingId && existing) {
      // A retried create: this request already made it.
      return { version: existing.version, created: false, before: existing, after: existing };
    }
    if (listingId && !existing) {
      throw staysError('not-found', 'not_found', 'That listing was not found.', { listingId });
    }
    if (existing && existing.version !== expectedVersion) {
      throw staysError('aborted', 'version_mismatch', 'This listing changed since you opened it. Reload and try again.', {
        version: existing.version,
      });
    }
    const others = docs.filter((d) => d.id !== id);
    assertDistinct(input, others);
    if (isLive(input) && !(existing && isLive(existing))) {
      assertListingCap(others.filter((d) => isLive(d.doc)).length, 1);
    }
    const version = (existing?.version ?? 0) + 1;
    const doc: StayListingDoc = {
      ...input,
      facilityId: ctx.facilityId,
      version,
      createdAt: existing?.createdAt ?? now,
      createdBy: existing?.createdBy ?? ctx.uid,
      updatedAt: now,
      updatedBy: ctx.uid,
    };
    tx.set(col.doc(id), doc);
    return { version, created: !existing, before: existing, after: doc };
  });

  let staysUpdated = 0;
  const before = saved.before;
  if (
    before &&
    saved.after !== before &&
    (before.name !== input.name || before.group !== input.group || before.kind !== input.kind)
  ) {
    staysUpdated = await refreshStayListingFields(ctx, id, input);
  }

  await auditStays(ctx, {
    eventType: 'stays.listing.saved',
    targetType: 'stayListing',
    targetId: id,
    metadata: { created: saved.created, version: saved.version, active: input.active, archived: input.archived, staysUpdated },
  });
  return { listingId: id, version: saved.version, created: saved.created, staysUpdated };
}

/**
 * Stays carry the listing's name, group and kind so the Today board and the
 * notifications read without a join. After a rename, current and future
 * stays are brought up to date through the stay writer (with a version
 * check, so a booking changed meanwhile is re-read, not overwritten). Best
 * effort: the listing is already saved, and a stay that could not be
 * updated keeps its old label until the next rename.
 */
async function refreshStayListingFields(ctx: StaysCallContext, listingId: string, input: StayListingInput): Promise<number> {
  const tz = canonicalIanaZone(ctx.controls.timeZone);
  if (!tz || !ctx.controls.timeZoneConfirmedAt) return 0;
  const today = facilityToday(tz, ctx.nowMs);
  const staysCol = facilityCol(ctx.db, ctx.facilityId, STAY_COLLECTIONS.stays);
  const fields = { listingName: input.name, listingGroup: input.group, listingKind: input.kind };
  const now = Timestamp.fromMillis(ctx.nowMs);
  let updated = 0;
  try {
    for (let attempt = 0; attempt < 3; attempt++) {
      const snap = await staysCol
        .where('listingId', '==', listingId)
        .where('checkOut', '>=', addDays(today, -STAYS_LIMITS.lockHorizonPastDays))
        .limit(500)
        .get();
      const stale = snap.docs
        .map((d) => ({ id: d.id, doc: d.data() as StayDoc }))
        .filter(({ doc }) => doc.listingName !== fields.listingName || doc.listingGroup !== fields.listingGroup || doc.listingKind !== fields.listingKind);
      if (stale.length === 0) break;
      let retry = false;
      for (let i = 0; i < stale.length; i += 50) {
        const chunk = stale.slice(i, i + 50);
        try {
          await applyStayMutations({
            db: ctx.db,
            facilityId: ctx.facilityId,
            controls: ctx.controls,
            nowMs: ctx.nowMs,
            actor: ctx.uid,
            mutations: chunk.map(({ id, doc }) => ({
              stayId: id,
              next: { ...doc, ...fields, version: (doc.version ?? 0) + 1, updatedAt: now, updatedBy: ctx.uid },
              expectedVersion: doc.version ?? 0,
              mode: 'sfc' as const,
            })),
          });
          updated += chunk.length;
        } catch (error) {
          if (staysErrorReason(error) === 'version_mismatch') retry = true;
          else throw error;
        }
      }
      if (!retry) break;
    }
  } catch (error) {
    functions.logger.warn('stays: could not refresh stays after a listing rename', {
      facilityId: ctx.facilityId,
      listingId,
      error: error instanceof Error ? error.message : String(error),
    });
  }
  return updated;
}

export const staysSaveListing = staysCallable(STAYS_CALLABLES.saveListing, async (data, context) => {
  const { listingId, version } = await handleSaveListing(data, context);
  return { listingId, version } satisfies StaysSaveListingResponse;
});

// ---------------------------------------------------------------------------
// staysBulkCreateRvSites
// ---------------------------------------------------------------------------

const MAX_SITE_NUMBER = 999;

/** What an RV site starts as; the request's `defaults` replace any top-level part of it. */
export function rvSiteBase(group: string): StayListingInput {
  return {
    name: '',
    shortCode: '',
    kind: 'rv_site',
    group,
    sortOrder: 0,
    active: true,
    archived: false,
    address: null,
    capacity: { maxGuests: 0, bedrooms: 0, beds: 0, bathrooms: 0, petsAllowed: true },
    rv: null,
    times: { checkIn: null, checkOut: null },
    stayRules: { minNights: 1, maxNights: STAYS_LIMITS.manualStayMaxNights },
    ratesCents: {
      nightly: 0,
      weekendNightly: null,
      weeklyNightly: null,
      cleaningFee: 0,
      petFee: 0,
      extraGuestFee: 0,
      extraGuestAfter: 0,
    },
    seasonalRates: [],
    taxLines: [],
    turnover: {
      mode: 'quick_check',
      afterOwnerBlocks: false,
      checklistTemplate: defaultChecklistFor('rv_site', 'quick_check'),
      defaultAssigneeUid: null,
      defaultAssigneeName: null,
    },
    accessCodeMode: 'none',
    airbnb: { listingNameAliases: [], listingUrl: null, calendarUrl: null },
    notes: '',
  };
}

/** 'RV ' and 12 → 'RV12'; a long prefix is cut so the code fits in 8 characters. */
export function siteShortCode(prefix: string, n: number): string {
  const digits = String(n);
  const letters = prefix.replace(/[^A-Za-z0-9]/g, '');
  return `${letters.slice(0, Math.max(0, 8 - digits.length))}${digits}`;
}

/** No two sites of one bulk request share a name or short code (ignoring case, like assertDistinct). */
function assertBatchDistinct(inputs: { n: number; input: Pick<StayListingInput, 'name' | 'shortCode'> }[]): void {
  const names = new Map<string, number>();
  const codes = new Map<string, number>();
  for (const { n, input } of inputs) {
    const name = input.name.trim().toLowerCase();
    const code = input.shortCode.trim().toLowerCase();
    if (names.has(name)) {
      throw invalid('prefix', `Sites ${names.get(name)} and ${n} would both be called "${input.name}". Change the prefix.`);
    }
    if (codes.has(code)) {
      throw invalid('prefix', `Sites ${codes.get(code)} and ${n} would both get the short code "${input.shortCode}". Use a shorter prefix.`);
    }
    names.set(name, n);
    codes.set(code, n);
  }
}

/** Per-site keys: `defaults` may not set these for every site at once. */
const PER_SITE_KEYS = new Set(['name', 'shortCode']);

export async function handleBulkCreateRvSites(
  rawData: unknown,
  context: functions.https.CallableContext,
  deps: StaysDeps = defaultStaysDeps(),
): Promise<StaysBulkCreateRvSitesResponse & { created: number }> {
  const ctx = await runStaysGuards(
    rawData,
    context,
    {
      callable: STAYS_CALLABLES.bulkCreateRvSites,
      roles: OWNER_OR_MANAGER,
      requireModuleEnabled: false,
      validate: (d) => void requireRequestId(d),
      rateLimit: { key: 'stays_bulk_rv', windowSeconds: 60, perFacility: 10 },
    },
    deps,
  );
  const requestId = requireRequestId(ctx.data);
  const d = ctx.data;
  if (typeof d.prefix !== 'string' || d.prefix.length > 20 || /[\r\n\t]/.test(d.prefix)) {
    throw invalid('prefix', 'The name prefix is up to 20 characters, e.g. "RV ".');
  }
  const prefix = d.prefix;
  const from = d.from;
  const to = d.to;
  if (!Number.isInteger(from) || !Number.isInteger(to) || (from as number) < 1 || (to as number) > MAX_SITE_NUMBER || (from as number) > (to as number)) {
    throw invalid('from', `Site numbers run from 1 to ${MAX_SITE_NUMBER}, first to last.`);
  }
  const count = (to as number) - (from as number) + 1;
  if (count > STAYS_LIMITS.activeListingsPerFacility) {
    throw invalid('to', `Add at most ${STAYS_LIMITS.activeListingsPerFacility} sites at a time.`);
  }
  if (typeof d.group !== 'string' || d.group.trim().length > 40) throw invalid('group', 'The group name is up to 40 characters.');
  const group = d.group.trim() || 'RV park';
  const defaults = d.defaults === undefined || d.defaults === null ? {} : d.defaults;
  if (typeof defaults !== 'object' || Array.isArray(defaults)) throw invalid('defaults', 'defaults must be an object.');
  const defaultsRecord = defaults as Record<string, unknown>;
  for (const key of Object.keys(defaultsRecord)) {
    if (PER_SITE_KEYS.has(key)) throw invalid(`defaults.${key}`, `Each site gets its own ${key}.`);
  }
  if (defaultsRecord.kind !== undefined && defaultsRecord.kind !== 'rv_site' && defaultsRecord.kind !== 'tent_site') {
    throw invalid('defaults.kind', 'Bulk sites are RV or tent sites.');
  }

  const perSiteRaw = d.perSite === undefined || d.perSite === null ? [] : d.perSite;
  if (!Array.isArray(perSiteRaw) || perSiteRaw.length > count) throw invalid('perSite', 'perSite lists at most one entry per site.');
  const perSite = new Map<number, unknown>();
  perSiteRaw.forEach((raw, i) => {
    const site = raw as Record<string, unknown>;
    const n = site?.n;
    if (!Number.isInteger(n) || (n as number) < (from as number) || (n as number) > (to as number)) {
      throw invalid(`perSite[${i}].n`, `Site ${String(n)} is not between ${from} and ${to}.`);
    }
    if (perSite.has(n as number)) throw invalid(`perSite[${i}].n`, `Site ${n} is listed twice.`);
    perSite.set(n as number, site);
  });

  const base = rvSiteBase(group);
  const inputs: { id: string; n: number; input: StayListingInput }[] = [];
  for (let n = from as number; n <= (to as number); n++) {
    const site = perSite.get(n) as Record<string, unknown> | undefined;
    const rv = site
      ? { hookup: site.hookup, amps: site.amps, maxLengthFt: site.maxLengthFt ?? null, pullThrough: site.pullThrough, surface: null }
      : defaultsRecord.rv;
    if (rv === undefined || rv === null) {
      throw invalid(`perSite`, `Set the hookup for site ${n}, or give defaults.rv for every site.`);
    }
    const merged = {
      ...base,
      ...defaultsRecord,
      name: `${prefix}${n}`.trim(),
      shortCode: siteShortCode(prefix, n),
      group,
      kind: defaultsRecord.kind ?? 'rv_site',
      sortOrder: (Number.isInteger(defaultsRecord.sortOrder) ? (defaultsRecord.sortOrder as number) : 0) + n,
      rv,
    };
    const input = validated(() => {
      try {
        validateRv(rv, 'rv');
        return validateListingInput(merged);
      } catch (error) {
        if (error instanceof StayValidationError) throw new StayValidationError(`site ${n}: ${error.field}`, `Site ${n}: ${error.message}`);
        throw error;
      }
    });
    inputs.push({ id: listingIdBulk(requestId, n), n, input });
  }
  // siteShortCode cuts a long prefix to fit 8 characters, so two sites of one
  // batch can come out the same ('ABCDEF1X': site 1 and site 11 are both
  // ABCDEF11). assertDistinct only checks other listings, so check the batch too.
  assertBatchDistinct(inputs);

  const now = Timestamp.fromMillis(ctx.nowMs);
  const col = facilityCol(ctx.db, ctx.facilityId, STAY_COLLECTIONS.listings);
  const created = await ctx.db.runTransaction(async (tx) => {
    const all = await tx.get(col.limit(500));
    const docs = all.docs.map((s) => ({ id: s.id, doc: s.data() as StayListingDoc }));
    const mine = new Set(inputs.map((i) => i.id));
    const missing = inputs.filter((i) => !docs.some((x) => x.id === i.id));
    if (missing.length === 0) return 0; // a retried request: every site exists already
    const others = docs.filter((x) => !mine.has(x.id));
    for (const { n, input } of missing) assertDistinct(input, others, `site ${n}: `);
    assertListingCap(docs.filter((x) => isLive(x.doc)).length, missing.filter((m) => isLive(m.input)).length);
    for (const { id, input } of missing) {
      const doc: StayListingDoc = {
        ...input,
        facilityId: ctx.facilityId,
        version: 1,
        createdAt: now,
        createdBy: ctx.uid,
        updatedAt: now,
        updatedBy: ctx.uid,
      };
      tx.create(col.doc(id), doc);
    }
    return missing.length;
  });

  await auditStays(ctx, {
    eventType: 'stays.listing.saved',
    targetType: 'stayListing',
    targetId: `bulk_${requestId}`,
    metadata: { bulk: true, from, to, created },
  });
  return { listingIds: inputs.map((i) => i.id), created };
}

export const staysBulkCreateRvSites = staysCallable(STAYS_CALLABLES.bulkCreateRvSites, async (data, context) => {
  const { listingIds } = await handleBulkCreateRvSites(data, context);
  return { listingIds } satisfies StaysBulkCreateRvSitesResponse;
});

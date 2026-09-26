#!/usr/bin/env node
/**
 * Strip an area prefix from one facility's unit numbers ("C2-12" in area
 * "Complex 2" becomes "12"), relabel the tenants whose label named those
 * units, and set facilities/{id}.unitNumbersRepeatAcrossAreas = true so the
 * app accepts the same number in different areas. One facility per run.
 * Reversible: every write is recorded, and --revert puts it back.
 *
 * The prefix map is explicit (--prefix-map "C2-=Complex 2,C3-=Complex 3"):
 * a live (not archived) unit is renumbered only when its trimmed number
 * starts with a mapped prefix (ignoring case) and its `area` is the mapped
 * area. Nothing is guessed.
 *
 * Pre-checks. Any failure aborts the run and nothing is written:
 *   - the facility exists;
 *   - every live unit with a mapped prefix has an area, and it is the mapped
 *     area (trimmed, ignoring case and repeated spaces);
 *   - the number left after the prefix is non-empty, does not itself start
 *     with a mapped prefix, and the unit has no legacyUnitNumber already;
 *   - after the change no two live units share (area, number), ignoring case
 *     and spaces, and no new number equals a live unit with no area;
 *   - no renumbered unit has an unexpired checkout hold
 *     (facilities/{id}/mapEngine/activeHolds/items/{unitId}), an unexpired
 *     pending/confirmed publicReservations doc, or a pending/confirmed
 *     facilities/{id}/reservations doc;
 *   - every ACTIVE tenant whose unitId or unitNumber names a renumbered unit
 *     is consistent: unitId is that unit, the unit's tenantId is the tenant,
 *     the label is the unit's number (trimmed, ignoring case) and unitArea is
 *     the unit's area;
 *   - it is not within 6 hours of 00:00Z on the 1st of a month, when the
 *     monthly rent jobs run (--allow-near-rent-run overrides, testing only).
 * Warnings (reported, not aborting): online rentals are on, a prefix matches
 * no unit, archived units still carry a prefix or collide, expired holds or
 * reservations still pending, units in `reserved` status, stale unit
 * holders, map labels that spell out old numbers.
 *
 * Writes (--apply, which also needs --confirm-app-supports-repeats: the app
 * build that allows a number to repeat across areas must be live first):
 * the facility flag is set FIRST, in its own transaction (harmless while the
 * numbers are still prefixed and unique), so a crash part-way never leaves
 * repeated numbers with the flag off. Then per unit, one transaction re-reads
 * the unit, the tenants it relabels and the unit's hold, refuses the item if
 * any changed since planning, and writes unit.unitNumber (+ legacyUnitNumber
 * = old) and each tenant's unitNumber (+ legacyUnitNumber = old label).
 * unitId, unitArea and updatedAt are left alone. Ledgers, payments,
 * contracts, invoices, reservations and other historical snapshots are never
 * touched; inactive tenants keep their old label. Afterwards the live units,
 * holds and reservations are read again and any (area, number) duplicate,
 * clash with a no-area unit, or new hold/reservation on a renumbered unit is
 * reported. Exit code 2 when anything was refused or the check found issues.
 *
 * The record (write-ahead): before the first write the full before/after
 * plan is written to --out (default backfill-records/ at the repo root, which
 * is gitignored), and it is rewritten as each item applies or is refused.
 * The record is the only source for --revert: keep it outside the checkout.
 *
 * --revert <record>: honours what the apply did. Items the apply refused are
 * skipped; applied and pending items (pending: a crash between commit and
 * record write) are handled by state. Per unit, one transaction restores the
 * recorded "before" values (deleting fields that were not there) when the
 * unit is still in its "after" state. A recorded tenant that has since moved
 * on (inactive, or its unitId no longer this unit) is detached and left
 * alone; an ACTIVE tenant who now holds the unit (unit.tenantId, or their
 * unitId is the unit) and whose label is the "after" number is relabelled to
 * the old number in the same transaction. An item where the unit, or a
 * still-attached recorded tenant, matches neither state is refused. The
 * facility flag is restored last: only when the record says the apply set it,
 * no item was refused, and no number is used by two live units (trimmed,
 * ignoring case; the app refuses to turn the setting off then too), counted
 * as the units stand after the unit restores, so a dry run predicts the real
 * outcome. A pending item whose unit is still as it was (never written)
 * leaves a since-changed recorded tenant alone instead of refusing. Dry run
 * unless --apply is given too.
 *
 * Map shapes link to units by unitId (lib/models/map_shape_model.dart), so
 * they need no change. The public map's unit list (publicFacilityMaps units)
 * is refreshed by syncPublicFacilityMapInventoryOnUnitWrite when a unit's
 * number changes; a shape label typed with an old number is not, and needs
 * editing and a re-publish from the app.
 *
 * Credentials: Application Default Credentials, project from --project,
 * GOOGLE_CLOUD_PROJECT, or storage-facility-creator. firebase-admin is
 * borrowed from --admin-from <package dir> (default
 * functions-tenant-lifecycle at the repo root).
 *
 * Usage:
 *   node scripts/renumber-units-by-area.mjs --facility <id> --prefix-map "C2-=Complex 2,C3-=Complex 3"
 *   node scripts/renumber-units-by-area.mjs --facility <id> --prefix-map "..." --apply --confirm-app-supports-repeats --out <dir outside the checkout>
 *   node scripts/renumber-units-by-area.mjs --revert backfill-records/<record>.json [--apply]
 *   Options: --project <id>  --out <dir>  --json  --allow-near-rent-run  --admin-from <dir>
 *            --confirm-app-supports-repeats (required with --apply)
 */
import { createRequire } from 'node:module';
import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');

/** Records go to the repo root's backfill-records/ (gitignored) unless --out says otherwise. */
export function defaultOutDir() {
  return path.join(repoRoot, 'backfill-records');
}

/** What must be true of the deployed app before --apply. */
export const APP_SUPPORT_NOTE =
  'The live app build must include the repeat-unit-numbers rules (PR #14: a number may repeat across areas when unitNumbersRepeatAcrossAreas is on) before --apply.';

/** Hours either side of 00:00Z on the 1st when the monthly rent jobs run. */
export const RENT_RUN_WINDOW_HOURS = 6;

/** A text field trimmed, or null when it is not a string or is blank. */
export function textOf(value) {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

/** A unit number as the app compares it (unitNumberKey): trimmed, ignoring case. */
export function unitNumberKey(value) {
  return String(value ?? '').trim().toLowerCase();
}

/** An area as the app compares it, and repeated spaces as one. '' for none. */
export function areaKey(value) {
  return (textOf(value) ?? '').replace(/\s+/g, ' ').toLowerCase();
}

/** Stricter key for collisions: every space removed, ignoring case. */
export function looseKey(value) {
  return String(value ?? '').replace(/\s+/g, '').toLowerCase();
}

/** A Firestore Timestamp, Date, millis or ISO string as a Date; null otherwise. */
export function toDate(value) {
  if (value == null) return null;
  if (value instanceof Date) return value;
  if (typeof value.toDate === 'function') return value.toDate();
  if (typeof value === 'number' || typeof value === 'string') {
    const d = new Date(value);
    return Number.isNaN(d.getTime()) ? null : d;
  }
  return null;
}

/** Whether [now] is within [hours] of 00:00Z on the 1st of this or next month. */
export function isNearRentRun(now, hours = RENT_RUN_WINDOW_HOURS) {
  const y = now.getUTCFullYear();
  const m = now.getUTCMonth();
  const window = hours * 3600 * 1000;
  return [Date.UTC(y, m, 1), Date.UTC(y, m + 1, 1)].some((t) => Math.abs(now.getTime() - t) < window);
}

/**
 * "C2-=Complex 2,C3-=Complex 3" as [{ prefix, area }]. Throws on an empty
 * prefix or area, a repeated prefix, or one prefix starting another (which
 * would make a number match two).
 */
export function parsePrefixMap(raw) {
  const entries = [];
  for (const part of String(raw ?? '').split(',')) {
    if (!part.trim()) continue;
    const eq = part.indexOf('=');
    if (eq < 0) throw new Error(`--prefix-map entry "${part}" needs prefix=area`);
    const prefix = part.slice(0, eq).trim();
    const area = part.slice(eq + 1).trim();
    if (!prefix) throw new Error(`--prefix-map entry "${part}" has no prefix`);
    if (!area) throw new Error(`--prefix-map entry "${part}" has no area`);
    entries.push({ prefix, area });
  }
  if (entries.length === 0) throw new Error('--prefix-map is empty');
  for (let i = 0; i < entries.length; i++) {
    for (let j = 0; j < entries.length; j++) {
      if (i === j) continue;
      const a = entries[i].prefix.toLowerCase();
      const b = entries[j].prefix.toLowerCase();
      if (a === b) throw new Error(`--prefix-map repeats prefix "${entries[i].prefix}"`);
      if (b.startsWith(a)) {
        throw new Error(`--prefix-map prefixes "${entries[i].prefix}" and "${entries[j].prefix}" overlap`);
      }
    }
  }
  return entries;
}

/** The entry of [prefixMap] whose prefix starts [number] (trimmed, ignoring case), or null. */
export function matchPrefix(number, prefixMap) {
  const n = String(number ?? '').trim().toLowerCase();
  return prefixMap.find((e) => n.startsWith(e.prefix.toLowerCase())) ?? null;
}

const isLive = (unit) => unit.data?.archived !== true;
const isActiveTenant = (tenant) => tenant.data?.isActive === true;
const OPEN_RESERVATION = new Set(['pending', 'confirmed']);

/** [fields] of [data] as { values, missing }: values null for a missing field, listed in missing. */
function snapshotFields(data, fields) {
  const values = {};
  const missing = [];
  for (const f of fields) {
    if (data == null || data[f] === undefined) {
      values[f] = null;
      missing.push(f);
    } else {
      values[f] = data[f];
    }
  }
  return { values, missing };
}

/**
 * Whether [data] holds exactly [values] for every field, with the fields in
 * [missing] absent (a field present with null does not count as absent).
 */
export function fieldsMatch(data, values, missing = []) {
  for (const [f, v] of Object.entries(values)) {
    const cur = data == null ? undefined : data[f];
    if (missing.includes(f)) {
      if (cur !== undefined) return false;
    } else if (cur !== v) {
      return false;
    }
  }
  return true;
}

/**
 * What the migration would do for one facility. Pure: every collection is
 * `{ id, data }` rows as read; [facility] is the facility doc's data or
 * null. Returns { ok, aborts, warnings, units, facilityChange, counts }.
 * `units` holds one item per unit to renumber, each with the tenants it
 * relabels; `facilityChange` is null when the flag is already true.
 */
export function planRenumber({
  facilityId,
  facility,
  units = [],
  tenants = [],
  holds = [],
  publicReservations = [],
  facilityReservations = [],
  publicSettings = null,
  mapLabels = [],
  prefixMap,
  now = new Date(),
  allowNearRentRun = false,
}) {
  const aborts = [];
  const warnings = [];
  const abort = (code, message, extra = {}) => aborts.push({ code, message, ...extra });
  const warn = (code, message, extra = {}) => warnings.push({ code, message, ...extra });

  const counts = {
    units: units.length,
    liveUnits: 0,
    archivedUnits: 0,
    unitsToRenumber: 0,
    alreadyMigrated: 0,
    tenantsToRelabel: 0,
    activeTenants: 0,
    inactiveTenantsWithOldLabel: 0,
    secondaryUnitsRenumbered: 0,
    byPrefix: Object.fromEntries(prefixMap.map((e) => [e.prefix, 0])),
  };

  if (!facility) abort('facility-missing', `facilities/${facilityId} does not exist`);
  if (isNearRentRun(now)) {
    if (allowNearRentRun) {
      warn('near-rent-run-overridden', 'Within 6 hours of the monthly rent run; overridden by --allow-near-rent-run');
    } else {
      abort('near-rent-run', `Within ${RENT_RUN_WINDOW_HOURS} hours of 00:00Z on the 1st (monthly rent jobs); run later`);
    }
  }
  if (publicSettings?.publicRentalsEnabled === true) {
    warn('online-rentals-on', 'Online rentals are on for this facility: a renter could start a checkout mid-run (each unit re-checks its hold in its transaction)');
  }

  // Units: which to renumber, and what each live unit's number ends up as.
  const planned = new Map(); // unitId -> item
  const finalNumber = new Map(); // unitId -> number after the run
  for (const unit of units) {
    const data = unit.data ?? {};
    const number = String(data.unitNumber ?? '');
    const entry = matchPrefix(number, prefixMap);
    if (!isLive(unit)) {
      counts.archivedUnits++;
      if (entry) warn('archived-unit-prefixed', `Archived unit ${unit.id} "${number}" keeps its prefix`, { unitId: unit.id });
      continue;
    }
    counts.liveUnits++;
    finalNumber.set(unit.id, number);
    if (!entry) {
      if (textOf(data.legacyUnitNumber) && matchPrefix(data.legacyUnitNumber, prefixMap)) counts.alreadyMigrated++;
      continue;
    }
    counts.byPrefix[entry.prefix]++;
    const area = textOf(data.area);
    const stripped = number.trim().slice(entry.prefix.length).trim();
    if (!area) {
      abort('unit-area-missing', `Unit ${unit.id} "${number}" has prefix "${entry.prefix}" but no area (expected "${entry.area}")`, { unitId: unit.id });
      continue;
    }
    if (areaKey(area) !== areaKey(entry.area)) {
      abort('unit-area-mismatch', `Unit ${unit.id} "${number}" has prefix "${entry.prefix}" but area "${area}" (expected "${entry.area}")`, { unitId: unit.id });
      continue;
    }
    if (!stripped) {
      abort('empty-stripped-number', `Unit ${unit.id} "${number}" is nothing but the prefix`, { unitId: unit.id });
      continue;
    }
    if (matchPrefix(stripped, prefixMap)) {
      abort('stripped-still-prefixed', `Unit ${unit.id} "${number}" would become "${stripped}", which still has a mapped prefix`, { unitId: unit.id });
      continue;
    }
    if (data.legacyUnitNumber !== undefined) {
      abort('legacy-already-set', `Unit ${unit.id} "${number}" already has legacyUnitNumber "${data.legacyUnitNumber}"`, { unitId: unit.id });
      continue;
    }
    if (String(data.status ?? '').toLowerCase() === 'reserved') {
      warn('unit-reserved', `Unit ${unit.id} "${number}" is in reserved status`, { unitId: unit.id });
    }
    const snap = snapshotFields(data, ['unitNumber', 'legacyUnitNumber']);
    planned.set(unit.id, {
      unitId: unit.id,
      area,
      prefix: entry.prefix,
      expect: { areaKey: areaKey(area), tenantId: textOf(data.tenantId) },
      before: snap.values,
      beforeMissing: snap.missing,
      after: { unitNumber: stripped, legacyUnitNumber: number },
      tenants: [],
    });
    finalNumber.set(unit.id, stripped);
  }
  for (const e of prefixMap) {
    if (counts.byPrefix[e.prefix] === 0) warn('prefix-unused', `No live unit starts with "${e.prefix}"`);
  }

  // Collisions among live units after the run, (area, number) ignoring case and spaces.
  const liveById = new Map(units.filter(isLive).map((u) => [u.id, u]));
  const groups = new Map();
  for (const [unitId, number] of finalNumber) {
    if (!looseKey(number)) continue;
    const key = `${looseKey(liveById.get(unitId).data?.area)}\u0000${looseKey(number)}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(unitId);
  }
  for (const ids of groups.values()) {
    if (ids.length < 2) continue;
    const area = textOf(liveById.get(ids[0]).data?.area) ?? '(no area)';
    const touched = ids.some((id) => planned.has(id));
    abort(
      touched ? 'collision' : 'duplicate-existing',
      `${touched ? 'Would leave' : 'Already has'} ${ids.length} live units numbered "${finalNumber.get(ids[0])}" in ${area}: ${ids.join(', ')}`,
      { unitIds: ids },
    );
  }
  const noAreaNumbers = new Map();
  for (const unit of liveById.values()) {
    if (textOf(unit.data?.area) || planned.has(unit.id)) continue;
    const k = looseKey(unit.data?.unitNumber);
    if (k) noAreaNumbers.set(k, unit.id);
  }
  for (const item of planned.values()) {
    const other = noAreaNumbers.get(looseKey(item.after.unitNumber));
    if (other) {
      abort('collision-with-no-area-unit', `Unit ${item.unitId} would become "${item.after.unitNumber}", the number of unit ${other}, which has no area`, { unitIds: [item.unitId, other] });
    }
  }
  // Archived units are not live, but the app has counted them when numbering.
  for (const unit of units) {
    if (isLive(unit)) continue;
    const k = looseKey(unit.data?.unitNumber);
    const a = looseKey(unit.data?.area);
    for (const item of planned.values()) {
      if (looseKey(item.after.unitNumber) === k && (a === '' || a === looseKey(item.area))) {
        warn('archived-collision', `Unit ${item.unitId} would become "${item.after.unitNumber}", as archived unit ${unit.id} is numbered`, { unitIds: [item.unitId, unit.id] });
      }
    }
  }

  // Old number -> planned units, for labels and reservations that name a unit by number.
  const byOldKey = new Map();
  for (const item of planned.values()) {
    const k = unitNumberKey(item.before.unitNumber);
    if (!byOldKey.has(k)) byOldKey.set(k, []);
    byOldKey.get(k).push(item);
  }
  const namedUnits = (unitId, unitNumber) => {
    const out = new Set();
    const id = textOf(unitId);
    if (id && planned.has(id)) out.add(planned.get(id));
    for (const item of byOldKey.get(unitNumberKey(unitNumber)) ?? []) out.add(item);
    return [...out];
  };

  // Holds and reservations on renumbered units.
  for (const hold of holds) {
    const unitId = textOf(hold.data?.unitId) ?? hold.id;
    if (!planned.has(unitId)) continue;
    const expires = toDate(hold.data?.expiresAt);
    if (!expires || expires > now) {
      abort('active-hold', `Unit ${unitId} has an active checkout hold (expires ${expires ? expires.toISOString() : 'never'})`, { unitId });
    } else {
      warn('expired-hold', `Unit ${unitId} has an expired hold doc left over`, { unitId });
    }
  }
  for (const r of publicReservations) {
    const d = r.data ?? {};
    if (d.facilityId !== undefined && d.facilityId !== facilityId) continue;
    if (!OPEN_RESERVATION.has(String(d.status ?? ''))) continue;
    for (const item of namedUnits(d.unitId, d.unitNumber)) {
      const expires = toDate(d.expiresAt);
      if (!expires || expires > now) {
        abort('open-public-reservation', `Public reservation ${r.id} (${d.status}) is open on unit ${item.unitId}`, { unitId: item.unitId, reservationId: r.id });
      } else {
        warn('expired-public-reservation', `Public reservation ${r.id} on unit ${item.unitId} is still ${d.status} but expired`, { unitId: item.unitId, reservationId: r.id });
      }
    }
  }
  for (const r of facilityReservations) {
    const d = r.data ?? {};
    if (!OPEN_RESERVATION.has(String(d.status ?? ''))) continue;
    for (const item of namedUnits(d.unitId, d.unitNumber)) {
      abort('open-facility-reservation', `Reservation ${r.id} (${d.status}) is open on unit ${item.unitId}`, { unitId: item.unitId, reservationId: r.id });
    }
  }

  // Tenants.
  const tenantById = new Map(tenants.map((t) => [t.id, t]));
  for (const tenant of tenants) {
    const data = tenant.data ?? {};
    if (!isActiveTenant(tenant)) {
      if (namedUnits(null, data.unitNumber).length) counts.inactiveTenantsWithOldLabel++;
      continue;
    }
    counts.activeTenants++;
    const unitId = textOf(data.unitId);
    const byId = unitId ? planned.get(unitId) : null;
    const byLabel = byOldKey.get(unitNumberKey(data.unitNumber)) ?? [];
    if (!byId && byLabel.length === 0) continue;
    const t = tenant.id;
    if (!byId) {
      if (byLabel.length > 1) {
        abort('tenant-label-ambiguous', `Tenant ${t}'s label "${data.unitNumber}" names ${byLabel.length} renumbered units`, { tenantId: t });
      } else if (!unitId) {
        abort('tenant-missing-unit-id', `Tenant ${t}'s label names unit ${byLabel[0].unitId} but the tenant has no unitId`, { tenantId: t, unitId: byLabel[0].unitId });
      } else {
        abort('tenant-label-names-other-unit', `Tenant ${t}'s label names unit ${byLabel[0].unitId} but its unitId is ${unitId}`, { tenantId: t, unitId: byLabel[0].unitId });
      }
      continue;
    }
    let consistent = true;
    if (byId.expect.tenantId !== t) {
      abort('tenant-unit-not-held', `Tenant ${t}'s unitId is ${byId.unitId}, whose tenantId is ${byId.expect.tenantId ?? 'empty'}`, { tenantId: t, unitId: byId.unitId });
      consistent = false;
    }
    if (unitNumberKey(data.unitNumber) !== unitNumberKey(byId.before.unitNumber)) {
      abort('tenant-label-mismatch', `Tenant ${t}'s label "${data.unitNumber}" is not unit ${byId.unitId}'s number "${byId.before.unitNumber}"`, { tenantId: t, unitId: byId.unitId });
      consistent = false;
    }
    if (areaKey(data.unitArea) !== byId.expect.areaKey) {
      abort('tenant-unit-area-mismatch', `Tenant ${t}'s unitArea "${data.unitArea ?? ''}" is not unit ${byId.unitId}'s area "${byId.area}"`, { tenantId: t, unitId: byId.unitId });
      consistent = false;
    }
    if (!consistent) continue;
    if (data.legacyUnitNumber !== undefined) {
      abort('legacy-already-set', `Tenant ${t} already has legacyUnitNumber`, { tenantId: t });
      continue;
    }
    const snap = snapshotFields(data, ['unitNumber', 'legacyUnitNumber']);
    byId.tenants.push({
      tenantId: t,
      expect: { unitId: byId.unitId, unitAreaKey: byId.expect.areaKey },
      before: snap.values,
      beforeMissing: snap.missing,
      after: { unitNumber: byId.after.unitNumber, legacyUnitNumber: data.unitNumber },
    });
  }
  for (const item of planned.values()) {
    const holder = item.expect.tenantId;
    if (!holder) continue;
    const tenant = tenantById.get(holder);
    if (!tenant || !isActiveTenant(tenant)) {
      warn('stale-unit-holder', `Unit ${item.unitId}'s tenantId ${holder} is ${tenant ? 'not active' : 'missing'}`, { unitId: item.unitId });
    } else if (!item.tenants.some((x) => x.tenantId === holder)) {
      counts.secondaryUnitsRenumbered++;
    }
  }

  // Labels on the map that spell out an old number are not rewritten.
  for (const label of mapLabels) {
    if (matchPrefix(label.label, prefixMap)) {
      warn('map-label-prefixed', `${label.source} label "${label.label}" spells out an old number; edit it and re-publish the map`, { source: label.source });
    }
  }

  const unitItems = [...planned.values()];
  counts.unitsToRenumber = unitItems.length;
  counts.tenantsToRelabel = unitItems.reduce((n, i) => n + i.tenants.length, 0);

  let facilityChange = null;
  if (facility && facility.unitNumbersRepeatAcrossAreas !== true) {
    const snap = snapshotFields(facility, ['unitNumbersRepeatAcrossAreas']);
    facilityChange = {
      before: snap.values,
      beforeMissing: snap.missing,
      after: { unitNumbersRepeatAcrossAreas: true },
    };
  }

  return { ok: aborts.length === 0, aborts, warnings, units: unitItems, facilityChange, counts };
}

/**
 * Why a planned unit item can no longer be applied, or null. [unit] and
 * [tenants] (by id) are the docs' data as read in the transaction; [hold] the
 * unit's hold doc data or null.
 */
export function applyItemRefusal(item, unit, tenants, hold, now = new Date()) {
  if (!unit) return 'unit no longer exists';
  if (unit.archived === true) return 'unit archived since planning';
  if (!fieldsMatch(unit, item.before, item.beforeMissing)) return 'unit number changed since planning';
  if (areaKey(unit.area) !== item.expect.areaKey) return 'unit area changed since planning';
  if (textOf(unit.tenantId) !== item.expect.tenantId) return 'unit tenant changed since planning';
  if (hold) {
    const expires = toDate(hold.expiresAt);
    if (!expires || expires > now) return 'unit has an active checkout hold';
  }
  for (const t of item.tenants) {
    const data = tenants[t.tenantId];
    if (!data) return `tenant ${t.tenantId} no longer exists`;
    if (data.isActive !== true) return `tenant ${t.tenantId} no longer active`;
    if (!fieldsMatch(data, t.before, t.beforeMissing)) return `tenant ${t.tenantId} label changed since planning`;
    if (textOf(data.unitId) !== t.expect.unitId) return `tenant ${t.tenantId} unitId changed since planning`;
    if (areaKey(data.unitArea) !== t.expect.unitAreaKey) return `tenant ${t.tenantId} unitArea changed since planning`;
  }
  return null;
}

/**
 * How to put one recorded doc back: 'restore' (it is in the recorded after
 * state; `set` and `remove` say what to write), 'already-before' (nothing
 * to do) or 'refuse' (it matches neither; someone changed it since).
 */
export function revertDocAction(entry, current) {
  if (current && fieldsMatch(current, entry.after)) {
    const set = {};
    const remove = [];
    for (const [f, v] of Object.entries(entry.before)) {
      if (entry.beforeMissing.includes(f)) remove.push(f);
      else set[f] = v;
    }
    return { action: 'restore', set, remove };
  }
  if (current && fieldsMatch(current, entry.before, entry.beforeMissing)) return { action: 'already-before' };
  return { action: 'refuse' };
}

/**
 * Revert of one unit item. [current] is what the transaction read:
 * `unit` (data or null), `tenants` (recorded tenant id -> data or null) and
 * `holders` ([{ id, data }], tenants linked to the unit now: unit.tenantId or
 * their unitId).
 *
 * The unit: restore / already-before / refuse (revertDocAction). A recorded
 * tenant that is gone, inactive or whose unitId is no longer this unit is
 * `detached` and left alone; otherwise restore / already-before / refuse
 * (except on a `pending` item whose unit is already-before: never written,
 * so a tenant changed since is detached, not refused). When
 * the unit is restored, an ACTIVE holder who was not recorded, is linked to
 * this unit (their unitId is it, or they have none and the unit's tenantId is
 * them) and whose label is the "after" number is `relabel`led to the old
 * number; other holders are left (`holder-other-label`). The item is refused
 * when any doc is `refuse`.
 */
export function planItemRevert(item, current) {
  const unitDoc = { kind: 'unit', id: item.unitId, ...revertDocAction(item, current.unit ?? null) };
  const docs = [unitDoc];
  const recorded = new Set();
  for (const t of item.tenants) {
    recorded.add(t.tenantId);
    const data = current.tenants?.[t.tenantId] ?? null;
    if (!data || data.isActive !== true || textOf(data.unitId) !== item.unitId) {
      docs.push({ kind: 'tenant', id: t.tenantId, action: 'detached' });
      continue;
    }
    const action = revertDocAction(t, data);
    // A pending item whose unit is still as it was was never written (the
    // apply stopped before its transaction): a tenant that has changed since
    // was changed by someone else, so leave it rather than refuse the item.
    if (action.action === 'refuse' && item.status === 'pending' && unitDoc.action === 'already-before') {
      docs.push({ kind: 'tenant', id: t.tenantId, action: 'detached' });
      continue;
    }
    docs.push({ kind: 'tenant', id: t.tenantId, ...action });
  }
  if (unitDoc.action === 'restore') {
    const unitHolder = textOf(current.unit?.tenantId);
    const seen = new Set();
    for (const h of current.holders ?? []) {
      if (recorded.has(h.id) || seen.has(h.id)) continue;
      seen.add(h.id);
      const data = h.data ?? {};
      if (data.isActive !== true) continue;
      const unitId = textOf(data.unitId);
      const linked = unitId ? unitId === item.unitId : unitHolder === h.id;
      if (!linked) continue;
      if (unitNumberKey(data.unitNumber) === unitNumberKey(item.after.unitNumber)) {
        docs.push({ kind: 'tenant', id: h.id, action: 'relabel', set: { unitNumber: item.before.unitNumber }, remove: [] });
      } else {
        docs.push({ kind: 'tenant', id: h.id, action: 'holder-other-label' });
      }
    }
  }
  const refused = docs.filter((d) => d.action === 'refuse');
  return { refused: refused.length > 0, refusedDocs: refused.map((d) => `${d.kind} ${d.id}`), docs };
}

/**
 * [units] ({ id, data } rows) with each unit in [restores] (unitId -> number)
 * given that number, as they will stand once a revert's unit restores land.
 */
export function withRestoredNumbers(units, restores = new Map()) {
  return units.map((u) => (restores.has(u.id) ? { id: u.id, data: { ...u.data, unitNumber: restores.get(u.id) } } : u));
}

/**
 * Unit numbers (trimmed, ignoring case) that more than one live unit uses,
 * as [{ number, unitIds }]. While any exist the facility flag must stay on:
 * the app refuses to turn the setting off then as well.
 */
export function repeatedNumbers(units) {
  const byKey = new Map();
  for (const unit of units) {
    if (!isLive(unit)) continue;
    const k = unitNumberKey(unit.data?.unitNumber);
    if (!k) continue;
    if (!byKey.has(k)) byKey.set(k, { number: String(unit.data?.unitNumber ?? '').trim(), unitIds: [] });
    byKey.get(k).unitIds.push(unit.id);
  }
  return [...byKey.values()].filter((g) => g.unitIds.length > 1);
}

/**
 * The check after --apply, on fresh reads. [items] are the applied unit
 * items. Issues: two live units with the same (area, number) ignoring case
 * and spaces; a renumbered unit whose number a no-area live unit has; an
 * active hold, or an open public or facility reservation, on a renumbered
 * unit (by unitId, or by its old or new number).
 */
export function verifyAfterApply({ facilityId, items, units = [], holds = [], publicReservations = [], facilityReservations = [], now = new Date() }) {
  const issues = [];
  const live = units.filter(isLive);
  const liveById = new Map(live.map((u) => [u.id, u]));
  const groups = new Map();
  for (const u of live) {
    const n = looseKey(u.data?.unitNumber);
    if (!n) continue;
    const key = `${looseKey(u.data?.area)}\u0000${n}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(u.id);
  }
  for (const ids of groups.values()) {
    if (ids.length < 2) continue;
    const u = liveById.get(ids[0]);
    issues.push({
      code: 'duplicate-after-apply',
      message: `${ids.length} live units numbered "${u.data?.unitNumber}" in ${textOf(u.data?.area) ?? '(no area)'}: ${ids.join(', ')}`,
      unitIds: ids,
    });
  }
  const noArea = new Map();
  for (const u of live) {
    const n = looseKey(u.data?.unitNumber);
    if (!textOf(u.data?.area) && n) noArea.set(n, u.id);
  }
  const itemIds = new Set(items.map((i) => i.unitId));
  for (const item of items) {
    const u = liveById.get(item.unitId);
    const other = u && textOf(u.data?.area) ? noArea.get(looseKey(u.data?.unitNumber)) : null;
    if (other) {
      issues.push({
        code: 'no-area-clash-after-apply',
        message: `Unit ${item.unitId} "${u.data?.unitNumber}" has the number of no-area unit ${other}`,
        unitIds: [item.unitId, other],
      });
    }
  }
  const names = (unitId, unitNumber) => {
    const out = new Set();
    const id = textOf(unitId);
    if (id && itemIds.has(id)) out.add(id);
    const k = unitNumberKey(unitNumber);
    if (k) {
      for (const i of items) {
        if (k === unitNumberKey(i.before.unitNumber) || k === unitNumberKey(i.after.unitNumber)) out.add(i.unitId);
      }
    }
    return [...out];
  };
  for (const h of holds) {
    const unitId = textOf(h.data?.unitId) ?? h.id;
    if (!itemIds.has(unitId)) continue;
    const expires = toDate(h.data?.expiresAt);
    if (!expires || expires > now) issues.push({ code: 'active-hold-after-apply', message: `Unit ${unitId} has an active checkout hold`, unitId });
  }
  for (const r of publicReservations) {
    const d = r.data ?? {};
    if (d.facilityId !== undefined && d.facilityId !== facilityId) continue;
    if (!OPEN_RESERVATION.has(String(d.status ?? ''))) continue;
    const expires = toDate(d.expiresAt);
    if (expires && expires <= now) continue;
    for (const unitId of names(d.unitId, d.unitNumber)) {
      issues.push({ code: 'open-public-reservation-after-apply', message: `Public reservation ${r.id} (${d.status}) is open on unit ${unitId}`, unitId, reservationId: r.id });
    }
  }
  for (const r of facilityReservations) {
    const d = r.data ?? {};
    if (!OPEN_RESERVATION.has(String(d.status ?? ''))) continue;
    for (const unitId of names(d.unitId, d.unitNumber)) {
      issues.push({ code: 'open-facility-reservation-after-apply', message: `Reservation ${r.id} (${d.status}) is open on unit ${unitId}`, unitId, reservationId: r.id });
    }
  }
  return issues;
}

/**
 * The --apply sequence over [record] (mutated: statuses, errors, result).
 * The facility flag first, in its own step: if it cannot be set nothing else
 * is written. Then each unit item. [ops]: setFlag(facilityChange),
 * applyItem(item) (throws to refuse), save() after every step.
 * Returns { applied, refused, result }: result 'applied', 'partial' (some
 * item refused) or 'aborted' (flag not set, nothing written).
 */
export async function runApplySteps(record, { setFlag, applyItem, save = () => {}, log = () => {} }) {
  const fc = record.facilityChange;
  if (fc) {
    try {
      await setFlag(fc);
      fc.status = 'applied';
      fc.appliedAt = new Date().toISOString();
    } catch (e) {
      fc.status = 'refused';
      fc.error = String(e?.message ?? e);
      for (const item of record.units) {
        item.status = 'skipped';
        item.error = 'facility flag was not set';
      }
      record.result = 'aborted';
      save();
      log(`  refused facility flag: ${fc.error}; no unit written`);
      return { applied: 0, refused: 0, result: 'aborted' };
    }
    save();
  }
  let applied = 0;
  let refused = 0;
  for (const item of record.units) {
    try {
      await applyItem(item);
      item.status = 'applied';
      item.appliedAt = new Date().toISOString();
      applied++;
    } catch (e) {
      item.status = 'refused';
      item.error = String(e?.message ?? e);
      refused++;
      log(`  refused unit ${item.unitId}: ${item.error}`);
    }
    save();
  }
  record.result = refused ? 'partial' : 'applied';
  save();
  return { applied, refused, result: record.result };
}

/**
 * The --revert sequence over an apply record [rec]. Items the apply refused
 * or skipped are left out; applied and pending ones (pending: a crash
 * between commit and record write) go to revertItem(item), which decides by
 * state and returns { status, docs } or throws to refuse. The facility flag
 * last, via revertFlag(facilityChange, { restores }) (returns a result,
 * throws to refuse), and only when the record says the apply set it and no
 * item was refused. `restores` maps each unit whose revert restores its
 * number (revertItem returned `restoredUnitNumber`) to that number, so a dry
 * run can check the flag against the numbers a real run would leave.
 */
export async function runRevertSteps(rec, { revertItem, revertFlag, save = () => {}, log = () => {} }) {
  const out = { units: [], facility: null, refusedItems: 0 };
  const restores = new Map();
  for (const item of rec.units ?? []) {
    if (item.status !== 'applied' && item.status !== 'pending') {
      out.units.push({ unitId: item.unitId, recordedStatus: item.status, status: 'skipped', reason: `the apply ${item.status ?? 'did not reach'} it` });
      continue;
    }
    const result = { unitId: item.unitId, recordedStatus: item.status };
    try {
      const r = await revertItem(item);
      result.status = r.status;
      result.docs = r.docs;
      if (r.restoredUnitNumber !== undefined) restores.set(item.unitId, r.restoredUnitNumber);
    } catch (e) {
      result.status = 'refused';
      result.error = String(e?.message ?? e);
      if (e?.docs) result.docs = e.docs;
      out.refusedItems++;
    }
    out.units.push(result);
    const summary = (result.docs ?? []).map((d) => `${d.kind} ${d.id}: ${d.action}`).join('; ');
    log(`  unit ${item.unitId}: ${result.status}${result.error ? ` (${result.error})` : ''}${summary ? ` [${summary}]` : ''}`);
    save(out);
  }
  const fc = rec.facilityChange;
  if (!fc) {
    out.facility = { status: 'unchanged', reason: 'the apply did not change the flag' };
  } else if (fc.status !== 'applied') {
    out.facility = { status: 'kept', reason: `the record says the flag change was ${fc.status ?? 'not run'}; check it by hand` };
  } else if (out.refusedItems > 0) {
    out.facility = { status: 'kept', reason: 'some unit items were refused; numbers may still repeat' };
  } else {
    try {
      out.facility = await revertFlag(fc, { restores });
    } catch (e) {
      out.facility = { status: 'refused', error: String(e?.message ?? e) };
    }
  }
  log(`  facility flag: ${JSON.stringify(out.facility)}`);
  save(out);
  return out;
}

/** Parses argv; throws on anything it does not know. */
export function parseArgs(argv) {
  const out = {
    apply: false,
    facility: null,
    prefixMap: null,
    revert: null,
    project: null,
    outDir: null,
    json: false,
    allowNearRentRun: false,
    adminFrom: null,
    confirmAppSupportsRepeats: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = () => {
      const v = argv[++i];
      if (v === undefined || v.startsWith('--')) throw new Error(`${arg} needs a value`);
      return v;
    };
    if (arg === '--apply') out.apply = true;
    else if (arg === '--facility') {
      if (out.facility) throw new Error('One --facility per run');
      out.facility = value();
    } else if (arg === '--prefix-map') out.prefixMap = parsePrefixMap(value());
    else if (arg === '--revert') out.revert = value();
    else if (arg === '--project') out.project = value();
    else if (arg === '--out') out.outDir = value();
    else if (arg === '--json') out.json = true;
    else if (arg === '--allow-near-rent-run') out.allowNearRentRun = true;
    else if (arg === '--admin-from') out.adminFrom = value();
    else if (arg === '--confirm-app-supports-repeats') out.confirmAppSupportsRepeats = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (out.revert) {
    if (out.prefixMap) throw new Error('--revert takes its prefix map from the record; drop --prefix-map');
  } else {
    if (!out.facility) throw new Error('Pass --facility <id>.');
    if (!out.prefixMap) throw new Error('Pass --prefix-map "C2-=Complex 2,...".');
    if (out.apply && !out.confirmAppSupportsRepeats) {
      throw new Error(`${APP_SUPPORT_NOTE} Confirm it by passing --confirm-app-supports-repeats with --apply.`);
    }
  }
  return out;
}

/** Writes [record] to [file] via a temp file and rename, so a crash leaves the last good copy. */
function writeRecord(file, record) {
  const tmp = `${file}.tmp`;
  writeFileSync(tmp, `${JSON.stringify(record, null, 2)}\n`);
  renameSync(tmp, file);
}

function loadAdmin(args, projectId) {
  const from = path.resolve(args.adminFrom || path.join(repoRoot, 'functions-tenant-lifecycle'));
  const require = createRequire(path.join(from, 'package.json'));
  const { initializeApp, applicationDefault } = require('firebase-admin/app');
  const { getFirestore, FieldValue } = require('firebase-admin/firestore');
  initializeApp({ credential: applicationDefault(), projectId });
  return { db: getFirestore(), FieldValue };
}

async function readFacility(db, facilityId) {
  const facilityRef = db.collection('facilities').doc(facilityId);
  const rows = (snap) => snap.docs.map((d) => ({ id: d.id, data: d.data() }));
  const [facilitySnap, unitSnap, tenantSnap, holdSnap, publicResSnap, resSnap, settingsSnap, shapeSnap, metaSnap] =
    await Promise.all([
      facilityRef.get(),
      facilityRef.collection('units').get(),
      facilityRef.collection('tenants').get(),
      facilityRef.collection('mapEngine').doc('activeHolds').collection('items').get(),
      db.collection('publicReservations').where('facilityId', '==', facilityId).get(),
      facilityRef.collection('reservations').get(),
      facilityRef.collection('settings').doc('public').get(),
      facilityRef.collection('mapShapes').get(),
      facilityRef.collection('mapEngine').doc('meta').get(),
    ]);
  const mapLabels = [];
  for (const d of shapeSnap.docs) {
    const label = d.data()?.metadata?.label;
    if (typeof label === 'string' && label.trim()) mapLabels.push({ source: `mapShapes/${d.id}`, label });
  }
  let publicMap = { slug: null, exists: false, units: 0 };
  const slug = String(metaSnap.data()?.publicSlug ?? '').trim();
  if (slug) {
    const pub = await db.collection('publicFacilityMaps').doc(slug).get();
    publicMap = { slug, exists: pub.exists, units: Array.isArray(pub.data()?.units) ? pub.data().units.length : 0 };
    for (const el of pub.data()?.elements ?? []) {
      if (typeof el?.label === 'string' && el.label.trim()) mapLabels.push({ source: `publicFacilityMaps element ${el.id ?? '?'}`, label: el.label });
    }
  }
  return {
    facilityRef,
    publicMap,
    input: {
      facilityId,
      facility: facilitySnap.exists ? facilitySnap.data() : null,
      units: rows(unitSnap),
      tenants: rows(tenantSnap),
      holds: rows(holdSnap),
      publicReservations: rows(publicResSnap),
      facilityReservations: rows(resSnap),
      publicSettings: settingsSnap.exists ? settingsSnap.data() : null,
      mapLabels,
    },
  };
}

function printPlan(plan, publicMap) {
  console.log(`  counts: ${JSON.stringify(plan.counts)}`);
  if (plan.facilityChange) {
    console.log(`  facility unitNumbersRepeatAcrossAreas: ${JSON.stringify(plan.facilityChange.before.unitNumbersRepeatAcrossAreas)} -> true`);
  } else {
    console.log('  facility unitNumbersRepeatAcrossAreas: already true');
  }
  for (const a of plan.aborts) console.log(`  ABORT [${a.code}] ${a.message}`);
  for (const w of plan.warnings) console.log(`  warn  [${w.code}] ${w.message}`);
  for (const item of plan.units) {
    console.log(`  unit ${item.unitId} [${item.area}] "${item.before.unitNumber}" -> "${item.after.unitNumber}"`);
    for (const t of item.tenants) {
      console.log(`    tenant ${t.tenantId} "${t.before.unitNumber}" -> "${t.after.unitNumber}"`);
    }
  }
  if (publicMap.slug) {
    console.log(`  public map ${publicMap.slug}: ${publicMap.exists ? `${publicMap.units} units listed; the unit-write trigger refreshes their numbers` : 'doc missing'}`);
  }
}

/** Units, holds and reservations of the facility as rows, for the check after --apply. */
async function readForVerify(db, facilityRef, facilityId) {
  const rows = (snap) => snap.docs.map((d) => ({ id: d.id, data: d.data() }));
  const [unitSnap, holdSnap, publicResSnap, resSnap] = await Promise.all([
    facilityRef.collection('units').get(),
    facilityRef.collection('mapEngine').doc('activeHolds').collection('items').get(),
    db.collection('publicReservations').where('facilityId', '==', facilityId).get(),
    facilityRef.collection('reservations').get(),
  ]);
  return {
    units: rows(unitSnap),
    holds: rows(holdSnap),
    publicReservations: rows(publicResSnap),
    facilityReservations: rows(resSnap),
  };
}

async function runPlanOrApply(args, projectId) {
  const { db } = loadAdmin(args, projectId);
  const facilityId = args.facility;
  const now = new Date();
  const outDir = path.resolve(args.outDir || defaultOutDir());
  if (args.apply && !args.outDir) {
    console.log('='.repeat(78));
    console.log('NOTE: no --out given. The revert record will be written inside this checkout:');
    console.log(`  ${outDir}`);
    console.log('The record is the ONLY source for --revert. Prefer --out <dir> outside the');
    console.log('checkout/worktree (a cleaned-up worktree takes the record with it).');
    console.log('='.repeat(78));
  }
  const { facilityRef, publicMap, input } = await readFacility(db, facilityId);
  const plan = planRenumber({ ...input, prefixMap: args.prefixMap, now, allowNearRentRun: args.allowNearRentRun });
  // Not an abort: the operator confirms it (--confirm-app-supports-repeats is required with --apply).
  plan.warnings.push({ code: 'app-must-support-repeats', message: APP_SUPPORT_NOTE });

  mkdirSync(outDir, { recursive: true });
  const stamp = now.toISOString().replace(/[:.]/g, '-');
  const mode = args.apply ? 'apply' : 'dry-run';
  const file = path.join(outDir, `renumber-units-${facilityId}-${mode}-${stamp}.json`);
  const record = {
    kind: 'renumber-units-by-area',
    mode,
    projectId,
    facilityId,
    prefixMap: args.prefixMap,
    plannedAt: now.toISOString(),
    confirmedAppSupportsRepeats: args.confirmAppSupportsRepeats,
    ok: plan.ok,
    counts: plan.counts,
    aborts: plan.aborts,
    warnings: plan.warnings,
    publicMap,
    units: plan.units.map((i) => ({ ...i, status: args.apply ? 'pending' : 'dry-run' })),
    facilityChange: plan.facilityChange ? { ...plan.facilityChange, status: args.apply ? 'pending' : 'dry-run' } : null,
  };

  console.log(`${args.apply ? 'APPLY' : 'DRY RUN'}: renumber units by area, project ${projectId}, facility ${facilityId}`);
  printPlan(plan, publicMap);

  if (!plan.ok) {
    record.result = 'aborted';
    writeRecord(file, record);
    console.log(`  ABORTED: ${plan.aborts.length} pre-check failure(s); nothing written`);
    console.log(`  record: ${file}`);
    process.exitCode = 2;
    return;
  }
  if (!args.apply) {
    record.result = 'dry-run';
    writeRecord(file, record);
    console.log('  pre-checks passed (dry run; --apply also needs --confirm-app-supports-repeats)');
    console.log(`  record: ${file}`);
    return;
  }

  // Write-ahead: the whole before/after plan is on disk before the first write.
  record.result = 'in-progress';
  writeRecord(file, record);
  console.log(`  record (write-ahead): ${file}`);

  const { applied, refused, result } = await runApplySteps(record, {
    save: () => writeRecord(file, record),
    log: (line) => console.log(line),
    // First: harmless while the numbers are still prefixed, and a crash later
    // never leaves plain repeated numbers with the flag off.
    setFlag: (fc) =>
      db.runTransaction(async (txn) => {
        const f = await txn.get(facilityRef);
        if (!f.exists) throw new Error('facility no longer exists');
        if (!fieldsMatch(f.data(), fc.before, fc.beforeMissing)) throw new Error('flag changed since planning');
        txn.update(facilityRef, fc.after);
      }),
    applyItem: (item) => {
      const unitRef = facilityRef.collection('units').doc(item.unitId);
      const holdRef = facilityRef.collection('mapEngine').doc('activeHolds').collection('items').doc(item.unitId);
      const tenantRefs = item.tenants.map((t) => facilityRef.collection('tenants').doc(t.tenantId));
      return db.runTransaction(async (txn) => {
        const [u, h, ...ts] = await Promise.all([txn.get(unitRef), txn.get(holdRef), ...tenantRefs.map((r) => txn.get(r))]);
        const tenantData = Object.fromEntries(item.tenants.map((t, i) => [t.tenantId, ts[i].exists ? ts[i].data() : null]));
        const why = applyItemRefusal(item, u.exists ? u.data() : null, tenantData, h.exists ? h.data() : null, new Date());
        if (why) throw new Error(why);
        txn.update(unitRef, item.after);
        item.tenants.forEach((t, i) => txn.update(tenantRefs[i], t.after));
      });
    },
  });

  if (result !== 'aborted') {
    const fresh = await readForVerify(db, facilityRef, facilityId);
    const issues = verifyAfterApply({
      facilityId,
      items: record.units.filter((i) => i.status === 'applied'),
      ...fresh,
      now: new Date(),
    });
    record.postApplyIssues = issues;
    for (const issue of issues) console.log(`  CHECK [${issue.code}] ${issue.message}`);
    if (issues.length) {
      record.result = `${record.result}-needs-attention`;
      console.log(`  ${issues.length} issue(s) after the run: look at them before anything else (revert with --revert ${file})`);
    } else {
      console.log('  check after the run: no duplicates, no-area clashes, holds or open reservations');
    }
  }
  record.finishedAt = new Date().toISOString();
  record.counts = { ...record.counts, applied, refused };
  writeRecord(file, record);
  const fc = record.facilityChange;
  console.log(`  result ${record.result}: applied ${applied}, refused ${refused}, facility flag ${fc ? fc.status : 'already on'}`);
  console.log(`  record: ${file}`);
  if (record.result !== 'applied') process.exitCode = 2;
}

async function runRevert(args, projectId) {
  const source = path.resolve(args.revert);
  const rec = JSON.parse(readFileSync(source, 'utf8'));
  if (rec.kind !== 'renumber-units-by-area' || rec.mode !== 'apply') {
    throw new Error(`${source} is not an --apply record of renumber-units-by-area`);
  }
  if (args.facility && args.facility !== rec.facilityId) throw new Error(`Record is for facility ${rec.facilityId}`);
  if (rec.projectId && rec.projectId !== projectId) throw new Error(`Record is for project ${rec.projectId}`);
  const now = new Date();
  if (isNearRentRun(now) && !args.allowNearRentRun) {
    throw new Error(`Within ${RENT_RUN_WINDOW_HOURS} hours of the monthly rent run; run later`);
  }
  const { db, FieldValue } = loadAdmin(args, projectId);
  const facilityRef = db.collection('facilities').doc(rec.facilityId);
  const tenantsCol = facilityRef.collection('tenants');

  const outDir = path.resolve(args.outDir || defaultOutDir());
  mkdirSync(outDir, { recursive: true });
  const stamp = now.toISOString().replace(/[:.]/g, '-');
  const file = path.join(outDir, `renumber-units-${rec.facilityId}-revert-${args.apply ? 'apply' : 'dry-run'}-${stamp}.json`);
  const meta = { kind: 'renumber-units-by-area-revert', mode: args.apply ? 'apply' : 'dry-run', source, projectId, facilityId: rec.facilityId, startedAt: now.toISOString() };
  console.log(`${args.apply ? 'APPLY' : 'DRY RUN'}: revert ${source}`);

  const fieldsFor = (d) => {
    const fields = { ...d.set };
    for (const f of d.remove) fields[f] = FieldValue.delete();
    return fields;
  };

  const out = await runRevertSteps(rec, {
    log: (line) => console.log(line),
    save: (partial) => {
      if (args.apply) writeRecord(file, { ...meta, ...partial });
    },
    revertItem: (item) => {
      const unitRef = facilityRef.collection('units').doc(item.unitId);
      return db.runTransaction(async (txn) => {
        const u = await txn.get(unitRef);
        const unit = u.exists ? u.data() : null;
        const tenants = {};
        for (const t of item.tenants) {
          const s = await txn.get(tenantsCol.doc(t.tenantId));
          tenants[t.tenantId] = s.exists ? s.data() : null;
        }
        // Whoever holds the unit now: by their unitId, and the unit's tenantId.
        const holders = (await txn.get(tenantsCol.where('unitId', '==', item.unitId))).docs.map((d) => ({ id: d.id, data: d.data() }));
        const holderId = textOf(unit?.tenantId);
        if (holderId && !holders.some((h) => h.id === holderId)) {
          const s = await txn.get(tenantsCol.doc(holderId));
          if (s.exists) holders.push({ id: s.id, data: s.data() });
        }
        const plan = planItemRevert(item, { unit, tenants, holders });
        const docs = plan.docs.map((d) => ({ kind: d.kind, id: d.id, action: d.action }));
        if (plan.refused) {
          const err = new Error(`changed since the run: ${plan.refusedDocs.join(', ')}`);
          err.docs = docs;
          throw err;
        }
        if (args.apply) {
          for (const d of plan.docs) {
            if (d.action !== 'restore' && d.action !== 'relabel') continue;
            txn.update(d.kind === 'unit' ? unitRef : tenantsCol.doc(d.id), fieldsFor(d));
          }
        }
        const unitRestore = plan.docs.find((d) => d.kind === 'unit' && d.action === 'restore');
        return {
          status: args.apply ? 'reverted' : 'would-revert',
          docs,
          ...(unitRestore ? { restoredUnitNumber: item.before.unitNumber } : {}),
        };
      });
    },
    revertFlag: (fc, { restores }) =>
      db.runTransaction(async (txn) => {
        const f = await txn.get(facilityRef);
        const d = revertDocAction(fc, f.exists ? f.data() : null);
        if (d.action === 'refuse') throw new Error('facility flag changed since the run');
        if (d.action === 'already-before') return { action: d.action, status: 'already-before' };
        // Off again only when no number is used twice; the app refuses the same.
        // Checked as the units stand once the unit restores are in: after them
        // in a real run (a no-op there), and as a dry run predicts them.
        const units = (await txn.get(facilityRef.collection('units'))).docs.map((x) => ({ id: x.id, data: x.data() }));
        const repeated = repeatedNumbers(withRestoredNumbers(units, restores));
        if (repeated.length) {
          throw new Error(`numbers still used by more than one live unit: ${repeated.map((g) => `"${g.number}" (${g.unitIds.length})`).join(', ')}`);
        }
        if (args.apply) txn.update(facilityRef, fieldsFor(d));
        return { action: d.action, status: args.apply ? 'restored' : 'would-restore' };
      }),
  });

  writeRecord(file, { ...meta, ...out, finishedAt: new Date().toISOString() });
  console.log(`  record: ${file}`);
  if (out.refusedItems || out.facility?.status === 'refused') process.exitCode = 2;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const projectId = args.project || process.env.GOOGLE_CLOUD_PROJECT || 'storage-facility-creator';
  if (args.revert) await runRevert(args, projectId);
  else await runPlanOrApply(args, projectId);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch((e) => {
    console.error(e?.message ?? e);
    process.exit(1);
  });
}

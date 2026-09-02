import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';

/** Fields that affect the anonymous public rental inventory payload. */
const INVENTORY_KEYS = [
  'status',
  'tenantId',
  'tenantName',
  'unitNumber',
  'unitType',
  'monthlyRate',
  'description',
  'dimensions',
  'archived',
  'isActive',
  'publicListingEnabled',
];

function slugify(raw: string): string {
  const lowered = raw.toLowerCase().trim();
  const cleaned = lowered.replace(/[^a-z0-9]+/gi, '-');
  const normalized = cleaned.replace(/-{2,}/g, '-').replace(/^-|-$/g, '');
  return normalized.length === 0 ? 'facility-map' : normalized;
}

function statusToPublicStatus(status: string): string {
  const s = String(status || '').toLowerCase();
  if (s === 'available') return 'available';
  if (s === 'reserved') return 'reserved';
  if (s === 'occupied') return 'rented';
  return 'unavailable';
}

/**
 * Rebuilds only `publicFacilityMaps.{slug}.units` from live unit docs so online
 * rentals match dashboard occupancy (including Cloud Function move-ins).
 */
const INVENTORY_PAGE_SIZE = 1000;

/**
 * The published unit list lives inside one Firestore document, and a document is capped at 1 MiB.
 * Stop well short of it: the array is not the only field, and a write that overshoots fails
 * outright, which would leave the public map frozen at whatever it last held.
 */
const MAX_PUBLISHED_UNITS_BYTES = 700_000;

/**
 * Every document in a collection, in pages.
 *
 * This replaced `.limit(500)` on tenants and `.limit(400)` on units. Neither had an `orderBy`, so
 * Firestore fell back to document-id order and the caps took an arbitrary slice rather than a
 * meaningful one. On units that quietly hid real units from the public map. On tenants it was
 * worse: `tenantClaimed` is what marks a unit as taken, so a tenant past the cap left their unit
 * advertised as available, and a stranger could try to rent a unit somebody already lives in.
 */
/**
 * Trim a sorted unit list until it fits in one document, from the end, and say how much went.
 *
 * Exported for tests. Pure on purpose: the loop below is the only part of the truncation that can
 * be got subtly wrong -- overshoot and the write fails, undershoot and it never terminates -- and
 * it should not need a Firestore to check.
 */
export function fitUnitsToDocument(
  units: Record<string, any>[],
  maxBytes: number = MAX_PUBLISHED_UNITS_BYTES,
): { published: Record<string, any>[]; omitted: number } {
  const bytes = (u: Record<string, any>[]) => Buffer.byteLength(JSON.stringify(u), 'utf8');
  if (bytes(units) <= maxBytes) return { published: units, omitted: 0 };

  let published = units;
  // Shrinking by a tenth converges in a handful of steps and, because Math.floor of a length
  // above 1 is always smaller, cannot stall.
  while (published.length > 1 && bytes(published) > maxBytes) {
    published = published.slice(0, Math.floor(published.length * 0.9));
  }
  return { published, omitted: units.length - published.length };
}

export async function readEveryDoc(
  col: admin.firestore.CollectionReference,
): Promise<admin.firestore.QueryDocumentSnapshot[]> {
  const out: admin.firestore.QueryDocumentSnapshot[] = [];
  let cursor: admin.firestore.QueryDocumentSnapshot | undefined;
  for (;;) {
    let q = col.orderBy(admin.firestore.FieldPath.documentId()).limit(INVENTORY_PAGE_SIZE);
    if (cursor) q = q.startAfter(cursor);
    const page = await q.get();
    out.push(...page.docs);
    if (page.size < INVENTORY_PAGE_SIZE) break;
    cursor = page.docs[page.docs.length - 1];
  }
  return out;
}

export async function syncPublicFacilityMapInventoryForFacility(facilityId: string): Promise<void> {
  const db = admin.firestore();
  const metaSnap = await db.doc(`facilities/${facilityId}/mapEngine/meta`).get();
  const publicSlug = String(metaSnap.data()?.publicSlug || '').trim();
  if (!publicSlug) return;

  const publicRef = db.collection('publicFacilityMaps').doc(publicSlug);
  const publicSnap = await publicRef.get();
  if (!publicSnap.exists) return;

  const settingsSnap = await db.doc(`facilities/${facilityId}/settings/public`).get();
  const settings = (settingsSnap.data() || {}) as Record<string, any>;
  const showPublicPricing = settings.publicPricingEnabled !== false;
  const showUnitNumbers = settings.publicUnitNumbersEnabled !== false;
  const enabledRaw = settings.enabledPublicUnitTypes;
  const enabledTypes: string[] = Array.isArray(enabledRaw)
    ? enabledRaw.map((e: any) => String(e).trim()).filter((e: string) => e.length > 0)
    : [];

  // Every tenant, not a sample: one missing tenant is one unit advertised as free that is not.
  const tenantDocs = await readEveryDoc(db.collection(`facilities/${facilityId}/tenants`));
  const tenantClaimed = new Set<string>();
  for (const tdoc of tenantDocs) {
    const td = tdoc.data();
    if (td.isActive === false) continue;
    const n = String(td.unitNumber || '').trim().toLowerCase();
    if (n.length > 0) tenantClaimed.add(n);
  }

  const unitDocs = await readEveryDoc(db.collection(`facilities/${facilityId}/units`));
  const units: Record<string, any>[] = [];

  for (const doc of unitDocs) {
    const d = doc.data();
    if (d.archived === true) continue;

    const unitType = String(d.unitType || '');
    const categorySlug = slugify(unitType);
    const isPubliclyEnabledType =
      enabledTypes.length === 0 || enabledTypes.includes(unitType);
    const st = String(d.status || '').toLowerCase();
    const unitNumNorm = String(d.unitNumber || '').trim().toLowerCase();
    const hasTenantLink =
      typeof d.tenantId === 'string' && String(d.tenantId).trim() !== '';
    const claimedByActiveTenant = tenantClaimed.has(unitNumNorm);
    const statusAllowsRental = st === 'available' || st === 'reserved';
    const publicListingEnabled = d.publicListingEnabled !== false;
    const isRentable =
      statusAllowsRental &&
      !hasTenantLink &&
      !claimedByActiveTenant &&
      isPubliclyEnabledType &&
      publicListingEnabled;
    const publicStatus = !publicListingEnabled
      ? 'unavailable'
      : hasTenantLink || claimedByActiveTenant
      ? 'rented'
      : statusToPublicStatus(st);

    const dims = (d.dimensions || {}) as Record<string, any>;
    const width = Number(dims.width);
    const depth = Number(dims.depth);
    let size: string | null = null;
    if (Number.isFinite(width) && Number.isFinite(depth)) {
      size = `${Math.round(width)}x${Math.round(depth)}`;
    }

    const unum = d.unitNumber;
    units.push({
      unitId: doc.id,
      unitNumber: showUnitNumbers ? unum : null,
      unitLabel: showUnitNumbers ? unum : null,
      displayName: showUnitNumbers ? `Unit ${unum}` : 'Available Unit',
      status: publicStatus,
      internalStatus: d.status ?? null,
      unitType,
      categorySlug,
      size,
      description: d.description ?? null,
      monthlyRate: showPublicPricing ? d.monthlyRate : null,
      isRentable,
      publicListingEnabled,
    });
  }

  units.sort((a, b) =>
    String(a.unitNumber ?? '').localeCompare(String(b.unitNumber ?? ''), undefined, {
      numeric: true,
      sensitivity: 'base',
    }),
  );

  // If the list genuinely will not fit in a document, drop from the end of the *sorted* list and
  // say so in the document, rather than silently publishing an arbitrary subset the way the old
  // caps did. Deterministic, visible, and complained about in the logs.
  const { published, omitted } = fitUnitsToDocument(units);
  if (omitted > 0) {
    functions.logger.error('publicFacilityMap unit list does not fit in one document', {
      facilityId,
      publicSlug,
      unitsTotal: units.length,
      unitsPublished: published.length,
      unitsOmitted: omitted,
    });
  }

  await publicRef.update({
    units: published,
    unitsTotal: units.length,
    unitsOmitted: omitted,
    inventorySyncedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
}

export const syncPublicFacilityMapInventoryOnUnitWrite = functions.firestore
  .document('facilities/{facilityId}/units/{unitId}')
  .onWrite(async (change, context) => {
    const facilityId = context.params.facilityId as string;
    const before = change.before.exists ? change.before.data() || {} : {};
    const after = change.after.exists ? change.after.data() || {} : {};

    const created = !change.before.exists;
    const deleted = !change.after.exists;
    let relevant = created || deleted;
    if (!relevant) {
      for (const k of INVENTORY_KEYS) {
        if (JSON.stringify((before as any)[k]) !== JSON.stringify((after as any)[k])) {
          relevant = true;
          break;
        }
      }
    }
    if (!relevant) return;

    try {
      await syncPublicFacilityMapInventoryForFacility(facilityId);
    } catch (err: any) {
      functions.logger.warn('syncPublicFacilityMapInventoryOnUnitWrite failed', {
        facilityId,
        error: err?.message || String(err),
      });
    }
  });

const TENANT_INVENTORY_KEYS = ['isActive', 'unitNumber'];

/** When staff creates/moves tenants without updating the unit doc, refresh public inventory. */
export const syncPublicFacilityMapInventoryOnTenantWrite = functions.firestore
  .document('facilities/{facilityId}/tenants/{tenantId}')
  .onWrite(async (change, context) => {
    const facilityId = context.params.facilityId as string;
    const before = change.before.exists ? change.before.data() || {} : {};
    const after = change.after.exists ? change.after.data() || {} : {};

    const created = !change.before.exists;
    const deleted = !change.after.exists;
    let relevant = created || deleted;
    if (!relevant) {
      for (const k of TENANT_INVENTORY_KEYS) {
        if (JSON.stringify((before as any)[k]) !== JSON.stringify((after as any)[k])) {
          relevant = true;
          break;
        }
      }
    }
    if (!relevant) return;

    try {
      await syncPublicFacilityMapInventoryForFacility(facilityId);
    } catch (err: any) {
      functions.logger.warn('syncPublicFacilityMapInventoryOnTenantWrite failed', {
        facilityId,
        error: err?.message || String(err),
      });
    }
  });

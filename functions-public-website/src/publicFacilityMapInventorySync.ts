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

  const tenantsSnap = await db.collection(`facilities/${facilityId}/tenants`).limit(500).get();
  const tenantClaimed = new Set<string>();
  for (const tdoc of tenantsSnap.docs) {
    const td = tdoc.data();
    if (td.isActive === false) continue;
    const n = String(td.unitNumber || '').trim().toLowerCase();
    if (n.length > 0) tenantClaimed.add(n);
  }

  const unitsSnap = await db.collection(`facilities/${facilityId}/units`).limit(400).get();
  const units: Record<string, any>[] = [];

  for (const doc of unitsSnap.docs) {
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

  await publicRef.update({
    units,
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

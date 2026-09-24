import type * as admin from 'firebase-admin';

/**
 * Old public map slugs, kept working after a slug change.
 *
 * `publicFacilityMaps` is keyed by the storefront's URL slug and world
 * readable. Changing the slug (FacilityMapV2Service.setPublicSlug in the app)
 * used to leave the old doc behind with its full unit list, and nothing synced
 * it again: old links kept serving a frozen list. The old doc now becomes a
 * pointer, `{ facilityId, movedToSlug, movedAt }` with no units or settings,
 * and readers follow it one hop, and only to a doc of the same facility. The
 * update rule pins `facilityId`, so a pointer keeps the old slug reserved to
 * its facility, and the same-facility check stops a pointer from serving
 * another facility's storefront. Keep in step with
 * FacilityMapV2Service.movedToSlugOf and resolvePublicMap in the app.
 */

export const PUBLIC_FACILITY_MAPS = 'publicFacilityMaps';

type DocData = Record<string, unknown>;

/** The slug a publicFacilityMaps doc forwards to, or null when it is a published map. */
export function movedToSlugOf(data: DocData | null | undefined): string | null {
  const raw = data?.movedToSlug;
  if (typeof raw !== 'string') return null;
  const slug = raw.trim();
  return slug.length > 0 ? slug : null;
}

/** The pointer an old slug's doc is overwritten with, pointing at [movedToSlug]. */
export function publicMapPointer(facilityId: string, movedToSlug: string, movedAt: unknown): DocData {
  return { facilityId, movedToSlug, movedAt };
}

export interface PublicFacilityMap {
  /** The slug the map was found at: the one asked for, or the one its pointer named. */
  slug: string;
  data: DocData;
}

/**
 * The published map at [slug], following a pointer one hop: the doc it names
 * is served only when it has the pointer's facilityId and is not a pointer
 * itself. Null when there is nothing to serve.
 */
export async function readPublicFacilityMap(
  db: admin.firestore.Firestore,
  slug: string,
): Promise<PublicFacilityMap | null> {
  if (!slug) return null;
  const maps = db.collection(PUBLIC_FACILITY_MAPS);
  const snap = await maps.doc(slug).get();
  if (!snap.exists) return null;
  const data = (snap.data() || {}) as DocData;
  const movedTo = movedToSlugOf(data);
  if (movedTo === null) return { slug, data };

  const facilityId = typeof data.facilityId === 'string' ? data.facilityId : '';
  if (!facilityId || movedTo === slug) return null;
  const target = await maps.doc(movedTo).get();
  if (!target.exists) return null;
  const targetData = (target.data() || {}) as DocData;
  if (targetData.facilityId !== facilityId || movedToSlugOf(targetData) !== null) return null;
  return { slug: movedTo, data: targetData };
}

export interface SlugPointerChange {
  /** The doc to overwrite with a pointer. */
  slug: string;
  /** What it holds now: a published map, or a pointer to somewhere else. */
  was: 'map' | 'pointer';
  /** Units in its list, which the pointer drops (0 for a pointer). */
  unitCount: number;
  /** Where it points now, for a pointer. */
  movedToSlug: string | null;
}

export type SlugPointerPlan =
  | { facilityId: string; currentSlug: string; changes: SlugPointerChange[] }
  | { facilityId: string; currentSlug: string | null; skipped: string };

/**
 * For the one-time migration (scripts/migrate_public_slug_pointers.cjs): which
 * of [facilityId]'s docs, [docs], to turn into pointers at [currentSlug], its
 * mapEngine/meta.publicSlug. Every doc of the facility but the current one,
 * unless it already points there. Nothing changes when the current slug has no
 * published map of the facility's own to point at: pointers there would break
 * the old links rather than keep them.
 */
export function planPublicSlugPointers(
  facilityId: string,
  currentSlug: string | null,
  docs: Array<{ id: string; data: DocData }>,
): SlugPointerPlan {
  const mine = docs.filter((d) => d.data.facilityId === facilityId);
  const slug = (currentSlug || '').trim();
  if (!slug) {
    return { facilityId, currentSlug: null, skipped: 'no mapEngine/meta.publicSlug' };
  }
  const current = mine.find((d) => d.id === slug);
  if (!current) {
    return { facilityId, currentSlug: slug, skipped: `no publicFacilityMaps/${slug} of this facility` };
  }
  if (movedToSlugOf(current.data) !== null) {
    return { facilityId, currentSlug: slug, skipped: `publicFacilityMaps/${slug} is itself a pointer` };
  }
  const changes: SlugPointerChange[] = [];
  for (const doc of mine) {
    if (doc.id === slug) continue;
    const movedTo = movedToSlugOf(doc.data);
    if (movedTo === slug) continue;
    changes.push({
      slug: doc.id,
      was: movedTo === null ? 'map' : 'pointer',
      unitCount: Array.isArray(doc.data.units) ? doc.data.units.length : 0,
      movedToSlug: movedTo,
    });
  }
  changes.sort((a, b) => a.slug.localeCompare(b.slug));
  return { facilityId, currentSlug: slug, changes };
}

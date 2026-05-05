import * as admin from 'firebase-admin';

/**
 * Idempotent migration for public website template v4 optional fields.
 *
 * This migration is intentionally additive and conservative:
 * - It does NOT remove or rename existing keys.
 * - It does NOT force new optional keys into every document.
 * - It only normalizes malformed `widgets` / `websiteConfig` containers so
 *   future optional fields can be stored safely without runtime type errors.
 */
export async function migratePublicWebsiteV4OptionalFields(): Promise<{
  scanned: number;
  updated: number;
  errors: string[];
}> {
  const errors: string[] = [];
  let scanned = 0;
  let updated = 0;

  const facilitiesSnap = await admin.firestore().collection('facilities').get();
  for (const facilityDoc of facilitiesSnap.docs) {
    scanned += 1;
    try {
      const settingsRef = facilityDoc.ref.collection('settings').doc('public');
      const settingsSnap = await settingsRef.get();
      if (!settingsSnap.exists) {
        continue;
      }

      const data = settingsSnap.data() || {};
      const widgetsRaw = data.widgets;
      const widgets =
        widgetsRaw && typeof widgetsRaw === 'object' && !Array.isArray(widgetsRaw)
          ? { ...(widgetsRaw as Record<string, unknown>) }
          : {};

      const websiteConfigRaw = widgets.websiteConfig;
      const websiteConfig =
        websiteConfigRaw &&
        typeof websiteConfigRaw === 'object' &&
        !Array.isArray(websiteConfigRaw)
          ? { ...(websiteConfigRaw as Record<string, unknown>) }
          : {};

      const needsUpdate =
        widgetsRaw !== widgets || websiteConfigRaw !== websiteConfig;
      if (!needsUpdate) {
        continue;
      }

      await settingsRef.set(
        {
          widgets: {
            ...widgets,
            websiteConfig,
          },
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      updated += 1;
    } catch (error: any) {
      errors.push(
        `facility ${facilityDoc.id}: ${String(error?.message || error)}`,
      );
    }
  }

  return { scanned, updated, errors };
}

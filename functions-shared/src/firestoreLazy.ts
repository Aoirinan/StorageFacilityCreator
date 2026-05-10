import * as admin from 'firebase-admin';

let cache: ReturnType<typeof admin.firestore> | null = null;

/**
 * Lazy Firestore singleton. Avoids `admin.firestore()` at module load time — in
 * CommonJS, dependent modules can load before `ensureFirebaseAdminApp()` runs
 * in a codebase `index.ts`, which can hang Firebase CLI deploy analysis.
 */
export function getFirestore(): ReturnType<typeof admin.firestore> {
  if (cache) {
    return cache;
  }
  if (admin.apps.length === 0) {
    admin.initializeApp();
  }
  cache = admin.firestore();
  return cache;
}

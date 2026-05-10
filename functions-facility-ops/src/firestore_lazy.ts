import * as admin from 'firebase-admin';

let cache: ReturnType<typeof admin.firestore> | null = null;

/**
 * Lazy Firestore client. Top-level `admin.firestore()` in sibling modules runs
 * before `ensureFirebaseAdminApp()` in `index.ts` (CommonJS `require` order),
 * which can hang or slow Firebase CLI’s deploy-time code probe (10s timeout).
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

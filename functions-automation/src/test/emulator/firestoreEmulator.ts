import * as admin from 'firebase-admin';

/**
 * Tests here run against the Firestore emulator only. `npm test` skips them;
 * `npm run test:emulator` starts the emulator through the rules tests'
 * harness (firestore-rules-test/scripts/run-with-firestore-emulator.mjs)
 * and runs them. With FIRESTORE_EMULATOR_HOST set the Admin SDK talks to
 * the emulator and nothing else.
 */
export const emulatorHost = process.env.FIRESTORE_EMULATOR_HOST || '';

/** A node:test skip reason when there is no emulator, else false. */
export const skipWithoutEmulator: string | false = emulatorHost
  ? false
  : 'needs the Firestore emulator: npm run test:emulator';

const projectId = process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT || 'demo-sfc-functions-test';

/** The default app (the callables use it), on the emulator. */
export function emulatorDb(): admin.firestore.Firestore {
  if (!emulatorHost) throw new Error('FIRESTORE_EMULATOR_HOST is not set');
  if (admin.apps.length === 0) admin.initializeApp({ projectId });
  return admin.firestore();
}

/** Deletes every document in the emulator's default database. */
export async function clearEmulator(): Promise<void> {
  const res = await fetch(
    `http://${emulatorHost}/emulator/v1/projects/${projectId}/databases/(default)/documents`,
    { method: 'DELETE' },
  );
  if (!res.ok) throw new Error(`clearing the emulator failed: ${res.status}`);
}

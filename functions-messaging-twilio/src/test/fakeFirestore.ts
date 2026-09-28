import type { LeaseDb } from '../a2pSubmission';
import type { FacilityDocRef, PaidStepDeps } from '../a2pPaidSteps';
import type { A2PTwilioClient } from '../a2pTwilioTypes';

/** Stand-in for FieldValue.delete(): a merge-set with it removes the key. */
export const DELETE = Symbol('delete');
/** Stand-in for FieldValue.serverTimestamp(). */
export const SERVER_TIME = 'SERVER_TIME';

/**
 * In-memory Firestore with serialised transactions: Firestore transactions are
 * atomic, and running them one at a time is the faithful single-process model.
 */
export function fakeDb() {
  const docs = new Map<string, Record<string, any>>();
  let queue: Promise<unknown> = Promise.resolve();

  const merge = (id: string, data: Record<string, unknown>) => {
    const next = { ...(docs.get(id) || {}) };
    for (const [key, value] of Object.entries(data)) {
      if (value === DELETE) delete next[key];
      else next[key] = value;
    }
    docs.set(id, next);
  };

  const ref = (id: string): FacilityDocRef => ({
    id,
    get: async () => ({ data: () => (docs.has(id) ? { ...docs.get(id)! } : undefined) }),
    set: async (data: Record<string, unknown>) => merge(id, data),
  });

  const db: LeaseDb = {
    runTransaction<T>(fn: (tx: any) => Promise<T>): Promise<T> {
      const run = queue.then(() =>
        fn({
          get: async (r: { id: string }) => ({
            data: () => (docs.has(r.id) ? { ...docs.get(r.id)! } : undefined),
          }),
          update: (r: { id: string }, data: Record<string, unknown>) => merge(r.id, data),
        }),
      );
      queue = run.catch(() => undefined);
      return run;
    },
  };
  return { db, docs, ref };
}

export function fakeDeps(db: LeaseDb, twilio: A2PTwilioClient | null): PaidStepDeps {
  let n = 0;
  return {
    db,
    twilio,
    serverTimestamp: () => SERVER_TIME,
    deleteField: () => DELETE,
    newId: () => `req${++n}`,
  };
}

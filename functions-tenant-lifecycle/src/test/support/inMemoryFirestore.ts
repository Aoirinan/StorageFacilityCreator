/**
 * A small in-memory Firestore for callable tests, modelled on the one in
 * functions-public-website/src/test/support. Only what the tests here use:
 * doc get/set/update, a whole-collection get, and transactions.
 */
import * as admin from 'firebase-admin';

type DocData = Record<string, unknown>;

export class InMemoryFirestore {
  private readonly store = new Map<string, DocData>();

  seed(path: string, data: DocData): void {
    this.store.set(path, { ...data });
  }

  read(path: string): DocData | undefined {
    const data = this.store.get(path);
    return data ? { ...data } : undefined;
  }

  /** Paths of the documents directly in [collectionPath]. */
  listCollection(collectionPath: string): string[] {
    const prefix = `${collectionPath}/`;
    return [...this.store.keys()].filter(
      (key) => key.startsWith(prefix) && !key.slice(prefix.length).includes('/'),
    );
  }

  firestore(): admin.firestore.Firestore {
    const store = this.store;
    // eslint-disable-next-line @typescript-eslint/no-this-alias
    const owner = this;

    class DocSnapshot {
      constructor(readonly ref: DocRef) {}

      get exists(): boolean {
        return store.has(this.ref.path);
      }

      get id(): string {
        return this.ref.id;
      }

      data(): DocData | undefined {
        const value = store.get(this.ref.path);
        return value ? { ...value } : undefined;
      }
    }

    class DocRef {
      constructor(readonly path: string) {}

      get id(): string {
        return this.path.split('/').pop() || '';
      }

      async get(): Promise<DocSnapshot> {
        return new DocSnapshot(this);
      }

      async set(data: DocData, options?: { merge?: boolean }): Promise<void> {
        const existing = options?.merge ? store.get(this.path) : undefined;
        store.set(this.path, { ...existing, ...data });
      }

      async update(data: DocData): Promise<void> {
        store.set(this.path, { ...store.get(this.path), ...data });
      }

      collection(name: string): CollectionRef {
        return new CollectionRef(`${this.path}/${name}`);
      }
    }

    class CollectionRef {
      constructor(readonly path: string) {}

      doc(id?: string): DocRef {
        return new DocRef(`${this.path}/${id || `auto_${store.size + 1}`}`);
      }

      async get() {
        const docs = owner.listCollection(this.path).map((key) => new DocSnapshot(new DocRef(key)));
        return {
          empty: docs.length === 0,
          size: docs.length,
          docs,
          forEach: (fn: (doc: DocSnapshot) => void) => docs.forEach(fn),
        };
      }
    }

    const db = {
      collection: (name: string) => new CollectionRef(name),
      doc: (path: string) => new DocRef(path),
      runTransaction: <T>(fn: (tx: Record<string, unknown>) => Promise<T>): Promise<T> =>
        fn({
          get: (ref: DocRef) => ref.get(),
          set: (ref: DocRef, data: DocData) => ref.set(data),
          update: (ref: DocRef, data: DocData) => ref.update(data),
        }),
    };
    return db as unknown as admin.firestore.Firestore;
  }
}

/** Point firebase-admin's `admin.firestore()` at [inMemory]; the static helpers stay real. */
export function installInMemoryFirestore(inMemory: InMemoryFirestore): void {
  if (!admin.apps.length) {
    admin.initializeApp({ projectId: 'in-memory-test' });
  }
  const real = admin.firestore;
  const db = inMemory.firestore();
  const firestoreFn = Object.assign(() => db, {
    Timestamp: real.Timestamp,
    FieldValue: real.FieldValue,
    FieldPath: real.FieldPath,
  });
  Object.defineProperty(admin, 'firestore', {
    configurable: true,
    writable: true,
    value: firestoreFn,
  });
}

import * as admin from 'firebase-admin';

type DocData = Record<string, unknown>;

function joinPath(...segments: string[]): string {
  return segments.filter(Boolean).join('/');
}

export class InMemoryFirestore {
  private readonly store = new Map<string, DocData>();

  seed(path: string, data: DocData): void {
    this.store.set(path, { ...data });
  }

  getStore(): Map<string, DocData> {
    return this.store;
  }

  read(path: string): DocData | undefined {
    const data = this.store.get(path);
    return data ? { ...data } : undefined;
  }

  firestore(): admin.firestore.Firestore {
    return this.buildFirestore() as unknown as admin.firestore.Firestore;
  }

  private buildFirestore(): Record<string, unknown> {
    const store = this.store;
    const self = this;

    const FieldValue = {
      serverTimestamp: () => admin.firestore.Timestamp.now(),
      increment: (n: number) => ({ __increment: n }),
    };

    class DocSnapshot {
      constructor(
        readonly ref: DocRef,
        private readonly path: string,
      ) {}

      get exists(): boolean {
        return store.has(this.path);
      }

      get id(): string {
        return this.path.split('/').pop() || '';
      }

      data(): DocData | undefined {
        const value = store.get(this.path);
        return value ? { ...value } : undefined;
      }
    }

    class DocRef {
      constructor(readonly path: string) {}

      get id(): string {
        return this.path.split('/').pop() || '';
      }

      async get(): Promise<DocSnapshot> {
        return new DocSnapshot(this, this.path);
      }

      async set(data: DocData, options?: { merge?: boolean }): Promise<void> {
        if (options?.merge && store.has(this.path)) {
          store.set(this.path, { ...store.get(this.path), ...data });
        } else {
          store.set(this.path, { ...data });
        }
      }

      async update(data: DocData): Promise<void> {
        const existing = store.get(this.path) || {};
        const next = { ...existing };
        for (const [key, value] of Object.entries(data)) {
          if (
            value &&
            typeof value === 'object' &&
            '__increment' in (value as Record<string, unknown>)
          ) {
            const delta = (value as { __increment: number }).__increment;
            next[key] = Number(next[key] ?? 0) + delta;
          } else {
            next[key] = value;
          }
        }
        store.set(this.path, next);
      }

      collection(name: string): CollectionRef {
        return new CollectionRef(joinPath(this.path, name));
      }
    }

    class CollectionRef {
      constructor(readonly path: string) {}

      doc(id?: string): DocRef {
        const docId = id || `auto_${store.size + 1}`;
        return new DocRef(joinPath(this.path, docId));
      }
    }

    class WriteBatch {
      private readonly ops: Array<() => void> = [];

      delete(ref: DocRef): WriteBatch {
        this.ops.push(() => store.delete(ref.path));
        return this;
      }

      async commit(): Promise<void> {
        for (const op of this.ops) {
          op();
        }
      }
    }

    return {
      collection(name: string): CollectionRef {
        return new CollectionRef(name);
      },
      batch(): WriteBatch {
        return new WriteBatch();
      },
      runTransaction<T>(fn: (tx: Record<string, unknown>) => Promise<T>): Promise<T> {
        const tx = {
          get: async (ref: DocRef) => ref.get(),
          set: async (ref: DocRef, data: DocData) => ref.set(data),
          update: async (ref: DocRef, data: DocData) => ref.update(data),
        };
        return fn(tx);
      },
      FieldValue,
    };
  }
}

/** Patch firebase-admin to use an in-memory Firestore instance for tests. */
export function installInMemoryFirestore(inMemory: InMemoryFirestore): void {
  if (!admin.apps.length) {
    admin.initializeApp({ projectId: 'in-memory-test' });
  }
  const TimestampStatic = admin.firestore.Timestamp;
  const FieldValueStatic = admin.firestore.FieldValue;
  const fs = inMemory.firestore();
  const firestoreFn = Object.assign(() => fs, {
    Timestamp: TimestampStatic,
    FieldValue: FieldValueStatic,
  });
  Object.defineProperty(admin, 'firestore', {
    configurable: true,
    writable: true,
    value: firestoreFn,
  });
}

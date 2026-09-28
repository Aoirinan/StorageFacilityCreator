import * as admin from 'firebase-admin';
import { FieldValue, Timestamp } from 'firebase-admin/firestore';

type DocData = Record<string, unknown>;

/** FieldValue.delete() as the code under test passes it: the field is removed. */
function isDeleteSentinel(value: unknown): boolean {
  return value instanceof FieldValue && value.isEqual(FieldValue.delete());
}

/** A map field, not a sentinel, Timestamp or array. */
function isPlainMap(value: unknown): value is DocData {
  return typeof value === 'object' && value !== null &&
    Object.getPrototypeOf(value) === Object.prototype && !('__increment' in value);
}

/** The value at a field path ('a' or 'a.b'), and whether it is there. */
function fieldAt(data: DocData, path: string): { exists: boolean; value: unknown } {
  let current: unknown = data;
  for (const segment of path.split('.')) {
    if (!isPlainMap(current) || !(segment in current)) return { exists: false, value: undefined };
    current = current[segment];
  }
  return { exists: true, value: current };
}

function joinPath(...segments: string[]): string {
  return segments.filter(Boolean).join('/');
}

export class InMemoryFirestore {
  private readonly store = new Map<string, DocData>();

  /** When set, every `count()` query rejects with it (a failed aggregate read). */
  countError: Error | null = null;

  /** A query's `get()` on a collection path listed here rejects with its error. */
  readonly queryErrors = new Map<string, Error>();

  /**
   * A write made outside a transaction to a doc in a collection path listed
   * here rejects with its error, as when the instance dies after a
   * transaction commits and before a follow-up write. Transaction writes are
   * not affected.
   */
  readonly writeErrorsOutsideTransactions = new Map<string, Error>();

  /** The last transaction queued; the next one starts when it settles. */
  private transactionTail: Promise<unknown> = Promise.resolve();

  /** Transactions started so far. */
  transactionCount = 0;

  /**
   * Runs as each transaction starts, with its number (1 for the first), as
   * another request writing between two steps of the code under test would.
   */
  beforeTransaction: ((transactionNumber: number) => void) | null = null;

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

  listCollection(prefix: string): string[] {
    const normalized = prefix.endsWith('/') ? prefix : `${prefix}/`;
    return [...this.store.keys()].filter((key) => key.startsWith(normalized));
  }

  firestore(): admin.firestore.Firestore {
    return this.buildFirestore() as unknown as admin.firestore.Firestore;
  }

  private buildFirestore(): Record<string, unknown> {
    const store = this.store;
    // eslint-disable-next-line @typescript-eslint/no-this-alias
    const owner = this;

    const FieldValue = {
      serverTimestamp: () => Timestamp.now(),
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
        this.failIfWritesRefused();
        this.write(data, options);
      }

      async update(data: DocData): Promise<void> {
        this.failIfWritesRefused();
        this.applyUpdate(data);
      }

      async delete(): Promise<void> {
        this.failIfWritesRefused();
        store.delete(this.path);
      }

      private failIfWritesRefused(): void {
        const collectionPath = this.path.split('/').slice(0, -1).join('/');
        const error = owner.writeErrorsOutsideTransactions.get(collectionPath);
        if (error) throw error;
      }

      /** A set, as a transaction or a direct write makes it. */
      write(data: DocData, options?: { merge?: boolean }): void {
        if (options?.merge && store.has(this.path)) {
          store.set(this.path, DocRef.mergeFields({ ...store.get(this.path) }, data));
        } else {
          store.set(this.path, DocRef.applyFields({}, data));
        }
      }

      /** set(..., { merge: true }): nested maps merge field by field, as Firestore merges them. */
      private static mergeFields(next: DocData, data: DocData): DocData {
        for (const [key, value] of Object.entries(data)) {
          const existing = next[key];
          if (isPlainMap(value) && isPlainMap(existing)) {
            next[key] = DocRef.mergeFields({ ...existing }, value);
          } else {
            DocRef.applyFields(next, { [key]: value });
          }
        }
        return next;
      }

      /** An update, as a transaction or a direct write makes it. */
      applyUpdate(data: DocData): void {
        if (!store.has(this.path)) {
          // As Firestore refuses an update to a missing doc.
          throw Object.assign(new Error(`No document to update: ${this.path}`), { code: 5 });
        }
        store.set(this.path, DocRef.applyFields({ ...store.get(this.path) }, data));
      }

      private static applyFields(next: DocData, data: DocData): DocData {
        for (const [key, value] of Object.entries(data)) {
          if (
            value &&
            typeof value === 'object' &&
            '__increment' in (value as Record<string, unknown>)
          ) {
            const delta = (value as { __increment: number }).__increment;
            next[key] = Number(next[key] ?? 0) + delta;
          } else if (isDeleteSentinel(value)) {
            delete next[key];
          } else {
            next[key] = value;
          }
        }
        return next;
      }

      collection(name: string): CollectionRef {
        return new CollectionRef(joinPath(this.path, name));
      }
    }

    /**
     * A collection query. Equality (`==`) filters are applied; other
     * operators, ordering and limits are ignored.
     */
    class Query {
      // [path] is a collection's path, or '**' + '/' + {id} for every
      // collection named {id} (a collection-group query).
      constructor(
        readonly path: string,
        private readonly equals: Array<[string, unknown]> = [],
      ) {}

      where(field?: string, op?: string, value?: unknown): Query {
        if (field === undefined || op !== '==') return this;
        return new Query(this.path, [...this.equals, [field, value]]);
      }

      private holds(key: string): boolean {
        if (this.path.startsWith('**/')) {
          const segments = key.split('/');
          return segments.length % 2 === 0 && segments[segments.length - 2] === this.path.slice(3);
        }
        const prefix = `${this.path}/`;
        return key.startsWith(prefix) && !key.slice(prefix.length).includes('/');
      }

      limit(): Query {
        return this;
      }

      orderBy(): Query {
        return this;
      }

      /** Cursors are ignored: limits are too, so one page holds every doc. */
      startAfter(): Query {
        return this;
      }

      async get(): Promise<{ empty: boolean; size: number; docs: DocSnapshot[] }> {
        const queryError = owner.queryErrors.get(this.path);
        if (queryError) throw queryError;
        const docs = [...store.keys()]
          .filter((key) => this.holds(key))
          .filter((key) => {
            const data = store.get(key) || {};
            return this.equals.every(([field, value]) => {
              // A dotted path ('refund.status') reads a field of a map, as Firestore does.
              const found = fieldAt(data, field);
              return found.exists && found.value === value;
            });
          })
          .map((key) => new DocSnapshot(new DocRef(key), key));
        return { empty: docs.length === 0, size: docs.length, docs };
      }

      count(): { get: () => Promise<{ data: () => { count: number } }> } {
        return {
          get: async () => {
            if (owner.countError) throw owner.countError;
            const { docs } = await this.get();
            return { data: () => ({ count: docs.length }) };
          },
        };
      }
    }

    class CollectionRef extends Query {
      constructor(path: string) {
        super(path);
      }

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
      doc(path: string): DocRef {
        return new DocRef(path);
      },
      // Its query errors are keyed '**' + '/' + collectionId.
      collectionGroup(collectionId: string): Query {
        return new Query(`**/${collectionId}`);
      },
      batch(): WriteBatch {
        return new WriteBatch();
      },
      /**
       * Transactions run one at a time. Writes still land as they are made,
       * so a transaction that throws part way leaves its earlier writes.
       */
      runTransaction<T>(fn: (tx: Record<string, unknown>) => Promise<T>): Promise<T> {
        const tx: Record<string, unknown> = {
          get: async (ref: DocRef) => ref.get(),
          set: (ref: DocRef, data: DocData, options?: { merge?: boolean }) => {
            ref.write(data, options);
            return tx;
          },
          update: (ref: DocRef, data: DocData) => {
            ref.applyUpdate(data);
            return tx;
          },
          delete: (ref: DocRef) => {
            store.delete(ref.path);
            return tx;
          },
        };
        const run = owner.transactionTail.then(() => {
          owner.transactionCount += 1;
          owner.beforeTransaction?.(owner.transactionCount);
          return fn(tx);
        });
        owner.transactionTail = run.catch(() => undefined);
        return run;
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
  const FieldPathStatic = admin.firestore.FieldPath;
  const fs = inMemory.firestore();
  const firestoreFn = Object.assign(() => fs, {
    Timestamp: TimestampStatic,
    FieldValue: FieldValueStatic,
    FieldPath: FieldPathStatic,
  });
  Object.defineProperty(admin, 'firestore', {
    configurable: true,
    writable: true,
    value: firestoreFn,
  });
}

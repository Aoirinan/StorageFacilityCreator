/**
 * A small in-memory Firestore for callable tests, modelled on the one in
 * functions-public-website/src/test/support. Only what the tests here use:
 * doc get/set/update, a collection get with equality filters, and
 * transactions.
 */
import * as admin from 'firebase-admin';

type DocData = Record<string, unknown>;

/** Firestore's default for a transaction whose reads were written before it committed. */
const MAX_TRANSACTION_ATTEMPTS = 5;

export class InMemoryFirestore {
  private readonly store = new Map<string, DocData>();

  /**
   * Runs as each attempt of a transaction is about to commit, after its
   * callback has made every read, as another request writing while it ran
   * would. A write here to anything it read through `tx.get` (a doc, or a
   * query's results) makes it run again, as Firestore does; a read made with
   * a plain `get()` is not checked, so it can go stale.
   */
  beforeCommit: ((attempt: number) => void) | null = null;

  /** Transaction attempts rerun because something they read was written before they committed. */
  transactionRetries = 0;

  /** For generated doc ids, which must differ while a transaction's writes are held. */
  private autoIds = 0;

  nextAutoId(): string {
    this.autoIds += 1;
    return `auto_${this.autoIds}`;
  }

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

    /** A collection, or a query on one; only equality (`==`) filters are applied. */
    class CollectionRef {
      constructor(
        readonly path: string,
        private readonly equals: Array<[string, unknown]> = [],
      ) {}

      doc(id?: string): DocRef {
        return new DocRef(`${this.path}/${id || owner.nextAutoId()}`);
      }

      where(field: string, op: string, value: unknown): CollectionRef {
        if (op !== '==') throw new Error(`in-memory Firestore: unsupported where op ${op}`);
        return new CollectionRef(this.path, [...this.equals, [field, value]]);
      }

      async get() {
        const docs = owner
          .listCollection(this.path)
          .filter((key) => {
            const data = store.get(key) || {};
            return this.equals.every(([field, value]) => field in data && data[field] === value);
          })
          .map((key) => new DocSnapshot(new DocRef(key)));
        return {
          empty: docs.length === 0,
          size: docs.length,
          docs,
          forEach: (fn: (doc: DocSnapshot) => void) => docs.forEach(fn),
        };
      }
    }

    /**
     * One attempt: reads first, writes held until the callback returns, then
     * committed unless something it read through `tx.get` was written
     * meanwhile (null: run it again). Every write replaces a doc's object, so
     * a different object (or none) means the doc was written.
     */
    const attemptTransaction = async <T>(
      fn: (tx: Record<string, unknown>) => Promise<T>,
      attempt: number,
    ): Promise<{ result: T } | null> => {
      const docReads: Array<{ path: string; seen: DocData | undefined }> = [];
      const queryReads: Array<{ query: CollectionRef; seen: Map<string, DocData | undefined> }> = [];
      const writes: Array<() => Promise<void>> = [];
      const tx = {
        get: async (target: DocRef | CollectionRef) => {
          if (writes.length > 0) {
            throw new Error('Firestore transactions require all reads to be executed before all writes.');
          }
          if (target instanceof DocRef) {
            docReads.push({ path: target.path, seen: store.get(target.path) });
            return target.get();
          }
          const result = await target.get();
          queryReads.push({
            query: target,
            seen: new Map(result.docs.map((doc) => [doc.ref.path, store.get(doc.ref.path)])),
          });
          return result;
        },
        set: (ref: DocRef, data: DocData) => {
          writes.push(() => ref.set(data));
          return tx;
        },
        update: (ref: DocRef, data: DocData) => {
          writes.push(() => ref.update(data));
          return tx;
        },
      };
      const result = await fn(tx);
      owner.beforeCommit?.(attempt);
      let stale = docReads.some((read) => store.get(read.path) !== read.seen);
      for (const read of queryReads) {
        if (stale) break;
        const now = (await read.query.get()).docs.map((doc) => doc.ref.path);
        stale = now.length !== read.seen.size ||
          now.some((p) => !read.seen.has(p) || read.seen.get(p) !== store.get(p));
      }
      if (stale) return null;
      for (const write of writes) await write();
      return { result };
    };

    const db = {
      collection: (name: string) => new CollectionRef(name),
      doc: (path: string) => new DocRef(path),
      runTransaction: async <T>(fn: (tx: Record<string, unknown>) => Promise<T>): Promise<T> => {
        for (let attempt = 1; attempt <= MAX_TRANSACTION_ATTEMPTS; attempt += 1) {
          const committed = await attemptTransaction(fn, attempt);
          if (committed) return committed.result;
          owner.transactionRetries += 1;
        }
        throw Object.assign(new Error('10 ABORTED: Too much contention on these documents.'), { code: 10 });
      },
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

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

/** The query operators the fake applies. */
const FILTER_OPS = new Set(['==', 'in', '<', '<=', '>', '>=']);

/**
 * How two field values order: Timestamps and Dates by time, numbers and
 * strings as themselves. Null when they cannot be compared (different kinds),
 * which Firestore treats as not matching a range filter.
 */
function compareValues(left: unknown, right: unknown): number | null {
  const millis = (value: unknown): number | null => {
    if (value instanceof Date) return value.getTime();
    if (value && typeof (value as { toMillis?: unknown }).toMillis === 'function') {
      return (value as { toMillis: () => number }).toMillis();
    }
    return null;
  };
  const leftMillis = millis(left);
  const rightMillis = millis(right);
  if (leftMillis !== null && rightMillis !== null) return leftMillis - rightMillis;
  if (typeof left === 'number' && typeof right === 'number') return left - right;
  if (typeof left === 'string' && typeof right === 'string') return left < right ? -1 : left > right ? 1 : 0;
  return null;
}

/** Firestore's default for a transaction whose reads were written before it committed. */
const MAX_TRANSACTION_ATTEMPTS = 5;

async function someAsync<T>(items: T[], test: (item: T) => Promise<boolean>): Promise<boolean> {
  for (const item of items) {
    if (await test(item)) return true;
  }
  return false;
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

  /** A document's `get()` on a path listed here rejects with its error. */
  readonly docErrors = new Map<string, Error>();

  /** The last transaction queued; the next one starts when it settles. */
  private transactionTail: Promise<unknown> = Promise.resolve();

  /** Transactions started so far. */
  transactionCount = 0;

  /**
   * Runs as each transaction starts, with its number (1 for the first), as
   * another request writing between two steps of the code under test would.
   */
  beforeTransaction: ((transactionNumber: number) => void) | null = null;

  /**
   * Runs as each attempt of a transaction is about to commit, after its
   * callback has made every read, as another request writing while it ran
   * would. [readPaths] are the docs it read with `tx.get` (its queries
   * aside), to tell one transaction from another. A write here to anything
   * it read with `tx.get`, a query's results included, makes it run again.
   */
  beforeCommit: ((commit: { transactionNumber: number; attempt: number; readPaths: string[] }) => void) | null = null;

  /** Transaction attempts rerun because something they read was written before they committed. */
  transactionRetries = 0;

  /** For generated doc ids, which must differ within one transaction's held writes. */
  private autoIds = 0;

  nextAutoId(): string {
    this.autoIds += 1;
    return `auto_${this.autoIds}`;
  }

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
        const docError = owner.docErrors.get(this.path);
        if (docError) throw docError;
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
     * A collection query. Filters `==`, `in`, `<`, `<=`, `>` and `>=` are
     * applied (a doc without the field never matches, as in Firestore), then
     * `orderBy`, `startAfter` (a doc snapshot) and `limit`. Unlike Firestore,
     * a doc without an `orderBy` field is kept, sorted last, and with no
     * `orderBy` docs come in the order they were first written, not by id.
     */
    class Query {
      // [path] is a collection's path, or '**' + '/' + {id} for every
      // collection named {id} (a collection-group query).
      constructor(
        readonly path: string,
        private readonly filters: Array<{ field: string; op: string; value: unknown }> = [],
        private readonly orders: Array<{ field: string | null; descending: boolean }> = [],
        private readonly max: number | null = null,
        private readonly after: string | null = null,
      ) {}

      private with(changes: {
        filters?: Query['filters'];
        orders?: Query['orders'];
        max?: number | null;
        after?: string | null;
      }): Query {
        return new Query(
          this.path,
          changes.filters ?? this.filters,
          changes.orders ?? this.orders,
          changes.max === undefined ? this.max : changes.max,
          changes.after === undefined ? this.after : changes.after,
        );
      }

      where(field?: unknown, op?: string, value?: unknown): Query {
        if (typeof field !== 'string' || !op || !FILTER_OPS.has(op)) return this;
        return this.with({ filters: [...this.filters, { field, op, value }] });
      }

      private holds(key: string): boolean {
        if (this.path.startsWith('**/')) {
          const segments = key.split('/');
          return segments.length % 2 === 0 && segments[segments.length - 2] === this.path.slice(3);
        }
        const prefix = `${this.path}/`;
        return key.startsWith(prefix) && !key.slice(prefix.length).includes('/');
      }

      limit(max?: number): Query {
        return this.with({ max: typeof max === 'number' ? max : null });
      }

      /** By a field, or by document id for anything else (FieldPath.documentId()). */
      orderBy(field?: unknown, direction?: string): Query {
        return this.with({
          orders: [...this.orders, { field: typeof field === 'string' ? field : null, descending: direction === 'desc' }],
        });
      }

      /** After [cursor], a doc snapshot from an earlier page of this query. */
      startAfter(cursor?: unknown): Query {
        const path = (cursor as { ref?: { path?: string } } | undefined)?.ref?.path;
        return this.with({ after: typeof path === 'string' ? path : null });
      }

      private matches(data: DocData): boolean {
        return this.filters.every(({ field, op, value }) => {
          // A dotted path ('refund.status') reads a field of a map, as Firestore does.
          const found = fieldAt(data, field);
          if (!found.exists) return false;
          if (op === '==') return found.value === value;
          if (op === 'in') return Array.isArray(value) && value.includes(found.value);
          const order = compareValues(found.value, value);
          if (order === null) return false;
          if (op === '<') return order < 0;
          if (op === '<=') return order <= 0;
          if (op === '>') return order > 0;
          return order >= 0;
        });
      }

      private sorted(keys: string[]): string[] {
        if (this.orders.length === 0) return keys;
        return [...keys].sort((a, b) => {
          for (const { field, descending } of this.orders) {
            let order: number;
            if (field === null) {
              order = a < b ? -1 : a > b ? 1 : 0;
            } else {
              const left = fieldAt(store.get(a) || {}, field);
              const right = fieldAt(store.get(b) || {}, field);
              if (!left.exists || !right.exists) {
                order = Number(!left.exists) - Number(!right.exists);
                if (order !== 0) return order;
                continue;
              }
              order = compareValues(left.value, right.value) ?? 0;
            }
            if (order !== 0) return descending ? -order : order;
          }
          return a < b ? -1 : a > b ? 1 : 0;
        });
      }

      async get(): Promise<{ empty: boolean; size: number; docs: DocSnapshot[] }> {
        const queryError = owner.queryErrors.get(this.path);
        if (queryError) throw queryError;
        let keys = this.sorted(
          [...store.keys()].filter((key) => this.holds(key)).filter((key) => this.matches(store.get(key) || {})),
        );
        if (this.after !== null) {
          const at = keys.indexOf(this.after);
          keys = at >= 0 ? keys.slice(at + 1) : keys;
        }
        if (this.max !== null) keys = keys.slice(0, this.max);
        const docs = keys.map((key) => new DocSnapshot(new DocRef(key), key));
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
        // Not from the store's size: a transaction's writes are held until
        // it commits, so two new docs in one would get the same id.
        const docId = id || owner.nextAutoId();
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
       * Transactions run one at a time, as Firestore's do: reads first (a
       * read after a write throws), writes held until the callback returns
       * and then committed together, nothing written when it throws. What a
       * transaction read through `tx.get` (a doc, or a query's results) is
       * checked again at commit: a write to any of it since, from
       * [beforeCommit] or any other writer, reruns the callback, up to
       * MAX_TRANSACTION_ATTEMPTS times. A read made with a plain `get()`
       * instead is not checked, so it can go stale, as it can in Firestore.
       */
      runTransaction<T>(fn: (tx: Record<string, unknown>) => Promise<T>): Promise<T> {
        const attemptOnce = async (transactionNumber: number, attempt: number): Promise<{ result: T } | null> => {
          // Each read's doc objects as read: every write replaces a doc's
          // object, so a different object (or none) means it was written.
          const docReads: Array<{ path: string; seen: DocData | undefined }> = [];
          const queryReads: Array<{ query: Query; seen: Map<string, DocData | undefined> }> = [];
          const writes: Array<() => void> = [];
          const tx: Record<string, unknown> = {
            get: async (target: DocRef | Query) => {
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
            set: (ref: DocRef, data: DocData, options?: { merge?: boolean }) => {
              writes.push(() => ref.write(data, options));
              return tx;
            },
            update: (ref: DocRef, data: DocData) => {
              writes.push(() => ref.applyUpdate(data));
              return tx;
            },
            delete: (ref: DocRef) => {
              writes.push(() => store.delete(ref.path));
              return tx;
            },
          };
          const result = await fn(tx);
          owner.beforeCommit?.({ transactionNumber, attempt, readPaths: docReads.map((read) => read.path) });
          const stale =
            docReads.some((read) => store.get(read.path) !== read.seen) ||
            await someAsync(queryReads, async (read) => {
              const now = (await read.query.get()).docs.map((doc) => doc.ref.path);
              return now.length !== read.seen.size ||
                now.some((path) => !read.seen.has(path) || read.seen.get(path) !== store.get(path));
            });
          if (stale) return null;
          // All or nothing: an update to a missing doc fails the whole commit.
          const beforeWrites = new Map(store);
          try {
            for (const write of writes) write();
          } catch (err) {
            store.clear();
            for (const [path, data] of beforeWrites) store.set(path, data);
            throw err;
          }
          return { result };
        };
        const run = owner.transactionTail.then(async () => {
          owner.transactionCount += 1;
          const transactionNumber = owner.transactionCount;
          owner.beforeTransaction?.(transactionNumber);
          for (let attempt = 1; attempt <= MAX_TRANSACTION_ATTEMPTS; attempt += 1) {
            const committed = await attemptOnce(transactionNumber, attempt);
            if (committed) return committed.result;
            owner.transactionRetries += 1;
          }
          throw Object.assign(new Error('10 ABORTED: Too much contention on these documents.'), { code: 10 });
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

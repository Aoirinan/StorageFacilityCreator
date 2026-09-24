/**
 * An in-memory Firestore for tests that need transactions to behave like the
 * real thing: optimistic, retried on conflict, all-or-nothing, reads before
 * writes. The simpler fakes elsewhere run a transaction callback once against
 * live state, so two racing completions both "win" there and a double credit
 * would go unnoticed.
 *
 * Supports: collection/doc refs, get/set(merge)/update/create/delete/add,
 * equality `where` + `limit` queries, `runTransaction`, `batch`, and the
 * `FieldValue` sentinels this codebase writes (serverTimestamp, increment,
 * arrayUnion, arrayRemove, delete) whether they come from firebase-admin or
 * from this fake's own `FieldValue`.
 *
 * Shipped from functions-shared (exports `./testing/*`) so every functions
 * package can test against one implementation. Not used in production code.
 */
import * as admin from 'firebase-admin';

type DocData = Record<string, unknown>;

const ALREADY_EXISTS = 6;
const NOT_FOUND = 5;
const ABORTED = 10;

function firestoreError(code: number, message: string): Error {
  return Object.assign(new Error(message), { code });
}

function clone<T>(value: T): T {
  if (value === null || typeof value !== 'object') return value;
  if (value instanceof admin.firestore.Timestamp || value instanceof Date) return value;
  if (Array.isArray(value)) return value.map((v) => clone(v)) as unknown as T;
  const out: DocData = {};
  for (const [k, v] of Object.entries(value as DocData)) out[k] = clone(v);
  return out as T;
}

function deepEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (a instanceof admin.firestore.Timestamp && b instanceof admin.firestore.Timestamp) {
    return a.isEqual(b);
  }
  if (typeof a !== 'object' || typeof b !== 'object' || a === null || b === null) return false;
  return JSON.stringify(a) === JSON.stringify(b);
}

/** Recognises a FieldValue sentinel and describes it, or returns null. */
function describeSentinel(value: unknown): { kind: string; operand?: unknown; elements?: unknown[] } | null {
  if (!value || typeof value !== 'object') return null;
  const own = value as { __fake?: string; operand?: unknown; elements?: unknown[] };
  if (typeof own.__fake === 'string') {
    return { kind: own.__fake, operand: own.operand, elements: own.elements };
  }
  if (value instanceof admin.firestore.FieldValue) {
    const methodName = String((value as unknown as { methodName?: string }).methodName || '');
    const kind = methodName.replace(/^FieldValue\./, '');
    return {
      kind,
      operand: (value as unknown as { operand?: unknown }).operand,
      elements: (value as unknown as { elements?: unknown[] }).elements,
    };
  }
  return null;
}

function applySentinel(current: unknown, sentinel: { kind: string; operand?: unknown; elements?: unknown[] }, now: admin.firestore.Timestamp): unknown {
  switch (sentinel.kind) {
    case 'serverTimestamp':
      return now;
    case 'increment':
      return Number(current ?? 0) + Number(sentinel.operand ?? 0);
    case 'arrayUnion': {
      const base = Array.isArray(current) ? [...current] : [];
      for (const el of sentinel.elements || []) {
        if (!base.some((existing) => deepEqual(existing, el))) base.push(clone(el));
      }
      return base;
    }
    case 'arrayRemove': {
      const base = Array.isArray(current) ? [...current] : [];
      return base.filter((existing) => !(sentinel.elements || []).some((el) => deepEqual(existing, el)));
    }
    default:
      throw new Error(`fakeFirestore: unsupported FieldValue ${sentinel.kind}`);
  }
}

/** Applies top-level fields (dotted paths supported) onto [base]. */
function applyFields(base: DocData, data: DocData, now: admin.firestore.Timestamp, dotted: boolean): DocData {
  const next = clone(base);
  for (const [rawKey, value] of Object.entries(data)) {
    const path = dotted ? rawKey.split('.') : [rawKey];
    let target: DocData = next;
    for (let i = 0; i < path.length - 1; i++) {
      const seg = path[i];
      if (!target[seg] || typeof target[seg] !== 'object') target[seg] = {};
      target = target[seg] as DocData;
    }
    const leaf = path[path.length - 1];
    const sentinel = describeSentinel(value);
    if (sentinel?.kind === 'delete') {
      delete target[leaf];
    } else if (sentinel) {
      target[leaf] = applySentinel(target[leaf], sentinel, now);
    } else if (value && typeof value === 'object' && !Array.isArray(value) &&
      !(value instanceof admin.firestore.Timestamp) && !(value instanceof Date) && !dotted &&
      target[leaf] && typeof target[leaf] === 'object' && !Array.isArray(target[leaf])) {
      // merge: nested maps merge key by key.
      target[leaf] = applyFields(target[leaf] as DocData, value as DocData, now, false);
    } else {
      target[leaf] = resolveNested(value, now);
    }
  }
  return next;
}

function resolveNested(value: unknown, now: admin.firestore.Timestamp): unknown {
  const sentinel = describeSentinel(value);
  if (sentinel) {
    if (sentinel.kind === 'delete') return undefined;
    return applySentinel(undefined, sentinel, now);
  }
  if (Array.isArray(value)) return value.map((v) => resolveNested(v, now));
  if (value && typeof value === 'object' && !(value instanceof admin.firestore.Timestamp) && !(value instanceof Date)) {
    const out: DocData = {};
    for (const [k, v] of Object.entries(value as DocData)) {
      const resolved = resolveNested(v, now);
      if (resolved !== undefined) out[k] = resolved;
    }
    return out;
  }
  return value;
}

type PendingWrite =
  | { op: 'set'; path: string; data: DocData; merge: boolean }
  | { op: 'update'; path: string; data: DocData }
  | { op: 'create'; path: string; data: DocData }
  | { op: 'delete'; path: string };

export type FakeWriteRecord = { op: PendingWrite['op']; path: string };

export class FakeFirestore {
  private readonly docs = new Map<string, { data: DocData; version: number }>();
  private autoId = 0;
  private versionCounter = 0;
  /** Every applied write, in order. Tests assert on this to prove a path wrote nothing. */
  readonly writes: FakeWriteRecord[] = [];
  /** Transaction attempts that were rolled back because another write got there first. */
  transactionConflicts = 0;
  /** Clock used for serverTimestamp. */
  now: () => Date = () => new Date();
  /**
   * Called inside every `runTransaction` after the callback ran and before
   * its writes commit. Lets a test land a competing write at the worst moment.
   */
  beforeCommit: ((attempt: number) => Promise<void> | void) | null = null;

  readonly FieldValue = {
    serverTimestamp: () => ({ __fake: 'serverTimestamp' }),
    increment: (operand: number) => ({ __fake: 'increment', operand }),
    arrayUnion: (...elements: unknown[]) => ({ __fake: 'arrayUnion', elements }),
    arrayRemove: (...elements: unknown[]) => ({ __fake: 'arrayRemove', elements }),
    delete: () => ({ __fake: 'delete' }),
  };

  seed(path: string, data: DocData): void {
    this.docs.set(path, { data: resolveNested(clone(data), this.timestamp()) as DocData, version: ++this.versionCounter });
  }

  read(path: string): DocData | undefined {
    const entry = this.docs.get(path);
    return entry ? clone(entry.data) : undefined;
  }

  /** Ids of the documents directly inside a collection path. */
  list(collectionPath: string): string[] {
    const prefix = `${collectionPath}/`;
    return [...this.docs.keys()]
      .filter((key) => key.startsWith(prefix) && !key.slice(prefix.length).includes('/'))
      .map((key) => key.slice(prefix.length))
      .sort();
  }

  writesTo(pathPrefix: string): FakeWriteRecord[] {
    return this.writes.filter((w) => w.path === pathPrefix || w.path.startsWith(`${pathPrefix}/`));
  }

  private timestamp(): admin.firestore.Timestamp {
    return admin.firestore.Timestamp.fromDate(this.now());
  }

  private version(path: string): number {
    return this.docs.get(path)?.version ?? 0;
  }

  private applyAll(writes: PendingWrite[]): void {
    // Validate first so a failing create/update leaves nothing half-applied.
    const exists = new Map<string, boolean>();
    const has = (path: string) => (exists.has(path) ? exists.get(path)! : this.docs.has(path));
    for (const w of writes) {
      if (w.op === 'create' && has(w.path)) {
        throw firestoreError(ALREADY_EXISTS, `ALREADY_EXISTS: ${w.path}`);
      }
      if (w.op === 'update' && !has(w.path)) {
        throw firestoreError(NOT_FOUND, `NOT_FOUND: ${w.path}`);
      }
      exists.set(w.path, w.op !== 'delete');
    }
    const now = this.timestamp();
    for (const w of writes) {
      const current = this.docs.get(w.path)?.data;
      let next: DocData | null;
      switch (w.op) {
        case 'delete':
          next = null;
          break;
        case 'create':
          next = applyFields({}, w.data, now, false);
          break;
        case 'set':
          next = applyFields(w.merge && current ? current : {}, w.data, now, false);
          break;
        case 'update':
          next = applyFields(current || {}, w.data, now, true);
          break;
      }
      if (next === null) this.docs.delete(w.path);
      else this.docs.set(w.path, { data: next, version: ++this.versionCounter });
      this.writes.push({ op: w.op, path: w.path });
    }
  }

  /** Yield so concurrent callers genuinely interleave at every await. */
  private async tick(): Promise<void> {
    await new Promise<void>((resolve) => setImmediate(resolve));
  }

  firestore(): admin.firestore.Firestore {
    return this.build() as unknown as admin.firestore.Firestore;
  }

  private build(): Record<string, unknown> {
    // eslint-disable-next-line @typescript-eslint/no-this-alias
    const fake = this;

    class DocSnapshot {
      constructor(readonly ref: DocRef, private readonly snapshotData: DocData | undefined) {}
      get exists(): boolean {
        return this.snapshotData !== undefined;
      }
      get id(): string {
        return this.ref.id;
      }
      data(): DocData | undefined {
        return this.snapshotData === undefined ? undefined : clone(this.snapshotData);
      }
      get(field: string): unknown {
        return this.snapshotData?.[field];
      }
    }

    class DocRef {
      constructor(readonly path: string) {}
      get id(): string {
        return this.path.split('/').pop() || '';
      }
      get parent(): CollectionRef {
        return new CollectionRef(this.path.split('/').slice(0, -1).join('/'));
      }
      collection(name: string): CollectionRef {
        return new CollectionRef(`${this.path}/${name}`);
      }
      async get(): Promise<DocSnapshot> {
        await fake.tick();
        return new DocSnapshot(this, fake.read(this.path));
      }
      async set(data: DocData, options?: { merge?: boolean }): Promise<void> {
        await fake.tick();
        fake.applyAll([{ op: 'set', path: this.path, data, merge: !!options?.merge }]);
      }
      async update(data: DocData): Promise<void> {
        await fake.tick();
        fake.applyAll([{ op: 'update', path: this.path, data }]);
      }
      async create(data: DocData): Promise<void> {
        await fake.tick();
        fake.applyAll([{ op: 'create', path: this.path, data }]);
      }
      async delete(): Promise<void> {
        await fake.tick();
        fake.applyAll([{ op: 'delete', path: this.path }]);
      }
    }

    class Query {
      constructor(
        readonly path: string,
        protected readonly filters: Array<[string, unknown]> = [],
        protected readonly max: number | null = null,
      ) {}
      where(field: string, op: string, value: unknown): Query {
        if (op !== '==') throw new Error(`fakeFirestore: only == filters are supported (got ${op})`);
        return new Query(this.path, [...this.filters, [field, value]], this.max);
      }
      limit(n: number): Query {
        return new Query(this.path, this.filters, n);
      }
      orderBy(): Query {
        return this;
      }
      async get(): Promise<{ empty: boolean; size: number; docs: DocSnapshot[] }> {
        await fake.tick();
        let ids = fake.list(this.path);
        ids = ids.filter((id) => {
          const data = fake.read(`${this.path}/${id}`) || {};
          return this.filters.every(([field, value]) => deepEqual(data[field], value));
        });
        if (this.max !== null) ids = ids.slice(0, this.max);
        const docs = ids.map((id) => new DocSnapshot(new DocRef(`${this.path}/${id}`), fake.read(`${this.path}/${id}`)));
        return { empty: docs.length === 0, size: docs.length, docs };
      }
    }

    class CollectionRef extends Query {
      constructor(path: string) {
        super(path);
      }
      get id(): string {
        return this.path.split('/').pop() || '';
      }
      doc(id?: string): DocRef {
        return new DocRef(`${this.path}/${id || `auto_${++fake.autoId}`}`);
      }
      async add(data: DocData): Promise<DocRef> {
        const ref = this.doc();
        await ref.create(data);
        return ref;
      }
    }

    class Transaction {
      readonly reads = new Map<string, number>();
      readonly pending: PendingWrite[] = [];
      async get(ref: DocRef): Promise<DocSnapshot> {
        if (this.pending.length > 0) {
          throw new Error('Firestore transactions require all reads to be executed before all writes.');
        }
        await fake.tick();
        if (!this.reads.has(ref.path)) this.reads.set(ref.path, fake.version(ref.path));
        return new DocSnapshot(ref, fake.read(ref.path));
      }
      set(ref: DocRef, data: DocData, options?: { merge?: boolean }): Transaction {
        this.pending.push({ op: 'set', path: ref.path, data, merge: !!options?.merge });
        return this;
      }
      update(ref: DocRef, data: DocData): Transaction {
        this.pending.push({ op: 'update', path: ref.path, data });
        return this;
      }
      create(ref: DocRef, data: DocData): Transaction {
        this.pending.push({ op: 'create', path: ref.path, data });
        return this;
      }
      delete(ref: DocRef): Transaction {
        this.pending.push({ op: 'delete', path: ref.path });
        return this;
      }
    }

    class WriteBatch {
      private readonly pending: PendingWrite[] = [];
      set(ref: DocRef, data: DocData, options?: { merge?: boolean }): WriteBatch {
        this.pending.push({ op: 'set', path: ref.path, data, merge: !!options?.merge });
        return this;
      }
      update(ref: DocRef, data: DocData): WriteBatch {
        this.pending.push({ op: 'update', path: ref.path, data });
        return this;
      }
      create(ref: DocRef, data: DocData): WriteBatch {
        this.pending.push({ op: 'create', path: ref.path, data });
        return this;
      }
      delete(ref: DocRef): WriteBatch {
        this.pending.push({ op: 'delete', path: ref.path });
        return this;
      }
      async commit(): Promise<void> {
        await fake.tick();
        fake.applyAll(this.pending);
      }
    }

    return {
      collection: (name: string) => new CollectionRef(name),
      doc: (path: string) => new DocRef(path),
      batch: () => new WriteBatch(),
      runTransaction: async <T>(fn: (tx: Transaction) => Promise<T>, options?: { maxAttempts?: number }) => {
        const maxAttempts = options?.maxAttempts ?? 5;
        for (let attempt = 1; attempt <= maxAttempts; attempt++) {
          const tx = new Transaction();
          const result = await fn(tx);
          if (fake.beforeCommit) await fake.beforeCommit(attempt);
          await fake.tick();
          const conflicted = [...tx.reads.entries()].some(([path, version]) => fake.version(path) !== version);
          if (conflicted) {
            fake.transactionConflicts++;
            continue;
          }
          fake.applyAll(tx.pending);
          return result;
        }
        throw firestoreError(ABORTED, 'ABORTED: too much contention on these documents');
      },
      FieldValue: fake.FieldValue,
    };
  }
}

/**
 * Point `admin.firestore()` at [fake] for code that reaches Firestore through
 * the firebase-admin namespace. Timestamp and FieldValue stay the real ones.
 */
export function installFakeFirestore(fake: FakeFirestore): void {
  if (!admin.apps.length) {
    admin.initializeApp({ projectId: 'fake-firestore-test' });
  }
  const db = fake.firestore();
  const firestoreFn = Object.assign(() => db, {
    Timestamp: admin.firestore.Timestamp,
    FieldValue: admin.firestore.FieldValue,
  });
  Object.defineProperty(admin, 'firestore', {
    configurable: true,
    writable: true,
    value: firestoreFn,
  });
}

/**
 * An in-memory Firestore for the functions-stays tests, close enough to the
 * Admin SDK for the code that runs night locks and money through it:
 *
 * - documents, nested collections, collectionGroup;
 * - queries with ==, !=, <, <=, >, >=, in, not-in, array-contains(-any),
 *   dotted field paths and FieldPath.documentId(), orderBy (which, like
 *   Firestore, leaves out docs without the field), limit, offset and count();
 * - runTransaction with optimistic read-set checks: every doc a transaction
 *   read and every query it ran is re-checked at commit, and a change aborts
 *   the attempt and retries it (maxAttempts, default 5), then fails with
 *   gRPC ABORTED (10), as the Admin SDK does under contention. Reads yield to
 *   the event loop, so two transactions started together really interleave;
 *   `onBeforeCommit` lets a test line them up exactly;
 * - create() failing with ALREADY_EXISTS (6), in a transaction at commit;
 * - batch(), a small bulkWriter() shim, FieldValue serverTimestamp, delete,
 *   increment, arrayUnion and arrayRemove;
 * - a write log, and an isolation check that no stay code touched the
 *   storage side (tenants, units, ledgers, payments, invoices, …).
 */
import { FieldValue, Firestore, Timestamp } from 'firebase-admin/firestore';

type Data = Record<string, unknown>;

interface StoredDoc {
  data: Data;
  version: number;
  createTime: Timestamp;
  updateTime: Timestamp;
}

export interface WriteLogEntry {
  op: 'set' | 'update' | 'create' | 'delete';
  path: string;
  via: 'direct' | 'transaction' | 'batch' | 'bulk';
}

/** The storage collections stays code must never touch (spec §0, §10.2). */
export const FORBIDDEN_COLLECTIONS = [
  'tenants',
  'units',
  'ledgers',
  'payments',
  'invoices',
  'reservations',
  'publicReservations',
  'publicPaymentLinks',
];

export class FakeFirestoreError extends Error {
  constructor(
    readonly code: number,
    message: string,
  ) {
    super(message);
    this.name = 'FakeFirestoreError';
  }
}

const ABORTED = 10;
const ALREADY_EXISTS = 6;
const NOT_FOUND = 5;
const INVALID_ARGUMENT = 3;

function tick(): Promise<void> {
  return new Promise((resolve) => setImmediate(resolve));
}

function isTimestamp(v: unknown): v is Timestamp {
  return v instanceof Timestamp;
}

function isPlainObject(v: unknown): v is Data {
  return typeof v === 'object' && v !== null && !Array.isArray(v) && !isTimestamp(v) && !(v instanceof FieldValue);
}

function clone<T>(v: T): T {
  if (Array.isArray(v)) return v.map(clone) as unknown as T;
  if (isPlainObject(v)) {
    const out: Data = {};
    for (const [k, val] of Object.entries(v)) out[k] = clone(val);
    return out as T;
  }
  return v;
}

function deepEqual(a: unknown, b: unknown): boolean {
  if (isTimestamp(a) && isTimestamp(b)) return a.isEqual(b);
  if (Array.isArray(a) && Array.isArray(b)) return a.length === b.length && a.every((v, i) => deepEqual(v, b[i]));
  if (isPlainObject(a) && isPlainObject(b)) {
    const ka = Object.keys(a).sort();
    const kb = Object.keys(b).sort();
    return deepEqual(ka, kb) && ka.every((k) => deepEqual(a[k], b[k]));
  }
  return a === b;
}

function fieldName(field: unknown): string {
  if (typeof field === 'string') return field;
  const f = field as { formattedName?: string; toString(): string };
  return f.formattedName ?? f.toString();
}

function getField(data: Data, path: string): { exists: boolean; value: unknown } {
  let cur: unknown = data;
  for (const part of path.split('.')) {
    if (!isPlainObject(cur) || !(part in cur)) return { exists: false, value: undefined };
    cur = cur[part];
  }
  return { exists: true, value: cur };
}

function typeRank(v: unknown): number {
  if (v === null) return 0;
  if (typeof v === 'boolean') return 1;
  if (typeof v === 'number') return 2;
  if (isTimestamp(v)) return 3;
  if (typeof v === 'string') return 4;
  if (Array.isArray(v)) return 8;
  return 9;
}

function compareValues(a: unknown, b: unknown): number {
  const ra = typeRank(a);
  const rb = typeRank(b);
  if (ra !== rb) return ra - rb;
  if (typeof a === 'number' && typeof b === 'number') return a - b;
  if (typeof a === 'boolean' && typeof b === 'boolean') return Number(a) - Number(b);
  if (isTimestamp(a) && isTimestamp(b)) return a.toMillis() - b.toMillis();
  if (typeof a === 'string' && typeof b === 'string') return a < b ? -1 : a > b ? 1 : 0;
  if (Array.isArray(a) && Array.isArray(b)) {
    for (let i = 0; i < Math.min(a.length, b.length); i++) {
      const c = compareValues(a[i], b[i]);
      if (c !== 0) return c;
    }
    return a.length - b.length;
  }
  return 0;
}

function segments(path: string): string[] {
  return path.split('/').filter(Boolean);
}

/** The collection names along a document or collection path. */
export function collectionSegments(path: string): string[] {
  return segments(path).filter((_, i) => i % 2 === 0);
}

function randomDocId(): string {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  let id = '';
  for (let i = 0; i < 20; i++) id += chars[Math.floor(Math.random() * chars.length)];
  return id;
}

type Filter = { field: string; op: string; value: unknown };
type Order = { field: string; dir: 'asc' | 'desc' };

interface QuerySpec {
  collectionPath: string | null;
  collectionGroup: string | null;
  filters: Filter[];
  orders: Order[];
  limit: number | null;
  offset: number;
}

export interface CommitInfo {
  txId: number;
  attempt: number;
}

export class FakeFirestore {
  private readonly docs = new Map<string, StoredDoc>();
  private version = 0;
  private txCounter = 0;
  readonly writeLog: WriteLogEntry[] = [];
  /** Awaited before each transaction commit; lets tests line transactions up. */
  onBeforeCommit: ((info: CommitInfo) => Promise<void>) | null = null;
  /** How many transaction attempts were retried because of contention. */
  retries = 0;
  /** The clock serverTimestamp() reads. */
  clock: () => number = () => Date.now();
  /** Makes reads of matching doc paths throw, to test fail-closed paths. */
  failReads: ((path: string) => boolean) | null = null;

  seed(path: string, data: Data): void {
    this.applyWrite({ op: 'set', path, data }, 'direct');
    this.writeLog.pop();
  }

  read(path: string): Data | undefined {
    const d = this.docs.get(path);
    return d ? clone(d.data) : undefined;
  }

  has(path: string): boolean {
    return this.docs.has(path);
  }

  paths(prefix = ''): string[] {
    return [...this.docs.keys()].filter((p) => p.startsWith(prefix)).sort();
  }

  /** Documents directly in a collection, e.g. 'facilities/f1/stays'. */
  list(collectionPath: string): { id: string; data: Data }[] {
    const depth = segments(collectionPath).length + 1;
    return this.paths(`${collectionPath}/`)
      .filter((p) => segments(p).length === depth)
      .map((p) => ({ id: segments(p)[depth - 1], data: clone(this.docs.get(p)!.data) }));
  }

  writesTo(collectionName: string): WriteLogEntry[] {
    return this.writeLog.filter((w) => collectionSegments(w.path).includes(collectionName));
  }

  /** Every stored doc or logged write under a storage-side collection. */
  forbiddenPaths(): string[] {
    const hits = new Set<string>();
    for (const p of [...this.docs.keys(), ...this.writeLog.map((w) => w.path)]) {
      if (collectionSegments(p).some((c) => FORBIDDEN_COLLECTIONS.includes(c))) hits.add(p);
    }
    return [...hits].sort();
  }

  /** Throws when stay code left anything under tenants, units, ledgers, payments, invoices, … */
  assertIsolation(): void {
    const hits = this.forbiddenPaths();
    if (hits.length > 0) {
      throw new Error(`Stays wrote to storage-side collections: ${hits.join(', ')}`);
    }
  }

  firestore(): Firestore {
    return new FakeDb(this) as unknown as Firestore;
  }

  // --- internals ---------------------------------------------------------

  /** @internal */
  docVersion(path: string): number {
    return this.docs.get(path)?.version ?? 0;
  }

  /** @internal */
  snapshot(path: string, db: FakeDb): FakeDocSnapshot {
    if (this.failReads?.(path)) throw new FakeFirestoreError(14, `UNAVAILABLE: read of ${path} failed`);
    const d = this.docs.get(path);
    return new FakeDocSnapshot(new FakeDocRef(db, path), d ? clone(d.data) : undefined, d);
  }

  /** @internal */
  runQuery(spec: QuerySpec, db: FakeDb): FakeDocSnapshot[] {
    let rows: { path: string; doc: StoredDoc }[] = [];
    for (const [path, doc] of this.docs) {
      const segs = segments(path);
      const parent = segs.slice(0, -1).join('/');
      if (spec.collectionPath !== null && parent !== spec.collectionPath) continue;
      if (spec.collectionGroup !== null && segs[segs.length - 2] !== spec.collectionGroup) continue;
      rows.push({ path, doc });
    }
    rows = rows.filter(({ path, doc }) => spec.filters.every((f) => matches(path, doc.data, f)));
    for (const o of spec.orders) {
      // Firestore leaves out docs that lack an orderBy field.
      rows = rows.filter(({ doc }) => o.field === '__name__' || getField(doc.data, o.field).exists);
    }
    rows.sort((a, b) => {
      for (const o of spec.orders) {
        const va = o.field === '__name__' ? a.path : getField(a.doc.data, o.field).value;
        const vb = o.field === '__name__' ? b.path : getField(b.doc.data, o.field).value;
        const c = compareValues(va, vb);
        if (c !== 0) return o.dir === 'desc' ? -c : c;
      }
      return a.path < b.path ? -1 : a.path > b.path ? 1 : 0;
    });
    rows = rows.slice(spec.offset);
    if (spec.limit !== null) rows = rows.slice(0, spec.limit);
    return rows.map(({ path, doc }) => new FakeDocSnapshot(new FakeDocRef(db, path), clone(doc.data), doc));
  }

  /** @internal Applies one write; throws ALREADY_EXISTS / NOT_FOUND like Firestore. */
  applyWrite(w: PendingWrite, via: WriteLogEntry['via']): void {
    const existing = this.docs.get(w.path);
    const now = Timestamp.fromMillis(this.clock());
    if (w.op === 'create' && existing) {
      throw new FakeFirestoreError(ALREADY_EXISTS, `ALREADY_EXISTS: ${w.path}`);
    }
    if (w.op === 'update' && !existing) {
      throw new FakeFirestoreError(NOT_FOUND, `NOT_FOUND: ${w.path}`);
    }
    this.writeLog.push({ op: w.op, path: w.path, via });
    if (w.op === 'delete') {
      this.docs.delete(w.path);
      this.version++;
      return;
    }
    let next: Data;
    if (w.op === 'update') {
      next = clone(existing!.data);
      for (const [key, value] of Object.entries(w.data ?? {})) setPath(next, key.split('.'), value, now);
    } else if (w.op === 'set' && w.merge && existing) {
      next = clone(existing.data);
      mergeInto(next, w.data ?? {}, now);
    } else {
      next = {};
      mergeInto(next, w.data ?? {}, now);
    }
    this.version++;
    this.docs.set(w.path, {
      data: next,
      version: this.version,
      createTime: existing?.createTime ?? now,
      updateTime: now,
    });
  }

  /** @internal Applies writes all-or-nothing, in order. */
  applyAtomically(writes: PendingWrite[], via: WriteLogEntry['via']): void {
    const exists = new Map<string, boolean>();
    for (const w of writes) {
      const present = exists.has(w.path) ? exists.get(w.path)! : this.docs.has(w.path);
      if (w.op === 'create' && present) throw new FakeFirestoreError(ALREADY_EXISTS, `ALREADY_EXISTS: ${w.path}`);
      if (w.op === 'update' && !present) throw new FakeFirestoreError(NOT_FOUND, `NOT_FOUND: ${w.path}`);
      exists.set(w.path, w.op !== 'delete');
    }
    for (const w of writes) this.applyWrite(w, via);
  }

  /** @internal */
  nextTxId(): number {
    return ++this.txCounter;
  }
}

function applyTransform(current: unknown, value: unknown, now: Timestamp): { remove: boolean; value: unknown } {
  if (value instanceof FieldValue) {
    if (value.isEqual(FieldValue.serverTimestamp())) return { remove: false, value: now };
    if (value.isEqual(FieldValue.delete())) return { remove: true, value: undefined };
    const name = (value as { constructor: { name: string } }).constructor.name;
    if (name === 'NumericIncrementTransform') {
      const operand = (value as unknown as { operand: number }).operand;
      return { remove: false, value: (typeof current === 'number' ? current : 0) + operand };
    }
    if (name === 'ArrayUnionTransform') {
      const elements = (value as unknown as { elements: unknown[] }).elements;
      const base = Array.isArray(current) ? [...current] : [];
      for (const e of elements) if (!base.some((b) => deepEqual(b, e))) base.push(clone(e));
      return { remove: false, value: base };
    }
    if (name === 'ArrayRemoveTransform') {
      const elements = (value as unknown as { elements: unknown[] }).elements;
      const base = Array.isArray(current) ? current : [];
      return { remove: false, value: base.filter((b) => !elements.some((e) => deepEqual(b, e))) };
    }
    throw new FakeFirestoreError(INVALID_ARGUMENT, `The fake does not support ${name}`);
  }
  if (value === undefined) {
    throw new FakeFirestoreError(INVALID_ARGUMENT, 'Cannot use "undefined" as a Firestore value');
  }
  if (isPlainObject(value)) {
    const out: Data = {};
    mergeInto(out, value, now);
    return { remove: false, value: out };
  }
  return { remove: false, value: clone(value) };
}

function mergeInto(target: Data, source: Data, now: Timestamp): void {
  for (const [key, value] of Object.entries(source)) {
    if (isPlainObject(value) && isPlainObject(target[key])) {
      mergeInto(target[key] as Data, value, now);
      continue;
    }
    const t = applyTransform(target[key], value, now);
    if (t.remove) delete target[key];
    else target[key] = t.value;
  }
}

function setPath(target: Data, parts: string[], value: unknown, now: Timestamp): void {
  const [head, ...rest] = parts;
  if (rest.length === 0) {
    const t = applyTransform(target[head], value, now);
    if (t.remove) delete target[head];
    else target[head] = t.value;
    return;
  }
  if (!isPlainObject(target[head])) target[head] = {};
  setPath(target[head] as Data, rest, value, now);
}

function matches(path: string, data: Data, f: Filter): boolean {
  if (f.field === '__name__') {
    // FieldPath.documentId(): compared by id (or full path), == and in only.
    const id = segments(path).slice(-1)[0];
    const hit = (candidate: unknown) => candidate === id || candidate === path;
    if (f.op === '==') return hit(f.value);
    if (f.op === 'in') return Array.isArray(f.value) && f.value.some(hit);
    throw new FakeFirestoreError(INVALID_ARGUMENT, `The fake supports only == and in on the document id, not ${f.op}`);
  }
  const found = getField(data, f.field);
  const value = found.value;
  switch (f.op) {
    case '==':
      return found.exists && deepEqual(value, f.value);
    case '!=':
      return found.exists && value !== null && !deepEqual(value, f.value);
    case 'in':
      return found.exists && Array.isArray(f.value) && f.value.some((v) => deepEqual(value, v));
    case 'not-in':
      return found.exists && value !== null && Array.isArray(f.value) && !f.value.some((v) => deepEqual(value, v));
    case 'array-contains':
      return Array.isArray(value) && value.some((v) => deepEqual(v, f.value));
    case 'array-contains-any':
      return Array.isArray(value) && Array.isArray(f.value) && value.some((v) => (f.value as unknown[]).some((t) => deepEqual(v, t)));
    case '<':
    case '<=':
    case '>':
    case '>=': {
      // Range filters match only values of the same type, as in Firestore.
      if (!found.exists || typeRank(value) !== typeRank(f.value)) return false;
      const c = compareValues(value, f.value);
      return f.op === '<' ? c < 0 : f.op === '<=' ? c <= 0 : f.op === '>' ? c > 0 : c >= 0;
    }
    default:
      throw new FakeFirestoreError(INVALID_ARGUMENT, `The fake does not support the ${f.op} filter`);
  }
}

interface PendingWrite {
  op: 'set' | 'update' | 'create' | 'delete';
  path: string;
  data?: Data;
  merge?: boolean;
}

class FakeDocSnapshot {
  constructor(
    readonly ref: FakeDocRef,
    private readonly value: Data | undefined,
    private readonly stored?: StoredDoc,
  ) {}

  get id(): string {
    return this.ref.id;
  }

  get exists(): boolean {
    return this.value !== undefined;
  }

  get createTime(): Timestamp | undefined {
    return this.stored?.createTime;
  }

  get updateTime(): Timestamp | undefined {
    return this.stored?.updateTime;
  }

  get readTime(): Timestamp {
    return Timestamp.now();
  }

  data(): Data | undefined {
    return this.value === undefined ? undefined : clone(this.value);
  }

  get(field: unknown): unknown {
    if (this.value === undefined) return undefined;
    const found = getField(this.value, fieldName(field));
    return found.exists ? clone(found.value) : undefined;
  }
}

class FakeQuerySnapshot {
  constructor(readonly docs: FakeDocSnapshot[]) {}

  get empty(): boolean {
    return this.docs.length === 0;
  }

  get size(): number {
    return this.docs.length;
  }

  forEach(fn: (doc: FakeDocSnapshot) => void): void {
    this.docs.forEach(fn);
  }
}

class FakeQuery {
  constructor(
    protected readonly db: FakeDb,
    readonly spec: QuerySpec,
  ) {}

  private with(patch: Partial<QuerySpec>): FakeQuery {
    return new FakeQuery(this.db, { ...this.spec, ...patch });
  }

  where(field: unknown, op: string, value: unknown): FakeQuery {
    return this.with({ filters: [...this.spec.filters, { field: fieldName(field), op, value }] });
  }

  orderBy(field: unknown, dir: 'asc' | 'desc' = 'asc'): FakeQuery {
    return this.with({ orders: [...this.spec.orders, { field: fieldName(field), dir }] });
  }

  limit(n: number): FakeQuery {
    return this.with({ limit: n });
  }

  offset(n: number): FakeQuery {
    return this.with({ offset: n });
  }

  select(): FakeQuery {
    return this;
  }

  async get(): Promise<FakeQuerySnapshot> {
    await tick();
    return new FakeQuerySnapshot(this.db.fake.runQuery(this.spec, this.db));
  }

  count(): { get(): Promise<{ data(): { count: number } }> } {
    return {
      get: async () => {
        await tick();
        const count = this.db.fake.runQuery({ ...this.spec, limit: null, offset: 0 }, this.db).length;
        return { data: () => ({ count }) };
      },
    };
  }
}

class FakeCollectionRef extends FakeQuery {
  constructor(
    db: FakeDb,
    readonly path: string,
  ) {
    super(db, { collectionPath: path, collectionGroup: null, filters: [], orders: [], limit: null, offset: 0 });
  }

  get id(): string {
    return segments(this.path).slice(-1)[0];
  }

  get parent(): FakeDocRef | null {
    const segs = segments(this.path);
    return segs.length > 1 ? new FakeDocRef(this.db, segs.slice(0, -1).join('/')) : null;
  }

  doc(id?: string): FakeDocRef {
    return new FakeDocRef(this.db, `${this.path}/${id ?? randomDocId()}`);
  }

  async add(data: Data): Promise<FakeDocRef> {
    const ref = this.doc();
    await ref.set(data);
    return ref;
  }
}

class FakeDocRef {
  constructor(
    private readonly db: FakeDb,
    readonly path: string,
  ) {
    if (segments(path).length % 2 !== 0) {
      throw new FakeFirestoreError(INVALID_ARGUMENT, `Not a document path: ${path}`);
    }
  }

  get id(): string {
    return segments(this.path).slice(-1)[0];
  }

  get parent(): FakeCollectionRef {
    return new FakeCollectionRef(this.db, segments(this.path).slice(0, -1).join('/'));
  }

  get firestore(): FakeDb {
    return this.db;
  }

  collection(name: string): FakeCollectionRef {
    return new FakeCollectionRef(this.db, `${this.path}/${name}`);
  }

  isEqual(other: FakeDocRef): boolean {
    return other.path === this.path;
  }

  async get(): Promise<FakeDocSnapshot> {
    await tick();
    return this.db.fake.snapshot(this.path, this.db);
  }

  async set(data: Data, options?: { merge?: boolean }): Promise<void> {
    await tick();
    this.db.fake.applyWrite({ op: 'set', path: this.path, data, merge: options?.merge === true }, 'direct');
  }

  async update(data: Data): Promise<void> {
    await tick();
    this.db.fake.applyWrite({ op: 'update', path: this.path, data }, 'direct');
  }

  async create(data: Data): Promise<void> {
    await tick();
    this.db.fake.applyWrite({ op: 'create', path: this.path, data }, 'direct');
  }

  async delete(): Promise<void> {
    await tick();
    this.db.fake.applyWrite({ op: 'delete', path: this.path }, 'direct');
  }
}

class FakeTransaction {
  readonly readDocs = new Map<string, number>();
  readonly readQueries: { spec: QuerySpec; signature: string }[] = [];
  readonly writes: PendingWrite[] = [];

  constructor(private readonly db: FakeDb) {}

  private assertNoWritesYet(): void {
    if (this.writes.length > 0) {
      throw new FakeFirestoreError(INVALID_ARGUMENT, 'Firestore transactions require all reads to be executed before all writes.');
    }
  }

  private noteDoc(path: string): void {
    if (!this.readDocs.has(path)) this.readDocs.set(path, this.db.fake.docVersion(path));
  }

  async get(target: FakeDocRef | FakeQuery): Promise<FakeDocSnapshot | FakeQuerySnapshot> {
    this.assertNoWritesYet();
    await tick();
    if (target instanceof FakeDocRef) {
      this.noteDoc(target.path);
      return this.db.fake.snapshot(target.path, this.db);
    }
    const docs = this.db.fake.runQuery(target.spec, this.db);
    this.readQueries.push({ spec: target.spec, signature: this.signature(docs) });
    for (const d of docs) this.noteDoc(d.ref.path);
    return new FakeQuerySnapshot(docs);
  }

  async getAll(...refs: FakeDocRef[]): Promise<FakeDocSnapshot[]> {
    this.assertNoWritesYet();
    await tick();
    return refs.map((r) => {
      this.noteDoc(r.path);
      return this.db.fake.snapshot(r.path, this.db);
    });
  }

  signature(docs: FakeDocSnapshot[]): string {
    return docs.map((d) => `${d.ref.path}@${this.db.fake.docVersion(d.ref.path)}`).join(',');
  }

  set(ref: FakeDocRef, data: Data, options?: { merge?: boolean }): FakeTransaction {
    this.writes.push({ op: 'set', path: ref.path, data: clone(data), merge: options?.merge === true });
    return this;
  }

  update(ref: FakeDocRef, data: Data): FakeTransaction {
    this.writes.push({ op: 'update', path: ref.path, data: clone(data) });
    return this;
  }

  create(ref: FakeDocRef, data: Data): FakeTransaction {
    this.writes.push({ op: 'create', path: ref.path, data: clone(data) });
    return this;
  }

  delete(ref: FakeDocRef): FakeTransaction {
    this.writes.push({ op: 'delete', path: ref.path });
    return this;
  }

  /** Whether anything this transaction read has changed since. */
  isStale(): boolean {
    for (const [path, version] of this.readDocs) {
      if (this.db.fake.docVersion(path) !== version) return true;
    }
    for (const q of this.readQueries) {
      if (this.signature(this.db.fake.runQuery(q.spec, this.db)) !== q.signature) return true;
    }
    return false;
  }
}

class FakeWriteBatch {
  private readonly writes: PendingWrite[] = [];

  constructor(private readonly db: FakeDb) {}

  set(ref: FakeDocRef, data: Data, options?: { merge?: boolean }): FakeWriteBatch {
    this.writes.push({ op: 'set', path: ref.path, data: clone(data), merge: options?.merge === true });
    return this;
  }

  update(ref: FakeDocRef, data: Data): FakeWriteBatch {
    this.writes.push({ op: 'update', path: ref.path, data: clone(data) });
    return this;
  }

  create(ref: FakeDocRef, data: Data): FakeWriteBatch {
    this.writes.push({ op: 'create', path: ref.path, data: clone(data) });
    return this;
  }

  delete(ref: FakeDocRef): FakeWriteBatch {
    this.writes.push({ op: 'delete', path: ref.path });
    return this;
  }

  async commit(): Promise<void> {
    await tick();
    this.db.fake.applyAtomically(this.writes, 'batch');
  }
}

class FakeBulkWriter {
  private errorHandler: ((error: unknown) => boolean) | null = null;
  private readonly pending: Promise<unknown>[] = [];

  constructor(private readonly db: FakeDb) {}

  private write(w: PendingWrite): Promise<void> {
    const p = (async () => {
      await tick();
      try {
        this.db.fake.applyWrite(w, 'bulk');
      } catch (error) {
        this.errorHandler?.(error);
        throw error;
      }
    })();
    this.pending.push(p.catch(() => undefined));
    return p;
  }

  create(ref: FakeDocRef, data: Data): Promise<void> {
    return this.write({ op: 'create', path: ref.path, data: clone(data) });
  }

  set(ref: FakeDocRef, data: Data, options?: { merge?: boolean }): Promise<void> {
    return this.write({ op: 'set', path: ref.path, data: clone(data), merge: options?.merge === true });
  }

  update(ref: FakeDocRef, data: Data): Promise<void> {
    return this.write({ op: 'update', path: ref.path, data: clone(data) });
  }

  delete(ref: FakeDocRef): Promise<void> {
    return this.write({ op: 'delete', path: ref.path });
  }

  onWriteError(handler: (error: unknown) => boolean): void {
    this.errorHandler = handler;
  }

  onWriteResult(): void {}

  async flush(): Promise<void> {
    await Promise.all(this.pending);
  }

  async close(): Promise<void> {
    await this.flush();
  }
}

class FakeDb {
  constructor(readonly fake: FakeFirestore) {}

  collection(path: string): FakeCollectionRef {
    return new FakeCollectionRef(this, path);
  }

  doc(path: string): FakeDocRef {
    return new FakeDocRef(this, path);
  }

  collectionGroup(id: string): FakeQuery {
    return new FakeQuery(this, { collectionPath: null, collectionGroup: id, filters: [], orders: [], limit: null, offset: 0 });
  }

  async getAll(...refs: FakeDocRef[]): Promise<FakeDocSnapshot[]> {
    await tick();
    return refs.map((r) => this.fake.snapshot(r.path, this));
  }

  batch(): FakeWriteBatch {
    return new FakeWriteBatch(this);
  }

  bulkWriter(): FakeBulkWriter {
    return new FakeBulkWriter(this);
  }

  async runTransaction<T>(fn: (tx: FakeTransaction) => Promise<T>, options?: { maxAttempts?: number }): Promise<T> {
    const maxAttempts = options?.maxAttempts ?? 5;
    const txId = this.fake.nextTxId();
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      const tx = new FakeTransaction(this);
      const result = await fn(tx);
      if (this.fake.onBeforeCommit) await this.fake.onBeforeCommit({ txId, attempt });
      // The check and the commit run without yielding, so they are atomic
      // with respect to every other transaction.
      if (tx.isStale()) {
        this.fake.retries++;
        await tick();
        continue;
      }
      this.fake.applyAtomically(tx.writes, 'transaction');
      return result;
    }
    throw new FakeFirestoreError(ABORTED, 'ABORTED: Too much contention on these documents. Please try again.');
  }
}

/** A barrier for onBeforeCommit: the first `count` first-attempt commits wait for each other. */
export function commitBarrier(count: number): (info: CommitInfo) => Promise<void> {
  let arrived = 0;
  let release: () => void = () => undefined;
  const all = new Promise<void>((resolve) => {
    release = resolve;
  });
  return async ({ attempt }) => {
    if (attempt !== 1) return;
    arrived++;
    if (arrived >= count) release();
    await all;
  };
}

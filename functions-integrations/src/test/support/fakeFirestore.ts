/**
 * In-memory stand-in for the slice of the Admin Firestore API the platform checkout
 * and subscription webhook code uses: doc get/update/set, equality `where` queries,
 * and transactions. Server timestamps become a fixed fake Timestamp; FieldValue.delete
 * removes the field. Not a general emulator.
 */
import * as admin from 'firebase-admin';

type Data = Record<string, unknown>;

export const FAKE_SERVER_TIME_MS = Date.parse('2026-10-01T12:00:00Z');

function resolveValue(value: unknown, existing: unknown): unknown | typeof DELETE {
  if (value instanceof admin.firestore.FieldValue) {
    if (value.isEqual(admin.firestore.FieldValue.serverTimestamp())) {
      return admin.firestore.Timestamp.fromMillis(FAKE_SERVER_TIME_MS);
    }
    if (value.isEqual(admin.firestore.FieldValue.delete())) return DELETE;
    const elements = (value as unknown as { elements?: unknown[] }).elements;
    if (Array.isArray(elements)) {
      const base = Array.isArray(existing) ? [...existing] : [];
      for (const e of elements) if (!base.includes(e)) base.push(e);
      return base;
    }
    throw new Error('fakeFirestore: unsupported FieldValue');
  }
  return value;
}

const DELETE = Symbol('delete');

function applyFields(target: Data, fields: Data): Data {
  const out = { ...target };
  for (const [k, v] of Object.entries(fields)) {
    const resolved = resolveValue(v, out[k]);
    if (resolved === DELETE) delete out[k];
    else out[k] = resolved;
  }
  return out;
}

class FakeSnapshot {
  constructor(
    readonly id: string,
    readonly ref: FakeDocRef,
    private readonly value: Data | undefined,
  ) {}
  get exists(): boolean {
    return this.value !== undefined;
  }
  data(): Data | undefined {
    return this.value === undefined ? undefined : { ...this.value };
  }
  get(field: string): unknown {
    return this.value?.[field];
  }
}

class FakeDocRef {
  constructor(
    readonly firestore: FakeFirestore,
    readonly path: string,
    readonly id: string,
  ) {}
  async get(): Promise<FakeSnapshot> {
    return new FakeSnapshot(this.id, this, this.firestore.read(this.path));
  }
  async update(fields: Data): Promise<void> {
    const current = this.firestore.read(this.path);
    if (current === undefined) throw Object.assign(new Error(`NOT_FOUND: ${this.path}`), { code: 5 });
    this.firestore.write(this.path, applyFields(current, fields));
  }
  async set(fields: Data, options?: { merge?: boolean }): Promise<void> {
    const base = options?.merge ? this.firestore.read(this.path) ?? {} : {};
    this.firestore.write(this.path, applyFields(base, fields));
  }
}

class FakeQuery {
  constructor(
    private readonly firestore: FakeFirestore,
    private readonly collection: string,
    private readonly filters: Array<[string, unknown]>,
    private readonly max: number | null = null,
  ) {}
  where(field: string, op: string, value: unknown): FakeQuery {
    if (op !== '==') throw new Error(`fakeFirestore: unsupported operator ${op}`);
    return new FakeQuery(this.firestore, this.collection, [...this.filters, [field, value]], this.max);
  }
  limit(n: number): FakeQuery {
    return new FakeQuery(this.firestore, this.collection, this.filters, n);
  }
  async get() {
    const matching = this.firestore
      .list(this.collection)
      .filter(([, data]) => this.filters.every(([f, v]) => data[f] === v))
      .map(([id, data]) => new FakeSnapshot(id, new FakeDocRef(this.firestore, `${this.collection}/${id}`, id), data));
    const docs = this.max === null ? matching : matching.slice(0, this.max);
    return { docs, empty: docs.length === 0, size: docs.length };
  }
}

class FakeCollection extends FakeQuery {
  constructor(
    private readonly fs: FakeFirestore,
    private readonly name: string,
  ) {
    super(fs, name, []);
  }
  doc(id: string): FakeDocRef {
    return new FakeDocRef(this.fs, `${this.name}/${id}`, id);
  }
}

export class FakeFirestore {
  private readonly docs = new Map<string, Data>();

  constructor(seed: Record<string, Data> = {}) {
    for (const [path, data] of Object.entries(seed)) this.docs.set(path, { ...data });
  }

  read(path: string): Data | undefined {
    const d = this.docs.get(path);
    return d === undefined ? undefined : { ...d };
  }
  write(path: string, data: Data): void {
    this.docs.set(path, data);
  }
  list(collection: string): Array<[string, Data]> {
    const prefix = `${collection}/`;
    return [...this.docs.entries()]
      .filter(([p]) => p.startsWith(prefix) && !p.slice(prefix.length).includes('/'))
      .map(([p, d]) => [p.slice(prefix.length), { ...d }]);
  }

  collection(name: string): FakeCollection {
    return new FakeCollection(this, name);
  }

  async runTransaction<T>(fn: (tx: {
    get: (ref: FakeDocRef) => Promise<FakeSnapshot>;
    update: (ref: FakeDocRef, fields: Data) => void;
    set: (ref: FakeDocRef, fields: Data, options?: { merge?: boolean }) => void;
  }) => Promise<T>): Promise<T> {
    const pending: Array<() => Promise<void>> = [];
    const result = await fn({
      get: (ref) => ref.get(),
      update: (ref, fields) => void pending.push(() => ref.update(fields)),
      set: (ref, fields, options) => void pending.push(() => ref.set(fields, options)),
    });
    for (const op of pending) await op();
    return result;
  }

  /** Typed as the Admin Firestore for the code under test. */
  asFirestore(): FirebaseFirestore.Firestore {
    return this as unknown as FirebaseFirestore.Firestore;
  }
}

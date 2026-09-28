// A small in-memory stand-in for the parts of the Admin SDK Firestore that
// processDelinquencyForFacility uses: doc get/update, collection add, and
// where('==' | '>=') queries. Sentinels from FieldValue.serverTimestamp() and
// FieldValue.delete() are applied the way Firestore applies them.
import * as admin from 'firebase-admin';

type Data = Record<string, unknown>;

const SERVER_TIMESTAMP = admin.firestore.FieldValue.serverTimestamp();
const DELETE = admin.firestore.FieldValue.delete();

function isSentinel(value: unknown, sentinel: admin.firestore.FieldValue): boolean {
  return value instanceof admin.firestore.FieldValue && value.isEqual(sentinel);
}

function comparable(value: unknown): unknown {
  if (value instanceof admin.firestore.Timestamp) return value.toMillis();
  if (value instanceof Date) return value.getTime();
  return value;
}

export class FakeFirestore {
  /** Collection path -> doc id -> data. */
  readonly store = new Map<string, Map<string, Data>>();
  private nextId = 1;

  constructor(private readonly now: () => Date) {}

  collection(path: string): FakeCollection {
    return new FakeCollection(this, path, []);
  }

  /** Every doc in a collection, by id. */
  docs(path: string): Map<string, Data> {
    let docs = this.store.get(path);
    if (!docs) {
      docs = new Map();
      this.store.set(path, docs);
    }
    return docs;
  }

  seed(path: string, id: string, data: Data): void {
    this.docs(path).set(id, { ...data });
  }

  newId(): string {
    return `auto${this.nextId++}`;
  }

  /** Applies write sentinels as Firestore would. */
  resolve(target: Data, update: Data): Data {
    const out = { ...target };
    for (const [key, value] of Object.entries(update)) {
      if (isSentinel(value, DELETE)) {
        delete out[key];
      } else if (isSentinel(value, SERVER_TIMESTAMP)) {
        out[key] = admin.firestore.Timestamp.fromDate(this.now());
      } else {
        out[key] = value;
      }
    }
    return out;
  }

  asFirestore(): admin.firestore.Firestore {
    return this as unknown as admin.firestore.Firestore;
  }
}

class FakeDocRef {
  constructor(
    private readonly db: FakeFirestore,
    readonly path: string,
    readonly id: string,
  ) {}

  collection(name: string): FakeCollection {
    return new FakeCollection(this.db, `${this.path}/${this.id}/${name}`, []);
  }

  async get(): Promise<FakeDocSnapshot> {
    return new FakeDocSnapshot(this, this.db.docs(this.path).get(this.id));
  }

  async update(data: Data): Promise<void> {
    const docs = this.db.docs(this.path);
    const current = docs.get(this.id);
    if (!current) throw new Error(`No document to update: ${this.path}/${this.id}`);
    docs.set(this.id, this.db.resolve(current, data));
  }

  async set(data: Data): Promise<void> {
    this.db.docs(this.path).set(this.id, this.db.resolve({}, data));
  }
}

class FakeDocSnapshot {
  constructor(
    readonly ref: FakeDocRef,
    private readonly stored: Data | undefined,
  ) {}

  get id(): string {
    return this.ref.id;
  }

  get exists(): boolean {
    return this.stored !== undefined;
  }

  data(): Data | undefined {
    return this.stored === undefined ? undefined : { ...this.stored };
  }
}

type Filter = { field: string; op: string; value: unknown };

class FakeCollection {
  constructor(
    private readonly db: FakeFirestore,
    private readonly path: string,
    private readonly filters: Filter[],
  ) {}

  doc(id: string): FakeDocRef {
    return new FakeDocRef(this.db, this.path, id);
  }

  where(field: string, op: string, value: unknown): FakeCollection {
    if (op !== '==' && op !== '>=') throw new Error(`Fake does not support ${op}`);
    return new FakeCollection(this.db, this.path, [...this.filters, { field, op, value }]);
  }

  async add(data: Data): Promise<FakeDocRef> {
    const ref = this.doc(this.db.newId());
    await ref.set(data);
    return ref;
  }

  async get(): Promise<{ empty: boolean; size: number; docs: FakeDocSnapshot[] }> {
    const docs: FakeDocSnapshot[] = [];
    for (const [id, data] of this.db.docs(this.path)) {
      const matches = this.filters.every(({ field, op, value }) => {
        const actual = comparable(data[field]);
        const wanted = comparable(value);
        if (op === '==') return actual === wanted;
        return actual !== undefined && (actual as number) >= (wanted as number);
      });
      if (matches) docs.push(new FakeDocSnapshot(this.doc(id), data));
    }
    return { empty: docs.length === 0, size: docs.length, docs };
  }
}

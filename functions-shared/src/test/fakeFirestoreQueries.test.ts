import test from 'node:test';
import assert from 'node:assert/strict';
import { Timestamp, type Query } from 'firebase-admin/firestore';
import { FakeFirestore } from '../testing/fakeFirestore';

// The fake backs tests that prove autopay leaves disputes out, the portal
// balance and the pre-deploy check, so its queries have to behave like
// Firestore's.
test('fake Firestore: collection-group, range, in and array-contains queries', async () => {
  const fake = new FakeFirestore();
  fake.seed('facilities/f1/tenants/t1/paymentMethods/pm1', { facilityId: 'f1', autopayEnabled: true });
  fake.seed('facilities/f1/tenants/t2/paymentMethods/pm2', { facilityId: 'f1', autopayEnabled: false });
  fake.seed('facilities/f2/tenants/t3/paymentMethods/pm3', { facilityId: 'f2', autopayEnabled: true });
  fake.seed('facilities/f1/ledgers/a', { amount: 5, at: Timestamp.fromMillis(1000), ids: ['x', 'y'], m: { d: 'du' } });
  fake.seed('facilities/f1/ledgers/b', { amount: 15, at: Timestamp.fromMillis(3000), ids: ['z'] });
  const db = fake.firestore();

  const armed = await db
    .collectionGroup('paymentMethods')
    .where('facilityId', '==', 'f1')
    .where('autopayEnabled', '==', true)
    .get();
  assert.deepEqual(armed.docs.map((d) => d.ref.path), ['facilities/f1/tenants/t1/paymentMethods/pm1']);

  const ledgers = db.collection('facilities/f1/ledgers');
  const ids = async (q: Query) => (await q.get()).docs.map((d) => d.id);
  assert.deepEqual(await ids(ledgers.where('amount', '>=', 10)), ['b']);
  assert.deepEqual(await ids(ledgers.where('amount', '<', 10)), ['a']);
  assert.deepEqual(await ids(ledgers.where('at', '>=', Timestamp.fromMillis(2000))), ['b']);
  assert.deepEqual(await ids(ledgers.where('ids', 'array-contains', 'y')), ['a']);
  assert.deepEqual(await ids(ledgers.where('amount', 'in', [15, 99])), ['b']);
  assert.deepEqual(await ids(ledgers.where('m.d', '==', 'du')), ['a']);
  assert.deepEqual(await ids(ledgers.where('m.d', '!=', 'other')), ['a']);
});

// A payment checked against the ledger and written in one transaction is
// only safe if a matching row added by someone else in between makes the
// transaction start again, as Firestore's serializable transactions do.
test('fake Firestore: a query read in a transaction is retried when a matching document appears', async () => {
  const fake = new FakeFirestore();
  fake.seed('facilities/f1/ledgers/a', { tenantId: 't1', amount: 100 });
  const db = fake.firestore();
  const rows = db.collection('facilities/f1/ledgers').where('tenantId', '==', 't1');
  let attempts = 0;
  fake.beforeCommit = async (attempt) => {
    if (attempt === 1) await db.collection('facilities/f1/ledgers').doc('b').set({ tenantId: 't1', amount: -100 });
  };

  const seen = await db.runTransaction(async (tx) => {
    attempts += 1;
    const snap = await tx.get(rows);
    return snap.docs.map((d) => d.id);
  });

  assert.equal(attempts, 2);
  assert.deepEqual(seen, ['a', 'b']);
  assert.equal(fake.transactionConflicts, 1);
});

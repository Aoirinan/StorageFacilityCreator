import test from 'node:test';
import assert from 'node:assert/strict';
import { Timestamp } from 'firebase-admin/firestore';

import { airbnbFolioFrom, handleRecordPayment, handleVoidIncome } from '../bookings/payments';
import { handleCancelStay, handleCreateStay } from '../bookings/stays';
import { FakeFirestore, commitBarrier } from './support/fakeFirestore';
import { EMPLOYEE, FAC, MANAGER, NOW, OWNER, callableContext, makeStay } from './support/staysFixtures';
import { Env, P, as, listingInput, reasonOf, rid, rvInput, seedListing, setupEnv } from './support/bookingFixtures';

const all: FakeFirestore[] = [];

function env(controls: Record<string, unknown> = {}): Env {
  const e = setupEnv(all, { controls });
  seedListing(
    e.fake,
    'lst_a',
    listingInput({ taxLines: [{ code: 'mt', label: 'Montana lodging', rateBps: 400, appliesTo: ['lodging'], remittedBy: 'owner' }] }),
  );
  seedListing(e.fake, 'lst_rv1', rvInput(1));
  return e;
}

/** A direct booking of Airbnb A, Oct 5–8: $300 lodging + $50 cleaning (+ $12 tax when lodging tax is on). */
async function book(e: Env, patch: Record<string, unknown> = {}): Promise<string> {
  const r = await handleCreateStay(
    {
      facilityId: FAC,
      requestId: rid(),
      listingId: 'lst_a',
      checkIn: '2026-10-05',
      checkOut: '2026-10-08',
      kind: 'reservation',
      source: 'direct',
      guest: { displayName: 'Ann A.', adults: 2, children: 0, pets: 0, rvLengthFt: null },
      ...patch,
    },
    callableContext(OWNER),
    e.deps,
    null,
  );
  return r.stayId;
}

function pay(e: Env, uid: string, stayId: string, amountCents: number, patch: Record<string, unknown> = {}) {
  return as(e, handleRecordPayment, uid, { requestId: rid(), stayId, method: 'cash', amountCents, receivedDate: '2026-10-01', ...patch });
}

test('a payment is one income row, moves the folio and the chip, and a retry records nothing more', async () => {
  const e = env();
  const stayId = await book(e);
  const requestId = rid();
  const call = () => as(e, handleRecordPayment, MANAGER, { requestId, stayId, method: 'check', amountCents: 20_000, receivedDate: '2026-09-30', memo: 'Check #1042' });
  const first = await call();
  assert.deepEqual([first.entryId, first.created, first.paymentStatus], [`man_${requestId}`, true, 'partial']);
  assert.deepEqual([first.folio?.paidCents, first.folio?.balanceCents], [20_000, 15_000]);
  const income = e.fake.read(`${P}/stayIncome/man_${requestId}`)!;
  assert.deepEqual(
    [income.kind, income.method, income.grossCents, income.netCents, income.receivedDate, income.receivedMonth, income.memo, income.createdBy],
    ['stay_payment', 'check', 20_000, 20_000, '2026-09-30', '2026-09', 'Check #1042', MANAGER],
  );
  // An earlier day is stamped at noon at the facility (18:00 UTC in Denver's summer time).
  assert.equal((income.receivedAt as Timestamp).toDate().toISOString(), '2026-09-30T18:00:00.000Z');
  const stay = e.fake.read(`${P}/stays/${stayId}`)!;
  assert.deepEqual([stay.paymentStatus, stay.version], ['partial', 2]);

  const again = await call();
  assert.deepEqual([again.created, again.entryId, again.folio?.paidCents], [false, `man_${requestId}`, 20_000]);
  assert.equal(e.fake.list(`${P}/stayIncome`).length, 1);
  assert.equal(e.fake.read(`${P}/stays/${stayId}`)!.version, 2);
  assert.equal(e.handle.audits.filter((a) => a.entry.eventType === 'stays.income.created').length, 1);
});

test('pass-through tax is split from each payment pro rata, and adds up to the tax exactly', async () => {
  const e = env({ lodgingTaxEnabled: true });
  const stayId = await book(e);
  // $300 lodging at 4% = $12 tax; total $362.
  assert.equal(e.fake.read(`${P}/stayFolios/${stayId}`)!.totalCents, 36_200);
  const a = await pay(e, OWNER, stayId, 18_100);
  const b = await pay(e, OWNER, stayId, 18_100);
  const rows = [a.entryId, b.entryId].map((id) => e.fake.read(`${P}/stayIncome/${id}`)!);
  assert.deepEqual(rows.map((r) => [r.taxPassThroughCents, r.netCents]), [
    [600, 17_500],
    [600, 17_500],
  ]);
  assert.equal(b.paymentStatus, 'paid');
  // The cleaning share rides along for the earnings report: $50 of $362.
  assert.equal((rows[0].cleaningFeeCents as number) + (rows[1].cleaningFeeCents as number), 5_000);
});

test('two payments at the same moment are both recorded, one after the other', async () => {
  const e = env();
  const stayId = await book(e);
  e.fake.onBeforeCommit = commitBarrier(2);
  const [a, b] = await Promise.all([pay(e, OWNER, stayId, 10_000), pay(e, MANAGER, stayId, 5_000)]);
  assert.equal(a.created && b.created, true);
  const folio = e.fake.read(`${P}/stayFolios/${stayId}`)!;
  assert.deepEqual([folio.paidCents, folio.balanceCents], [15_000, 20_000]);
  assert.equal(e.fake.list(`${P}/stayIncome`).length, 2);
  assert.equal(e.fake.read(`${P}/stays/${stayId}`)!.version, 3);
});

test('six payments landing together are all recorded; one that can never get through says contention', async () => {
  const e = env();
  const stayId = await book(e);
  e.fake.onBeforeCommit = commitBarrier(6);
  const results = await Promise.all([1, 2, 3, 4, 5, 6].map((i) => pay(e, i % 2 === 0 ? OWNER : MANAGER, stayId, 1_000 * i)));
  assert.equal(results.every((r) => r.created), true);
  assert.equal(e.fake.read(`${P}/stayFolios/${stayId}`)!.paidCents, 21_000);
  assert.equal(e.fake.list(`${P}/stayIncome`).length, 6);

  // A booking that changes under every attempt: "being changed, try again", never "you opened an old copy".
  const busy = env();
  const busyStay = await book(busy);
  busy.fake.onBeforeCommit = async () => {
    const stay = busy.fake.read(`${P}/stays/${busyStay}`)!;
    busy.fake.seed(`${P}/stays/${busyStay}`, { ...stay, version: (stay.version as number) + 1 });
  };
  assert.equal(await reasonOf(pay(busy, OWNER, busyStay, 1_000)), 'contention');
  assert.equal(busy.fake.list(`${P}/stayIncome`).length, 0);
});

test('a channel-collected booking takes no hand-recorded payment (its earnings come from the CSV)', async () => {
  const e = env();
  const stayId = await book(e, { source: 'airbnb', confirmationCode: 'HMPAID0001' });
  assert.equal(await reasonOf(pay(e, OWNER, stayId, 20_000)), 'invalid_argument');
  assert.equal(await reasonOf(pay(e, MANAGER, stayId, -100)), 'invalid_argument');
  assert.equal(e.fake.list(`${P}/stayIncome`).length, 0);
  assert.equal(e.fake.read(`${P}/stays/${stayId}`)!.paymentStatus, 'channel_collected');
});

test('a request id already used for a different payment is refused, not reported as recorded', async () => {
  const e = env();
  const a = await book(e);
  const b = await book(e, { checkIn: '2026-10-10', checkOut: '2026-10-12' });
  const requestId = rid();
  const payWith = (stayId: string, amountCents: number, method = 'cash') =>
    as(e, handleRecordPayment, OWNER, { requestId, stayId, method, amountCents, receivedDate: '2026-10-01' });
  await payWith(a, 5_000);
  assert.equal(await reasonOf(payWith(b, 5_000)), 'invalid_argument');
  assert.equal(await reasonOf(payWith(a, 7_000)), 'invalid_argument');
  assert.equal(await reasonOf(payWith(a, 5_000, 'check')), 'invalid_argument');
  assert.equal(e.fake.read(`${P}/stayFolios/${b}`)!.paidCents, 0);
  // The same payment sent again is still a quiet retry.
  const again = await payWith(a, 5_000);
  assert.deepEqual([again.created, again.folio?.paidCents], [false, 5_000]);
  assert.equal(e.fake.list(`${P}/stayIncome`).length, 1);
});

test('a payment voided by someone else while this void was in flight is not reversed twice', async () => {
  const e = env();
  const stayId = await book(e);
  const paid = await pay(e, OWNER, stayId, 10_000);
  let raced = false;
  e.fake.onBeforeCommit = async () => {
    if (raced) return;
    raced = true;
    const row = e.fake.read(`${P}/stayIncome/${paid.entryId}`)!;
    e.fake.seed(`${P}/stayIncome/${paid.entryId}`, { ...row, status: 'voided', voidedBy: MANAGER });
  };
  assert.equal(await reasonOf(as(e, handleVoidIncome, OWNER, { entryId: paid.entryId, reason: 'Bounced' })), 'invalid_argument');
  assert.equal(e.fake.read(`${P}/stayFolios/${stayId}`)!.paidCents, 10_000);
  assert.equal(e.fake.read(`${P}/stayIncome/${paid.entryId}`)!.voidedBy, MANAGER);
});

test('refunds: owners and managers only, never more than was paid; a cancelled stay paid back shows refunded', async () => {
  const e = env({ employeesCanRecordCash: true });
  const stayId = await book(e);
  await pay(e, OWNER, stayId, 35_000);
  assert.equal(await reasonOf(pay(e, EMPLOYEE, stayId, -1_000)), 'role_not_allowed');
  assert.equal(await reasonOf(pay(e, OWNER, stayId, -35_001)), 'invalid_argument');
  await as(e, handleCancelStay, OWNER, { stayId, expectedVersion: 2, reason: 'Storm' });
  assert.equal(e.fake.read(`${P}/stays/${stayId}`)!.paymentStatus, 'paid');
  const refund = await pay(e, MANAGER, stayId, -35_000, { method: 'venmo' });
  assert.equal(refund.paymentStatus, 'refunded');
  const row = e.fake.read(`${P}/stayIncome/${refund.entryId}`)!;
  assert.deepEqual([row.kind, row.grossCents, row.netCents, row.countsAsIncome], ['refund_given', -35_000, -35_000, true]);
  assert.equal(refund.folio?.paidCents, 0);
});

test('who may record, and what is refused', async () => {
  const e = env();
  const stayId = await book(e);
  assert.equal(await reasonOf(pay(e, EMPLOYEE, stayId, 1_000)), 'employee_setting_off');
  assert.equal(await reasonOf(pay(e, OWNER, stayId, 1_000, { receivedDate: '2026-10-02' })), 'invalid_dates');
  assert.equal(await reasonOf(pay(e, OWNER, stayId, 1_000, { receivedDate: '2025-09-01' })), 'invalid_dates');
  assert.equal(await reasonOf(pay(e, OWNER, stayId, 1_000, { method: 'airbnb' })), 'invalid_argument');
  assert.equal(await reasonOf(pay(e, OWNER, stayId, 0)), 'invalid_argument');
  assert.equal(await reasonOf(pay(e, OWNER, stayId, 10.5)), 'invalid_argument');
  assert.equal(await reasonOf(pay(e, OWNER, 'man_nope', 1_000)), 'not_found');
  const block = await book(e, { kind: 'owner_block', source: 'owner', checkIn: '2026-10-20', checkOut: '2026-10-22' });
  assert.equal(await reasonOf(pay(e, OWNER, block, 1_000)), 'invalid_argument');
  assert.equal(e.fake.list(`${P}/stayIncome`).length, 0);

  const allowed = env({ employeesCanRecordCash: true });
  const walkUp = await book(allowed, { listingId: 'lst_rv1', source: 'walk_up', checkIn: '2026-10-01', checkOut: '2026-10-02' });
  const r = await pay(allowed, EMPLOYEE, walkUp, 4_500);
  assert.equal(r.paymentStatus, 'paid');
});

test('voiding a hand-recorded payment reverses it on the folio and the chip, once', async () => {
  const e = env();
  const stayId = await book(e);
  const paid = await pay(e, OWNER, stayId, 35_000);
  assert.equal(paid.paymentStatus, 'paid');
  assert.equal(await reasonOf(as(e, handleVoidIncome, EMPLOYEE, { entryId: paid.entryId, reason: 'Bounced' })), 'role_not_allowed');
  assert.equal(await reasonOf(as(e, handleVoidIncome, OWNER, { entryId: paid.entryId, reason: '' })), 'invalid_argument');
  const voided = await as(e, handleVoidIncome, MANAGER, { entryId: paid.entryId, reason: 'Check bounced' });
  assert.deepEqual([voided.status, voided.folio?.paidCents, voided.folio?.balanceCents, voided.folio?.stayId], ['voided', 0, 35_000, stayId]);
  const row = e.fake.read(`${P}/stayIncome/${paid.entryId}`)!;
  assert.deepEqual([row.status, row.voidedBy, row.voidReason, row.grossCents], ['voided', MANAGER, 'Check bounced', 35_000]);
  assert.equal(e.fake.read(`${P}/stays/${stayId}`)!.paymentStatus, 'due');
  assert.equal(await reasonOf(as(e, handleVoidIncome, OWNER, { entryId: paid.entryId, reason: 'again' })), 'invalid_argument');
  assert.equal(await reasonOf(as(e, handleVoidIncome, OWNER, { entryId: 'man_nope', reason: 'x' })), 'not_found');
  // Nothing is ever deleted.
  assert.equal(e.fake.list(`${P}/stayIncome`).length, 1);
});

test('a check refunded in cash and then voided leaves the guest owing the refund, not "refunded"', async () => {
  const e = env();
  const stayId = await book(e);
  const check = await pay(e, OWNER, stayId, 10_000, { method: 'check' });
  assert.equal((await pay(e, MANAGER, stayId, -10_000)).paymentStatus, 'refunded');
  // The check bounces after the cash went back: $100 out that never came in, on top of the $350.
  const voided = await as(e, handleVoidIncome, OWNER, { entryId: check.entryId, reason: 'Check bounced' });
  assert.deepEqual([voided.folio?.paidCents, voided.folio?.balanceCents], [-10_000, 45_000]);
  assert.equal(e.fake.read(`${P}/stays/${stayId}`)!.paymentStatus, 'due');
  // Cancelling the booking does not wash it out either.
  await as(e, handleCancelStay, OWNER, { stayId, expectedVersion: 4, reason: 'Bounced' });
  assert.equal(e.fake.read(`${P}/stays/${stayId}`)!.paymentStatus, 'due');
});

test('voiding an Airbnb CSV row recomputes the Airbnb figures from the rows left', async () => {
  const e = env();
  const ts = Timestamp.fromMillis(NOW);
  e.fake.seed(`${P}/stays/airbnb_HMCSV00001`, makeStay('lst_a', '2026-09-10', '2026-09-13', { source: 'airbnb', origin: 'csv', paymentStatus: 'channel_collected' }) as never);
  e.fake.seed(`${P}/stayFolios/airbnb_HMCSV00001`, {
    facilityId: FAC,
    stayId: 'airbnb_HMCSV00001',
    currency: 'usd',
    lines: [],
    taxLines: [],
    subtotalCents: 0,
    taxCents: 0,
    totalCents: 0,
    paidCents: 0,
    balanceCents: 0,
    quoteVersion: 0,
    quotedAt: ts,
    adjustment: null,
    airbnb: { grossCents: 40_000, hostFeeCents: 1_200, cleaningFeeCents: 5_000, taxRemittedCents: 2_000, netCents: 38_800, rowCount: 2 },
    updatedAt: ts,
  });
  const row = (id: string, gross: number, fee: number) =>
    e.fake.seed(`${P}/stayIncome/${id}`, {
      facilityId: FAC,
      stayId: 'airbnb_HMCSV00001',
      listingId: 'lst_a',
      source: 'airbnb_csv',
      kind: 'channel_booking',
      status: 'posted',
      countsAsIncome: true,
      grossCents: gross,
      channelFeeCents: fee,
      cleaningFeeCents: 2_500,
      taxRemittedByChannelCents: 1_000,
      netCents: gross - fee,
    });
  row('abnb_one', 30_000, 900);
  row('abnb_two', 10_000, 300);
  // A payout row is not income and never counts.
  e.fake.seed(`${P}/stayIncome/abnb_payout`, { facilityId: FAC, stayId: 'airbnb_HMCSV00001', source: 'airbnb_csv', kind: 'payout', status: 'posted', countsAsIncome: false, grossCents: 99_999, netCents: 99_999 });

  const r = await as(e, handleVoidIncome, OWNER, { entryId: 'abnb_two', reason: 'Imported twice by hand' });
  assert.deepEqual(r.folio?.airbnb, { grossCents: 30_000, hostFeeCents: 900, cleaningFeeCents: 2_500, taxRemittedCents: 1_000, netCents: 29_100, rowCount: 1 });
  assert.equal(e.fake.read(`${P}/stays/airbnb_HMCSV00001`)!.paymentStatus, 'channel_collected');
  await as(e, handleVoidIncome, OWNER, { entryId: 'abnb_one', reason: 'Wrong stay' });
  assert.equal(e.fake.read(`${P}/stayFolios/airbnb_HMCSV00001`)!.airbnb, null);
  // A row with no stay is just voided.
  e.fake.seed(`${P}/stayIncome/abnb_loose`, { facilityId: FAC, stayId: null, source: 'airbnb_csv', kind: 'adjustment', status: 'posted', countsAsIncome: true, grossCents: -500, netCents: -500 });
  const loose = await as(e, handleVoidIncome, OWNER, { entryId: 'abnb_loose', reason: 'Duplicate' });
  assert.equal(loose.folio, null);
  assert.equal(e.fake.read(`${P}/stayIncome/abnb_loose`)!.status, 'voided');
});

test('the Airbnb folio figure keeps an expected-only amount when no earnings rows are left', () => {
  const expected = { grossCents: 0, hostFeeCents: 0, cleaningFeeCents: 0, taxRemittedCents: 0, netCents: 41_000, rowCount: 0, expectedOnly: true };
  assert.deepEqual(airbnbFolioFrom([], expected), expected);
  assert.equal(airbnbFolioFrom([], { ...expected, expectedOnly: false }), null);
});

test('stay money never touched a storage-side collection', () => {
  assert.ok(all.length > 0);
  for (const fake of all) fake.assertIsolation();
});

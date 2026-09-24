import test from 'node:test';
import assert from 'node:assert/strict';
import { Timestamp } from 'firebase-admin/firestore';

import type { StayDoc } from '@sfc/functions-shared/stays/contracts';

import { refreshChannelsFirst } from '../bookings/shared';
import { handleCancelStay, handleCreateStay, handleModifyStay, handleQuote, handleReviewStay } from '../bookings/stays';
import { staysErrorReason } from '../common/errors';
import { applyStayMutations } from '../common/stayWriter';
import { FakeFirestore, commitBarrier } from './support/fakeFirestore';
import { EMPLOYEE, FAC, MANAGER, NOW, OWNER, VIEWER, callableContext, controlsOn, makeStay } from './support/staysFixtures';
import { Env, P, as, errorOf, listingInput, nightsOf, reasonOf, rid, rvInput, seedListing, setupEnv } from './support/bookingFixtures';

// Today at the facility is Thursday 2026-10-01 (NOW is noon in Denver).
const all: FakeFirestore[] = [];

function env(controls: Record<string, unknown> = {}): Env {
  const e = setupEnv(all, { controls });
  seedListing(e.fake, 'lst_a', listingInput());
  seedListing(e.fake, 'lst_b', listingInput({ name: 'Airbnb B', shortCode: 'B1' }));
  seedListing(e.fake, 'lst_rv1', rvInput(1));
  seedListing(e.fake, 'lst_rv2', rvInput(2));
  return e;
}

const noSync = null;

function create(e: Env, uid: string, data: Record<string, unknown>, sync: Parameters<typeof handleCreateStay>[3] = noSync) {
  return handleCreateStay({ facilityId: FAC, ...data }, callableContext(uid), e.deps, sync);
}

function modify(e: Env, uid: string, data: Record<string, unknown>, sync: Parameters<typeof handleModifyStay>[3] = noSync) {
  return handleModifyStay({ facilityId: FAC, ...data }, callableContext(uid), e.deps, sync);
}

/** A direct booking of Airbnb A, Oct 5–8, for two. */
function booking(patch: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    requestId: rid(),
    listingId: 'lst_a',
    checkIn: '2026-10-05',
    checkOut: '2026-10-08',
    kind: 'reservation',
    source: 'direct',
    guest: { displayName: 'Ann A.', adults: 2, children: 0, pets: 0, rvLengthFt: null },
    ...patch,
  };
}

function seedStay(e: Env, id: string, stay: StayDoc): void {
  e.fake.seed(`${P}/stays/${id}`, stay as unknown as Record<string, unknown>);
}

async function rebuild(e: Env, listingId: string, months: string[]) {
  await applyStayMutations({ db: e.fake.firestore(), facilityId: FAC, controls: controlsOn(), mutations: [], nowMs: NOW, rebuild: [{ listingId, months }] });
}

async function softBlock(e: Env, listingId: string, checkIn: string, checkOut: string) {
  await applyStayMutations({
    db: e.fake.firestore(),
    facilityId: FAC,
    controls: controlsOn(),
    mutations: [],
    nowMs: NOW,
    channelBlockUpdates: [{ channelId: `ch_${listingId}`, listingId, provider: 'airbnb', ranges: [{ checkIn, checkOut, echo: false }] }],
  });
}

function seedChannel(e: Env, listingId: string, lastSuccessMs: number | null, provider = 'airbnb') {
  e.fake.seed(`${P}/stayChannels/ch_${listingId}`, {
    facilityId: FAC,
    listingId,
    provider,
    active: true,
    sync: { lastSuccessAt: lastSuccessMs === null ? null : Timestamp.fromMillis(lastSuccessMs) },
  });
}

// ---------------------------------------------------------------------------
// Walk-up and create
// ---------------------------------------------------------------------------

test('a walk-up check-in writes stay, locks, folio, income, private details and profile in one go; a replay adds nothing', async () => {
  const e = env();
  const requestId = rid();
  const request = {
    requestId,
    listingId: 'lst_rv1',
    checkIn: '2026-10-01',
    checkOut: '2026-10-03',
    kind: 'reservation',
    source: 'walk_up',
    guest: { displayName: '', adults: 2, children: 0, pets: 1, rvLengthFt: 35 },
    guestProfile: { create: { name: 'Jane Doe', phone: '(406) 555-0123', vehicle: { plate: 'mt 1-abc', rvLengthFt: 35 } } },
    checkInNow: true,
    payment: { method: 'cash', amountCents: 9_000, receivedDate: '2026-10-01' },
  };
  const first = await create(e, OWNER, request);
  const stayId = `man_${requestId}`;
  assert.deepEqual([first.stayId, first.created, first.status, first.incomeEntryId], [stayId, true, 'confirmed', `man_${requestId}`]);

  const stay = e.fake.read(`${P}/stays/${stayId}`)!;
  assert.equal(stay.arrivalState, 'checked_in');
  assert.ok(stay.checkedInAt instanceof Timestamp);
  assert.equal(stay.guestDisplayName, 'Jane D.');
  assert.equal(stay.paymentStatus, 'paid');
  assert.deepEqual([stay.listingName, stay.listingGroup, stay.listingKind, stay.origin, stay.nights], ['RV 1', 'RV park', 'rv_site', 'sfc', 2]);
  assert.equal(stay.createdAtMs, NOW);
  assert.deepEqual(Object.keys(nightsOf(e.fake, 'lst_rv1', '2026-10')), ['2026-10-01', '2026-10-02']);
  assert.equal(nightsOf(e.fake, 'lst_rv1', '2026-10')['2026-10-01'].s, stayId);

  // Two nights at $45, no cleaning fee: all paid in cash.
  const folio = e.fake.read(`${P}/stayFolios/${stayId}`)!;
  assert.deepEqual([folio.totalCents, folio.paidCents, folio.balanceCents, folio.quoteVersion], [9_000, 9_000, 0, 1]);
  assert.deepEqual(first.folio?.totalCents, 9_000);
  const income = e.fake.read(`${P}/stayIncome/man_${requestId}`)!;
  assert.deepEqual(
    [income.grossCents, income.netCents, income.taxPassThroughCents, income.method, income.kind, income.countsAsIncome, income.receivedMonth, income.status],
    [9_000, 9_000, 0, 'cash', 'stay_payment', true, '2026-10', 'posted'],
  );
  assert.equal(income.stayId, stayId);
  assert.equal(Object.keys(income).some((k) => /tenant/i.test(k)), false);

  const priv = e.fake.read(`${P}/stayPrivate/${stayId}`)!;
  assert.deepEqual([priv.fullName, priv.phoneLast4, priv.guestProfileId], ['Jane Doe', '0123', `gp_${requestId}`]);
  const profile = e.fake.read(`${P}/stayGuestProfiles/gp_${requestId}`)!;
  assert.deepEqual([profile.name, profile.nameLower, profile.phoneE164, profile.stayCount], ['Jane Doe', 'jane doe', '+14065550123', 1]);
  assert.equal((profile.vehicle as { plate: string }).plate, 'MT1ABC');
  // The stay doc every role reads carries no contact details.
  assert.equal(JSON.stringify(stay).includes('555'), false);

  const replay = await create(e, OWNER, request);
  assert.deepEqual([replay.stayId, replay.created, replay.incomeEntryId], [stayId, false, `man_${requestId}`]);
  assert.equal(e.fake.list(`${P}/stayIncome`).length, 1);
  assert.equal(e.fake.list(`${P}/stays`).length, 1);
  assert.equal(e.fake.read(`${P}/stayGuestProfiles/gp_${requestId}`)!.stayCount, 1);
  assert.equal(e.handle.audits.filter((a) => a.entry.eventType === 'stays.stay.created').length, 1);
});

test('a full name typed as the display name stays off the stay doc; a chosen display name is kept', async () => {
  const e = env();
  const typed = await create(e, OWNER, booking({ guest: { displayName: 'jane doe', adults: 1, children: 0, pets: 0, rvLengthFt: null }, guestProfile: { create: { name: 'Jane Doe' } } }));
  assert.equal(e.fake.read(`${P}/stays/${typed.stayId}`)!.guestDisplayName, 'Jane D.');
  assert.equal(e.fake.read(`${P}/stayPrivate/${typed.stayId}`)!.fullName, 'Jane Doe');
  const chosen = await create(e, OWNER, booking({ checkIn: '2026-10-10', checkOut: '2026-10-12', guest: { displayName: 'The Does', adults: 2, children: 0, pets: 0, rvLengthFt: null }, guestProfile: { create: { name: 'John Doe' } } }));
  assert.equal(e.fake.read(`${P}/stays/${chosen.stayId}`)!.guestDisplayName, 'The Does');
});

test('a double tap sent twice at once still makes one stay and one payment', async () => {
  const e = env();
  e.fake.onBeforeCommit = commitBarrier(2);
  const request = booking({ payment: { method: 'check', amountCents: 5_000, receivedDate: '2026-10-01' } });
  const [a, b] = await Promise.all([create(e, OWNER, request), create(e, OWNER, request)]);
  assert.deepEqual([a.created, b.created].sort(), [false, true]);
  assert.equal(a.stayId, b.stayId);
  assert.equal(e.fake.list(`${P}/stays`).length, 1);
  assert.equal(e.fake.list(`${P}/stayIncome`).length, 1);
});

test('two people booking the same nights at once: exactly one commits, the other is told who has them', async () => {
  const e = env();
  e.fake.onBeforeCommit = commitBarrier(2);
  const results = await Promise.allSettled([
    create(e, OWNER, booking({ guest: { displayName: 'Ann A.', adults: 2, children: 0, pets: 0, rvLengthFt: null } })),
    create(e, MANAGER, booking({ checkIn: '2026-10-06', checkOut: '2026-10-09', guest: { displayName: 'Bob B.', adults: 1, children: 0, pets: 0, rvLengthFt: null } })),
  ]);
  const won = results.filter((r) => r.status === 'fulfilled');
  const lost = results.filter((r) => r.status === 'rejected') as PromiseRejectedResult[];
  assert.equal(won.length, 1);
  assert.equal(lost.length, 1);
  assert.equal(staysErrorReason(lost[0].reason), 'hard_conflict');
  assert.equal(e.fake.list(`${P}/stays`).length, 1);
  const nights = (lost[0].reason as { details: { nights: { label: string }[] } }).details.nights;
  assert.ok(nights.length >= 2);
  assert.match(nights[0].label, /^(Ann A\.|Bob B\.) · 2026-10-0/);
});

test('an Airbnb reservation entered by hand is airbnb_{CODE}, channel-collected, and cannot be entered twice', async () => {
  const e = env();
  const r = await create(e, OWNER, booking({ source: 'airbnb', confirmationCode: ' hmabc12345 ' }));
  assert.equal(r.stayId, 'airbnb_HMABC12345');
  assert.equal(r.folio, null);
  const stay = e.fake.read(`${P}/stays/airbnb_HMABC12345`)!;
  assert.equal(stay.paymentStatus, 'channel_collected');
  assert.deepEqual(stay.external, {
    provider: 'airbnb',
    uid: null,
    uidHistory: [],
    confirmationCode: 'HMABC12345',
    reservationUrl: 'https://www.airbnb.com/hosting/reservations/details/HMABC12345',
    summary: null,
  });
  assert.equal(e.fake.has(`${P}/stayFolios/airbnb_HMABC12345`), false);

  const dup = await errorOf(create(e, MANAGER, booking({ source: 'airbnb', confirmationCode: 'HMABC12345', checkIn: '2026-11-01', checkOut: '2026-11-03' })));
  assert.equal(staysErrorReason(dup), 'duplicate_reservation');
  assert.equal((dup.details as { stayId: string }).stayId, 'airbnb_HMABC12345');
  assert.equal(await reasonOf(create(e, OWNER, booking({ source: 'airbnb' }))), 'invalid_argument');
  assert.equal(await reasonOf(create(e, OWNER, booking({ source: 'vrbo', confirmationCode: 'HA-123456', payment: { method: 'cash', amountCents: 100, receivedDate: '2026-10-01' } }))), 'invalid_argument');
  const vrbo = await create(e, OWNER, booking({ source: 'vrbo', confirmationCode: 'HA-123456', checkIn: '2026-10-20', checkOut: '2026-10-22' }));
  assert.equal((e.fake.read(`${P}/stays/${vrbo.stayId}`)!.external as { provider: string }).provider, 'vrbo');
});

test('owner and maintenance blocks: source owner, no guest, no price, no stay rules', async () => {
  const e = env();
  seedListing(e.fake, 'lst_min3', listingInput({ name: 'Cabin', shortCode: 'CB', stayRules: { minNights: 3, maxNights: 28 } }));
  const r = await create(e, OWNER, { requestId: rid(), listingId: 'lst_min3', checkIn: '2026-10-05', checkOut: '2026-10-06', kind: 'owner_block', source: 'owner', notes: 'Family visiting' });
  assert.equal(r.folio, null);
  const block = e.fake.read(`${P}/stays/${r.stayId}`)!;
  assert.deepEqual([block.kind, block.paymentStatus, block.guestDisplayName, block.staffNotes], ['owner_block', 'none', '', 'Family visiting']);
  assert.equal(nightsOf(e.fake, 'lst_min3', '2026-10')['2026-10-05'].h, true);
  assert.equal(await reasonOf(create(e, OWNER, { ...booking(), kind: 'maintenance_block', source: 'direct' })), 'invalid_argument');
  assert.equal(await reasonOf(create(e, OWNER, { ...booking(), source: 'owner' })), 'invalid_argument');
  // A 1-night guest booking on the 3-night-minimum cabin is refused.
  assert.equal(await reasonOf(create(e, OWNER, booking({ listingId: 'lst_min3', checkIn: '2026-10-10', checkOut: '2026-10-11' }))), 'min_nights');
});

test('dates: 1–180 nights, not too far back, and ending inside the lock horizon', async () => {
  const e = env();
  assert.equal(await reasonOf(create(e, OWNER, booking({ checkOut: '2026-10-05' }))), 'invalid_dates');
  assert.equal(await reasonOf(create(e, OWNER, booking({ checkIn: '2026-10-07', checkOut: '2026-10-05' }))), 'invalid_dates');
  const long = await errorOf(create(e, OWNER, booking({ checkIn: '2026-10-05', checkOut: '2027-04-05' })));
  assert.equal(staysErrorReason(long), 'max_nights');
  assert.match(long.message, /monthly/);
  assert.equal(await reasonOf(create(e, OWNER, booking({ checkIn: '2026-10-05', checkOut: '2026-11-05' }))), 'max_nights');
  const far = await errorOf(create(e, OWNER, booking({ checkIn: '2028-06-01', checkOut: '2028-06-03' })));
  assert.equal(staysErrorReason(far), 'invalid_dates');
  assert.equal((far.details as { maxCheckOut: string }).maxCheckOut, '2028-03-24');
  assert.equal(await reasonOf(create(e, OWNER, booking({ checkIn: '2026-07-01', checkOut: '2026-07-03' }))), 'invalid_dates');
  assert.equal(await reasonOf(create(e, OWNER, booking({ checkInNow: true }))), 'invalid_argument');
  assert.equal(await reasonOf(create(e, OWNER, booking({ payment: { method: 'cash', amountCents: 100, receivedDate: '2026-10-02' } }))), 'invalid_dates');
  seedListing(e.fake, 'lst_off', listingInput({ name: 'Off', shortCode: 'OFF', active: false }));
  assert.equal(await reasonOf(create(e, OWNER, booking({ listingId: 'lst_off' }))), 'listing_inactive');
  assert.equal(await reasonOf(create(e, OWNER, booking({ listingId: 'lst_nope' }))), 'not_found');
  assert.equal(e.fake.list(`${P}/stays`).length, 0);
});

test('a channel block needs an explicit override, which only an owner or manager can give', async () => {
  const e = env({ employeesCanBook: true });
  await softBlock(e, 'lst_a', '2026-10-06', '2026-10-07');
  const soft = await errorOf(create(e, OWNER, booking()));
  assert.equal(staysErrorReason(soft), 'soft_block');
  assert.deepEqual((soft.details as { dates: string[] }).dates, ['2026-10-06']);
  assert.equal(await reasonOf(create(e, EMPLOYEE, booking({ overrideSoftBlocks: true }))), 'role_not_allowed');
  const ok = await create(e, MANAGER, booking({ overrideSoftBlocks: true }));
  assert.equal(nightsOf(e.fake, 'lst_a', '2026-10')['2026-10-06'].s, ok.stayId);
});

test('short notice on a listing a channel also sells needs her to confirm she blocked it there', async () => {
  const e = env();
  seedChannel(e, 'lst_a', NOW - 60_000);
  const soon = booking({ checkIn: '2026-10-03', checkOut: '2026-10-05' });
  const refused = await errorOf(create(e, OWNER, soon));
  assert.equal(staysErrorReason(refused), 'short_lead_ack_required');
  assert.deepEqual(refused.details as Record<string, unknown>, { hours: 72, providers: ['airbnb'], reason: 'short_lead_ack_required' });
  const ok = await create(e, OWNER, { ...soon, acknowledgeShortLead: true });
  assert.ok(ok.warnings.some((w) => w.code === 'short_lead'));
  // A week out, or on a listing no channel sells, needs no confirmation.
  assert.equal(await reasonOf(create(e, OWNER, booking({ checkIn: '2026-10-10', checkOut: '2026-10-12' }))), null);
  assert.equal(await reasonOf(create(e, OWNER, booking({ listingId: 'lst_rv1', checkIn: '2026-10-01', checkOut: '2026-10-02', source: 'walk_up' }))), null);
  // A 0-hour window turns the rule off.
  const off = env({ shortLeadWarningHours: 0 });
  seedChannel(off, 'lst_a', NOW - 60_000);
  assert.equal(await reasonOf(create(off, OWNER, soon)), null);
});

test('a stale channel is re-read before booking, so a block it just gained is respected', async () => {
  const e = env({ icalSyncEnabled: true });
  seedChannel(e, 'lst_a', NOW - 2 * 3_600_000);
  const calls: string[] = [];
  const sync = async (facilityId: string, channelId: string, trigger: string) => {
    calls.push(`${facilityId}/${channelId}/${trigger}`);
    await softBlock(e, 'lst_a', '2026-10-06', '2026-10-07');
  };
  assert.equal(await reasonOf(create(e, OWNER, booking(), sync)), 'soft_block');
  assert.deepEqual(calls, [`${FAC}/ch_lst_a/save`]);

  // A failing refresh never stops the booking; it says availability is as of the last sync.
  const failing = env({ icalSyncEnabled: true });
  seedChannel(failing, 'lst_a', null);
  const r = await create(failing, OWNER, booking(), async () => {
    throw new Error('feed down');
  });
  assert.deepEqual(r.warnings.map((w) => w.code), ['fresh_sync_failed']);
  // No sync module (or sync turned off): skipped, said so. A fresh channel is not re-read at all.
  const skipped = env();
  seedChannel(skipped, 'lst_a', NOW - 3_600_000);
  assert.deepEqual((await create(skipped, OWNER, booking(), null)).warnings.map((w) => w.code), ['fresh_sync_skipped']);
  const fresh = env({ icalSyncEnabled: true });
  seedChannel(fresh, 'lst_a', NOW - 60_000);
  let called = false;
  await create(fresh, OWNER, booking(), async () => {
    called = true;
  });
  assert.equal(called, false);
  // A refresh that hangs gives up at its budget.
  const hung = await refreshChannelsFirst({
    sync: () => new Promise(() => undefined),
    channels: [{ channelId: 'c', provider: 'airbnb', lastSuccessMs: null }],
    facilityId: FAC,
    syncEnabled: true,
    nowMs: NOW,
    timeoutMs: 20,
  });
  assert.equal(hung?.code, 'fresh_sync_failed');
});

test('employees: walk-ups only when allowed, never adjustments, cash only when allowed', async () => {
  const off = env();
  const walkUp = (patch: Record<string, unknown> = {}) =>
    booking({ listingId: 'lst_rv1', source: 'walk_up', checkIn: '2026-10-01', checkOut: '2026-10-02', ...patch });
  assert.equal(await reasonOf(create(off, EMPLOYEE, walkUp())), 'employee_setting_off');
  assert.equal(await reasonOf(create(off, VIEWER, walkUp())), 'role_not_allowed');

  const on = env({ employeesCanBook: true });
  const r = await create(on, EMPLOYEE, walkUp({ checkInNow: true }));
  assert.equal(r.created, true);
  assert.equal(await reasonOf(create(on, EMPLOYEE, walkUp({ checkIn: '2026-10-10', checkOut: '2026-10-11', adjustment: { cents: -500, reason: 'Friend' } }))), 'role_not_allowed');
  assert.equal(await reasonOf(create(on, EMPLOYEE, { ...walkUp({ checkIn: '2026-10-10', checkOut: '2026-10-11' }), kind: 'owner_block', source: 'owner' })), 'role_not_allowed');
  assert.equal(await reasonOf(create(on, EMPLOYEE, walkUp({ source: 'airbnb', confirmationCode: 'HMEMPLOYEE1' }))), 'role_not_allowed');
  assert.equal(await reasonOf(create(on, EMPLOYEE, walkUp({ checkIn: '2026-09-28', checkOut: '2026-09-29' }))), 'invalid_dates');
  const cash = { payment: { method: 'cash', amountCents: 4_500, receivedDate: '2026-10-01' } };
  assert.equal(await reasonOf(create(on, EMPLOYEE, walkUp({ listingId: 'lst_rv2', ...cash }))), 'employee_setting_off');
  const both = env({ employeesCanBook: true, employeesCanRecordCash: true });
  const paid = await create(both, EMPLOYEE, walkUp({ listingId: 'lst_rv2', ...cash }));
  assert.equal(paid.incomeEntryId !== null, true);
  assert.equal(both.fake.read(`${P}/stays/${paid.stayId}`)!.paymentStatus, 'paid');
});

test('a do-not-rent guest is refused unless an owner or manager confirms; a new profile with their phone is the same guest', async () => {
  const e = env({ employeesCanBook: true });
  e.fake.seed(`${P}/stayGuestProfiles/gp_banned`, {
    facilityId: FAC,
    name: 'Rex Ruin',
    nameLower: 'rex ruin',
    phoneE164: '+14065550999',
    email: null,
    vehicle: null,
    notes: '',
    doNotRent: true,
    doNotRentReason: 'Damage',
    consent: null,
    stayCount: 2,
    lastStayAt: null,
  });
  // Typed in fresh at the desk, with the same phone number.
  const disguised = booking({ guestProfile: { create: { name: 'R. Ruin', phone: '406-555-0999' } } });
  const refused = await errorOf(create(e, EMPLOYEE, { ...disguised, source: 'walk_up', listingId: 'lst_rv1', checkIn: '2026-10-01', checkOut: '2026-10-02' }));
  assert.equal(staysErrorReason(refused), 'do_not_rent');
  assert.match(refused.message, /Ask the owner/);
  assert.equal(await reasonOf(create(e, EMPLOYEE, { ...disguised, acknowledgeDoNotRent: true })), 'role_not_allowed');
  assert.equal(await reasonOf(create(e, OWNER, booking({ guestProfile: { profileId: 'gp_banned' } }))), 'do_not_rent');
  const ok = await create(e, OWNER, booking({ guestProfile: { profileId: 'gp_banned' }, acknowledgeDoNotRent: true }));
  assert.ok(ok.warnings.some((w) => w.code === 'do_not_rent'));
  assert.equal(e.fake.read(`${P}/stayGuestProfiles/gp_banned`)!.stayCount, 3);
  assert.equal(e.fake.list(`${P}/stayGuestProfiles`).length, 1);
});

test('party heads-ups: over capacity, pets where none are allowed, a rig too long', async () => {
  const e = env();
  const r = await create(e, OWNER, booking({ guest: { displayName: 'Big P.', adults: 4, children: 2, pets: 1, rvLengthFt: null } }));
  assert.deepEqual(r.warnings.map((w) => w.code).sort(), ['over_capacity', 'pets_not_allowed']);
  const rv = await create(e, OWNER, booking({ listingId: 'lst_rv1', source: 'phone', guest: { displayName: 'Long R.', adults: 2, children: 0, pets: 0, rvLengthFt: 45 } }));
  assert.deepEqual(rv.warnings.map((w) => w.code), ['rv_too_long']);
});

test('an adjustment is priced into the folio, owners and managers only', async () => {
  const e = env();
  const r = await create(e, MANAGER, booking({ adjustment: { cents: -2_500, reason: 'Returning guest' } }));
  // 3 nights × $100 + $50 cleaning − $25.
  assert.equal(r.folio?.totalCents, 32_500);
  const folio = e.fake.read(`${P}/stayFolios/${r.stayId}`)!;
  assert.deepEqual(folio.adjustment, { cents: -2_500, reason: 'Returning guest', by: MANAGER });
  assert.equal(e.fake.read(`${P}/stays/${r.stayId}`)!.paymentStatus, 'due');
  assert.equal(await reasonOf(create(e, OWNER, booking({ checkIn: '2026-10-20', checkOut: '2026-10-21', adjustment: { cents: 0, reason: 'x' } }))), 'invalid_argument');
});

// ---------------------------------------------------------------------------
// Quote
// ---------------------------------------------------------------------------

test('a quote prices the stay and reports conflicts, channel blocks, short notice and orphan gaps', async () => {
  const e = env({ employeesCanBook: true });
  seedChannel(e, 'lst_a', NOW - 60_000);
  seedStay(e, 'man_held', makeStay('lst_a', '2026-10-10', '2026-10-12', { guestDisplayName: 'Cal C.' }));
  await rebuild(e, 'lst_a', ['2026-10']);
  await softBlock(e, 'lst_a', '2026-10-03', '2026-10-04');

  const free = await as(e, handleQuote, EMPLOYEE, { listingId: 'lst_a', checkIn: '2026-10-05', checkOut: '2026-10-08', adults: 2, children: 0, pets: 0 });
  assert.equal(free.available, true);
  assert.equal(free.quote.totalCents, 35_000);
  assert.equal(free.shortLead, false);
  // Oct 4 would be left between the channel block and this stay; Oct 8 and 9 between it and Cal's.
  assert.deepEqual(
    free.warnings.filter((w) => w.code === 'orphan_gap').map((w) => w.details),
    [
      { side: 'before', nights: ['2026-10-04'] },
      { side: 'after', nights: ['2026-10-08', '2026-10-09'] },
    ],
  );

  const clash = await as(e, handleQuote, OWNER, { listingId: 'lst_a', checkIn: '2026-10-03', checkOut: '2026-10-11', adults: 2, children: 0, pets: 0 });
  assert.equal(clash.available, false);
  assert.deepEqual(clash.hardConflicts.map((c) => [c.date, c.stayId, c.label]), [['2026-10-10', 'man_held', 'Cal C. · 2026-10-10 to 2026-10-12']]);
  assert.deepEqual(clash.softNights, ['2026-10-03']);
  assert.equal(clash.shortLead, true);
  assert.deepEqual(clash.warnings.map((w) => w.code).sort(), ['short_lead', 'soft_nights']);

  // A stay's own nights do not count against it when it is being changed.
  const self = await as(e, handleQuote, OWNER, { listingId: 'lst_a', checkIn: '2026-10-10', checkOut: '2026-10-13', adults: 2, children: 0, pets: 0, excludeStayId: 'man_held' });
  assert.equal(self.available, true);

  assert.equal(await reasonOf(as(e, handleQuote, VIEWER, { listingId: 'lst_a', checkIn: '2026-10-05', checkOut: '2026-10-08' })), 'role_not_allowed');
  assert.equal(await reasonOf(as(e, handleQuote, OWNER, { listingId: 'lst_a', checkIn: '2026-10-05', checkOut: '2027-10-08' })), 'max_nights');
  assert.equal(await reasonOf(as(e, handleQuote, OWNER, { listingId: 'lst_a', checkIn: '2026-10-05', checkOut: 'soon' })), 'invalid_dates');
});

test('a quote with no confirmed zone is refused, never guessed', async () => {
  const e = env({ timeZone: null, timeZoneConfirmedAt: null });
  assert.equal(await reasonOf(as(e, handleQuote, OWNER, { listingId: 'lst_a', checkIn: '2026-10-05', checkOut: '2026-10-08' })), 'timezone_unconfirmed');
});

// ---------------------------------------------------------------------------
// Modify
// ---------------------------------------------------------------------------

test('moving a stay to another site rebuilds both, keeps the agreed price, and bumps the version', async () => {
  const e = env();
  const r = await create(e, OWNER, booking({ listingId: 'lst_rv1', source: 'phone', checkIn: '2026-10-05', checkOut: '2026-10-07' }));
  const moved = await modify(e, OWNER, { stayId: r.stayId, expectedVersion: 1, changes: { listingId: 'lst_rv2' } });
  assert.deepEqual([moved.stay.listingId, moved.stay.listingName, moved.stay.version], ['lst_rv2', 'RV 2', 2]);
  assert.equal(e.fake.has(`${P}/stayNightLocks/lst_rv1_2026-10`), false);
  assert.equal(nightsOf(e.fake, 'lst_rv2', '2026-10')['2026-10-05'].s, r.stayId);
  assert.equal(moved.folio?.totalCents, 9_000);
  assert.equal(moved.folio?.quoteVersion, 1);

  // Onto a booked site: refused, nothing moves.
  seedStay(e, 'man_other', makeStay('lst_rv1', '2026-10-06', '2026-10-07', { guestDisplayName: 'Dee D.' }));
  await rebuild(e, 'lst_rv1', ['2026-10']);
  const clash = await errorOf(modify(e, OWNER, { stayId: r.stayId, expectedVersion: 2, changes: { listingId: 'lst_rv1' } }));
  assert.equal(staysErrorReason(clash), 'hard_conflict');
  assert.equal(e.fake.read(`${P}/stays/${r.stayId}`)!.listingId, 'lst_rv2');
  // A stale version is refused before anything is written.
  assert.equal(await reasonOf(modify(e, OWNER, { stayId: r.stayId, expectedVersion: 1, changes: { checkOut: '2026-10-08' } })), 'version_mismatch');
});

test('new dates re-price the stay; money already paid stays paid', async () => {
  const e = env();
  const r = await create(e, OWNER, booking({ payment: { method: 'card_external', amountCents: 35_000, receivedDate: '2026-10-01' } }));
  assert.equal(e.fake.read(`${P}/stays/${r.stayId}`)!.paymentStatus, 'paid');
  const longer = await modify(e, OWNER, { stayId: r.stayId, expectedVersion: 1, changes: { checkOut: '2026-10-09' } });
  assert.deepEqual([longer.folio?.totalCents, longer.folio?.paidCents, longer.folio?.balanceCents, longer.folio?.quoteVersion], [45_000, 35_000, 10_000, 2]);
  assert.equal(longer.stay.paymentStatus, 'partial');
  assert.equal(longer.stay.nights, 4);
  assert.equal(nightsOf(e.fake, 'lst_a', '2026-10')['2026-10-08'].s, r.stayId);
  // Paying the rest with the change settles it, in one step.
  const settled = await modify(e, OWNER, {
    stayId: r.stayId,
    expectedVersion: 2,
    requestId: rid(),
    changes: { checkOutTime: '12:00' },
    payment: { method: 'cash', amountCents: 10_000, receivedDate: '2026-10-01' },
  });
  assert.equal(settled.stay.paymentStatus, 'paid');
  assert.equal(settled.folio?.balanceCents, 0);
  assert.equal(e.fake.list(`${P}/stayIncome`).length, 2);
  assert.equal(await reasonOf(modify(e, OWNER, { stayId: r.stayId, expectedVersion: 3, changes: {}, payment: { method: 'cash', amountCents: 1, receivedDate: '2026-10-01' } })), 'invalid_argument');
});

test("a feed's stay keeps its dates under the channel's control; name and times can still be set", async () => {
  const e = env();
  const feed = makeStay('lst_a', '2026-10-05', '2026-10-08', {
    source: 'airbnb',
    origin: 'feed',
    guestDisplayName: '',
    paymentStatus: 'channel_collected',
    sync: { channelId: 'ch1', firstSeenAt: Timestamp.fromMillis(NOW), lastSeenAt: Timestamp.fromMillis(NOW), missCount: 0, firstMissAt: null, lastMissAt: null, needsReview: false, agedOutAt: null, detached: false },
    version: 1,
  });
  seedStay(e, 'airbnb_HMFEED0001', feed);
  const dates = await errorOf(modify(e, OWNER, { stayId: 'airbnb_HMFEED0001', expectedVersion: 1, changes: { checkOut: '2026-10-09' } }));
  assert.equal(staysErrorReason(dates), 'feed_owned_dates');
  assert.match(dates.message, /Airbnb/);
  // A cleaner leaves a note while the rename is in flight: the rename must not undo it.
  let noted = false;
  e.fake.onBeforeCommit = async () => {
    if (noted) return;
    noted = true;
    seedStay(e, 'airbnb_HMFEED0001', { ...feed, cleanerNotes: 'Extra towels' });
  };
  const named = await modify(e, MANAGER, { stayId: 'airbnb_HMFEED0001', expectedVersion: 1, changes: { guest: { displayName: 'Kim K.' }, checkInTime: '16:00' } });
  assert.deepEqual([named.stay.guestDisplayName, named.stay.checkInTime, named.stay.cleanerNotes], ['Kim K.', '16:00', 'Extra towels']);
  assert.equal(named.stay.paymentStatus, 'channel_collected');
  assert.equal(named.folio, null);
});

test('an employee may only add nights to a walk-up', async () => {
  const e = env({ employeesCanBook: true });
  const r = await create(e, EMPLOYEE, booking({ listingId: 'lst_rv1', source: 'walk_up', checkIn: '2026-10-01', checkOut: '2026-10-02', checkInNow: true }));
  const plusOne = await modify(e, EMPLOYEE, { stayId: r.stayId, expectedVersion: 1, changes: { checkOut: '2026-10-03' } });
  assert.equal(plusOne.stay.checkOut, '2026-10-03');
  assert.equal(plusOne.folio?.totalCents, 9_000);
  // The check-in is kept (the writer keeps staff fields it does not own).
  assert.equal(plusOne.stay.arrivalState, 'checked_in');
  for (const changes of [{ checkOut: '2026-10-02' }, { listingId: 'lst_rv2' }, { guest: { displayName: 'Other' } }, { checkOutTime: '13:00' }]) {
    assert.equal(await reasonOf(modify(e, EMPLOYEE, { stayId: r.stayId, expectedVersion: 2, changes })), 'role_not_allowed', JSON.stringify(changes));
  }
  const direct = await create(e, OWNER, booking());
  assert.equal(await reasonOf(modify(e, EMPLOYEE, { stayId: direct.stayId, expectedVersion: 1, changes: { checkOut: '2026-10-09' } })), 'role_not_allowed');
});

// ---------------------------------------------------------------------------
// Cancel and review
// ---------------------------------------------------------------------------

test("cancelling a conflict's winner hands its nights to the other booking in the same commit", async () => {
  const e = env();
  const winner = await create(e, OWNER, booking());
  // The Airbnb feed then brings in a clashing reservation: recorded as a conflict.
  await applyStayMutations({
    db: e.fake.firestore(),
    facilityId: FAC,
    controls: controlsOn(),
    nowMs: NOW,
    mutations: [{ stayId: 'airbnb_HMLATE0001', next: makeStay('lst_a', '2026-10-06', '2026-10-09', { source: 'airbnb', origin: 'feed', createdAtMs: NOW + 1_000 }), mode: 'feed' }],
  });
  assert.equal(e.fake.read(`${P}/stays/airbnb_HMLATE0001`)!.status, 'conflict');

  const cancelled = await as(e, handleCancelStay, OWNER, { stayId: winner.stayId, expectedVersion: 1, reason: 'Guest cancelled by phone' });
  assert.deepEqual([cancelled.stay.status, cancelled.stay.cancelledBy, cancelled.stay.cancelReason, cancelled.stay.paymentStatus], ['cancelled', OWNER, 'Guest cancelled by phone', 'none']);
  assert.equal(e.fake.read(`${P}/stays/airbnb_HMLATE0001`)!.status, 'confirmed');
  assert.equal(nightsOf(e.fake, 'lst_a', '2026-10')['2026-10-06'].s, 'airbnb_HMLATE0001');
  assert.equal(nightsOf(e.fake, 'lst_a', '2026-10')['2026-10-05'], undefined);
  const audit = e.handle.audits.find((a) => a.entry.eventType === 'stays.stay.cancelled')!;
  assert.deepEqual(audit.entry.metadata?.freedStays, ['airbnb_HMLATE0001']);
  // The feed's reservation is cancelled in Airbnb, not here.
  assert.equal(await reasonOf(as(e, handleCancelStay, OWNER, { stayId: 'airbnb_HMLATE0001', expectedVersion: 2, reason: 'x' })), 'feed_owned_dates');
  assert.equal(await reasonOf(as(e, handleCancelStay, OWNER, { stayId: winner.stayId, expectedVersion: 2, reason: 'again' })), 'invalid_argument');
  assert.equal(await reasonOf(as(e, handleCancelStay, EMPLOYEE, { stayId: winner.stayId, expectedVersion: 2, reason: 'x' })), 'role_not_allowed');
});

test('a checked-in guest is not cancelled; a no-show frees the nights from arrival day on', async () => {
  const e = env();
  const inHouse = await create(e, OWNER, booking({ listingId: 'lst_rv1', source: 'walk_up', checkIn: '2026-10-01', checkOut: '2026-10-03', checkInNow: true }));
  assert.equal(await reasonOf(as(e, handleCancelStay, OWNER, { stayId: inHouse.stayId, expectedVersion: 1, reason: 'Left' })), 'invalid_argument');

  const future = await create(e, OWNER, booking({ checkIn: '2026-10-10', checkOut: '2026-10-12' }));
  assert.equal(await reasonOf(as(e, handleCancelStay, OWNER, { stayId: future.stayId, expectedVersion: 1, reason: 'Never came', noShow: true })), 'invalid_argument');
  const today = await create(e, OWNER, booking({ listingId: 'lst_rv2', source: 'phone', checkIn: '2026-10-01', checkOut: '2026-10-03' }));
  const noShow = await as(e, handleCancelStay, MANAGER, { stayId: today.stayId, expectedVersion: 1, reason: 'Never came', noShow: true });
  assert.deepEqual([noShow.stay.status, noShow.stay.arrivalState], ['cancelled', 'no_show']);
  assert.equal(e.fake.has(`${P}/stayNightLocks/lst_rv2_2026-10`), false);
});

test('acknowledging a double booking is kept, even through later rebuilds', async () => {
  const e = env();
  seedStay(e, 'man_first', makeStay('lst_a', '2026-10-10', '2026-10-12', { createdAtMs: 100 }));
  seedStay(e, 'ical_second', makeStay('lst_a', '2026-10-11', '2026-10-13', { createdAtMs: 200, source: 'vrbo', origin: 'feed' }));
  await rebuild(e, 'lst_a', ['2026-10']);
  assert.equal(e.fake.read(`${P}/stays/ical_second`)!.status, 'conflict');
  const acked = await as(e, handleReviewStay, OWNER, { stayId: 'ical_second', action: 'acknowledge_conflict', note: 'Moving them to Airbnb B' });
  const conflict = acked.stay.conflict!;
  assert.equal(conflict.acknowledgedBy, OWNER);
  assert.equal(conflict.note, 'Moving them to Airbnb B');
  assert.deepEqual(conflict.stayIds, ['man_first']);
  await rebuild(e, 'lst_a', ['2026-10']);
  assert.equal((e.fake.read(`${P}/stays/ical_second`)!.conflict as { acknowledgedBy: string }).acknowledgedBy, OWNER);
  assert.equal(await reasonOf(as(e, handleReviewStay, OWNER, { stayId: 'man_first', action: 'acknowledge_conflict', note: '' })), 'invalid_argument');
});

test('restoring: a removed feed booking comes back detached from the feed; a cancelled one only if its nights are free', async () => {
  const e = env();
  const sync = { channelId: 'ch1', firstSeenAt: Timestamp.fromMillis(NOW), lastSeenAt: Timestamp.fromMillis(NOW), missCount: 3, firstMissAt: Timestamp.fromMillis(NOW), lastMissAt: Timestamp.fromMillis(NOW), needsReview: true, agedOutAt: null, detached: false };
  seedStay(e, 'airbnb_HMGONE0001', makeStay('lst_a', '2026-10-05', '2026-10-08', { source: 'airbnb', origin: 'feed', status: 'removed_from_feed', sync }));
  const restored = await as(e, handleReviewStay, MANAGER, { stayId: 'airbnb_HMGONE0001', action: 'restore', note: 'Guest confirmed' });
  assert.equal(restored.stay.status, 'confirmed');
  assert.deepEqual([restored.stay.sync?.detached, restored.stay.sync?.missCount, restored.stay.sync?.needsReview], [true, 0, false]);
  assert.equal(nightsOf(e.fake, 'lst_a', '2026-10')['2026-10-05'].s, 'airbnb_HMGONE0001');

  const c = await create(e, OWNER, booking({ checkIn: '2026-10-20', checkOut: '2026-10-22' }));
  await as(e, handleCancelStay, OWNER, { stayId: c.stayId, expectedVersion: 1, reason: 'Changed plans' });
  await create(e, OWNER, booking({ checkIn: '2026-10-21', checkOut: '2026-10-23' }));
  assert.equal(await reasonOf(as(e, handleReviewStay, OWNER, { stayId: c.stayId, action: 'restore', note: '' })), 'hard_conflict');
  const d = await create(e, OWNER, booking({ checkIn: '2026-10-25', checkOut: '2026-10-27' }));
  await as(e, handleCancelStay, OWNER, { stayId: d.stayId, expectedVersion: 1, reason: 'Oops' });
  const back = await as(e, handleReviewStay, OWNER, { stayId: d.stayId, action: 'restore', note: '' });
  assert.deepEqual([back.stay.status, back.stay.cancelledAt, back.stay.paymentStatus], ['confirmed', null, 'due']);
  assert.equal(await reasonOf(as(e, handleReviewStay, OWNER, { stayId: d.stayId, action: 'restore', note: '' })), 'invalid_argument');
});

test('clearing a review flag, and who may review', async () => {
  const e = env();
  const sync = { channelId: 'ch1', firstSeenAt: Timestamp.fromMillis(NOW), lastSeenAt: Timestamp.fromMillis(NOW), missCount: 0, firstMissAt: null, lastMissAt: null, needsReview: true, agedOutAt: null, detached: false };
  seedStay(e, 'airbnb_HMREVIEW01', makeStay('lst_a', '2026-10-05', '2026-10-08', { source: 'airbnb', origin: 'feed', sync }));
  assert.equal(await reasonOf(as(e, handleReviewStay, EMPLOYEE, { stayId: 'airbnb_HMREVIEW01', action: 'clear_review', note: '' })), 'role_not_allowed');
  assert.equal(await reasonOf(as(e, handleReviewStay, OWNER, { stayId: 'airbnb_HMREVIEW01', action: 'clear_review', note: '', expectedVersion: 9 })), 'version_mismatch');
  const cleared = await as(e, handleReviewStay, OWNER, { stayId: 'airbnb_HMREVIEW01', action: 'clear_review', note: '' });
  assert.equal(cleared.stay.sync?.needsReview, false);
  assert.equal(cleared.stay.version, 2);
  assert.equal(await reasonOf(as(e, handleReviewStay, OWNER, { stayId: 'airbnb_HMREVIEW01', action: 'clear_review', note: '' })), 'invalid_argument');
  assert.equal(await reasonOf(as(e, handleReviewStay, OWNER, { stayId: 'airbnb_HMREVIEW01', action: 'delete', note: '' })), 'invalid_argument');
});

test('the booking engine never touched a storage-side collection', () => {
  assert.ok(all.length > 0);
  for (const fake of all) fake.assertIsolation();
});

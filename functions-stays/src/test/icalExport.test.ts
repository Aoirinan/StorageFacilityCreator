import test from 'node:test';
import assert from 'node:assert/strict';

import { exportTokenHash, sha256Hex } from '@sfc/functions-shared/stays/ids';
import { parseIcs } from '@sfc/functions-shared/stays/ical';
import type { StayDoc } from '@sfc/functions-shared/stays/contracts';

import { resetStaysGateCacheForTests } from '../common/serverConfig';
import { ExportRequest, createIcalExportHandler, fetcherFamily } from '../sync/icalExport';
import { createExportLinkHandler, revokeExportLinkHandler } from '../sync/exportLinks';
import { FakeFirestore } from './support/fakeFirestore';
import { OWNER, callableContext, makeStay, seedControls, seedGate } from './support/staysFixtures';
import { FAC, LISTING, MIN, NOW, P, SyncWorld, syncWorld } from './support/syncFixtures';

const all: FakeFirestore[] = [];
const TZ = 'America/Denver';

interface Captured {
  statusCode: number;
  headers: Record<string, string>;
  body: string | undefined;
  ended: boolean;
}

function world(controls: Record<string, unknown> = {}, gate: Record<string, unknown> = {}): SyncWorld {
  const w = syncWorld({ channel: false, controls: { icalExportEnabled: true, ...controls }, gate });
  all.push(w.fake);
  const stay = (id: string, checkIn: string, checkOut: string, patch: Partial<StayDoc>) =>
    w.fake.seed(`${P.stays}/${id}`, makeStay(LISTING, checkIn, checkOut, patch) as unknown as Record<string, unknown>);
  stay('man_owner', '2026-10-10', '2026-10-12', { kind: 'owner_block', source: 'owner', guestDisplayName: '' });
  stay('man_direct', '2026-10-12', '2026-10-14', { source: 'direct', guestDisplayName: 'Jane D.', staffNotes: 'Gate code 4455' });
  stay('man_walk', '2026-10-20', '2026-10-21', { source: 'walk_up', guestDisplayName: 'Rig Owner' });
  stay('airbnb_HMEXPORT01', '2026-10-03', '2026-10-06', { source: 'airbnb', origin: 'feed' });
  stay('ical_vrbo', '2026-10-25', '2026-10-27', { source: 'vrbo', origin: 'feed' });
  stay('man_cancel', '2026-10-15', '2026-10-16', { source: 'direct', status: 'cancelled' });
  stay('man_past', '2026-09-01', '2026-09-03', { source: 'direct' });
  stay('man_other_listing', '2026-10-15', '2026-10-17', { source: 'direct', listingId: 'lst_other' });
  // Imported channel blocks on this listing: never exported.
  w.fake.seed(`${P.blocks}/ch_x`, { facilityId: FAC, listingId: LISTING, provider: 'airbnb', ranges: [{ checkIn: '2026-11-01', checkOut: '2026-11-10', echo: false }] });
  return w;
}

/** Seeds a link and its token lookup directly (so a paused platform can still be tested). */
function seedLink(w: SyncWorld, opts: { scope?: string; target?: string; active?: boolean; tokenActive?: boolean; id?: string } = {}): string {
  const id = opts.id ?? 'xl_test';
  const token = sha256Hex(`token:${id}`).slice(0, 48);
  w.fake.seed(`${P.links}/${id}`, {
    facilityId: FAC,
    listingId: LISTING,
    targetProvider: opts.target ?? 'airbnb',
    label: 'SFC',
    scope: opts.scope ?? 'blocks_only',
    active: opts.active ?? true,
    stats: { lastFetchedAt: null, lastFetcher: null, lastStatus: null, statsWrittenAt: null },
  });
  w.fake.seed(`${P.links}/${id}/secret/current`, { token });
  w.fake.seed(`stayCalendarExportTokens/${exportTokenHash(token)}`, { facilityId: FAC, listingId: LISTING, linkId: id, active: opts.tokenActive ?? true });
  return token;
}

async function fetchFeed(w: SyncWorld, path: string, opts: { method?: string; ua?: string; ip?: string } = {}): Promise<Captured> {
  const res: Captured & {
    status(c: number): typeof res;
    set(h: Record<string, string>): typeof res;
    send(b: string): void;
    end(): void;
  } = {
    statusCode: 0,
    headers: {},
    body: undefined,
    ended: false,
    status(c) {
      this.statusCode = c;
      return this;
    },
    set(h) {
      Object.assign(this.headers, h);
      return this;
    },
    send(b) {
      this.body = b;
      this.ended = true;
    },
    end() {
      this.ended = true;
    },
  };
  const req: ExportRequest = { method: opts.method ?? 'GET', path, ip: opts.ip ?? '203.0.113.9', headers: { 'user-agent': opts.ua ?? 'Airbnb/1.0 (calendar sync)' } };
  await createIcalExportHandler({ db: () => w.fake.firestore(), now: () => w.now.ms })(req, res);
  return res;
}

const path = (token: string) => `/api/ical/${token}.ics`;

function nightsIn(body: string): string[][] {
  return parseIcs(body, TZ).events.map((e) => [e.checkIn, e.checkOut]);
}

test('a live link answers 200 with busy blocks only, uncached and unindexed', async () => {
  const w = world();
  const token = seedLink(w);
  const res = await fetchFeed(w, path(token));
  assert.equal(res.statusCode, 200);
  assert.equal(res.headers['Content-Type'], 'text/calendar; charset=utf-8');
  assert.equal(res.headers['Cache-Control'], 'no-store');
  assert.equal(res.headers['X-Robots-Tag'], 'noindex');
  assert.deepEqual(nightsIn(res.body!), [['2026-10-10', '2026-10-12']]);
  assert.match(res.body!, /X-WR-CALNAME:SFC Airbnb 1/);
});

test('scope decides what goes out, and the target channel never gets its own bookings back', async () => {
  const w = world();
  const sfc = seedLink(w, { id: 'xl_sfc', scope: 'sfc' });
  assert.deepEqual(nightsIn((await fetchFeed(w, path(sfc))).body!), [
    ['2026-10-10', '2026-10-12'],
    ['2026-10-12', '2026-10-14'],
    ['2026-10-20', '2026-10-21'],
  ]);
  const everything = seedLink(w, { id: 'xl_all1', scope: 'all' });
  assert.deepEqual(nightsIn((await fetchFeed(w, path(everything))).body!), [
    ['2026-10-10', '2026-10-12'],
    ['2026-10-12', '2026-10-14'],
    ['2026-10-20', '2026-10-21'],
    ['2026-10-25', '2026-10-27'],
  ]);
  const toVrbo = seedLink(w, { id: 'xl_vrbo2', scope: 'all', target: 'vrbo' });
  assert.deepEqual(nightsIn((await fetchFeed(w, path(toVrbo))).body!), [
    ['2026-10-03', '2026-10-06'],
    ['2026-10-10', '2026-10-12'],
    ['2026-10-12', '2026-10-14'],
    ['2026-10-20', '2026-10-21'],
  ]);
});

test('no guest data, stay ids, notes or imported blocks ever leave in the feed', async () => {
  const w = world();
  const token = seedLink(w, { scope: 'all', target: 'google' });
  const body = (await fetchFeed(w, path(token))).body!;
  for (const secret of ['Jane', 'Rig Owner', 'man_', 'airbnb_', 'HMEXPORT01', 'ical_vrbo', '4455', 'DESCRIPTION', 'direct', 'walk_up']) {
    assert.equal(body.includes(secret), false, secret);
  }
  // The imported block (Nov 1–10) is not ours to export; cancelled, past and other listings' stays are out.
  const nights = nightsIn(body).map((n) => n[0]);
  assert.equal(nights.includes('2026-11-01'), false);
  assert.equal(nights.includes('2026-10-15'), false);
  assert.equal(nights.includes('2026-09-01'), false);
  assert.equal((body.match(/SUMMARY:Not available/g) ?? []).length, nights.length);
});

test('unknown, malformed and revoked tokens are 404', async () => {
  const w = world();
  for (const p of [
    path('0'.repeat(48)),
    '/api/ical/abc.ics',
    `/api/ical/${'A'.repeat(48)}.ics`,
    `/api/ical/${'a'.repeat(48)}.ics/x`,
    `/api/ical/${'a'.repeat(48)}`,
    '/',
  ]) {
    const res = await fetchFeed(w, p);
    assert.equal(res.statusCode, 404, p);
    assert.equal(res.headers['Cache-Control'], 'no-store');
  }
  // A token revoked through the callable stops working at once.
  const created = await createExportLinkHandler(
    { facilityId: FAC, listingId: LISTING, targetProvider: 'airbnb', label: 'x' },
    callableContext(OWNER),
    w.handle.deps,
  );
  const token = /\/api\/ical\/([a-f0-9]{48})\.ics$/.exec(created.url)![1];
  assert.equal((await fetchFeed(w, path(token))).statusCode, 200);
  await revokeExportLinkHandler({ facilityId: FAC, linkId: created.linkId }, callableContext(OWNER), w.handle.deps);
  assert.equal((await fetchFeed(w, path(token))).statusCode, 404);
  const inactiveToken = seedLink(w, { id: 'xl_dead1', tokenActive: false });
  assert.equal((await fetchFeed(w, path(inactiveToken))).statusCode, 404);
});

test('503 with Retry-After on every "not now", never an empty calendar', async () => {
  const cases: [string, (w: SyncWorld) => void][] = [
    ['kill switch', (w) => seedGate(w.fake, { killSwitch: true })],
    ['not allowlisted', (w) => seedGate(w.fake, { allowlistFacilityIds: ['someone-else'] })],
    ['no platform config', (w) => w.fake.seed('staysServerConfig/current', {})],
    ['module off', (w) => seedControls(w.fake, { icalExportEnabled: true, moduleEnabled: false })],
    ['export off', (w) => seedControls(w.fake, { icalExportEnabled: false })],
    ['zone unconfirmed', (w) => seedControls(w.fake, { icalExportEnabled: true, timeZoneConfirmedAt: null })],
    ['link revoked but lookup still active', (w) => w.fake.seed(`${P.links}/xl_test`, { ...w.fake.read(`${P.links}/xl_test`), active: false })],
    ['a read fails', (w) => (w.fake.failReads = (p) => p.includes('/stayListings/'))],
    ['the token lookup fails', (w) => (w.fake.failReads = (p) => p.startsWith('stayCalendarExportTokens/'))],
  ];
  for (const [name, breakIt] of cases) {
    const w = world();
    const token = seedLink(w);
    resetStaysGateCacheForTests();
    breakIt(w);
    const res = await fetchFeed(w, path(token));
    assert.equal(res.statusCode, 503, name);
    assert.equal(res.headers['Retry-After'], '900', name);
    assert.equal(res.headers['Cache-Control'], 'no-store', name);
    assert.equal((res.body ?? '').includes('BEGIN:VCALENDAR'), false, name);
  }
});

test('only GET and HEAD; HEAD sends headers and no body', async () => {
  const w = world();
  const token = seedLink(w);
  const post = await fetchFeed(w, path(token), { method: 'POST' });
  assert.equal(post.statusCode, 405);
  assert.equal(post.headers.Allow, 'GET, HEAD');
  const head = await fetchFeed(w, path(token), { method: 'HEAD' });
  assert.equal(head.statusCode, 200);
  assert.equal(head.body, undefined);
  assert.equal(head.ended, true);
  assert.equal(head.headers['Content-Type'], 'text/calendar; charset=utf-8');
});

test('fetch telemetry names the fetcher and is written at most every 10 minutes', async () => {
  const w = world();
  const token = seedLink(w);
  const linkWrites = () => w.fake.writesTo('stayExportLinks').length;
  const before = linkWrites();
  await fetchFeed(w, path(token), { ua: 'Airbnb/1.0' });
  const stats = w.fake.read(`${P.links}/xl_test`)?.stats as Record<string, unknown>;
  assert.equal(stats.lastFetcher, 'airbnb');
  assert.equal(stats.lastStatus, 200);
  assert.equal((stats.lastFetchedAt as { toMillis(): number }).toMillis(), NOW);
  assert.equal(linkWrites(), before + 1);
  w.now.ms += 5 * MIN;
  await fetchFeed(w, path(token), { ua: 'Google-Calendar-Importer' });
  assert.equal(linkWrites(), before + 1);
  w.now.ms += 6 * MIN;
  await fetchFeed(w, path(token), { ua: 'Google-Calendar-Importer' });
  assert.equal(linkWrites(), before + 2);
  assert.equal((w.fake.read(`${P.links}/xl_test`)?.stats as Record<string, unknown>).lastFetcher, 'google');
  assert.equal(fetcherFamily('Mozilla/5.0 (compatible; HomeAway-iCal)'), 'vrbo');
  assert.equal(fetcherFamily('Booking.com calendar'), 'booking');
  assert.equal(fetcherFamily('curl/8.0'), 'other');
});

test('30 fetches a minute per token, then 429', async () => {
  const w = world();
  const token = seedLink(w);
  for (let i = 0; i < 30; i++) assert.equal((await fetchFeed(w, path(token))).statusCode, 200);
  const limited = await fetchFeed(w, path(token));
  assert.equal(limited.statusCode, 429);
  assert.equal(limited.headers['Retry-After'], '60');
  w.now.ms += MIN;
  assert.equal((await fetchFeed(w, path(token))).statusCode, 200);
});

test('isolation: the export feed never touched a storage collection', () => {
  for (const fake of all) fake.assertIsolation();
});

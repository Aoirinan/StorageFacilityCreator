import test from 'node:test';
import assert from 'node:assert/strict';

import { exportTokenHash, sha256Hex } from '@sfc/functions-shared/stays/ids';
import { parseIcs } from '@sfc/functions-shared/stays/ical';
import type { StayDoc } from '@sfc/functions-shared/stays/contracts';

import { resetStaysGateCacheForTests } from '../common/serverConfig';
import { ExportRequest, clientIp, createIcalExportHandler, fetcherFamily, ipRateKey } from '../sync/icalExport';
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

/** A second facility with Stays and export on, one listing and one live link; returns its token. */
function otherFacilityLink(w: SyncWorld): string {
  const fac = 'fac-two';
  seedGate(w.fake, { allowlistFacilityIds: [FAC, fac] });
  resetStaysGateCacheForTests();
  w.fake.seed(`facilities/${fac}`, { name: 'Other Storage', ownerUid: 'uid-two', timeZone: TZ, roles: { 'uid-two': 'owner' } });
  w.fake.seed(`facilities/${fac}/stayControls/current`, {
    ...w.fake.read(`facilities/${FAC}/stayControls/current`),
    facilityId: fac,
  });
  w.fake.seed(`facilities/${fac}/stayListings/lst_two`, { facilityId: fac, name: 'Site 1', active: true, archived: false });
  const token = sha256Hex('token:fac-two').slice(0, 48);
  w.fake.seed(`facilities/${fac}/stayExportLinks/xl_two`, {
    facilityId: fac,
    listingId: 'lst_two',
    targetProvider: 'airbnb',
    label: 'SFC',
    scope: 'blocks_only',
    active: true,
    stats: { lastFetchedAt: null, lastFetcher: null, lastStatus: null, statsWrittenAt: null },
  });
  w.fake.seed(`stayCalendarExportTokens/${exportTokenHash(token)}`, { facilityId: fac, listingId: 'lst_two', linkId: 'xl_two', active: true });
  return token;
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

async function fetchFeed(
  w: SyncWorld,
  path: string,
  opts: { method?: string; ua?: string; ip?: string; headers?: Record<string, string> } = {},
): Promise<Captured> {
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
  const req: ExportRequest = {
    method: opts.method ?? 'GET',
    path,
    ip: opts.ip ?? '203.0.113.9',
    headers: { 'user-agent': opts.ua ?? 'Airbnb/1.0 (calendar sync)', ...(opts.headers ?? {}) },
  };
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

test("a named channel never gets its own bookings back; an 'other' link gets every channel's", async () => {
  const w = world();
  const ext = (provider: string) => ({ provider, uid: `${provider}-uid`, uidHistory: [], confirmationCode: null, reservationUrl: null, summary: null });
  const seed = (id: string, checkIn: string, checkOut: string, patch: Partial<StayDoc>) =>
    w.fake.seed(`${P.stays}/${id}`, makeStay(LISTING, checkIn, checkOut, patch) as unknown as Record<string, unknown>);
  // From a Hipcamp feed, typed in as Hipcamp, from a Google feed, typed in as "other channel", from an 'other' feed.
  seed('ical_hip', '2026-11-03', '2026-11-05', { source: 'hipcamp', origin: 'feed', external: ext('hipcamp') as StayDoc['external'] });
  seed('man_hip', '2026-11-05', '2026-11-07', { source: 'hipcamp', origin: 'sfc', external: null });
  seed('ical_goog', '2026-11-07', '2026-11-09', { source: 'other_channel', origin: 'feed', external: ext('google') as StayDoc['external'] });
  seed('man_other', '2026-11-11', '2026-11-13', { source: 'other_channel', origin: 'sfc', external: ext('other') as StayDoc['external'] });
  seed('ical_other', '2026-11-13', '2026-11-15', { source: 'other_channel', origin: 'feed', external: ext('other') as StayDoc['external'] });
  const november = async (target: string) =>
    nightsIn((await fetchFeed(w, path(seedLink(w, { id: `xl_${target}`, scope: 'all', target })))).body!)
      .map((n) => n[0])
      .filter((d) => d >= '2026-11-01');
  // Hipcamp imports a 'hipcamp' link: its own bookings (feed or typed in) stay out, every other channel's go.
  assert.deepEqual(await november('hipcamp'), ['2026-11-07', '2026-11-11', '2026-11-13']);
  assert.deepEqual(await november('google'), ['2026-11-03', '2026-11-05', '2026-11-11', '2026-11-13']);
  // 'other' is any site without a target of its own: it must see every channel's bookings, or it could sell their nights.
  assert.deepEqual(await november('other'), ['2026-11-03', '2026-11-05', '2026-11-07', '2026-11-11', '2026-11-13']);
});

test('a token whose lookup names another listing than its link is refused with 503', async () => {
  const w = world();
  const token = seedLink(w);
  const lookup = `stayCalendarExportTokens/${exportTokenHash(token)}`;
  w.fake.seed(lookup, { ...w.fake.read(lookup), listingId: 'lst_other' });
  const res = await fetchFeed(w, path(token));
  assert.equal(res.statusCode, 503);
  assert.equal((res.body ?? '').includes('BEGIN:VCALENDAR'), false);
});

test('guessed tokens write nothing: only known tokens are rate-limited', async () => {
  const w = world();
  const before = w.fake.writesTo('rateLimits').length;
  for (let i = 0; i < 20; i++) assert.equal((await fetchFeed(w, path(sha256Hex(`guess:${i}`).slice(0, 48)))).statusCode, 404);
  assert.equal(w.fake.writesTo('rateLimits').length, before);
  await fetchFeed(w, path(seedLink(w)));
  assert.ok(w.fake.writesTo('rateLimits').length > before);
});

test('300 fetches a minute per client address across one facility\'s tokens, keyed on the address Hosting saw', async () => {
  const w = world();
  const tokens = Array.from({ length: 11 }, (_, i) => seedLink(w, { id: `xl_ip${i}` }));
  const USER = '198.51.100.7';
  // Behind the Hosting rewrite every caller arrives through the same Google hops.
  const GOOGLE_HOP = '35.191.0.10';
  const viaHosting = (user: string, claimed: string) => ({
    'fastly-client-ip': user,
    'x-forwarded-for': `${claimed}, ${GOOGLE_HOP}`,
    'x-appengine-user-ip': GOOGLE_HOP,
  });
  let n = 0;
  for (const token of tokens) {
    for (let j = 0; j < 28 && n < 300; j++, n++) {
      // The caller rotates what it claims in X-Forwarded-For (what Express reports as req.ip).
      const claimed = `10.9.${j}.${n % 250}`;
      assert.equal((await fetchFeed(w, path(token), { headers: viaHosting(USER, claimed), ip: claimed })).statusCode, 200, `fetch ${n}`);
    }
  }
  const over = await fetchFeed(w, path(tokens[10]), { headers: viaHosting(USER, '1.2.3.4'), ip: '1.2.3.4' });
  assert.equal(over.statusCode, 429);
  assert.equal(over.headers['Retry-After'], '60');
  // Another user behind the same Google hops is not held up by it.
  assert.equal((await fetchFeed(w, path(tokens[10]), { headers: viaHosting('203.0.113.50', '1.2.3.4'), ip: '1.2.3.4' })).statusCode, 200);
  // Nor is another facility's link fetched from the same address (a channel's fetcher serves every
  // SFC customer, and the address may be one the caller chose).
  const other = otherFacilityLink(w);
  assert.equal((await fetchFeed(w, path(other), { headers: viaHosting(USER, '1.2.3.4'), ip: '1.2.3.4' })).statusCode, 200);
  assert.notEqual(ipRateKey(FAC, USER), ipRateKey('fac-two', USER));
  // A direct call to the function URL (no CDN header) is keyed on the platform's view of the peer.
  assert.equal(clientIp({ headers: { 'x-appengine-user-ip': '198.51.100.8', 'x-forwarded-for': '6.6.6.6' }, ip: '6.6.6.6' }), '198.51.100.8');
  assert.equal(clientIp({ headers: {}, ip: '192.0.2.1' }), '192.0.2.1');
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
  assert.equal(fetcherFamily('Hipcamp-Calendar-Sync/2.1'), 'hipcamp');
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

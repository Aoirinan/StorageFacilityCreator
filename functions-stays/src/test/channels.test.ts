import test from 'node:test';
import assert from 'node:assert/strict';
import { Timestamp } from 'firebase-admin/firestore';

import type { StaysUpsertChannelCommitted, StaysUpsertChannelPreview } from '@sfc/functions-shared/stays/contracts';

import { staysErrorReason } from '../common/errors';
import { removeChannelHandler, syncNowHandler, upsertChannelHandler } from '../sync/channels';
import { FakeFirestore } from './support/fakeFirestore';
import { EMPLOYEE, MANAGER, OWNER, VIEWER, callableContext } from './support/staysFixtures';
import { CHANNEL, FAC, FEED_URL, LISTING, MIN, P, SyncWorld, nightsOf, seedListing, syncWorld } from './support/syncFixtures';

const all: FakeFirestore[] = [];

function world(opts: Parameters<typeof syncWorld>[0] = {}): SyncWorld {
  const w = syncWorld({ channel: false, ...opts });
  all.push(w.fake);
  return w;
}

async function reasonOf(p: Promise<unknown>): Promise<string | null> {
  try {
    await p;
    return null;
  } catch (error) {
    return staysErrorReason(error) ?? `untyped: ${String(error)}`;
  }
}

const EVENTS = [
  { code: 'HMCHAN0001', checkIn: '2026-10-03', checkOut: '2026-10-06' },
  { code: 'HMCHAN0002', checkIn: '2026-10-10', checkOut: '2026-10-12' },
  { checkIn: '2026-10-20', checkOut: '2026-10-25' },
  { checkIn: '2028-03-01', checkOut: '2028-07-01' },
];

function upsert(w: SyncWorld, uid: string, patch: Record<string, unknown> = {}) {
  return upsertChannelHandler(
    { facilityId: FAC, listingId: LISTING, provider: 'airbnb', label: 'Airbnb 1', url: FEED_URL, importBlocks: true, dryRun: true, ...patch },
    callableContext(uid),
    w.callableDeps,
  );
}

test('the preview fetches and counts the feed, and writes nothing', async () => {
  const w = world();
  w.feed.set(EVENTS);
  const writes = w.fake.writeLog.length;
  const preview = (await upsert(w, OWNER)) as StaysUpsertChannelPreview;
  assert.equal(preview.dryRun, true);
  assert.equal(preview.status, 'ok');
  assert.equal(preview.reservations, 2);
  assert.equal(preview.blocks, 2);
  assert.equal(preview.nextArrival, '2026-10-03');
  assert.equal(preview.firstDate, '2026-10-03');
  assert.equal(preview.lastDate, '2028-03-24');
  assert.deepEqual(preview.warnings.map((x) => x.code), ['far_future_clamped']);
  assert.equal(w.fake.writeLog.length, writes);
  assert.equal(w.fake.list(P.channels).length, 0);
  assert.equal(w.feed.calls[0].url, FEED_URL);

  w.feed.set([]);
  const empty = (await upsert(w, MANAGER)) as StaysUpsertChannelPreview;
  assert.deepEqual([empty.reservations, empty.blocks, empty.nextArrival], [0, 0, null]);
  assert.deepEqual(empty.warnings.map((x) => x.code), ['feed_empty']);
});

test('previews are limited to 10 an hour per person', async () => {
  const w = world();
  w.feed.set(EVENTS);
  for (let i = 0; i < 10; i++) await upsert(w, OWNER);
  assert.equal(await reasonOf(upsert(w, OWNER)), 'rate_limited');
  assert.equal(await reasonOf(upsert(w, MANAGER)), null);
});

test('a link from an unknown site, a login page or a dead link is explained, not saved', async () => {
  const w = world();
  assert.equal(await reasonOf(upsert(w, OWNER, { url: 'https://calendar.evil.example/cal.ics' })), 'feed_host_not_allowed');
  assert.equal(await reasonOf(upsert(w, OWNER, { url: 'https://user:pw@www.airbnb.com/cal.ics' })), 'feed_host_not_allowed');
  assert.equal(await reasonOf(upsert(w, OWNER, { url: 'https://www.airbnb.com:8443/cal.ics', dryRun: false })), 'feed_host_not_allowed');
  assert.equal(w.feed.calls.length, 0);
  w.feed.setText('<html><body>Log in</body></html>');
  assert.equal(await reasonOf(upsert(w, OWNER)), 'feed_invalid');
  w.feed.fail('invalid_feed', 200);
  assert.equal(await reasonOf(upsert(w, OWNER)), 'feed_invalid');
  w.feed.fail('gone', 404);
  assert.equal(await reasonOf(upsert(w, OWNER)), 'feed_fetch_failed');
  w.feed.fail('too_large', 200);
  assert.equal(await reasonOf(upsert(w, OWNER)), 'feed_too_large');
  assert.equal(w.fake.list(P.channels).length, 0);
});

test('a host added by the platform config is accepted', async () => {
  const w = world({ gate: { extraIcalHosts: ['www.hipcamp.com'] } });
  w.feed.set(EVENTS);
  const preview = await upsert(w, OWNER, { provider: 'hipcamp', url: 'https://www.hipcamp.com/ical/abc.ics' });
  assert.equal(preview.dryRun, true);
});

test('saving connects the feed, keeps the URL secret, and runs the first sync', async () => {
  const w = world();
  w.feed.set(EVENTS);
  const saved = (await upsert(w, OWNER, { dryRun: false })) as StaysUpsertChannelCommitted;
  assert.equal(saved.dryRun, false);
  assert.match(saved.channelId, /^ch_[a-f0-9]{20}$/);
  assert.equal(saved.urlHost, 'www.airbnb.com');
  assert.match(saved.urlFingerprint, /^[a-f0-9]{12}$/);
  assert.equal(saved.firstSync.status, 'ok');
  assert.equal(saved.firstSync.created, 2);

  const ch = w.fake.read(`${P.channels}/${saved.channelId}`)!;
  assert.equal(ch.listingId, LISTING);
  assert.equal(ch.active, true);
  assert.equal(ch.label, 'Airbnb 1');
  assert.equal(JSON.stringify(ch).includes('0123456789abcdef'), false, 'the URL is not on the readable channel doc');
  assert.equal(w.fake.read(`${P.channels}/${saved.channelId}/secret/current`)?.url, FEED_URL);
  assert.equal(w.fake.list(P.stays).length, 2);

  const audit = w.handle.audits.find((a) => a.entry.eventType === 'stays.channel.saved')!;
  assert.equal(audit.entry.actorUid, OWNER);
  assert.equal(JSON.stringify(audit).includes('0123456789abcdef'), false, 'the URL is never audited');

  // The same link twice on one listing is refused.
  assert.equal(await reasonOf(upsert(w, OWNER, { dryRun: false })), 'invalid_argument');
  // Renaming the saved channel is fine.
  const renamed = (await upsert(w, MANAGER, { dryRun: false, channelId: saved.channelId, label: 'Main Airbnb' })) as StaysUpsertChannelCommitted;
  assert.equal(renamed.channelId, saved.channelId);
  assert.equal(w.fake.read(`${P.channels}/${saved.channelId}`)?.label, 'Main Airbnb');
});

test('one calendar link feeds one listing: pasting it on a second listing is refused until it is removed from the first', async () => {
  const w = world();
  w.feed.set(EVENTS);
  seedListing(w.fake, 'lst_rv2', { name: 'RV 2', shortCode: 'R2' });
  const saved = (await upsert(w, OWNER, { dryRun: false })) as StaysUpsertChannelCommitted;
  let refused: unknown = null;
  try {
    await upsert(w, OWNER, { dryRun: false, listingId: 'lst_rv2', label: 'Wrong link' });
  } catch (error) {
    refused = error;
  }
  assert.equal(staysErrorReason(refused), 'invalid_argument');
  assert.match((refused as Error).message, /already connected to another listing/);
  assert.deepEqual(
    (({ channelId, listingId }) => ({ channelId, listingId }))((refused as { details: { channelId: string; listingId: string } }).details),
    { channelId: saved.channelId, listingId: LISTING },
  );
  assert.equal(w.fake.list(P.channels).filter((c) => c.data.listingId === 'lst_rv2').length, 0);
  // Moved on purpose (removed from the first listing, then added to the second): accepted.
  await removeChannelHandler({ facilityId: FAC, channelId: saved.channelId }, callableContext(OWNER), w.callableDeps);
  w.now.ms += 5 * MIN;
  const again = (await upsert(w, OWNER, { dryRun: false, listingId: 'lst_rv2' })) as StaysUpsertChannelCommitted;
  assert.equal(w.fake.read(`${P.channels}/${again.channelId}`)?.listingId, 'lst_rv2');
});

test('at most 4 feeds per listing', async () => {
  const w = world();
  w.feed.set(EVENTS);
  for (let i = 0; i < 4; i++) await upsert(w, OWNER, { dryRun: false, url: `${FEED_URL}&n=${i}` });
  assert.equal(await reasonOf(upsert(w, OWNER, { dryRun: false, url: `${FEED_URL}&n=9` })), 'limit_reached');
});

test('only owners and managers manage feeds; archived listings take none', async () => {
  const w = world();
  w.feed.set(EVENTS);
  assert.equal(await reasonOf(upsert(w, EMPLOYEE)), 'role_not_allowed');
  assert.equal(await reasonOf(upsert(w, VIEWER)), 'role_not_allowed');
  seedListing(w.fake, 'lst_old', { archived: true });
  assert.equal(await reasonOf(upsert(w, OWNER, { listingId: 'lst_old' })), 'listing_inactive');
  assert.equal(await reasonOf(upsert(w, OWNER, { provider: 'expedia' })), 'invalid_argument');
  assert.equal(await reasonOf(syncNowHandler({ facilityId: FAC }, callableContext(EMPLOYEE), w.callableDeps)), 'role_not_allowed');
});

test('removing a feed drops its soft blocks, keeps its bookings (detached), and deletes the secret; re-adding adopts them', async () => {
  const w = world();
  w.feed.set(EVENTS);
  const saved = (await upsert(w, OWNER, { dryRun: false })) as StaysUpsertChannelCommitted;
  assert.equal(nightsOf(w.fake, '2026-10')['2026-10-21'].h, false);

  const removed = await removeChannelHandler({ facilityId: FAC, channelId: saved.channelId }, callableContext(OWNER), w.callableDeps);
  assert.deepEqual(removed, { channelId: saved.channelId, detachedStays: 2 });
  assert.equal(w.fake.read(`${P.channels}/${saved.channelId}`)?.active, false);
  assert.equal(w.fake.has(`${P.channels}/${saved.channelId}/secret/current`), false);
  assert.deepEqual(w.fake.read(`${P.blocks}/${saved.channelId}`)?.ranges, []);
  assert.equal(nightsOf(w.fake, '2026-10')['2026-10-21'], undefined);
  const kept = w.fake.read(`${P.stays}/airbnb_HMCHAN0001`)!;
  assert.equal(kept.status, 'confirmed');
  assert.equal((kept.sync as { detached: boolean }).detached, true);
  assert.equal(nightsOf(w.fake, '2026-10')['2026-10-03'].s, 'airbnb_HMCHAN0001');
  assert.ok(w.handle.audits.some((a) => a.entry.eventType === 'stays.channel.removed'));

  // Paste the same link again: the same stays are taken back, none duplicated.
  w.now.ms += 5 * MIN;
  const again = (await upsert(w, OWNER, { dryRun: false })) as StaysUpsertChannelCommitted;
  assert.notEqual(again.channelId, saved.channelId);
  assert.equal(again.firstSync.created, 0);
  assert.equal(w.fake.list(P.stays).length, 2);
  const back = w.fake.read(`${P.stays}/airbnb_HMCHAN0001`)!;
  assert.equal((back.sync as { channelId: string; detached: boolean }).channelId, again.channelId);
  assert.equal((back.sync as { detached: boolean }).detached, false);
});

test('a feed cannot be removed while it is syncing', async () => {
  const w = world({ channel: true });
  const ch = w.fake.read(`${P.channels}/${CHANNEL}`)!;
  w.fake.seed(`${P.channels}/${CHANNEL}`, { ...ch, sync: { ...(ch.sync as object), lease: { runId: 'r', expiresAt: Timestamp.fromMillis(w.now.ms + MIN) } } });
  assert.equal(await reasonOf(removeChannelHandler({ facilityId: FAC, channelId: CHANNEL }, callableContext(OWNER), w.callableDeps)), 'contention');
  assert.equal(await reasonOf(removeChannelHandler({ facilityId: FAC, channelId: 'ch_nope' }, callableContext(OWNER), w.callableDeps)), 'not_found');
});

test('changing a feed link or block import waits for a sync in flight; a rename does not', async () => {
  const w = world();
  w.feed.set(EVENTS);
  const saved = (await upsert(w, OWNER, { dryRun: false })) as StaysUpsertChannelCommitted;
  const path = `${P.channels}/${saved.channelId}`;
  const lease = (expiresAt: number) => {
    const ch = w.fake.read(path)!;
    w.fake.seed(path, { ...ch, sync: { ...(ch.sync as object), lease: { runId: 'r', expiresAt: Timestamp.fromMillis(expiresAt) } } });
  };
  lease(w.now.ms + MIN);
  const sha = (w.fake.read(path)!.sync as { contentSha256: string }).contentSha256;
  assert.equal(await reasonOf(upsert(w, OWNER, { dryRun: false, channelId: saved.channelId, importBlocks: false })), 'contention');
  assert.equal(await reasonOf(upsert(w, OWNER, { dryRun: false, channelId: saved.channelId, url: `${FEED_URL}&n=2` })), 'contention');
  assert.equal(w.fake.read(path)?.importBlocks, true);
  assert.equal((w.fake.read(path)!.sync as { contentSha256: string }).contentSha256, sha);
  const renamed = (await upsert(w, OWNER, { dryRun: false, channelId: saved.channelId, label: 'Main Airbnb' })) as StaysUpsertChannelCommitted;
  assert.equal(renamed.firstSync.skipped, true, 'the rename saved; its sync gave way to the one in flight');
  assert.equal(w.fake.read(path)?.label, 'Main Airbnb');

  // Once that sync is over (or its lease lapsed), the switch goes through and the blocks go.
  lease(w.now.ms - 1);
  await upsert(w, OWNER, { dryRun: false, channelId: saved.channelId, label: 'Main Airbnb', importBlocks: false });
  assert.equal(w.fake.read(path)?.importBlocks, false);
  assert.deepEqual(w.fake.read(`${P.blocks}/${saved.channelId}`)?.ranges, []);
});

test('Sync now: once a minute per feed, 20 a day per facility', async () => {
  const w = world({ channel: true });
  w.feed.set(EVENTS);
  const first = await syncNowHandler({ facilityId: FAC, channelId: CHANNEL }, callableContext(OWNER), w.callableDeps);
  assert.equal(first.results.length, 1);
  assert.equal(first.results[0].created, 2);
  assert.equal(await reasonOf(syncNowHandler({ facilityId: FAC, channelId: CHANNEL }, callableContext(OWNER), w.callableDeps)), 'rate_limited');
  // "Sync all" skips a feed synced in the last minute instead of failing.
  const allNow = await syncNowHandler({ facilityId: FAC }, callableContext(MANAGER), w.callableDeps);
  assert.deepEqual(allNow.results.map((r) => [r.channelId, r.skipped === true]), [[CHANNEL, true]]);
  assert.ok(w.handle.audits.some((a) => a.entry.eventType === 'stays.channel.synced_manually'));
  assert.ok(w.handle.rateLimitKeys.includes('stays_sync_now'));
  assert.equal(await reasonOf(syncNowHandler({ facilityId: FAC, channelId: 'ch_nope' }, callableContext(OWNER), w.callableDeps)), 'not_found');
});

test('isolation: the channel callables never touched a storage collection', () => {
  for (const fake of all) fake.assertIsolation();
});

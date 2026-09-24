import test from 'node:test';
import assert from 'node:assert/strict';

import { exportTokenHash } from '@sfc/functions-shared/stays/ids';

import { staysErrorReason } from '../common/errors';
import {
  createExportLinkHandler,
  getExportUrlHandler,
  revokeExportLinkHandler,
  updateExportLinkHandler,
} from '../sync/exportLinks';
import { FakeFirestore } from './support/fakeFirestore';
import { EMPLOYEE, MANAGER, OWNER, VIEWER, callableContext } from './support/staysFixtures';
import { FAC, LISTING, P, SyncWorld, seedListing, syncWorld } from './support/syncFixtures';

const all: FakeFirestore[] = [];
const URL_RE = /^https:\/\/app\.storagefacilitycreator\.com\/api\/ical\/([a-f0-9]{48})\.ics$/;

function world(): SyncWorld {
  const w = syncWorld({ channel: false });
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

function create(w: SyncWorld, uid = OWNER, patch: Record<string, unknown> = {}) {
  return createExportLinkHandler({ facilityId: FAC, listingId: LISTING, targetProvider: 'airbnb', label: 'SFC to Airbnb', ...patch }, callableContext(uid), w.handle.deps);
}

test('creating a link stores the token only as a secret and a hash lookup; the URL is returned once', async () => {
  const w = world();
  const { linkId, url } = await create(w);
  const token = URL_RE.exec(url)?.[1];
  assert.ok(token, url);
  assert.match(linkId, /^xl_[a-f0-9]{20}$/);
  const link = w.fake.read(`${P.links}/${linkId}`)!;
  assert.deepEqual(
    { listingId: link.listingId, targetProvider: link.targetProvider, scope: link.scope, active: link.active, label: link.label },
    { listingId: LISTING, targetProvider: 'airbnb', scope: 'blocks_only', active: true, label: 'SFC to Airbnb' },
  );
  assert.equal(JSON.stringify(link).includes(token), false);
  assert.equal(w.fake.read(`${P.links}/${linkId}/secret/current`)?.token, token);
  const lookup = w.fake.read(`stayCalendarExportTokens/${exportTokenHash(token!)}`)!;
  assert.deepEqual(lookup.facilityId, FAC);
  assert.deepEqual([lookup.listingId, lookup.linkId, lookup.active], [LISTING, linkId, true]);
  const audit = w.handle.audits.find((a) => a.entry.eventType === 'stays.export_link.created')!;
  assert.equal(JSON.stringify(audit).includes(token!), false, 'the token is never audited');
  assert.deepEqual(audit.entry.metadata, { listingId: LISTING, targetProvider: 'airbnb', scope: 'blocks_only' });
});

test('a create sent twice with one requestId (a double tap or a retry) makes one link, not two live tokens', async () => {
  const w = world();
  const requestId = 'a'.repeat(32);
  const first = await create(w, OWNER, { requestId });
  assert.equal(first.linkId, `xl_${requestId}`);
  assert.deepEqual(await create(w, OWNER, { requestId }), first);
  // Two taps racing each other land on the same link too.
  const [x, y] = await Promise.all([create(w, OWNER, { requestId: 'b'.repeat(32) }), create(w, OWNER, { requestId: 'b'.repeat(32) })]);
  assert.deepEqual(x, y);
  assert.equal(w.fake.list(P.links).length, 2);
  assert.equal(w.fake.list('stayCalendarExportTokens').length, 2);
  assert.equal(w.handle.audits.filter((a) => a.entry.eventType === 'stays.export_link.created').length, 2);
  // Each repeat showed the URL again, and is audited as a view.
  assert.equal(w.handle.audits.filter((a) => a.entry.eventType === 'stays.export_link.url_viewed').length, 2);
  // Two more fit under the limit of four: the repeats took no slot.
  await create(w);
  await create(w);
  assert.equal(await reasonOf(create(w)), 'limit_reached');

  // One requestId cannot name two different links, and a revoked link is not brought back.
  assert.equal(await reasonOf(create(w, OWNER, { requestId, targetProvider: 'vrbo' })), 'invalid_argument');
  await revokeExportLinkHandler({ facilityId: FAC, linkId: first.linkId }, callableContext(OWNER), w.handle.deps);
  assert.equal(await reasonOf(create(w, OWNER, { requestId })), 'not_found');
  assert.equal(await reasonOf(create(w, OWNER, { requestId: 'NOT-HEX' })), 'invalid_argument');
});

test('four links per listing at most; archived or unknown listings take none; staff cannot create them', async () => {
  const w = world();
  for (let i = 0; i < 4; i++) await create(w, OWNER, { targetProvider: i % 2 ? 'vrbo' : 'airbnb' });
  assert.equal(await reasonOf(create(w)), 'limit_reached');
  seedListing(w.fake, 'lst_old', { archived: true });
  assert.equal(await reasonOf(create(w, OWNER, { listingId: 'lst_old' })), 'listing_inactive');
  assert.equal(await reasonOf(create(w, OWNER, { listingId: 'lst_none' })), 'not_found');
  assert.equal(await reasonOf(create(w, EMPLOYEE)), 'role_not_allowed');
  assert.equal(await reasonOf(create(w, VIEWER)), 'role_not_allowed');
  assert.equal(await reasonOf(create(w, OWNER, { targetProvider: 'expedia' })), 'invalid_argument');
  assert.equal(await reasonOf(create(w, OWNER, { scope: 'everything' })), 'invalid_argument');
});

test('seeing the URL again is audited every time and limited to 30 an hour per person', async () => {
  const w = world();
  const { linkId, url } = await create(w);
  const again = await getExportUrlHandler({ facilityId: FAC, linkId }, callableContext(MANAGER), w.handle.deps);
  assert.equal(again.url, url);
  const viewed = w.handle.audits.filter((a) => a.entry.eventType === 'stays.export_link.url_viewed');
  assert.equal(viewed.length, 1);
  assert.equal(viewed[0].entry.actorUid, MANAGER);
  for (let i = 1; i < 30; i++) await getExportUrlHandler({ facilityId: FAC, linkId }, callableContext(MANAGER), w.handle.deps);
  assert.equal(await reasonOf(getExportUrlHandler({ facilityId: FAC, linkId }, callableContext(MANAGER), w.handle.deps)), 'rate_limited');
  assert.equal(await reasonOf(getExportUrlHandler({ facilityId: FAC, linkId }, callableContext(EMPLOYEE), w.handle.deps)), 'role_not_allowed');
});

test('changing the scope is audited; the label can change quietly', async () => {
  const w = world();
  const { linkId } = await create(w);
  const res = await updateExportLinkHandler({ facilityId: FAC, linkId, scope: 'sfc' }, callableContext(OWNER), w.handle.deps);
  assert.deepEqual(res, { linkId, scope: 'sfc', label: 'SFC to Airbnb' });
  const changed = w.handle.audits.filter((a) => a.entry.eventType === 'stays.export_link.scope_changed');
  assert.deepEqual(changed.map((a) => a.entry.metadata), [{ from: 'blocks_only', to: 'sfc' }]);
  await updateExportLinkHandler({ facilityId: FAC, linkId, label: 'Airbnb import' }, callableContext(OWNER), w.handle.deps);
  assert.equal(w.fake.read(`${P.links}/${linkId}`)?.label, 'Airbnb import');
  assert.equal(w.handle.audits.filter((a) => a.entry.eventType === 'stays.export_link.scope_changed').length, 1);
  assert.equal(await reasonOf(updateExportLinkHandler({ facilityId: FAC, linkId, scope: 'guests' }, callableContext(OWNER), w.handle.deps)), 'invalid_argument');
});

test('revoking kills the token at once; rotating also returns a new link to re-paste', async () => {
  const w = world();
  const { linkId, url } = await create(w, OWNER, { scope: 'sfc' });
  const token = URL_RE.exec(url)![1];

  const rotated = await revokeExportLinkHandler({ facilityId: FAC, linkId, rotate: true }, callableContext(OWNER), w.handle.deps);
  assert.equal(rotated.revoked, true);
  assert.ok(rotated.rotated);
  assert.notEqual(rotated.rotated!.linkId, linkId);
  assert.notEqual(rotated.rotated!.url, url);
  assert.deepEqual(rotated.warnings.map((x) => x.code), ['repaste_required']);
  assert.equal(w.fake.read(`stayCalendarExportTokens/${exportTokenHash(token)}`)?.active, false);
  assert.equal(w.fake.has(`${P.links}/${linkId}/secret/current`), false);
  assert.equal(w.fake.read(`${P.links}/${linkId}`)?.active, false);
  const fresh = w.fake.read(`${P.links}/${rotated.rotated!.linkId}`)!;
  assert.deepEqual([fresh.scope, fresh.targetProvider, fresh.active], ['sfc', 'airbnb', true]);
  assert.ok(fresh.rotatedAt);
  assert.ok(w.handle.audits.some((a) => a.entry.eventType === 'stays.export_link.rotated'));
  assert.equal(await reasonOf(getExportUrlHandler({ facilityId: FAC, linkId }, callableContext(OWNER), w.handle.deps)), 'not_found');

  const plain = await revokeExportLinkHandler({ facilityId: FAC, linkId: rotated.rotated!.linkId }, callableContext(MANAGER), w.handle.deps);
  assert.deepEqual([plain.revoked, plain.rotated, plain.warnings], [true, undefined, []]);
  assert.ok(w.handle.audits.some((a) => a.entry.eventType === 'stays.export_link.revoked'));
  // Revoking again is harmless; rotating a revoked link is not allowed.
  assert.equal((await revokeExportLinkHandler({ facilityId: FAC, linkId }, callableContext(OWNER), w.handle.deps)).revoked, true);
  assert.equal(await reasonOf(revokeExportLinkHandler({ facilityId: FAC, linkId, rotate: true }, callableContext(OWNER), w.handle.deps)), 'not_found');
});

test('isolation: export links never touched a storage collection', () => {
  for (const fake of all) fake.assertIsolation();
});
